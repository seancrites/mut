#!/bin/sh
#
# Script: mut_inv.sh
# Purpose: Builds a MikroTik inventory CSV or performs upgrades using neighbor data or existing CSV
# Author: Sean Crites
# Version: 1.1.10
# Created: 2025-05-18
# Last Updated: 2025-06-04
#
# Copyright (c) 2025 Sean Crites <sean.crites@gmail.com>
# See the BSD 3-Clause License in the repository root (LICENSE file) for details.
#
# Requirements:
#    - POSIX-compliant shell (e.g., sh, bash, or dash)
#    - POSIX utilities: awk, sed, read, stty, cat
#    - SSH client (OpenSSH recommended, version 7.0 or later)
#    - sshpass (version 1.06 or later)
#    - Expect (version 5.45 or later) for mut_up.exp
#    - ping for host reachability checks
#    - SSH access to MikroTik devices (port 22, admin privileges)
#    - Write permissions for CSV output (current directory, $HOME, BACKUP_DIR, LOGS_DIR)
#    - Optional: Configuration file (mut_opt.conf)
#    - Environment: Linux or UNIX-like system
# Notes:
#    - Warnings may include:
#        - "No valid neighbors found in output" for empty neighbor data.
#        - "No hosts match filter criteria (routable IPv4 or IPv6)" for no routable IPs.
#        - "Host <host> is not reachable, skipping upgrade" for unreachable hosts.
#
# Usage: mut_inv.sh [-b [-c csv_file] | -u [-c csv_file] [-f filter] [-r version]] [-d] [-e] [-t] [-l] [-o options_file] [<host>]
# Notes:
#    - Build mode (-b): Builds CSV from <host> neighbor data. With -c csv_file, saves to specified path or current directory if writable, else $HOME; without -c, outputs to console.
#    - Upgrade mode (-u):
#        - Without -c: Upgrades <host> directly (no CSV, <host> required).
#        - With -c: Upgrades hosts from existing csv_file (at specified path, current directory, or $HOME) matching -f filter (no <host>, -f required).
#    - Filter (-f) matches model_name first, then identity (alphanumeric, case-insensitive).
#    - Version (-r version): Specifies RouterOS version (N.NN or N.NN.N). N.NN selects highest fix in os/vN.NN; N.NN.N selects exact version.
#    - Debug mode (-d) enables debug output, logs all commands and responses, and passes -d to mut_up.exp.
#    - Enhanced logging (-e) logs MikroTik commands to CLI (requires -b or -u; with -d, -e is ignored as -d includes command logging).
#    - Test mode (-t) simulates upgrades using -t flag in mut_up.exp.
#    - Log mode (-l) enables logging to LOGS_DIR and displays output to user.
#    - Non-POSIX utilities: ssh, sshpass, expect, ping, getent, host
#

# --- Default Configuration Variables ---
SCRIPT_DIR=$(dirname "$0")
ROS_IMAGE_DIR="$SCRIPT_DIR/os"
BACKUP_DIR="$SCRIPT_DIR/backups"
LOGS_DIR="$SCRIPT_DIR/logs"
EXPECT_SCRIPT="$SCRIPT_DIR/mut_up.exp"
SSH_TIMEOUT="${SSH_TIMEOUT:=30}"
USERNAME=""
PASSWORD=""
MTIK_CLI="${MTIK_CLI:=+tce200w}"
DEBUG=0
ENHANCED_LOGGING=0
SUPPRESS_CSV=0
TEST_MODE=0
LOGGING=0
FILTER=""
ROS_VERSION=""

# WARNING: If CLEANUP is disabled, temporary files, including MikroTik credentials, may get stored locally in /tmp.
CLEANUP=1

# Catch EXIT, INT, TERM, HUP to ensure cleanup of credentials file
trap cleanup 0 1 2 15

# --- Functions ---

# Print usage and exit
usage()
{
   echo "Usage: $0 [-b [-c csv_file] | -u [-c csv_file] [-f filter] [-r version]] [-d] [-e] [-t] [-l] [-o options_file] [<host>]"
   echo "Options:"
   echo "   -b             Build inventory CSV (no upgrades)"
   echo "   -u             Upgrade mode: upgrade host or filtered CSV hosts"
   echo "   -c csv_file    Write CSV to specified path, current directory if writable, or $HOME (build mode); read existing CSV from same locations (upgrade mode)"
   echo "   -d             Enable debug output and pass to expect script"
   echo "   -e             Enable enhanced logging of MikroTik commands (with -d, -e is ignored)"
   echo "   -t             Enable test mode (simulates upgrades using -t in expect script)"
   echo "   -l             Enable logging to LOGS_DIR and display output"
   echo "   -f filter      Filter hosts to upgrade by model_name or identity (alphanumeric, requires -u and -c)"
   echo "   -r version     Specify RouterOS version (e.g., 7.18 or 7.18.2) for upgrades (requires -u)"
   echo "   -o options_file   Source variables from options file (default: mut_opt.conf)"
   echo "Notes:"
   echo "   - In build mode (-b) without -c, <host> is required, csv_file is optional, output to console."
   echo "   - In build mode (-b) with -c, <host> and csv_file are required."
   echo "   - In upgrade mode (-u) without -c, <host> is required and upgraded directly."
   echo "   - In upgrade mode (-u) with -c, no <host>, -f is required, upgrades filtered CSV hosts."
   echo "   - Version (-r): N.NN selects highest fix in os/vN.NN; N.NN.N selects exact version."
   exit 1
}

