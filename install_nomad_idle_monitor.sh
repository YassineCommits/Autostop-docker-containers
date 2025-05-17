#!/bin/sh

# =======================================================
# Installation Script for Nomad Idle Job Stopper Service 
# =======================================================
# This script will:
# 1. Accept configuration via command-line arguments.
# 2. Create the monitoring script (/usr/local/bin/nomad-idle-monitor.sh)
#    -> Uses POSIX-compliant syntax (removed mapfile).
#    -> Includes network activity threshold.
#    -> Includes corrected Nomad job name derivation.
# 3. Create the systemd service file (/etc/systemd/system/nomad-idle-monitor.service)
# 4. Create the environment file (/etc/default/nomad-idle-monitor) using args
#    and adding ACTIVITY_THRESHOLD.
# 5. Set permissions for the monitoring script.
# 6. Reload systemd, enable and start the service.
# ========================================================

# --- Configuration ---
SCRIPT_PATH="/usr/local/bin/nomad-idle-monitor.sh"
SERVICE_PATH="/etc/systemd/system/nomad-idle-monitor.service"
ENV_PATH="/etc/default/nomad-idle-monitor"
SERVICE_NAME="nomad-idle-monitor.service"

# --- Argument Parsing ---
if [ "$#" -ne 5 ]; then
    echo "Usage: $0 <nomad_endpoint_url> <nomad_token> <idle_timeout_seconds> <check_interval_seconds> <container_filter>" >&2
    echo "Example: $0 http://127.0.0.1:4646 your-nomad-token 600 60 \"label=autostop=idle\"" >&2
    echo "  - Use \"\" for <container_filter> to monitor all containers." >&2
    exit 1
fi

ARG_NOMAD_ENDPOINT="$1"
ARG_NOMAD_TOKEN="$2"
ARG_IDLE_TIMEOUT="$3"
ARG_CHECK_INTERVAL="$4"
ARG_CONTAINER_FILTER="$5"

# --- POSIX-compliant number validation ---
case "$ARG_IDLE_TIMEOUT" in
    ''|*[!0-9]*) # Check if empty or contains non-digits
        echo "ERROR: Idle timeout must be a positive integer." >&2
        exit 1
        ;;
esac
case "$ARG_CHECK_INTERVAL" in
    ''|*[!0-9]*) # Check if empty or contains non-digits
        echo "ERROR: Check interval must be a positive integer." >&2
        exit 1
        ;;
esac

# Remove trailing slash from endpoint if present
ARG_NOMAD_ENDPOINT=${ARG_NOMAD_ENDPOINT%/}

# --- Check for Root Privileges ---
if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: This script must be run as root or with sudo." >&2
  exit 1
fi

# --- Check for necessary commands ---
# Using POSIX command -v check
check_command() {
    command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' command not found. Please install $1." >&2; exit 1; }
}
check_command docker
check_command systemctl
check_command curl
check_command bc
check_command awk
check_command grep
check_command date
check_command sleep
check_command chmod
check_command cat
check_command read # Check for read built-in (should always exist)
check_command cut
check_command wc
check_command sed
check_command ls
check_command rm
check_command mkdir
check_command printf
check_command sh # Check for the shell itself

echo "--- Starting Nomad Idle Job Stopper Installation (v5.4) ---"
echo "  Nomad Endpoint: $ARG_NOMAD_ENDPOINT"
echo "  Nomad Token: [REDACTED]"
echo "  Idle Timeout: ${ARG_IDLE_TIMEOUT}s"
echo "  Check Interval: ${ARG_CHECK_INTERVAL}s"
echo "  Container Filter: '$ARG_CONTAINER_FILTER'"

# --- Create Monitoring Script ---
echo "Creating monitoring script at $SCRIPT_PATH..."
# Use cat with EOF to write the script content
# Make embedded script use #!/bin/sh as well for consistency
cat << 'EOF' > "$SCRIPT_PATH"
#!/bin/sh

# Nomad Idle Job Stopper Monitoring Script (v5.4 - POSIX Compliant, No mapfile)

