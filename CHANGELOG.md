# Changelog

All notable changes to the MikroTik Upgrade Tool (MUT) project will be documented in this file.

## [1.0.0] - 2025-06-05

### Added

- Initial release of `mut_inv.sh`:
  - Builds a CSV inventory from MikroTik router neighbor data, including identity, IP address, MAC address, interface, platform, board_name, version, and upgrade status.
  - Supports console output or saving to a CSV file (current directory or `$HOME`).
  - Includes a switch to re-read CSV and call `mut_up.exp` for upgrades.
  - Added `validate_ros_version` function to ensure RouterOS version formats (N.NN or N.NN.N).
  - Added `resolve_csv_path` function for centralized CSV file path handling.
  - Added check for empty inventory data to prevent generating empty CSVs.
  - Dependencies: `ssh`, `sshpass`, `expect`, `awk`, `sed`, `ping`, `read`, `stty`, `cat`, `getent`, `host`.
- Initial release of `mut_up.exp`:
  - Automates RouterOS upgrades/downgrades via SSH, with support for specific versions and addon packages.
  - Validates credentials file format (key=value) for secure authentication.
  - Supports configurable SSH timeout via `mut_opt.conf`.
  - Provides enhanced SCP error handling with specific failure messages (e.g., permission denied, no route to host).
  - Includes test mode for simulating upgrades and debug mode for verbose logging.
  - Dependencies: `expect`, `ssh`, `scp`, `sshpass`, `sh`.
- Added `README.md` with detailed documentation:
  - Installation instructions with dependency examples for Alpine Linux (`apk`), Debian (`apt`), and Rocky Linux (`dnf`).
  - Configuration file (`mut_opt.conf`) format and usage.
  - Usage examples for inventory building and upgrades.
- Added support for `mut_opt.conf` to customize paths (`ROS_IMAGE_DIR`, `BACKUP_DIR`, `LOGS_DIR`) and `SSH_TIMEOUT`.

[1.0.0]: https://github.com/seancrites/mut/releases/tag/v1.0.0
[Keep a Changelog](https://keepachangelog.com/en/1.0.0/)
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).