# Log message with timestamp
log_msg()
{
   if [ "$LOGGING" -eq 1 ]
   then
      printf "[%s]: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$1" | tee -a "$LOG_FILE" >&2
   else
      printf "[%s]: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >&2
   fi
}

# Check if host is reachable
check_host_reachable()
{
   host="$1"
   # Use ping with 2 attempts and a 2-second timeout per attempt
   if ping -c 2 -W 2 "$host" >/dev/null 2>&1
   then
      [ "$DEBUG" -eq 1 ] && log_msg "Debug: Host $host is reachable"
      return 0
   else
      log_msg "WARNING: Host $host is not reachable, skipping upgrade"
      return 1
   fi
}

# Validate RouterOS version format
validate_ros_version()
{
   version="$1"
   if ! echo "$version" | grep -qE '^[0-9]+\.[0-9]+(\.[0-9]+)?$'
   then
      log_msg "ERROR: Invalid RouterOS version format: $version (expected N.NN or N.NN.N)"
      exit 1
   fi
}

# Resolve CSV path for reading or writing
resolve_csv_path()
{
   csv_file="$1"
   mode="$2" # "read" or "write"
   case "$csv_file" in
      */*)
         csv_path="$csv_file"
         csv_dir=$(dirname "$csv_path")
         if [ ! -d "$csv_dir" ]
         then
            log_msg "ERROR: Directory $csv_dir does not exist"
            exit 1
         fi
         if [ "$mode" = "write" ] && [ ! -w "$csv_dir" ]
         then
            log_msg "ERROR: Directory $csv_dir is not writable"
            exit 1
         fi
         ;;
      *)
         csv_path="./$csv_file"
         if [ "$mode" = "write" ] && [ ! -w . ]
         then
            log_msg "WARNING: Current directory not writable, falling back to $HOME"
            csv_path="$HOME/$csv_file"
            if [ ! -w "$HOME" ]
            then
               log_msg "ERROR: $HOME is not writable"
               exit 1
            fi
         elif [ "$mode" = "read" ] && { [ ! -f "$csv_path" ] || [ ! -r "$csv_path" ]; }
         then
            log_msg "WARNING: CSV $csv_path not found or not readable, trying $HOME"
            csv_path="$HOME/$csv_file"
         fi
         ;;
   esac
   if [ "$mode" = "read" ]
   then
      if [ ! -f "$csv_path" ]
      then
         log_msg "ERROR: CSV file $csv_path does not exist"
         exit 1
      fi
      if [ ! -r "$csv_path" ]
      then
         log_msg "ERROR: CSV file $csv_path is not readable"
         exit 1
      fi
   fi
   echo "$csv_path"
}

# Perform pre-flight checks
preflight_checks()
{
   for cmd in awk sed ssh sshpass expect read stty cat ping
   do
      if ! command -v "$cmd" >/dev/null 2>&1
      then
         log_msg "ERROR: Required command '$cmd' not found in PATH"
         exit 1
      fi
   done
   if [ "$DEBUG" -eq 1 ]
   then
      ssh_version=$(ssh -V 2>&1 | head -n 1)
      sshpass_version=$(sshpass -V 2>&1 | grep -o '[0-9]\.[0-9]\+' || echo "unknown")
      expect_version=$(expect -v 2>&1 | grep -o '[0-9]\.[0-9]\+' || echo "unknown")
      awk_version=$(awk -W version 2>&1 | head -n 1 || awk --version 2>&1 | head -n 1 || echo "unknown")
      ping_version=$(ping -V 2>&1 | head -n 1 || echo "unknown")
      log_msg "Pre-flight: SSH version: $ssh_version"
      log_msg "Pre-flight: sshpass version: $sshpass_version"
      log_msg "Pre-flight: Expect version: $expect_version"
      log_msg "Pre-flight: awk version: $awk_version"
      log_msg "Pre-flight: ping version: $ping_version"
   fi
   if [ ! -d "$ROS_IMAGE_DIR" ]
   then
      log_msg "ERROR: ROS_IMAGE_DIR $ROS_IMAGE_DIR does not exist"
      exit 1
   fi
   if [ ! -d "$BACKUP_DIR" ]
   then
      log_msg "ERROR: BACKUP_DIR $BACKUP_DIR does not exist"
      exit 1
   fi
   if [ ! -w "$BACKUP_DIR" ]
   then
      log_msg "ERROR: BACKUP_DIR $BACKUP_DIR is not writable"
      exit 1
   fi
   if [ "$LOGGING" -eq 1 ]
   then
      if [ ! -d "$LOGS_DIR" ]
      then
         mkdir -p "$LOGS_DIR" || { log_msg "ERROR: Cannot create LOGS_DIR $LOGS_DIR"; exit 1; }
      fi
      if [ ! -w "$LOGS_DIR" ]
      then
         log_msg "ERROR: LOGS_DIR $LOGS_DIR is not writable"
         exit 1
      fi
   fi
   if [ ! -f "$EXPECT_SCRIPT" ]
   then
      log_msg "ERROR: EXPECT_SCRIPT $EXPECT_SCRIPT does not exist"
      exit 1
   fi
   if [ ! -r "$EXPECT_SCRIPT" ]
   then
      log_msg "ERROR: EXPECT_SCRIPT $EXPECT_SCRIPT is not readable"
      exit 1
   fi
   if [ -z "$SSH_TIMEOUT" ] || [ -n "${SSH_TIMEOUT##*[0-9]*}" ] || [ "$SSH_TIMEOUT" = "0" ]
   then
      log_msg "ERROR: SSH_TIMEOUT must be a positive number"
      exit 1
   fi
   # Check if expect script supports -t, -d, -e, -l, and -r
   if [ "$TEST_MODE" -eq 1 ]
   then
      if ! expect -f "$EXPECT_SCRIPT" --help 2>&1 | grep -q -- -t
      then
         log_msg "ERROR: $EXPECT_SCRIPT does not support -t option for test mode"
         exit 1
      fi
   fi
   if [ "$DEBUG" -eq 1 ]
   then
      if ! expect -f "$EXPECT_SCRIPT" --help 2>&1 | grep -q -- -d
      then
         log_msg "ERROR: $EXPECT_SCRIPT does not support -d option for debug mode"
         exit 1
      fi
   fi
   if [ "$ENHANCED_LOGGING" -eq 1 ]
   then
      if ! expect -f "$EXPECT_SCRIPT" --help 2>&1 | grep -q -- -e
      then
         log_msg "ERROR: $EXPECT_SCRIPT does not support -e option for enhanced logging"
         exit 1
      fi
   fi
   if [ "$LOGGING" -eq 1 ]
   then
      if ! expect -f "$EXPECT_SCRIPT" --help 2>&1 | grep -q -- -l
      then
         log_msg "ERROR: $EXPECT_SCRIPT does not support -l option for logging"
         exit 1
      fi
   fi
   if [ -n "$ROS_VERSION" ]
   then
      if ! expect -f "$EXPECT_SCRIPT" --help 2>&1 | grep -q -- -r
      then
         log_msg "ERROR: $EXPECT_SCRIPT does not support -r option for version specification"
         exit 1
      fi
   fi
   log_msg "Pre-flight checks passed"
}

# Prompt for credentials once and store
prompt_credentials()
{
   if [ -n "$USERNAME" ] && [ -n "$PASSWORD" ]
   then
      # Credentials already set, reuse them
      log_msg "Reusing stored credentials for $USERNAME"
      CRED_FILE="/tmp/mikrotik_cred_$$.txt"
      echo "username=$USERNAME" > "$CRED_FILE"
      echo "password=$PASSWORD" >> "$CRED_FILE"
      chmod 600 "$CRED_FILE"
      return
   fi
   printf "Enter MikroTik username: "
   read -r USERNAME
   if [ -z "$USERNAME" ]
   then
      log_msg "ERROR: Username cannot be empty"
      exit 1
   fi
   USERNAME_MTIK="${USERNAME}${MTIK_CLI}"
   printf "Enter MikroTik password: "
   # Check if stdin is a terminal before using stty
   if [ -t 0 ]
   then
      stty -echo
      read -r PASSWORD
      stty echo
      echo
   else
      log_msg "WARNING: Non-interactive terminal detected, attempting password read without stty"
      read -r PASSWORD
      echo
   fi
   if [ -z "$PASSWORD" ]
   then
      log_msg "ERROR: Password cannot be empty"
      exit 1
   fi
   CRED_FILE="/tmp/mikrotik_cred_$$.txt"
   echo "username=$USERNAME_MTIK" > "$CRED_FILE"
   echo "password=$PASSWORD" >> "$CRED_FILE"
   chmod 600 "$CRED_FILE"
}

# Source options file with tilde and variable expansion
source_options()
{
   options_file="$1"
   if [ ! -f "$options_file" ]
   then
      log_msg "ERROR: Options file $options_file does not exist"
      exit 1
   fi
   if [ ! -r "$options_file" ]
   then
      log_msg "ERROR: Options file $options_file is not readable"
      exit 1
   fi
   log_msg "Sourcing options from $options_file"
   while IFS='=' read -r key value
   do
      case "$key" in
         ''|\#*) continue ;;
      esac
      value=$(echo "$value" | sed 's/^[ \t]*//;s/[ \t]*$//')
      # Expand ~ to $HOME and $PWD to current directory
      value=$(echo "$value" | sed "s|^~|$HOME|;s|\$PWD|$PWD|")
      case "$key" in
         ROS_IMAGE_DIR|BACKUP_DIR|LOGS_DIR|EXPECT_SCRIPT|SSH_TIMEOUT)
            eval "$key=\"$value\""
            log_msg "Set $key=$value"
            ;;
         *)
            log_msg "Ignoring unknown option: $key"
            ;;
      esac
   done < "$options_file"
}