# --- Configuration (Defaults - Should be overridden by Env File) ---
# Read environment variables if they exist, otherwise use defaults
IDLE_TIMEOUT=${IDLE_TIMEOUT:-600}
CHECK_INTERVAL=${CHECK_INTERVAL:-60}
CONTAINER_FILTER=${CONTAINER_FILTER:-""}
NOMAD_ENDPOINT=${NOMAD_ENDPOINT:-""}
NOMAD_TOKEN=${NOMAD_TOKEN:-""}
ACTIVITY_THRESHOLD=${ACTIVITY_THRESHOLD:-500} # Default 500 bytes

# --- State Tracking ---
# Using temporary files for associative array simulation in POSIX sh
# Using /var/tmp which might persist longer than /tmp on some systems
STATE_DIR="/var/tmp/nomad_idle_monitor_state_$$" # Use PID for uniqueness
mkdir -p "$STATE_DIR"
# Cleanup state directory on exit
# Using trap with a function for better signal handling
cleanup() {
    echo "$(date '+%Y-%m-%d %H:%M:%S'): Cleaning up state directory $STATE_DIR..." >&2
    rm -rf "$STATE_DIR"
    echo "$(date '+%Y-%m-%d %H:%M:%S'): Cleanup complete." >&2
}
trap cleanup EXIT INT TERM

# Helper functions for state (using files)
get_state() { # $1=container_id, $2=state_type (last_bytes|last_time)
    # Use cat and handle potential errors silently
    cat "$STATE_DIR/$1.$2" 2>/dev/null || echo ""
}
set_state() { # $1=container_id, $2=state_type, $3=value
    # Use printf for potentially better portability than echo
    printf '%s' "$3" > "$STATE_DIR/$1.$2"
}
unset_state() { # $1=container_id, $2=state_type
    rm -f "$STATE_DIR/$1.$2"
}
list_tracked_ids() { # $1=state_type
    # List files matching the pattern, handle case where dir is empty
    ls "$STATE_DIR" 2>/dev/null | grep "\.$1$" | sed "s/\.$1$//"
}


# --- Function to Parse Human Readable Bytes ---
parse_bytes() {
    input_str="$1"
    # Use awk for more robust parsing in POSIX sh
    echo "$input_str" | awk '
    BEGIN {
        # Using 1000-based units (kB, MB, GB) as commonly output by docker stats
        # If docker stats uses KiB/MiB (1024-based), adjust multipliers here
        units["B"] = 1
        units["kB"] = 1000; units["KB"] = 1000; units["K"] = 1000
        units["MB"] = 1000000; units["M"] = 1000000
        units["GB"] = 1000000000; units["G"] = 1000000000
        units["TB"] = 1000000000000; units["T"] = 1000000000000
        # Add KiB/MiB/GiB/TiB just in case docker stats format changes
        units["KiB"] = 1024
        units["MiB"] = 1048576
        units["GiB"] = 1073741824
        units["TiB"] = 1099511627776
    }
    {
        num = $0+0 # Extract numeric part, handles leading/trailing whitespace
        unit = $0; sub(/^[0-9.]+/, "", unit); sub(/^[[:space:]]+|[[:space:]]+$/, "", unit) # Extract unit part, trim whitespace

        multiplier = units[unit]
        if (multiplier == "") {
             # Handle no unit or unknown unit
             if (unit != "" && unit != "B") {
                 # Log to stderr
                 printf "WARN: Unknown unit '\''%s'\'' in '\''%s'\'', assuming bytes.\n", unit, $0 > "/dev/stderr"
             }
             multiplier = 1
        }
        # Use printf for integer conversion, safer than bc for simple cases
        printf "%.0f\n", num * multiplier
    }'
}

