# MikroTik Upgrade Tool (MUT)

**MUT** is a command-line toolset for managing MikroTik routers, designed to automate the creation of a CSV inventory, perform configuration backups, and execute RouterOS upgrades or downgrades. It leverages SSH and Expect to interact with MikroTik devices, making it ideal for network administrators managing multiple routers. The tool operates in two modes: **build mode** to generate a CSV inventory from neighbor data, and **upgrade mode** to upgrade devices directly or based on filtered CSV data.

## Disclaimer

This software is provided by the copyright holders and contributors "as is" and any express or implied warranties, including, but not limited to, the implied warranties of merchantability and fitness for a particular purpose are disclaimed. In no event shall Bindle Binaries be liable for any direct, indirect, incidental, special, exemplary, or consequential damages (including, but not limited to, procurement of substitute goods or services; loss of use, data, or profits; or business interruption) however caused and on any theory of liability, whether in contract, strict liability, or tort (including negligence or otherwise) arising in any way out of the use of this software, even if advised of the possibility of such damage.

## Features

- **Inventory Creation**: Generates a CSV file with details like identity, IP address, MAC address, interface, platform, board name, version, and status using MikroTik neighbor data.
- **Configuration Backups**: Automatically backs up router configurations before upgrades, saving them as `.rsc` files.
- **RouterOS Upgrades/Downgrades**: Supports upgrading or downgrading to specific RouterOS versions (e.g., `7.18` or `7.18.2`), with version selection logic to pick the highest fix or exact match.
- **CSV Filtering**: Allows upgrades of specific devices by filtering CSV data based on board name or identity.
- **Test Mode**: Simulates upgrades without applying changes, ideal for testing workflows.
- **Debug Mode**: Provides verbose output and detailed logging for troubleshooting.
- **Logging**: Saves detailed logs to a specified directory for audit trails.
- **POSIX Compliance**: `mut_inv.sh` is largely POSIX-compliant, with non-POSIX utilities (`grep`, `awk`, `ssh`) clearly noted.
- **Configuration File**: Supports a `mut_opt.conf` file for customizing paths and settings.

## Requirements

- **Operating System**: Linux or UNIX-like system
- **Shell**: POSIX-compliant shell (e.g., `sh`, `bash`, `dash`)
- **Utilities**:
  - `ssh` (OpenSSH, version 7.0 or later)
  - `scp` (for file transfers)
  - `sshpass` (version 1.06 or later)
  - `expect` (version 5.45 or later)
  - `awk` (`mawk` or `gawk`), `sed`, `read`, `stty`, `cat`
- **MikroTik Access**:
  - SSH access to devices (port 22, admin privileges)
  - RouterOS `.npk` files in `os/vN.NN/` (e.g., `os/v7.18/routeros-7.18.2-mipsbe.npk`)
- **Permissions**:
  - Write access to `backups/`, `logs/`, and `$HOME` for CSV output
- **Files**:
  - `mut_inv.sh` (version 1.0.2)
  - `mut_up.exp` (version 1.0.16)
  - Optional: `mut_opt.conf` for configuration

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
   On a Debian-based system:

   ```bash
   sudo apt-get update
   sudo apt-get install openssh-client sshpass expect gawk sed coreutils
   ```

   For other systems, ensure `ssh`, `scp`, `sshpass`, `expect`, `awk`, `sed`, and `cat` are installed.

5. **Set Permissions**:
   Make scripts executable:

   ```bash
   chmod +x mut_inv.sh mut_up.exp
   ```

6. **Optional: Configure `mut_opt.conf`**:
   Create `mut_opt.conf` to customize paths (e.g., `ROS_IMAGE_DIR`, `BACKUP_DIR`, `LOGS_DIR`, `SSH_TIMEOUT`):

   ```bash
   echo "ROS_IMAGE_DIR=$PWD/os" > mut_opt.conf
   echo "BACKUP_DIR=$PWD/backups" >> mut_opt.conf
   echo "LOGS_DIR=$PWD/logs" >> mut_opt.conf
   echo "SSH_TIMEOUT=30" >> mut_opt.conf
   ```

