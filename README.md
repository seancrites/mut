# MikroTik Upgrade Tool (MUT) v1.0.0

**MUT** is a command-line toolset for managing MikroTik routers, designed to automate the creation of a CSV inventory, perform configuration backups, and execute RouterOS upgrades or downgrades. It leverages SSH and Expect to interact with MikroTik devices, making it ideal for network administrators managing MikroTik infrastructure. It supports air-gapped networks, robust hostname handling, and addon package upgrades, making it ideal for systems engineers managing multiple devices. The tool operates in two modes: **build mode** to generate a CSV inventory from neighbor data, and **upgrade mode** to upgrade devices directly or based on filtered CSV data.

## Disclaimer

This software is provided by the copyright holders and contributors "as is" and any express or implied warranties, including, but not limited to, the implied warranties of merchantability and fitness for a particular purpose are disclaimed. In no event shall Sean Crites be liable for any direct, indirect, incidental, special, exemplary, or consequential damages (including, but not limited to, procurement of substitute goods or services; loss of use, data, or profits; or business interruption) however caused and on any theory of liability, whether in contract, strict liability, or tort (including negligence or otherwise) arising in any way out of the use of this software, even if advised of the possibility of such damage.

## Features

- **Inventory Creation**: Generates a CSV file with details like identity, IP address, MAC address, interface, platform, board_name, version, and upgrade status using MikroTik neighbor data.
- **Configuration Backups**: Automatically backs up router configurations before upgrades, saving them as `.rsc` files.
- **RouterOS Upgrades/Downgrades**: Supports upgrading or downgrading to specific RouterOS versions (e.g., `7.18` or `7.18.2`), with version selection logic to pick the highest patch or exact match, including addon packages (e.g., `wireless`, `dhcp`).
- **RouterOS Version Validation**: Ensures valid version formats (N.NN or N.NN.N) for `-r` option.
- **Centralized CSV Path Resolution**: Consistently handles CSV file paths (current directory or `$HOME`) for build and upgrade modes.
- **Credentials File Validation**: Ensures `mut_up.exp` credentials file uses correct key=value format.
- **Configurable SSH Timeout**: Supports customizable SSH timeouts via `mut_opt.conf` for both scripts.
- **Enhanced SCP Error Handling**: Provides specific error messages for SCP failures (e.g., permission denied, no route to host).
- **Air-Gapped Support**: Enables automated updates in air-gapped networks by downloading the project and RouterOS `.npk` files/packages offline.
- **Hostname Support**: Handles FQDNs (e.g., `router.prv.example.com`), short hostnames (e.g., `router.prv`), and local FQDNs (e.g., `router.local.lan`) with a fallback mechanism that tries short hostname prompts first, then full FQDN.
- **CSV Filtering**: Allows upgrades of specific devices by filtering CSV data with `awk` regex on `identity` or `board_name` fields.
- **Failure Tracking**: Tracks and summarizes failed upgrades when processing multiple devices, ensuring all devices are attempted.
- **Test Mode**: Simulates upgrades without applying changes, ideal for testing workflows.
- **Debug Mode**: Provides verbose output and detailed logging for troubleshooting.
- **Logging**: Saves detailed logs to a specified directory, including a summary of failed upgrades for multiple devices.
- **POSIX Compliance**: `mut_inv.sh` is largely POSIX-compliant, with documented external dependencies.
- **Configuration File**: Supports a `mut_opt.conf` file for customizing paths and settings.
- **Firmware Verification**: Verifies firmware versions post-upgrade, handling pending firmware upgrades with automatic reboots.
- **Reachability Check**: Confirms device reachability via `ping` before upgrades, enhancing reliability.

## Requirements

- **Shell**: POSIX-compliant shell (e.g., `sh`, `bash`, `dash`)
- **Utilities**:
  - `ssh` (OpenSSH, version 7.0 or later)
  - `scp` (for file transfers)
  - `sshpass` (version 1.06 or later)
  - `expect` (version 5.45 or later)
  - `awk`, `ping`, `sed`, `read`, `stty`, `cat`
  - `getent`, `host` (for hostname resolution in `mut_inv.sh`)
- **MikroTik Access**:
  - SSH access to devices (port 22, admin privileges)
  - RouterOS `.npk` files (including addon packages) in `os/vN.NN/` (e.g., `os/v7.18/routeros-7.18.2-mipsbe.npk`, `os/v7.18/wireless-7.18.2-mipsbe.npk`)
- **Permissions**:
  - Write access to `backups/`, `logs/`, and `$HOME` for CSV output
- **Files**:
  - `mut_inv.sh`
  - `mut_up.exp`
  - Optional: `mut_opt.conf` for configuration overrides

For air-gapped networks, download the project and `.npk` files offline and transfer them to the target system.