# --- Initial Validation ---
if [ -z "$NOMAD_ENDPOINT" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S'): FATAL: NOMAD_ENDPOINT environment variable not set. Exiting."
    exit 1
fi
if [ -z "$NOMAD_TOKEN" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S'): FATAL: NOMAD_TOKEN environment variable not set. Exiting."
    exit 1
fi
# POSIX check for number
case "$ACTIVITY_THRESHOLD" in
    ''|*[!0-9]*)
        echo "$(date '+%Y-%m-%d %H:%M:%S'): WARN: Invalid ACTIVITY_THRESHOLD '$ACTIVITY_THRESHOLD', using default 500."
        ACTIVITY_THRESHOLD=500
        ;;
esac
NOMAD_ENDPOINT=${NOMAD_ENDPOINT%/} # Remove trailing slash

echo "--- Nomad Idle Job Stopper Started ---"
echo "Nomad Endpoint: ${NOMAD_ENDPOINT}"
echo "Nomad Token: **** (Hidden)"
echo "Idle Timeout: ${IDLE_TIMEOUT}s"
echo "Check Interval: ${CHECK_INTERVAL}s"
echo "Container Filter: '${CONTAINER_FILTER:-<all>}'"
echo "Activity Threshold: ${ACTIVITY_THRESHOLD} bytes"

# --- Main Loop ---
while true; do
    echo "$(date '+%Y-%m-%d %H:%M:%S'): Checking containers..."
    current_time=$(date +%s)
    # Keep track of found IDs to clean up state later
    found_ids_file="$STATE_DIR/found_ids.$$"
    # Ensure file is empty/created
    : > "$found_ids_file"

    # Construct arguments for docker ps
    # POSIX sh doesn't have arrays, build command string carefully
    # Use printf for safer quoting of the filter value
    docker_ps_cmd="docker ps --format '{{.ID}}' --no-trunc"
    if [ -n "$CONTAINER_FILTER" ]; then
        quoted_filter=$(printf "%s" "$CONTAINER_FILTER" | sed "s/'/'\\\\''/g; 1s/^/'/; \$s/\$/'/") # Escape single quotes within the filter
        docker_ps_cmd="$docker_ps_cmd --filter $quoted_filter"
    fi

    echo "$(date '+%Y-%m-%d %H:%M:%S'): DEBUG: Running docker command: $docker_ps_cmd"

    # Execute docker ps and read IDs line by line
    # Use sh -c to handle the command string properly
    docker_ps_output=$(sh -c "$docker_ps_cmd" 2>&1)
    cmd_status=$?

    if [ $cmd_status -ne 0 ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S'): ERROR: Failed to list containers. Is Docker running? Exit status: $cmd_status. Output: $docker_ps_output"
        sleep "$CHECK_INTERVAL"
        continue
    fi
    echo "$(date '+%Y-%m-%d %H:%M:%S'): DEBUG: docker ps raw output:"$'\n'"$docker_ps_output"

    # Check if output is empty before processing
    if [ -z "$docker_ps_output" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S'): No running containers matching filter found."
    fi

    # Process each container ID using a while read loop (POSIX compliant)
    echo "$docker_ps_output" | while IFS= read -r container_id || [ -n "$container_id" ]; do # Handle last line without newline
        # Skip empty lines just in case
        if [ -z "$container_id" ]; then continue; fi

        # Record found ID (using printf for safety)
        printf '%s\n' "$container_id" >> "$found_ids_file"
        container_name="" # Reset

        # Get current network stats as string "Rx / Tx"
        current_stats_str=$(docker stats --no-stream --format "{{.NetIO}}" "$container_id" 2>/dev/null)
        stats_status=$?

        # Shorten container ID for logging
        short_id=$(echo "$container_id" | cut -c 1-12)

        if [ $stats_status -ne 0 ] || [ -z "$current_stats_str" ]; then
            # Try to get name even if stats failed
            container_name=$(docker ps -a --no-trunc --format '{{.Names}}' -f "id=$container_id" 2>/dev/null || echo "<unknown>")
            echo "$(date '+%Y-%m-%d %H:%M:%S'): WARN: Could not get stats for container ${container_name} (${short_id}). It might have stopped."
            unset_state "$container_id" "last_bytes"
            unset_state "$container_id" "last_time"
            continue
        fi

        # Parse the current Rx and Tx bytes
        # Split using awk for POSIX compliance
        current_rx_str=$(echo "$current_stats_str" | awk '{print $1}')
        current_tx_str=$(echo "$current_stats_str" | awk '{print $3}')
        current_rx_bytes=$(parse_bytes "$current_rx_str")
        current_tx_bytes=$(parse_bytes "$current_tx_str")
        # Use arithmetic expansion (POSIX)
        current_total_bytes=$((current_rx_bytes + current_tx_bytes))

        # Get last known state
        last_active_time_val=$(get_state "$container_id" "last_time")

        # Check if we have seen this container before
        if [ -z "$last_active_time_val" ]; then
            container_name=$(docker ps --no-trunc --format '{{.Names}}' -f "id=$container_id" 2>/dev/null)
            echo "$(date '+%Y-%m-%d %H:%M:%S'): INFO: Tracking new container ${container_name:-<unknown>} (${short_id}). Initial NetIO: ${current_stats_str} (${current_total_bytes} bytes total)"
            set_state "$container_id" "last_bytes" "$current_total_bytes"
            set_state "$container_id" "last_time" "$current_time"
        else
            # Compare current total bytes with last known total bytes
            last_bytes=$(get_state "$container_id" "last_bytes")
            # Handle case where last_bytes might be empty if state file was missing
            if [ -z "$last_bytes" ]; then last_bytes=0; fi

            change_in_bytes=$((current_total_bytes - last_bytes))

            # Check if change exceeds the threshold
            # Use POSIX integer comparison '-gt'
            if [ "$change_in_bytes" -gt "$ACTIVITY_THRESHOLD" ]; then
                container_name=$(docker ps --no-trunc --format '{{.Names}}' -f "id=$container_id" 2>/dev/null)
                echo "$(date '+%Y-%m-%d %H:%M:%S'): INFO: Significant network activity detected for ${container_name:-<unknown>} (${short_id}). NetIO: ${current_stats_str} (${current_total_bytes} bytes total. Change: +${change_in_bytes} bytes > ${ACTIVITY_THRESHOLD})"
                set_state "$container_id" "last_bytes" "$current_total_bytes"
                set_state "$container_id" "last_time" "$current_time"
            else
                # No significant activity, check idle time
                idle_duration=$((current_time - last_active_time_val))
                container_name=$(docker ps --no-trunc --format '{{.Names}}' -f "id=$container_id" 2>/dev/null)
                echo "$(date '+%Y-%m-%d %H:%M:%S'): INFO: Container ${container_name:-<unknown>} (${short_id}) idle for ${idle_duration}s. (NetIO: ${current_stats_str}, ${current_total_bytes} bytes total. Change: ${change_in_bytes} bytes <= ${ACTIVITY_THRESHOLD})"

                # Use POSIX integer comparison '-ge'
                if [ "$idle_duration" -ge "$IDLE_TIMEOUT" ]; then
                    echo "$(date '+%Y-%m-%d %H:%M:%S'): ACTION: Container ${container_name:-<unknown>} (${short_id}) idle for ${idle_duration}s (>= ${IDLE_TIMEOUT}s). Attempting to stop associated Nomad job..."

                    # --- Nomad Job Stop Logic ---
                    if [ -z "$container_name" ]; then
                        echo "$(date '+%Y-%m-%d %H:%M:%S'): ERROR: Could not retrieve name for container ${short_id} to determine Nomad job. Cannot stop job."
                    else
                        # --- Job Name Derivation (v5.1 logic - adapted for POSIX) ---
                        alloc_id_length=37
                        container_name_length=$(echo -n "$container_name" | wc -c)
                        job_name_end_index=$((container_name_length - alloc_id_length))
                        job_name="" # Default to empty

                        # Use POSIX integer comparison '-gt'
                        if [ "$job_name_end_index" -gt 0 ]; then
                            job_name=$(echo "$container_name" | cut -c 1-$job_name_end_index)
                            # Basic check: suffix looks like UUID part?
                            alloc_part=$(echo "$container_name" | cut -c $((job_name_end_index + 1))-)
                            # POSIX check for pattern: starts with '-', contains only hex/hyphens
                            case "$alloc_part" in
                                -*[!0-9a-fA-F-]*) # Contains invalid chars after initial hyphen
                                    echo "$(date '+%Y-%m-%d %H:%M:%S'): WARN: Suffix removed ('$alloc_part') contains invalid chars. Check container naming convention. Container: '${container_name}'"
                                    job_name="" ;;
                                -*) ;; # Looks okay (starts with hyphen, only allowed chars checked implicitly)
                                *) # Does not start with hyphen
                                    echo "$(date '+%Y-%m-%d %H:%M:%S'): WARN: Suffix removed ('$alloc_part') does not start with hyphen. Check container naming convention. Container: '${container_name}'"
                                    job_name="" ;;
                            esac
                        fi

                        echo "$(date '+%Y-%m-%d %H:%M:%S'): DEBUG: Original container name: '${container_name}'. Derived job name: '${job_name}'"

                        if [ -z "$job_name" ]; then # Check if derivation failed or was reset
                            echo "$(date '+%Y-%m-%d %H:%M:%S'): WARN: Could not derive valid Nomad job name from container name '${container_name}'. Skipping API call."
                        else
                            # URL encode the job name for safety in URL path
                            # Simple encoding: replace '/' with '%2F' (common issue)
                            encoded_job_name=$(printf '%s' "$job_name" | sed 's|/|%2F|g')
                            api_url="${NOMAD_ENDPOINT}/v1/job/${encoded_job_name}?purge=false"
                            echo "$(date '+%Y-%m-%d %H:%M:%S'): INFO: Sending DELETE request to Nomad API: ${api_url} for derived job '${job_name}'"

                            # Use temporary file for curl output/error
                            curl_temp_output="$STATE_DIR/curl_out.$$"
                            # Capture status code separately
                            http_code=$(curl --silent --show-error --fail -X DELETE \
                                -H "X-Nomad-Token: $NOMAD_TOKEN" \
                                "$api_url" -o "$curl_temp_output" -w "%{http_code}" 2>"$curl_temp_output.err")
                            curl_status=$?
                            curl_err=$(cat "$curl_temp_output.err")
                            curl_output=$(cat "$curl_temp_output")
                            rm -f "$curl_temp_output" "$curl_temp_output.err"


                            # Check curl exit code first, then HTTP status code
                            if [ $curl_status -eq 0 ]; then
                                echo "$(date '+%Y-%m-%d %H:%M:%S'): SUCCESS: Nomad job stop request sent successfully for job '${job_name}'. HTTP Status: $http_code. API Response: ${curl_output:-<none>}"
                            else
                                # Check for common Nomad errors (like 404 Not Found) using grep
                                if echo "$curl_err" | grep -q -E '404 Not Found|job not found'; then
                                     echo "$(date '+%Y-%m-%d %H:%M:%S'): ERROR: Failed to stop Nomad job '${job_name}'. Job not found (404) or derivation incorrect. Curl exit code: $curl_status. HTTP Status: $http_code. Error: ${curl_err}"
                                elif echo "$curl_err" | grep -q 'Could not resolve host'; then
                                     echo "$(date '+%Y-%m-%d %H:%M:%S'): ERROR: Failed to send Nomad job stop request for job '${job_name}'. Could not resolve Nomad host. Curl exit code: $curl_status. Error: ${curl_err}"
                                else
                                     echo "$(date '+%Y-%m-%d %H:%M:%S'): ERROR: Failed to send Nomad job stop request for job '${job_name}'. Curl exit code: $curl_status. HTTP Status: $http_code. Error: ${curl_err}"
                                fi
                            fi
                        fi
                    fi
                    # --- End Nomad Job Stop Logic ---

                    # Remove container from tracking AFTER attempting the API call
                    echo "$(date '+%Y-%m-%d %H:%M:%S'): INFO: Removing container ${container_name:-${short_id}} from active monitoring."
                    unset_state "$container_id" "last_bytes"
                    unset_state "$container_id" "last_time"

                fi # End idle duration check
            fi # End significant activity check
        fi # End first time seen check
    done # End container loop

    # --- Cleanup State ---
    # List currently tracked IDs (based on last_time files)
    list_tracked_ids "last_time" | while IFS= read -r tracked_id || [ -n "$tracked_id" ]; do
        # Skip empty lines
        [ -z "$tracked_id" ] && continue
        # Check if the tracked ID was found in the current docker ps output
        # Use grep -Fx to match the whole line exactly
        if ! grep -q -Fx "$tracked_id" "$found_ids_file"; then
             # Try to get name for logging
             tracked_name=$(docker ps -a --no-trunc --format '{{.Names}}' -f "id=$tracked_id" 2>/dev/null || echo "<unknown name>")
             tracked_short_id=$(echo "$tracked_id" | cut -c 1-12)
             echo "$(date '+%Y-%m-%d %H:%M:%S'): INFO: Container ${tracked_name} (${tracked_short_id}) is no longer running or matching filter. Removing from tracking."
             unset_state "$tracked_id" "last_bytes"
             unset_state "$tracked_id" "last_time"
        fi
    done
    # Clean up the temporary found IDs file
    rm -f "$found_ids_file"

    sleep "$CHECK_INTERVAL"
