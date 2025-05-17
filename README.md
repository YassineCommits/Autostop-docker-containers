# Nomad Idle Job Stopper Service

## Purpose

This service monitors running Docker containers managed by HashiCorp Nomad. If a container exhibits network inactivity for a configurable duration (based on `docker stats`), the service attempts to stop the corresponding Nomad job by sending a `DELETE` request to the Nomad API.

This is useful for automatically shutting down development environments, temporary services, or other jobs that should not run indefinitely when idle, helping to conserve resources.

## How it Works

1.  **Identify Containers:** The monitoring script (`/usr/local/bin/nomad-idle-monitor.sh`) periodically lists running Docker containers, optionally filtering them based on the `CONTAINER_FILTER` setting in `/etc/default/nomad-idle-monitor`.
2.  **Monitor Network Stats:** For each targeted container, it retrieves network I/O statistics (Rx/Tx bytes) using `docker stats --no-stream`.
3.  **Calculate Change:** It calculates the total bytes transferred (Rx + Tx) and compares it to the value from the previous check stored in its state directory (managed by `systemd` under `/run/nomad-idle-monitor` by default when installed via package).
4.  **Check Activity Threshold:** If the *change* in total bytes since the last check is greater than the configured `ACTIVITY_THRESHOLD`, the container is considered active, and its "last active time" is updated. This helps ignore minor background network noise.
5.  **Check Idle Timeout:** If the change does *not* exceed the threshold, the script calculates how long the container has been inactive (since the last *significant* activity). If this duration exceeds the `IDLE_TIMEOUT`, the script proceeds to stop the job.
6.  **Derive Job Name:** It retrieves the Docker container's name and attempts to derive the corresponding Nomad Job Name by removing the typical allocation ID suffix (assumed to be a hyphen followed by a 36-character UUID).
7.  **Call Nomad API:** It sends an HTTP `DELETE` request to the configured `NOMAD_ENDPOINT` for the derived job name (e.g., `DELETE /v1/job/<derived-job-name>?purge=false`), using the provided `NOMAD_TOKEN` for authentication.
8.  **Loop:** The script sleeps for `CHECK_INTERVAL` seconds and repeats the process.

The service is managed by `systemd` using the unit file `/etc/systemd/system/nomad-idle-monitor.service`.

## Installation

There are two methods to install the service:

### Method 1: Using Debian Package (Recommended)

This is the preferred method for systems that support `.deb` packages (Debian, Ubuntu, Mint, etc.).

**Prerequisites:**

* You need the `nomad-idle-monitor_*.deb` package file. (See "Building the Package" below if you need to create it).
* The target system needs `apt` or `dpkg`.

**Steps:**

1.  **Copy Package:** Transfer the `.deb` file to the target machine.
2.  **Install:** Open a terminal and run:
    ```bash
    sudo apt update
    # Replace the filename with the actual package name
    sudo apt install ./nomad-idle-monitor_1.0.0-1_all.deb
    ```
    *Using `apt install ./<filename>` is recommended as it automatically handles installing dependencies.*
3.  **Configure:** The service will **not** start automatically yet. You **must** edit the configuration file to provide your Nomad API details:
    ```bash
    sudo nano /etc/default/nomad-idle-monitor
    ```
    * Set `NOMAD_ENDPOINT` to your Nomad API URL (e.g., `"http://127.0.0.1:4646"`).
    * Set `NOMAD_TOKEN` to your Nomad ACL token.
    * Adjust `IDLE_TIMEOUT`, `CHECK_INTERVAL`, `CONTAINER_FILTER`, `ACTIVITY_THRESHOLD` as needed.
    * Save the file and exit (`Ctrl+X`, then `Y`, then `Enter` in `nano`).
4.  **Start Service:** Manually start the service for the first time:
    ```bash
    sudo systemctl start nomad-idle-monitor.service
    ```
    The service is already enabled to start on future boots.

### Method 2: Manual Install Script (Alternative)

This method uses the original shell script to install the service. Use this if you are not on a Debian-based system or prefer manual installation.

**Prerequisites:**