# Confirm file overwrite
confirm_overwrite()
{
   file="$1"
   if [ -f "$file" ]
   then
      printf "File %s exists. Overwrite? [y/N]: " "$file"
      read -r answer
      case "$answer" in
         [Yy]*) return 0 ;;
         *) log_msg "Aborted by user"; exit 1 ;;
      esac
   fi
}

# Resolve hostname or IP to IP address for ip_addr field
resolve_host_to_ip()
{
   host="$1"
   # If host is already an IP (IPv4 or IPv6), return it
   if echo "$host" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$|^([0-9a-fA-F]{1,4}:){1,7}[0-9a-fA-F]{1,4}$'
   then
      echo "$host"
      return 0
   fi
   # Try to resolve hostname using getent (POSIX-compliant, fallback to host command)
   ip_addr=$(getent ahosts "$host" 2>/dev/null | awk '/^[0-9a-fA-F.:]+/ {print $1; exit}' || host "$host" 2>/dev/null | awk '/has address/ {print $4; exit}')
   if [ -z "$ip_addr" ]
   then
      log_msg "ERROR: Cannot resolve hostname $host to IP address"
      exit 1
   fi
   echo "$ip_addr"
}

# Execute SSH command
ssh_exec()
{
   host="$1"
   cmd="$2"
   fatal="$3" # Optional flag to suppress error exit (1=fatal, 0=non-fatal)
   if [ -z "$fatal" ]
   then
      fatal=1
   fi
   if [ -z "$USERNAME_MTIK" ] || [ -z "$PASSWORD" ]
   then
      log_msg "ERROR: Username or password not set for SSH to $host"
      exit 1
   fi
   # Log command only if enhanced logging (-e) or debug (-d) is enabled
   if [ "$ENHANCED_LOGGING" -eq 1 ] || [ "$DEBUG" -eq 1 ]
   then
      log_msg "CMD> $cmd"
   fi
   # Capture output and exit status, allow non-fatal failures
   output=$(SSHPASS="$PASSWORD" sshpass -e ssh -o ConnectTimeout="$SSH_TIMEOUT" -o StrictHostKeyChecking=no "$USERNAME_MTIK@$host" "$cmd" 2>/dev/null)
   status=$?
   if [ "$status" -ne 0 ] && [ "$fatal" -eq 1 ]
   then
      log_msg "ERROR: SSH command failed on $USERNAME_MTIK@$host"
      exit 1
   fi
   echo "$output"
   return "$status"
}