done

echo "$(date '+%Y-%m-%d %H:%M:%S'): --- Nomad Idle Job Stopper Exiting ---"
exit 0
EOF
# Check script creation
if [ $? -ne 0 ]; then echo "ERROR: Failed to create script file." >&2; exit 1; fi

# --- Set Script Permissions ---
echo "Setting executable permissions for $SCRIPT_PATH..."
chmod +x "$SCRIPT_PATH"
if [ $? -ne 0 ]; then echo "ERROR: Failed to set permissions." >&2; exit 1; fi

# --- Create Systemd Service File ---
echo "Creating systemd service file at $SERVICE_PATH..."
cat << EOF > "$SERVICE_PATH"
[Unit]
Description=Nomad Idle Job Stopper Service
After=docker.service network-online.target
Requires=docker.service
Wants=network-online.target

[Service]
User=root
EnvironmentFile=$ENV_PATH
# Explicitly use /bin/sh to run the script
ExecStart=/bin/sh $SCRIPT_PATH
Restart=on-failure
RestartSec=10s
StandardOutput=journal
StandardError=journal
# Consider using RuntimeDirectory for state if /tmp is too volatile
# RuntimeDirectory=nomad-idle-monitor
# RuntimeDirectoryPreserve=yes

[Install]
WantedBy=multi-user.target
EOF
# Check service file creation
if [ $? -ne 0 ]; then echo "ERROR: Failed to create service file." >&2; exit 1; fi

