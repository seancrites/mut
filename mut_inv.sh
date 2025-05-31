#!/bin/sh
#
# Script: mut_inv.sh
# Purpose: Builds a MikroTik inventory CSV or performs upgrades using neighbor data or existing CSV
# Author: Sean Crites
# Version: 1.0.2
# Created: 2025-05-18
# Last Updated: 2025-05-31
#
# Copyright (c) 2025 Sean Crites <sean.crites@gmail.com>
# This script is licensed under the BSD 3-Clause License.
# See the LICENSE file in the project root for the full license text.
#
# Requirements:
#    - POSIX-compliant shell (e.g., sh, bash, or dash)
#    - SSH client (OpenSSH recommended, version 7.0 or later)
#    - sshpass (version 1.06 or later)
#    - Expect (version 5.45 or later) for mut_up.exp
#    - Standard POSIX utilities: awk (mawk or gawk), sed, read, stty, cat
#    - SSH access to MikroTik devices (port 22, admin privileges)
#    - Write permissions for CSV output ($HOME for CSV, BACKUP_DIR, LOGS_DIR)
#    - Optional: Configuration file (mut_opt.conf)
#    - Environment: Linux or UNIX-like system
#    - Warnings:
#        - "WARNING: No valid neighbors found in output" for empty neighbor data
#        - "WARNING: No hosts match filter criteria (routable IPv4 or IPv6)" for no routable IPs
#
# Usage: mut_inv.sh [-b [-c csv_file] | -u [-c csv_file] [-f filter] [-r version]] [-d] [-t] [-l] [-o options_file] [<host>]
# Notes:
#    - Build mode (-b): Builds CSV from <host> neighbor data. Requires -c csv_file to write to $HOME/csv_file, else outputs to console.
#    - Upgrade mode (-u):
#        - Without -c: Upgrades <host> directly (no CSV, <host> required).
#        - With -c: Upgrades hosts from existing csv_file (in $HOME or specified path) matching -f filter (no <host>, -f required).
#    - Filter (-f) matches model_name first, then identity (alphanumeric, case-insensitive).
#    - Version (-r version): Specifies RouterOS version (N.NN or N.NN.N). N.NN selects highest fix in os/vN.NN; N.NN.N selects exact version.
#    - Test mode (-t) simulates upgrades using -t flag in mut_up.exp.
#    - Debug mode (-d) enables debug output and passes -d to mut_up.exp.
#    - Log mode (-l) enables logging to LOGS_DIR and displays output to user.
#

# --- Default Configuration Variables ---
SCRIPT_DIR=$(dirname "$0")
ROS_IMAGE_DIR="$SCRIPT_DIR/os"
BACKUP_DIR="$SCRIPT_DIR/backups"
LOGS_DIR="$SCRIPT_DIR/logs"
EXPECT_SCRIPT="$SCRIPT_DIR/mut_up.exp"
SSH_TIMEOUT=30
USERNAME=""
PASSWORD=""
DEBUG=0
SUPPRESS_CSV=0
TEST_MODE=0
LOGGING=0
FILTER=""
ROS_VERSION=""

# --- Function Definitions ---