# Validate MAC address format (XX:XX:XX:XX:XX:XX)
is_valid_mac()
{
   mac="$1"
   # Check for 6 colon-separated hex pairs
   if echo "$mac" | grep -qE '^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$'
   then
      return 0
   else
      return 1
   fi
}

# Parse neighbor data to CSV
parse_neighbors()
{
   raw_data="$1"
   self_data="$2" # Connected device data (CSV row)
   if [ -z "$raw_data" ] && [ -z "$self_data" ]
   then
      log_msg "WARNING: No valid neighbors or self data found"
      echo "identity,ip_addr,mac_addr,interface,platform,model_name,version,mut_status"
      return
   fi
   tmp_output="/tmp/mikrotik_neighbors_$$.csv"
   {
      echo "identity,ip_addr,mac_addr,interface,platform,model_name,version,mut_status"
      # Output connected device data first, if provided
      if [ -n "$self_data" ]
      then
         echo "$self_data"
         [ "$DEBUG" -eq 1 ] && log_msg "Debug: Added connected device to CSV: $self_data"
      fi
      # Process neighbor data if present
      if [ -n "$raw_data" ] && echo "$raw_data" | grep -q '.id='
      then
         echo "$raw_data" | awk -v debug="$DEBUG" '
            BEGIN {
               RS=";"; FS="="; OFS=",";
               identity=""; ip_addr=""; mac_addr=""; iface=""; platform="MikroTik"; model=""; version=""; mut_status=""
               count=0
            }
            /.id=/ {
               if (identity != "" && ip_addr != "") {
                  if (debug) print "Debug: Processing entry: identity=" identity ", ip_addr=" ip_addr ", mac_addr=" mac_addr > "/dev/stderr"
                  if (ip_addr !~ /^fe80::/ && (ip_addr ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ || ip_addr ~ /^([0-9a-fA-F]{1,4}:){1,7}[0-9a-fA-F]{1,4}$/)) {
                     identity_esc=identity; gsub(/"/, "\"\"", identity_esc)
                     ip_addr_esc=ip_addr; gsub(/"/, "\"\"", ip_addr_esc)
                     mac_addr_esc=mac_addr; gsub(/"/, "\"\"", mac_addr_esc)
                     iface_esc=iface; gsub(/"/, "\"\"", iface_esc)
                     platform_esc=platform; gsub(/"/, "\"\"", platform_esc)
                     model_esc=model; gsub(/"/, "\"\"", model_esc)
                     version_esc=version; gsub(/"/, "\"\"", version_esc)
                     mut_status_esc=mut_status; gsub(/"/, "\"\"", mut_status_esc)
                     printf "\"%s\",\"%s\",\"%s\",\"%s\",\"%s\",\"%s\",\"%s\",\"%s\"\n",
                            identity_esc, ip_addr_esc, mac_addr_esc, iface_esc,
                            platform_esc, model_esc, version_esc, mut_status_esc
                     if (debug) print "Discovered: " identity " (" ip_addr ")" > "/dev/stderr"
                     count++
                  } else {
                     if (debug) print "Skipping entry: identity=" identity " (ip_addr=" ip_addr ", mac_addr=" mac_addr ")" > "/dev/stderr"
                  }
               } else if (identity != "") {
                  if (debug) print "Skipping entry: identity=" identity " (ip_addr=" ip_addr ", mac_addr=" mac_addr ")" > "/dev/stderr"
               }
               identity=""; ip_addr=""; mac_addr=""; iface=""; platform="MikroTik"; model=""; version=""; mut_status=""
            }
            /^address=/ { ip_addr=$2; if (debug) print "Debug: Set ip_addr=" ip_addr > "/dev/stderr" }
            /^mac-address=/ { mac_addr=$2; if (debug) print "Debug: Set mac_addr=" mac_addr > "/dev/stderr" }
            /^identity=/ { identity=$2 }
            /^interface=/ { iface=$2 }
            /^board=/ { model=$2 }
            /^version=/ {
               version=$2;
               sub(/ \(.*/, "", version)
            }
            END {
               if (identity != "" && ip_addr != "") {
                  if (debug) print "Debug: Processing final entry: identity=" identity ", ip_addr=" ip_addr ", mac_addr=" mac_addr > "/dev/stderr"
                  if (ip_addr !~ /^fe80::/ && (ip_addr ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ || ip_addr ~ /^([0-9a-fA-F]{1,4}:){1,7}[0-9a-fA-F]{1,4}$/)) {
                     identity_esc=identity; gsub(/"/, "\"\"", identity_esc)
                     ip_addr_esc=ip_addr; gsub(/"/, "\"\"", ip_addr_esc)
                     mac_addr_esc=mac_addr; gsub(/"/, "\"\"", mac_addr_esc)
                     iface_esc=iface; gsub(/"/, "\"\"", iface_esc)
                     platform_esc=platform; gsub(/"/, "\"\"", platform_esc)
                     model_esc=model; gsub(/"/, "\"\"", model_esc)
                     version_esc=version; gsub(/"/, "\"\"", version_esc)
                     mut_status_esc=mut_status; gsub(/"/, "\"\"", mut_status_esc)
                     printf "\"%s\",\"%s\",\"%s\",\"%s\",\"%s\",\"%s\",\"%s\",\"%s\"\n",
                            identity_esc, ip_addr_esc, mac_addr_esc, iface_esc,
                            platform_esc, model_esc, version_esc, mut_status_esc
                     if (debug) print "Discovered: " identity " (" ip_addr ")" > "/dev/stderr"
                     count++
                  } else {
                     if (debug) print "Skipping entry: identity=" identity " (ip_addr=" ip_addr ", mac_addr=" mac_addr ")" > "/dev/stderr"
                  }
               } else if (identity != "") {
                  if (debug) print "Skipping entry: identity=" identity " (ip_addr=" ip_addr ", mac_addr=" mac_addr ")" > "/dev/stderr"
               }
            }
         '
      fi
   } > "$tmp_output"
   cat "$tmp_output"
   neighbor_count=$(awk 'NR>1' "$tmp_output" | wc -l)
   neighbor_count=$((neighbor_count))
   log_msg "Processed $neighbor_count device(s) to CSV"
   if [ "$neighbor_count" -eq 0 ]
   then
      log_msg "WARNING: No hosts match filter criteria (routable IPv4 or IPv6 address)"
   fi
   rm -f "$tmp_output"
}

# Build inventory CSV
build_inventory()
{
   host="$1"
   csv_file="$2"
   log_msg "Building inventory for $host"
   # Check if host is reachable before SSH commands
   if ! check_host_reachable "$host"
   then
      log_msg "ERROR: Host $host is not reachable, cannot build inventory"
      exit 1
   fi
   # Resolve host to IP address for ip_addr
   ip_addr=$(resolve_host_to_ip "$host")
   [ "$DEBUG" -eq 1 ] && log_msg "Debug: Resolved host $host to IP $ip_addr"
   # Collect connected device data
   identity=$(ssh_exec "$host" ":put [/system/identity/print as-value]" | awk -F'=' '/name=/ {print $2}' | sed -e 's/\r$//g')
   model_name=$(ssh_exec "$host" ":put [/system/routerboard/get model]" | sed -e 's/\r$//g')
   version=$(ssh_exec "$host" ":put [/system/routerboard/get current-firmware]" | sed -e 's/\r$//g')
   # Try Ethernet then VLAN for mac_addr
   mac_addr=""
   # Try Ethernet interface
   ethernet_cmd=":put [/interface/ethernet/get value-name=mac-address [find where name=[/ip/address/get value-name=interface [find where address~\"$ip_addr\"]]]]"
   if mac_addr=$(ssh_exec "$host" "$ethernet_cmd" 0 | sed -n 's/\r$//; /^[0-9A-Fa-f]\{2\}:[0-9A-Fa-f]\{2\}:[0-9A-Fa-f]\{2\}:[0-9A-Fa-f]\{2\}:[0-9A-Fa-f]\{2\}:[0-9A-Fa-f]\{2\}$/p') && is_valid_mac "$mac_addr"
   then
      [ "$DEBUG" -eq 1 ] && log_msg "Debug: Found MAC address via Ethernet interface: $mac_addr"
   else
      # Try VLAN interface
      vlan_cmd=":put [/interface/vlan/get value-name=mac-address [find where name=[/ip/address/get value-name=interface [find where address~\"$ip_addr\"]]]]"
      if mac_addr=$(ssh_exec "$host" "$vlan_cmd" 0 | sed -n 's/\r$//; /^[0-9A-Fa-f]\{2\}:[0-9A-Fa-f]\{2\}:[0-9A-Fa-f]\{2\}:[0-9A-Fa-f]\{2\}:[0-9A-Fa-f]\{2\}:[0-9A-Fa-f]\{2\}$/p') && is_valid_mac "$mac_addr"
      then
         [ "$DEBUG" -eq 1 ] && log_msg "Debug: Found MAC address via VLAN interface: $mac_addr"
      else
         mac_addr=""
         [ "$DEBUG" -eq 1 ] && log_msg "Debug: Failed to retrieve MAC address for $ip_addr"
      fi
   fi
   # Validate collected data
   if [ -z "$identity" ] || [ -z "$model_name" ] || [ -z "$version" ] || [ -z "$ip_addr" ] || [ -z "$mac_addr" ]
   then
      log_msg "ERROR: Failed to collect complete data for $host (identity=$identity, model=$model_name, version=$version, ip=$ip_addr, mac=$mac_addr)"
      exit 1
   fi
   # Format connected device data as CSV row
   self_data="\"$identity\",\"$ip_addr\",\"$mac_addr\",\"self\",\"MikroTik\",\"$model_name\",\"$version\",\"\""
   [ "$DEBUG" -eq 1 ] && log_msg "Debug: Connected device data: $self_data"
   # Collect neighbor data
   raw_data=$(ssh_exec "$host" ":put [/ip/neighbor/print as-value]")
   if [ -z "$raw_data" ]
   then
      log_msg "WARNING: Empty output from :put [/ip/neighbor/print as-value], including only connected device"
   fi
   # Check for completely empty data
   if [ -z "$self_data" ] && [ -z "$raw_data" ]
   then
      log_msg "ERROR: No valid data collected for $host (self_data and neighbor data empty)"
      exit 1
   fi
   log_msg "Parsing neighbor data"
   if [ "$SUPPRESS_CSV" -eq 1 ]
   then
      csv_path=$(resolve_csv_path "$csv_file" "write")
      confirm_overwrite "$csv_path"
      parse_neighbors "$raw_data" "$self_data" > "$csv_path"
      log_msg "Inventory saved to $csv_path"
   else
      parse_neighbors "$raw_data" "$self_data"
      log_msg "Inventory output to console"
   fi
}

# Remove temporary files on exit or interrupt
cleanup()
{
   if [ "$CLEANUP" -eq 1 ]
   then
      if [ -n "$CRED_FILE" ] && [ -f "$CRED_FILE" ]
      then
         rm -f "$CRED_FILE" 2>/dev/null
         [ "$DEBUG" -eq 1 ] && log_msg "Debug: Removed temporary credentials file $CRED_FILE"
      fi
      if [ -n "$tmp_hosts" ] && [ -f "$tmp_hosts" ]
      then
         rm -f "$tmp_hosts" 2>/dev/null
         [ "$DEBUG" -eq 1 ] && log_msg "Debug: Removed temporary MikroTik hosts file $tmp_hosts"
      fi
      if [ -n "$tmp_csv" ] && [ -f "$tmp_csv" ]
      then
         rm -f "$tmp_csv" 2>/dev/null
         [ "$DEBUG" -eq 1 ] && log_msg "Debug: Removed temporary MikroTik CSV file $tmp_csv"
      fi
   fi
}

# Filter hosts from CSV, removing duplicates
filter_hosts()
{
   csv_file="$1"
   filter="$2"
   csv_path=$(resolve_csv_path "$csv_file" "read")
   tmp_hosts="/tmp/mikrotik_hosts_$$.txt"
   awk -F',' -v filter="$filter" '
      BEGIN {
         OFS=","; count=0
      }
      NR==1 { next }
      {
         model_name=tolower(gsub(/^"|"$/,"",$6))
         identity=tolower(gsub(/^"|"$/,"",$1))
         if ((tolower($6) ~ tolower(filter) || tolower($1) ~ tolower(filter)) && !seen[$1]++) {
            print $1,$6; count++
         }
      }
      END {
         if (count == 0) {
            print "No hosts matched filter \"" filter "\"" > "/dev/stderr"
         }
      }
   ' "$csv_path" > "$tmp_hosts"
   if [ ! -s "$tmp_hosts" ]
   then
      log_msg "ERROR: No hosts found in $csv_path matching filter '$filter'"
      rm -f "$tmp_hosts"
      exit 1
   fi
   log_msg "Hosts matched by filter '$filter':"
   while IFS=',' read -r identity model_name
   do
      log_msg "  Identity: $identity, Model: $model_name"
   done < "$tmp_hosts"
   echo "$tmp_hosts,$csv_path"
}

# Confirm upgrades
confirm_upgrades()
{
   hosts_file="$1"
   host_count=$(wc -l < "$hosts_file")
   if [ "$TEST_MODE" -eq 1 ]
   then
      printf "Simulate upgrades for %d host(s)? [y/N]: " "$host_count"
   else
      printf "Perform upgrades for %d host(s)? [y/N]: " "$host_count"
   fi
   read -r answer
   case "$answer" in
      [Yy]*) return 0 ;;
      *) log_msg "Upgrades aborted by user"; rm -f "$hosts_file"; exit 0 ;;
   esac
}