* Ensure the dependencies (see below) are installed manually first.

**Steps:**

1.  **Save the script:** Download or copy the `install_nomad_idle_monitor.sh` script to the target machine.
2.  **Make executable:** `chmod +x install_nomad_idle_monitor.sh`
3.  **Run with sudo and arguments:**
    ```bash
    sudo ./install_nomad_idle_monitor.sh <nomad_endpoint_url> <nomad_token> <idle_timeout_seconds> <check_interval_seconds> "<container_filter>"
    ```
    * **`<nomad_endpoint_url>`:** The base URL of your Nomad API (e.g., `http://127.0.0.1:4646`).
    * **`<nomad_token>`:** Your Nomad ACL token with permissions to stop jobs.
    * **`<idle_timeout_seconds>`:** How long (in seconds) a container must be idle before its job is stopped (e.g., `900` for 15 minutes).
    * **`<check_interval_seconds>`:** How often (in seconds) the script checks container stats (e.g., `60` for 1 minute).
    * **`<container_filter>`:** A Docker `ps --filter` argument.
        * Use `""` (empty string) to monitor **all** running containers.
        * Use `"label=autostop=idle"` to only monitor containers with that specific label.
        * Use `"name=^my-job-"` to monitor containers whose names start with `my-job-`.

    **Example:**
    ```bash
    sudo ./install_nomad_idle_monitor.sh [http://10.0.4.10:4646](http://10.0.4.10:4646) my-secret-nomad-token 900 60 ""
    ```
    The script will create the necessary files, set permissions, reload `systemd`, and start/enable the service. It populates `/etc/default/nomad-idle-monitor` with the provided arguments.

## Dependencies

The following command-line tools must be available on the system where the service runs:

* `docker`: To interact with Docker containers (`ps`, `stats`). The `docker.io` or `docker-ce` package usually provides this.
* `systemd`: For service management (`systemctl`). Usually present on modern Linux systems.
* `curl`: To send HTTP requests to the Nomad API.
* `bc`: Basic calculator (used for parsing byte values).
* Standard POSIX utilities: `sh`, `awk`, `grep`, `sed`, `cut`, `wc`, `ls`, `rm`, `mkdir`, `cat`, `date`, `sleep`, `chmod`, `printf`. Usually provided by `coreutils`, `libc-bin`, `debianutils`.

*Note: When installing via the Debian package (Method 1), these dependencies should be installed automatically if they are missing.*

## Configuration

Configuration is done by editing the environment file: `/etc/default/nomad-idle-monitor`.

After installing via the **Debian package**, you **must** edit this file manually to set `NOMAD_ENDPOINT` and `NOMAD_TOKEN`.

If you used the **Manual Install Script**, it populates this file with the arguments you provided during installation. You can still edit it later.

**Remember to restart the service** for any changes in this file to take effect:
`sudo systemctl restart nomad-idle-monitor.service`.

**Variables:**