# --- Create Environment File ---
echo "Creating/Overwriting environment file at $ENV_PATH..."
cat << EOF > "$ENV_PATH"
# Configuration for the Nomad Idle Job Stopper Service ($SCRIPT_PATH)
# Generated by installation script - edit manually with caution or re-run install script.

# === Monitoring Settings ===
IDLE_TIMEOUT="$ARG_IDLE_TIMEOUT"
CHECK_INTERVAL="$ARG_CHECK_INTERVAL"
CONTAINER_FILTER="$ARG_CONTAINER_FILTER"

# ACTIVITY_THRESHOLD: Minimum change in total bytes (Rx+Tx) since last check
# to be considered "significant activity" that resets the idle timer.
# Helps ignore background network noise. Default is 500.
ACTIVITY_THRESHOLD=500

# === Nomad API Settings ===
NOMAD_ENDPOINT="$ARG_NOMAD_ENDPOINT"
# SECURITY WARNING: This token is stored in plain text.
NOMAD_TOKEN="$ARG_NOMAD_TOKEN"

EOF
# Check env file creation
if [ $? -ne 0 ]; then echo "ERROR: Failed to create environment file." >&2; exit 1; fi
chmod 600 "$ENV_PATH"

# --- Reload Systemd, Enable and Start Service ---
echo "Reloading systemd daemon..."
systemctl daemon-reload
if [ $? -ne 0 ]; then echo "ERROR: Failed to reload systemd." >&2; exit 1; fi