# Run upgrade on a single host
run_upgrade()
{
   host="$1"
   csv_path="$2"
   log_msg "Starting Upgrade Process on $host"
   # Check if host is reachable
   if ! check_host_reachable "$host"
   then
      # Update CSV if provided and not in test mode
      if [ -n "$csv_path" ] && [ "$TEST_MODE" -eq 0 ]
      then
         if [ -f "$csv_path" ]
         then
            tmp_csv="/tmp/mikrotik_csv_$$.csv"
            timestamp=$(date '+%Y-%m-%d %H:%M:%S %z')
            awk -F',' -v host="\"$host\"" -v status="\"FAILED: Ping Fail $timestamp\"" -v OFS=',' '
               $1 == host {$8 = status; print $0}
               $1 != host {print $0}
            ' "$csv_path" > "$tmp_csv" && mv "$tmp_csv" "$csv_path"
            log_msg "Updated CSV $csv_path: $host marked as FAILED"
         fi
      fi
      log_msg ""
      return 0
   fi
   # Update CSV to PENDING if provided and not in test mode
   if [ -n "$csv_path" ] && [ "$TEST_MODE" -eq 0 ]
   then
      if [ -f "$csv_path" ]
      then
         tmp_csv="/tmp/mikrotik_csv_$$.csv"
         awk -F',' -v host="\"$host\"" -v status="\"PENDING\"" -v OFS=',' '
            $1 == host {$8 = status; print $0}
            $1 != host {print $0}
         ' "$csv_path" > "$tmp_csv" && mv "$tmp_csv" "$csv_path"
         log_msg "Updated CSV $csv_path: $host marked as PENDING"
      fi
   fi
   log_msg "Running upgrade on $host"
   # Build expect command
   expect_cmd="expect -f \"$EXPECT_SCRIPT\" --"
   if [ "$TEST_MODE" -eq 1 ]
   then
      expect_cmd="$expect_cmd -t"
   fi
   if [ "$DEBUG" -eq 1 ]
   then
      expect_cmd="$expect_cmd -d"
   fi
   if [ "$ENHANCED_LOGGING" -eq 1 ]
   then
      expect_cmd="$expect_cmd -e"
   fi
   if [ "$LOGGING" -eq 1 ]
   then
      expect_cmd="$expect_cmd -l"
   fi
   if [ -n "$ROS_VERSION" ]
   then
      expect_cmd="$expect_cmd -r \"$ROS_VERSION\""
   fi
   # Use absolute path for ROS_IMAGE_DIR
   expect_cmd="$expect_cmd \"$host\" \"$BACKUP_DIR\" \"$ROS_IMAGE_DIR\" \"$CRED_FILE\""
   if [ "$DEBUG" -eq 1 ]
   then
      log_msg "Executing: $expect_cmd"
   fi
   if [ "$LOGGING" -eq 1 ]
   then
      # Run expect in a subshell, capture exit status, and pipe output to tee
      (eval "$expect_cmd 2>&1"; echo $? > /tmp/mut_exit_$$.tmp) | tee -a "$LOG_FILE"
      status=$(cat /tmp/mut_exit_$$.tmp)
      rm -f /tmp/mut_exit_$$.tmp
   else
      eval "$expect_cmd"
      status=$?
   fi
   # Update CSV based on upgrade result if provided and not in test mode
   if [ -n "$csv_path" ] && [ "$TEST_MODE" -eq 0 ]
   then
      if [ -f "$csv_path" ]
      then
         tmp_csv="/tmp/mikrotik_csv_$$.csv"
         timestamp=$(date '+%Y-%m-%d %H:%M:%S %z')
         if [ "$status" -eq 0 ]
         then
            new_status="\"SUCCESS: Updated to v$ROS_VERSION $timestamp\""
            awk -F',' -v host="\"$host\"" -v status="$new_status" -v ver="\"$ROS_VERSION\"" -v OFS=',' '
               $1 == host {$7 = ver; $8 = status; print $0}
               $1 != host {print $0}
            ' "$csv_path" > "$tmp_csv" && mv "$tmp_csv" "$csv_path"
            log_msg "Updated CSV $csv_path: $host marked as SUCCESS"
         else
            case $status in
               1)
                  new_status="\"FAILED: Invalid credentials $timestamp\""
                  ;;
               2)
                  new_status="\"FAILED: SSH timeout $timestamp\""
                  ;;
               3)
                  new_status="\"FAILED: Connection refused $timestamp\""
                  ;;
               4)
                  new_status="\"FAILED: SSH connection failed $timestamp\""
                  ;;
               *)
                  new_status="\"FAILED: Unknown error (code $status) $timestamp\""
                  ;;
            esac
            awk -F',' -v host="\"$host\"" -v status="$new_status" -v OFS=',' '
               $1 == host {$8 = status; print $0}
               $1 != host {print $0}
            ' "$csv_path" > "$tmp_csv" && mv "$tmp_csv" "$csv_path"
            log_msg "Updated CSV $csv_path: $host marked as FAILED"
         fi
      fi
   fi
   rm -f "$CRED_FILE"
   if [ "$status" -eq 0 ]
   then
      if [ "$TEST_MODE" -eq 1 ]
      then
         log_msg "Firmware update successful for $host (simulated)"
      else
         log_msg "Firmware update successful for $host"
      fi
   else
      log_msg "Firmware update failed for $host ($status)"
      return 1
   fi
   log_msg ""
}