## Usage

### Build Inventory Mode

Generate a CSV inventory from a MikroTik router’s ip neighbor data.

- **Console Output** (no CSV file):

  ```bash
  ./mut_inv.sh -b <host>
  ```

  Example:

  ```bash
  ./mut_inv.sh -b 192.168.1.1
  ```

- **Save to CSV** (in `$HOME`):

  ```bash
  ./mut_inv.sh -b -c inventory.csv <host>
  ```

  Example:

  ```bash
  ./mut_inv.sh -b -c routers.csv 192.168.1.1
  ```

### Upgrade Mode

Upgrade or downgrade MikroTik routers, either directly or based on a filtered CSV.

- **Direct Upgrade** (single host):

  ```bash
  ./mut_inv.sh -u [-r version] <host>

  ```

  Example (upgrade to latest `7.18` fix):

  ```bash
  ./mut_inv.sh -u -r 7.18 192.168.1.1
  ```

- **Filtered Upgrade** (from CSV):

  ```bash
  ./mut_inv.sh -u -c <csv_file> -f <filter> [-r version]
  ```

  Example (upgrade devices with board name containing “RB” to `7.18.2`):

  ```bash
  ./mut_inv.sh -u -c routers.csv -f RB -r 7.18.2
  ```

### Additional Options

- `-d`: Enable debug output for troubleshooting.
- `-t`: Simulate upgrades (test mode).
- `-l`: Enable logging to `logs/` directory.
- `-o <options_file>`: Use a custom configuration file (default: `mut_opt.conf`).

Example with all options:

```bash
./mut_inv.sh -u -c routers.csv -f RB -r 7.18.2 -d -t -l -o custom.conf
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
- `status`: Status (currently empty)

Example:

```csv
"identity","ip_addr","mac_addr","interface","platform","board_name","version","status"
"Router1","192.168.1.2","00:0C:29:12:34:56","ether1","MikroTik","RB4011","7.17.1",""
```

## Backup Process

- **When**: Backups are performed before upgrades in `mut_up.exp`.
- **Format**: Configuration exports (`/export show-sensitive`) saved as `.rsc` files in `backups/`.
- **Naming**: `config.<host>-<timestamp>.rsc` (e.g., `config.router1-20250528_123456.rsc`).
- **Verification**: Backups are verified for readability and non-empty content.

## Logging

- **Enabled**: With `-l` option.
- **Location**: `logs/mut_inventory_<timestamp>.log` (for `mut_inv.sh`) and `logs/mut_upgrade_<timestamp>.log` (for `mut_up.exp`).
- **Debug Logs**: With `-d`, additional debug logs (`logs/mut_upgrade_debug_<timestamp>.log`) include Expect diagnostics and CLI interactions.

## Security Notes

- **Credentials**: Stored temporarily in a secure file (`/tmp/mikrotik_cred_$$.txt`, mode 600), deleted after use.
- **SSH**: Uses `sshpass` for automation; ensure `cred_file` is protected.
- **Sensitive Data**: Passwords are suppressed in debug logs for security.

## Known Limitations

- Requires routable IPv4 or IPv6 addresses (excludes link-local `fe80::` addresses).
- Non-POSIX utilities (`grep`, `awk`, `ssh`, `sshpass`) are used, noted in headers.
- Upgrade process assumes `.npk` files are organized in `os/vN.NN/` directories.
- Downgrades may require manual intervention if RouterOS restrictions apply.
- Hostname for SSH use must match prompt in **/system/identity/set name=NAME**

## Contributing

Contributions are welcome! Please:

1. Fork the repository.
2. Create a feature branch (`git checkout -b feature/your-feature`).
3. Commit changes (`git commit -m "Add your feature"`).
4. Push to the branch (`git push origin feature/your-feature`).
5. Open a pull request.

## License

This project is licensed under the MIT License. See the `LICENSE` file for details.

## Contact

For issues or questions, open a GitHub issue or contact Sean Crites at [sean.crites@gmail.com](mailto:sean.crites@gmail.com).