echo "Stopping potentially running/failed service $SERVICE_NAME..."
systemctl stop "$SERVICE_NAME"

echo "Enabling service $SERVICE_NAME to start on boot..."
systemctl enable "$SERVICE_NAME"
if [ $? -ne 0 ]; then echo "ERROR: Failed to enable service." >&2; exit 1; fi

echo "Starting service $SERVICE_NAME..."
systemctl start "$SERVICE_NAME"
if [ $? -ne 0 ]; then
    echo "ERROR: Failed to start service $SERVICE_NAME." >&2
    echo "       Check service status with 'systemctl status $SERVICE_NAME'"
    echo "       Check service logs with 'journalctl -u $SERVICE_NAME'"
    exit 1
fi

sleep 2

echo ""
echo "--- Installation/Update Complete! ---"
echo ""
echo "The Nomad Idle Job Stopper service ($SERVICE_NAME) has been installed/updated and started."
echo "Configuration is stored in: $ENV_PATH"
echo "  -> You can edit ACTIVITY_THRESHOLD in this file (default is 500 bytes)."
echo "  -> Re-run this installation script with new arguments to update other settings."
echo "  -> SECURITY: The Nomad token is stored in plain text in $ENV_PATH. Protect this file."
echo ""
echo "To check the service status:"
echo "  sudo systemctl status $SERVICE_NAME"
echo ""
echo "To view the service logs (check for 'Significant network activity' vs idle messages):"
echo "  sudo journalctl -u $SERVICE_NAME -f"
echo ""
echo "To stop the service:"
echo "  sudo systemctl stop $SERVICE_NAME"
echo ""

echo "Current service status:"
systemctl status "$SERVICE_NAME" --no-pager -l

exit 0