* `IDLE_TIMEOUT`: Seconds of inactivity before stopping the job.
* `CHECK_INTERVAL`: Seconds between container checks.
* `CONTAINER_FILTER`: Docker `ps` filter string. Empty means monitor all.
* `ACTIVITY_THRESHOLD`: Minimum change in total network bytes (Rx+Tx) since the last check required to reset the idle timer. Helps ignore background noise. Default is `500`.
* `NOMAD_ENDPOINT`: URL of the Nomad API (e.g., `http://127.0.0.1:4646`). **Must be set.**
* `NOMAD_TOKEN`: Nomad ACL token. **Must be set.**
    * **SECURITY WARNING:** This token is stored in plain text in the environment file, which is typically readable only by root (`chmod 600`). Protect this file appropriately and consider more secure methods (like Vault integration or systemd's `LoadCredential=`) for production environments.

## Usage / Management

Manage the service using standard `systemctl` commands:

* **Check Status:** `sudo systemctl status nomad-idle-monitor.service`
* **View Logs:** `sudo journalctl -u nomad-idle-monitor.service`
    * Follow logs in real-time: `sudo journalctl -f -u nomad-idle-monitor.service`
* **Start Service:** `sudo systemctl start nomad-idle-monitor.service`
* **Stop Service:** `sudo systemctl stop nomad-idle-monitor.service`
* **Restart Service:** `sudo systemctl restart nomad-idle-monitor.service`
* **Enable on Boot:** `sudo systemctl enable nomad-idle-monitor.service` (Done automatically by installer)
* **Disable on Boot:** `sudo systemctl disable nomad-idle-monitor.service`

## Troubleshooting

* **Check Logs:** Use `journalctl -u nomad-idle-monitor.service` first. Look for `INFO`, `WARN`, `ERROR`, and `DEBUG` messages. Look for FATAL errors about `NOMAD_ENDPOINT` or `NOMAD_TOKEN` not being set.
* **Check Configuration:** Verify settings in `/etc/default/nomad-idle-monitor` are correct, especially the endpoint and token. Remember to restart the service after changes.
* **"No running containers matching filter found":** Verify the `CONTAINER_FILTER` in `/etc/default/nomad-idle-monitor` matches your target containers. Use `sudo docker ps --format "table {{.ID}}\t{{.Names}}\t{{.Labels}}"` to check container names and labels. Restart the service after changing the filter.
* **"Could not derive valid Nomad job name":** The script assumes container names follow the pattern `<job-name>-<36-char-uuid>`. If your container names are different, the job name derivation logic in `/usr/local/bin/nomad-idle-monitor.sh` needs adjustment.
* **Job Restarts Immediately:** If the logs show the script successfully sending the `DELETE` request but the container/job reappears quickly, check the `restart` and `reschedule` stanzas in your Nomad job file. Nomad might be configured to automatically restart the job after it's stopped.
* **False Activity Detected:** If containers rarely reach the `IDLE_TIMEOUT` despite no user traffic, check the logs for "Significant network activity detected" messages. You might need to increase the `ACTIVITY_THRESHOLD` in `/etc/default/nomad-idle-monitor` (and restart the service) to better filter out background noise.
* **Permission Errors:** Ensure the service runs as a user (default: `root` via package/script) that can access the Docker socket (`/var/run/docker.sock`) and read `/etc/default/nomad-idle-monitor`.

## Caveats & Assumptions

* **Job Name Derivation:** Relies on the assumption that the Docker container name generated by Nomad is `<actual-job-name>-<36-character-uuid>`. If this pattern differs, the script will fail to stop the correct job.
* **Nomad Restart/Reschedule Policies:** This script simply sends a stop request. It does not override Nomad's built-in job lifecycle policies. Jobs configured to restart automatically *will* restart after being stopped by this script.
* **Token Security:** Storing the Nomad token in `/etc/default/nomad-idle-monitor` is convenient but not the most secure method for production.

## Building the Package (Optional)

If you need to build the `.deb` package yourself from the source files (the monitor script, systemd file, etc.):

1.  **Prerequisites:** Install `dpkg-dev`: `sudo apt update && sudo apt install dpkg-dev`
2.  **Structure:** Arrange the files in a specific directory structure:
    ```
    nomad-idle-monitor-pkg/
    ├── DEBIAN/
    │   ├── control     # Package metadata, dependencies
    │   ├── conffiles   # Lists config files (/etc/default/nomad-idle-monitor)
    │   ├── postinst    # Post-installation script (executable)
    │   ├── postrm    # Post-removal script (executable)
    │   └── prerm     # Pre-removal script (executable)
    ├── etc/
    │   ├── default/
    │   │   └── nomad-idle-monitor  # Default environment/config file
    │   └── systemd/
    │       └── system/
    │           └── nomad-idle-monitor.service # Systemd unit file
    └── usr/
        └── local/
            └── bin/
                └── nomad-idle-monitor.sh # The main script (executable)
    ```
3.  **Build:** Navigate to the directory *containing* `nomad-idle-monitor-pkg` and run:
    ```bash
    dpkg-deb --build nomad-idle-monitor-pkg .
    ```
    This will create the `.deb` file in the current directory.