## Installation

1. **Clone the Repository**:

   ```bash
   git clone https://github.com/seancrites/mut.git
   cd mut
   ```

2. **Set Up Directories**:
   Create directories for RouterOS images, backups, and logs:

   ```bash
   mkdir -p os backups logs
   ```

3. **Download RouterOS Images**:
   Place `.npk` files in versioned subdirectories (e.g., `os/v7.18/routeros-7.18.2-mipsbe.npk`). Obtain these from [MikroTik’s download page](https://mikrotik.com/download).

4. **Install Dependencies**:
   Ensure all required utilities are installed using the package manager for your distribution. Below are examples for Alpine Linux, Debian, and Rocky Linux.

   - **Alpine Linux** (using `apk`):

     ```bash
     apk update
     apk add openssh-client sshpass expect gawk iputils-ping sed coreutils net-tools
     ```

     *Note*: `sshpass` is in the `community` repository; ensure it’s enabled in `/etc/apk/repositories` (e.g., `https://dl-cdn.alpinelinux.org/alpine/v3.22/community`). The `coreutils` package provides `read`, `stty`, and `cat`; `net-tools` provides `getent` and `host`.[](https://www.cyberciti.biz/faq/10-alpine-linux-apk-command-examples/)[](https://wiki.alpinelinux.org/wiki/Repositories)

   - **Debian** (using `apt`):

     ```bash
     sudo apt update
     sudo apt install openssh-client sshpass expect gawk iputils-ping sed coreutils net-tools
     ```

     *Note*: All utilities are available in Debian’s default repositories. The `coreutils` package includes `read`, `stty`, and `cat`; `net-tools` provides `getent` and `host`.

   - **Rocky Linux** (using `dnf`):

     ```bash
     sudo dnf update
     sudo dnf install openssh-clients sshpass expect gawk iputils sed coreutils net-tools
     ```

     *Note*: `sshpass` may require the EPEL repository. Enable it with `sudo dnf install epel-release`. The `coreutils` package includes `read`, `stty`, and `cat`; `net-tools` provides `getent` and `host`.[](https://docs.rockylinux.org/labs/systems_administration_I/lab7-software_management/)

5. **Set Permissions**:
   Make scripts executable:

   ```bash
   chmod +x mut_inv.sh mut_up.exp
   ```

6. **Configure `mut_opt.conf`** (optional):
   Create or edit `mut_opt.conf` to customize paths and settings (see [Configuration File](#configuration-file)):

   ```plaintext
   ROS_IMAGE_DIR=$PWD/os
   BACKUP_DIR=$PWD/backups
   LOGS_DIR=$PWD/logs
   SSH_TIMEOUT=30
   ```

## Configuration File

The optional `mut_opt.conf` file customizes script behavior. It uses a `key=value` format, with supported keys:

- `ROS_IMAGE_DIR`: Directory for RouterOS `.npk` files (default: `./os`).
- `BACKUP_DIR`: Directory for configuration backups (default: `./backups`).
- `LOGS_DIR`: Directory for logs (default: `./logs`).
- `SSH_TIMEOUT`: SSH connection timeout in seconds (default: 30).

Example `mut_opt.conf`:

```plaintext
ROS_IMAGE_DIR=/opt/mikrotik/os
BACKUP_DIR=/var/backups/mikrotik
LOGS_DIR=/var/log/mikrotik
SSH_TIMEOUT=60
```

Lines starting with `#` are ignored, and `~` or `$PWD` are expanded to `$HOME` or the current directory.

## Usage

### Build Inventory Mode

Generate a CSV inventory from a MikroTik router’s IP neighbor data.

- **Console Output** (no CSV file):

  ```bash
  ./mut_inv.sh -b <host>
  ```

  Example:

  ```bash
  ./mut_inv.sh -b router.prv.example.com
  ```

- **Save to CSV** (tries current directory, then `$HOME` if not writable, or specify with `-c`):

  ```bash
  ./mut_inv.sh -b [-c inventory.csv] <host>
  ```

  Example:

  ```bash
  ./mut_inv.sh -b -c /path/to/routers.csv router.prv.example.com
  ```

### Upgrade Mode

Upgrade or downgrade MikroTik routers, either directly or based on a filtered CSV. When using `-c`, all filtered devices are processed, even if some fail, with a summary of failures logged. The `-r` version must be in `N.NN` or `N.NN.N` format.

- **Direct Upgrade** (single host):

  ```bash
  ./mut_inv.sh -u [-r version] <host>
  ```

  Example (upgrade to latest `7.18` patch):

  ```bash
  ./mut_inv.sh -u -r 7.18 router.prv.example.com
  ```

  Example (upgrade to exact `7.18.2`):

  ```bash
  ./mut_inv.sh -u -r 7.18.2 router.prv.example.com
  ```

- **Filtered Upgrade** (from CSV):

  ```bash
  ./mut_inv.sh -u -c <csv_file> -f <filter> [-r version]
  ```

  Example (upgrade devices with board_name containing “rb” to `7.18.2`):

  ```bash
  ./mut_inv.sh -u -c routers.csv -f rb -r 7.18.2
  ```

  Example (upgrade both CRS312 and mAP devices to `7.16.2`):

  ```bash
  ./mut_inv.sh -u -c routers.csv -f "crs312|rbmap2nd" -r 7.16.2
  ```

### Additional Options

- `-d`: Enable debug output for troubleshooting.
- `-e`: Enable enhanced logging of MikroTik commands (ignored if `-d` is used).
- `-t`: Simulate upgrades (test mode).
- `-l`: Enable logging to `logs/` directory.
- `-o <options_file>`: Use a custom configuration file (default: `mut_opt.conf`).

Example with all options:

```bash
./mut_inv.sh -u -c routers.csv -f rb -r 7.18.2 -d -e -t -l -o custom.conf
```

## CSV Format

The inventory CSV has the following columns:

- `identity`: Router identity (name)
- `ip_addr`: IP address (IPv4 or IPv6, non-link-local)
- `mac_addr`: MAC address
- `interface`: Interface used
- `platform`: Platform (always “MikroTik”)
- `board_name`: Board name (e.g., “RB4011”)
- `version`: RouterOS version
- `mut_status`: Upgrade status (e.g., `SUCCESS: Updated to v<version> <timestamp>`, `FAILED: Invalid credentials <timestamp>`)

Example:

```csv
identity,ip_addr,mac_addr,interface,platform,board_name,version,mut_status
"Router1","192.168.1.2","00:0C:29:12:34:56","ether1","MikroTik","RB4011","7.16.2","SUCCESS: Updated to v7.16.2 20250604_123456 -0800"
"Router2","192.168.1.3","00:0C:29:78:90:AB","ether2","MikroTik","CRS312","7.18.2","FAILED: Invalid credentials 20250604_123500 -0800"
```

## Backup Process

- **When**: Backups are performed before upgrades in `mut_up.exp`.
- **Format**: Configuration exports (`/export show-sensitive`) saved as `.rsc` files in `backups/`.
- **Naming**: `config.<host>-<timestamp>.rsc` (e.g., `config.router1-20250604_123456.rsc`).
- **Verification**: Backups are verified for readability and non-empty content.

## Logging

- **Enabled**: With `-l` option.
- **Location**: `logs/mut_inventory_<timestamp>.log` (for `mut_inv.sh`) and `logs/mut_upgrade_<timestamp>.log` (for `mut_up.exp`).
- **Failure Summary**: In `-c` mode, a summary of failed upgrades is logged (e.g., `Summary: Failed upgrades for hosts: router1 router2`).
- **Debug Logs**: With `-d`, additional debug logs (`logs/mut_upgrade_debug_<timestamp>.log`) include Expect diagnostics and CLI interactions.

## Security Notes

- **Credentials**: Stored temporarily in a secure file (`/tmp/mikrotik_cred_<pid>.txt`, mode 600, where `<pid>` is the process ID), deleted after use.
- **SSH**: Uses `sshpass` for automation; ensure `cred_file` is protected.
- **Sensitive Data**: Passwords are suppressed in debug logs for security.

## Known Limitations

- Requires routable IPv4 or IPv6 addresses (excludes link-local `fe80::` addresses).
- Non-POSIX utilities (`awk`, `ssh`, `sshpass`, `expect`, `getent`, `host`) are used, noted in headers.
- Upgrade process assumes `.npk` files are organized in `os/vN.NN/` directories.
- Multiple device upgrades (`-c`) continue despite failures, exiting with 0 unless a critical error occurs (e.g., invalid CSV).
- Hostname for SSH must match the prompt set in `/system/identity/set name=NAME`, typically the short hostname for internet-routable FQDNs (e.g., `router.prv` for `router.prv.example.com`).
- Invalid RouterOS versions (e.g., `7`, `abc`) or malformed credentials files cause explicit errors.
- SSH timeouts are configurable but require sufficient network stability.

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for a detailed history of changes.

## Contributing

Contributions are welcome! Please:

1. Fork the repository.
2. Create a feature branch (`git checkout -b feature/your-feature`).
3. Commit changes (`git commit -m "Add your feature"`).
4. Push to the branch (`git push origin feature/your-feature`).
5. Open a pull request.

## License

This project is licensed under the BSD 3-Clause License. See the `LICENSE` file for details.

## Contact

For issues or questions, open a GitHub issue or contact Sean Crites at [sean.crites@gmail.com](mailto:sean.crites@gmail.com).