# Main function
main()
{
   options_file=""
   mode=""
   csv_file=""
   while [ $# -gt 0 ]
   do
      case "$1" in
         -b|-u)
            if [ -n "$mode" ]
            then
               usage
            fi
            mode="$1"
            shift
            ;;
         -c)
            if [ $# -lt 2 ]
            then
               usage
            fi
            SUPPRESS_CSV=1
            csv_file="$2"
            shift 2
            ;;
         -d)
            DEBUG=1
            shift
            ;;
         -e)
            ENHANCED_LOGGING=1
            # Debug log to confirm -e is parsed
            [ "$DEBUG" -eq 1 ] && log_msg "Debug: Enabled enhanced logging"
            shift
            ;;
         -t)
            TEST_MODE=1
            shift
            ;;
         -l)
            LOGGING=1
            shift
            ;;
         -f)
            if [ $# -lt 2 ]
            then
               usage
            fi
            FILTER="$2"
            shift 2
            ;;
         -r)
            if [ $# -lt 2 ]
            then
               usage
            fi
            ROS_VERSION="$2"
            shift 2
            ;;
         -o)
            if [ $# -lt 2 ]
            then
               usage
            fi
            options_file="$2"
            shift 2
            ;;
         *)
            break
            ;;
      esac
   done
   # Validate RouterOS version if provided
   if [ -n "$ROS_VERSION" ]
   then
      validate_ros_version "$ROS_VERSION"
   fi
   # Set up logging if enabled
   if [ "$LOGGING" -eq 1 ]
   then
      LOG_FILE="$LOGS_DIR/mut_inventory_$(date +%Y%m%d_%H%M%S).log"
      touch "$LOG_FILE" 2>/dev/null || { log_msg "ERROR: Cannot create log file $LOG_FILE"; exit 1; }
      log_msg "Logging enabled: Output will be saved to $LOG_FILE"
   fi
   # Validate arguments
   if [ -z "$mode" ]
   then
      usage
   fi
   if [ "$mode" = "-b" ]
   then
      if [ "$SUPPRESS_CSV" -eq 1 ]
      then
         if [ $# -ne 1 ] || [ -z "$csv_file" ]
         then
            usage
         fi
      else
         if [ $# -lt 1 ] || [ $# -gt 1 ]
         then
            usage
         fi
      fi
   elif [ "$mode" = "-u" ]
   then
      if [ "$SUPPRESS_CSV" -eq 1 ]
      then
         if [ $# -ne 0 ] || [ -z "$csv_file" ] || [ -z "$FILTER" ]
         then
            usage
         fi
      else
         if [ $# -ne 1 ] || [ -n "$FILTER" ]
         then
            usage
         fi
      fi
      if [ -n "$ROS_VERSION" ] && [ -z "$mode" ]
      then
         log_msg "ERROR: Option -r requires -u (upgrade mode)"
         usage
      fi
   fi
   # Source options file
   if [ -n "$options_file" ]
   then
      source_options "$options_file"
   fi
   # Pre-flight checks
   preflight_checks
   host="$1"
   case "$mode" in
      -b)
         # Build mode requires credentials for SSH
         prompt_credentials
         build_inventory "$host" "$csv_file"
         ;;
      -u)
         if [ "$SUPPRESS_CSV" -eq 1 ]
         then
            log_msg "Reading inventory from $csv_file"
            hosts_info=$(filter_hosts "$csv_file" "$FILTER")
            hosts_file=$(echo "$hosts_info" | cut -d',' -f1)
            csv_path=$(echo "$hosts_info" | cut -d',' -f2)
            confirm_upgrades "$hosts_file"
            # Prompt for credentials only after confirmation
            prompt_credentials
            log_msg "Processing upgrades for filtered hosts in $csv_path"
            failed_hosts=""
            while IFS=',' read -r target_host model_name
            do
               prompt_credentials
               run_upgrade "$target_host" "$csv_path" || failed_hosts="$failed_hosts $target_host"
            done < "$hosts_file"
            rm -f "$hosts_file"
            if [ -n "$failed_hosts" ]
            then
               log_msg ""
               log_msg "Summary: Failed upgrades for hosts:$failed_hosts"
            else
               log_msg "Summary: All updates were successful."
            fi
         else
            # Direct upgrade requires credentials immediately
            prompt_credentials
            log_msg "Upgrading host $host"
            run_upgrade "$host" ""
         fi
         ;;
      *)
         usage
         ;;
   esac
   rm -f "$CRED_FILE" 2>/dev/null
}

# --- Script Entry Point ---
main "$@"