# Print usage and exit
usage()
{
   echo "Usage: $0 [-b [-c csv_file] | -u [-c csv_file] [-f filter] [-r version]] [-d] [-t] [-l] [-o options_file] [<host>]"
   echo "Options:"
   echo "   -b             Build inventory CSV (no upgrades)"
   echo "   -u             Upgrade mode: upgrade host or filtered CSV hosts"
   echo "   -c csv_file    Write CSV to $HOME/csv_file and suppress console output (build mode) or read existing CSV (upgrade mode)"
   echo "   -d             Enable debug output and pass to expect script"
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

# Perform pre-flight checks
preflight_checks()
{
   for cmd in awk sed ssh sshpass expect read stty cat
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
      log_msg "Pre-flight: SSH version: $ssh_version"
      log_msg "Pre-flight: sshpass version: $sshpass_version"
      log_msg "Pre-flight: Expect version: $expect_version"
      log_msg "Pre-flight: awk version: $awk_version"
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
   if [ -z "$SSH_TIMEOUT" ] || ! expr "$SSH_TIMEOUT" + 0 >/dev/null 2>&1
   then
      log_msg "ERROR: SSH_TIMEOUT must be a positive number"
      exit 1
   fi
   # Check if expect script supports -t, -d, -l, and -r
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
   USERNAME="${USERNAME}+tce200w"
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
   echo "username=$USERNAME" > "$CRED_FILE"
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

# Execute SSH command
ssh_exec()
{
   host="$1"
   cmd="$2"
   if [ -z "$USERNAME" ] || [ -z "$PASSWORD" ]
   then
      log_msg "ERROR: Username or password not set for SSH to $host"
      exit 1
   fi
   SSHPASS="$PASSWORD" sshpass -e ssh -o ConnectTimeout="$SSH_TIMEOUT" -o StrictHostKeyChecking=no "$USERNAME@$host" "$cmd" 2>/dev/null
   if [ $? -ne 0 ]
   then
      log_msg "ERROR: SSH command failed on $USERNAME@$host"
      exit 1
   fi
}

# Parse neighbor data to CSV
parse_neighbors()
{
   raw_data="$1"
   if [ -z "$raw_data" ] || ! echo "$raw_data" | grep -q '.id='
   then
      log_msg "WARNING: No valid neighbors found in output"
      echo "identity,ip_addr,mac_addr,interface,platform,model_name,version,status"
      return
   fi
   tmp_output="/tmp/mikrotik_neighbors_$$.csv"
   echo "$raw_data" | awk -v debug="$DEBUG" '
      BEGIN {
         RS=";"; FS="="; OFS=",";
         identity=""; ip_addr=""; mac_addr=""; iface=""; platform="MikroTik"; model=""; version=""; status=""
         count=0
         print "identity,ip_addr,mac_addr,interface,platform,model_name,version,status"
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
               status_esc=status; gsub(/"/, "\"\"", status_esc)
               printf "\"%s\",\"%s\",\"%s\",\"%s\",\"%s\",\"%s\",\"%s\",\"%s\"\n",
                      identity_esc, ip_addr_esc, mac_addr_esc, iface_esc,
                      platform_esc, model_esc, version_esc, status_esc
               if (debug) print "Discovered: " identity " (" ip_addr ")" > "/dev/stderr"
               count++
            } else {
               if (debug) print "Skipping entry: identity=" identity " (ip_addr=" ip_addr ", mac_addr=" mac_addr ")" > "/dev/stderr"
            }
         } else if (identity != "") {
            if (debug) print "Skipping entry: identity=" identity " (ip_addr=" ip_addr ", mac_addr=" mac_addr ")" > "/dev/stderr"
         }
         identity=""; ip_addr=""; mac_addr=""; iface=""; platform="MikroTik"; model=""; version=""; status=""
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
               status_esc=status; gsub(/"/, "\"\"", status_esc)
               printf "\"%s\",\"%s\",\"%s\",\"%s\",\"%s\",\"%s\",\"%s\",\"%s\"\n",
                      identity_esc, ip_addr_esc, mac_addr_esc, iface_esc,
                      platform_esc, model_esc, version_esc, status_esc
               if (debug) print "Discovered: " identity " (" ip_addr ")" > "/dev/stderr"
               count++
            } else {
               if (debug) print "Skipping entry: identity=" identity " (ip_addr=" ip_addr ", mac_addr=" mac_addr ")" > "/dev/stderr"
            }
         } else if (identity != "") {
            if (debug) print "Skipping entry: identity=" identity " (ip_addr=" ip_addr ", mac_addr=" mac_addr ")" > "/dev/stderr"
         }
      }
   ' > "$tmp_output"
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
   raw_data=$(ssh_exec "$host" ":put [/ip/neighbor/print as-value]")
   if [ -z "$raw_data" ]
   then
      log_msg "ERROR: Empty output from :put [/ip/neighbor/print as-value]"
      exit 1
   fi
   log_msg "Parsing neighbor data"
   if [ "$SUPPRESS_CSV" -eq 1 ]
   then
      # Save to $HOME/csv_file
      csv_path="$HOME/$csv_file"
      confirm_overwrite "$csv_path"
      parse_neighbors "$raw_data" > "$csv_path"
      log_msg "Inventory saved to $csv_path"
   else
      parse_neighbors "$raw_data"
      log_msg "Inventory output to console"
   fi
}

# Filter hosts from CSV, removing duplicates
filter_hosts()
{
   csv_file="$1"
   filter="$2"
   # Determine CSV path
   case "$csv_file" in
      */*)
         # Directory specified
         csv_dir=$(dirname "$csv_file")
         csv_name=$(basename "$csv_file")
         if [ ! -d "$csv_dir" ]
         then
            log_msg "ERROR: Directory $csv_dir does not exist"
            exit 1
         fi
         csv_path="$csv_file"
         ;;
      *)
         # No directory, default to $HOME
         csv_path="$HOME/$csv_file"
         csv_name="$csv_file"
         ;;
   esac
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
   echo "$tmp_hosts"
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
   csv_file="$2"
   log_msg "Running upgrade on $host"
   # Build expect command
   expect_cmd="expect -f \"$EXPECT_SCRIPT\""
   if [ "$TEST_MODE" -eq 1 ]
   then
      expect_cmd="$expect_cmd -t"
   fi
   if [ "$DEBUG" -eq 1 ]
   then
      expect_cmd="$expect_cmd -d"
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
      eval "$expect_cmd 2>&1 | tee -a \"$LOG_FILE\""
      status=$?
   else
      eval "$expect_cmd"
      status=$?
   fi
   rm -f "$CRED_FILE"
   if [ $status -eq 0 ]
   then
      if [ "$TEST_MODE" -eq 1 ]
      then
         log_msg "Test mode: Simulated upgrade successful for $host"
      else
         log_msg "Upgrade successful for $host"
      fi
   else
      log_msg "ERROR: Upgrade failed for $host (exit code: $status)"
      exit 1
   fi
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
            hosts_file=$(filter_hosts "$csv_file" "$FILTER")
            confirm_upgrades "$hosts_file"
            # Prompt for credentials only after confirmation
            prompt_credentials
            log_msg "Processing upgrades for filtered hosts in $csv_file"
            while IFS=',' read -r target_host model_name
            do
               run_upgrade "$target_host" "$csv_file"
            done < "$hosts_file"
            rm -f "$hosts_file"
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