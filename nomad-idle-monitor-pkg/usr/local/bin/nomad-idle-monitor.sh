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
# Create a unique state dir IF the service manager doesn't provide one (like systemd's RuntimeDirectory)
# We check if STATE_DIRECTORY is set by systemd (or similar)
if [ -z "$STATE_DIRECTORY" ]; then
    # If not set by systemd, create a unique one in /var/tmp based on PID
    # Note: This might not be ideal if multiple instances run, but systemd prevents that by default.
    STATE_DIR="/var/tmp/nomad_idle_monitor_state_$$" # Use PID for uniqueness
    mkdir -p "$STATE_DIR"
    CLEANUP_DIR="$STATE_DIR" # Mark this dir for cleanup
else
    # Use the directory provided by systemd's RuntimeDirectory=
    STATE_DIR="$STATE_DIRECTORY"
    # Do not clean up this directory, systemd manages it.
    CLEANUP_DIR=""
fi


# Cleanup state directory on exit (only if we created it)
# Using trap with a function for better signal handling
cleanup() {
    if [ -n "$CLEANUP_DIR" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S'): Cleaning up state directory $CLEANUP_DIR..." >&2
        rm -rf "$CLEANUP_DIR"
        echo "$(date '+%Y-%m-%d %H:%M:%S'): Cleanup complete." >&2
    else
         echo "$(date '+%Y-%m-%d %H:%M:%S'): Not cleaning up state directory $STATE_DIR (managed externally)." >&2
    fi
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
    echo "$(date '+%Y-%m-%d %H:%M:%S'): FATAL: NOMAD_ENDPOINT environment variable not set or empty in /etc/default/nomad-idle-monitor. Exiting."
    exit 1
fi
if [ -z "$NOMAD_TOKEN" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S'): FATAL: NOMAD_TOKEN environment variable not set or empty in /etc/default/nomad-idle-monitor. Exiting."
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
echo "State Directory: ${STATE_DIR}"
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
    # Use the state dir managed by systemd or the script itself
    found_ids_file="$STATE_DIR/found_ids.$$"
    # Ensure file is empty/created
    : > "$found_ids_file"

    # Construct arguments for docker ps
    # POSIX sh doesn't have arrays, build command string carefully
    # Use printf for safer quoting of the filter value
    docker_ps_cmd="docker ps --format '{{.ID}}' --no-trunc"
    if [ -n "$CONTAINER_FILTER" ]; then
        # Escape single quotes within the filter for safe execution via sh -c
        # This sequence replaces ' with '\''
        safe_filter=$(printf '%s' "$CONTAINER_FILTER" | sed "s/'/'\\\\''/g")
        docker_ps_cmd="$docker_ps_cmd --filter '$safe_filter'"
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
    # Add newline for formatting debug output
    echo "$(date '+%Y-%m-%d %H:%M:%S'): DEBUG: docker ps raw output:"$'\n'"$docker_ps_output"

    # Check if output is empty before processing
    if [ -z "$docker_ps_output" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S'): No running containers matching filter found."
    fi

    # Process each container ID using a while read loop (POSIX compliant)
    # Handles last line even if it doesn't end with a newline
    echo "$docker_ps_output" | while IFS= read -r container_id || [ -n "$container_id" ]; do
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
            # Try to get name even if stats failed (container might have just stopped)
            container_name=$(docker ps -a --no-trunc --format '{{.Names}}' -f "id=$container_id" 2>/dev/null || echo "<unknown>")
            echo "$(date '+%Y-%m-%d %H:%M:%S'): WARN: Could not get stats for container ${container_name} (${short_id}). It might have stopped."
            # Clean up state for this potentially stopped container
            unset_state "$container_id" "last_bytes"
            unset_state "$container_id" "last_time"
            continue
        fi

        # Parse the current Rx and Tx bytes
        # Split using awk for POSIX compliance
        current_rx_str=$(echo "$current_stats_str" | awk '{print $1}')
        current_tx_str=$(echo "$current_stats_str" | awk '{print $3}') # Get 3rd field for Tx
        current_rx_bytes=$(parse_bytes "$current_rx_str")
        current_tx_bytes=$(parse_bytes "$current_tx_str")

        # Use arithmetic expansion (POSIX) - ensure variables are numbers
        current_total_bytes=$(( ${current_rx_bytes:-0} + ${current_tx_bytes:-0} ))

        # Get last known state
        last_active_time_val=$(get_state "$container_id" "last_time")

        # Check if we have seen this container before
        if [ -z "$last_active_time_val" ]; then
            # First time seeing this container, get its name
            container_name=$(docker ps --no-trunc --format '{{.Names}}' -f "id=$container_id" 2>/dev/null)
            echo "$(date '+%Y-%m-%d %H:%M:%S'): INFO: Tracking new container ${container_name:-<unknown>} (${short_id}). Initial NetIO: ${current_stats_str} (${current_total_bytes} bytes total)"
            set_state "$container_id" "last_bytes" "$current_total_bytes"
            set_state "$container_id" "last_time" "$current_time"
        else
            # Compare current total bytes with last known total bytes
            last_bytes=$(get_state "$container_id" "last_bytes")
            # Handle case where last_bytes might be empty if state file was missing
            if [ -z "$last_bytes" ]; then last_bytes=0; fi

            # Use POSIX arithmetic expansion
            change_in_bytes=$((current_total_bytes - last_bytes))

            # Check if change exceeds the threshold
            # Use POSIX integer comparison '-gt'
            if [ "$change_in_bytes" -gt "$ACTIVITY_THRESHOLD" ]; then
                # Significant activity detected, update state
                container_name=$(docker ps --no-trunc --format '{{.Names}}' -f "id=$container_id" 2>/dev/null) # Get name for logging
                echo "$(date '+%Y-%m-%d %H:%M:%S'): INFO: Significant network activity detected for ${container_name:-<unknown>} (${short_id}). NetIO: ${current_stats_str} (${current_total_bytes} bytes total. Change: +${change_in_bytes} bytes > ${ACTIVITY_THRESHOLD})"
                set_state "$container_id" "last_bytes" "$current_total_bytes"
                set_state "$container_id" "last_time" "$current_time"
            else
                # No significant activity, check idle time
                # Use POSIX arithmetic expansion
                idle_duration=$((current_time - last_active_time_val))
                container_name=$(docker ps --no-trunc --format '{{.Names}}' -f "id=$container_id" 2>/dev/null) # Get name for logging
                echo "$(date '+%Y-%m-%d %H:%M:%S'): INFO: Container ${container_name:-<unknown>} (${short_id}) idle for ${idle_duration}s. (NetIO: ${current_stats_str}, ${current_total_bytes} bytes total. Change: ${change_in_bytes} bytes <= ${ACTIVITY_THRESHOLD})"

                # Check if idle duration exceeds the timeout
                # Use POSIX integer comparison '-ge'
                if [ "$idle_duration" -ge "$IDLE_TIMEOUT" ]; then
                    echo "$(date '+%Y-%m-%d %H:%M:%S'): ACTION: Container ${container_name:-<unknown>} (${short_id}) idle for ${idle_duration}s (>= ${IDLE_TIMEOUT}s). Attempting to stop associated Nomad job..."

                    # --- Nomad Job Stop Logic ---
                    if [ -z "$container_name" ]; then
                        echo "$(date '+%Y-%m-%d %H:%M:%S'): ERROR: Could not retrieve name for container ${short_id} to determine Nomad job. Cannot stop job."
                    else
                        # --- Job Name Derivation (v5.1 logic - adapted for POSIX) ---
                        # Assuming name format: <job-name>-<alloc-uuid-part>
                        # <alloc-uuid-part> is usually a hyphen followed by 36 chars (UUID)
                        alloc_id_length=37 # 1 hyphen + 36 chars
                        container_name_length=$(printf '%s' "$container_name" | wc -c)
                        job_name_end_index=$((container_name_length - alloc_id_length))
                        job_name="" # Default to empty

                        # Use POSIX integer comparison '-gt'
                        if [ "$job_name_end_index" -gt 0 ]; then
                            # Extract potential job name
                            job_name=$(echo "$container_name" | cut -c 1-$job_name_end_index)
                            # Extract potential allocation suffix
                            alloc_part=$(echo "$container_name" | cut -c $((job_name_end_index + 1))-)

                            # Basic check: Does the suffix look like a Nomad alloc ID suffix?
                            # Starts with '-', length 37, contains hex chars and hyphens.
                            # POSIX check: Starts with '-', contains only allowed characters afterwards.
                            case "$alloc_part" in
                                # Pattern: Starts with '-', followed by 36 chars that are NOT non-alphanumeric/non-hyphen
                                # This is tricky in pure POSIX sh pattern matching. Grep is easier.
                                # Let's use a simpler check: starts with '-' and is correct length.
                                # And refine if needed based on real-world container names.
                                -* )
                                    alloc_part_length=$(printf '%s' "$alloc_part" | wc -c)
                                    if [ "$alloc_part_length" -ne "$alloc_id_length" ]; then
                                         echo "$(date '+%Y-%m-%d %H:%M:%S'): WARN: Suffix '$alloc_part' removed from '${container_name}' has incorrect length (${alloc_part_length} != ${alloc_id_length}). Check container naming convention. Resetting derived job name."
                                         job_name=""
                                    # else: Looks plausible length-wise
                                    fi
                                    ;;
                                * ) # Does not start with hyphen
                                    echo "$(date '+%Y-%m-%d %H:%M:%S'): WARN: Container name '${container_name}' does not seem to end with expected '-<alloc-id>' suffix. Cannot derive job name reliably."
                                    job_name=""
                                    ;;
                            esac
                        else
                            echo "$(date '+%Y-%m-%d %H:%M:%S'): WARN: Container name '${container_name}' is too short to derive job name using expected suffix length. Cannot stop job."
                            job_name="" # Ensure job_name is empty if index calculation failed
                        fi


                        echo "$(date '+%Y-%m-%d %H:%M:%S'): DEBUG: Original container name: '${container_name}'. Derived job name: '${job_name}'"

                        if [ -z "$job_name" ]; then # Check if derivation failed or was reset
                            echo "$(date '+%Y-%m-%d %H:%M:%S'): WARN: Could not derive valid Nomad job name from container name '${container_name}'. Skipping API call."
                        else
                            # URL encode the job name for safety in URL path
                            # Very basic POSIX encoding: only '/' -> '%2F' for now.
                            # Full URL encoding in pure POSIX sh is complex. Assumes job names are simple.
                            encoded_job_name=$(printf '%s' "$job_name" | sed 's|/|%2F|g')
                            api_url="${NOMAD_ENDPOINT}/v1/job/${encoded_job_name}?purge=false"
                            echo "$(date '+%Y-%m-%d %H:%M:%S'): INFO: Sending DELETE request to Nomad API: ${api_url} for derived job '${job_name}'"

                            # Use temporary file for curl output/error in state dir
                            curl_temp_output="$STATE_DIR/curl_out.$$"
                            # Capture status code separately using -w
                            http_code=$(curl --silent --show-error --fail -X DELETE \
                                -H "X-Nomad-Token: $NOMAD_TOKEN" \
                                "$api_url" -o "$curl_temp_output" -w "%{http_code}" 2>"$curl_temp_output.err")
                            curl_status=$?
                            curl_err=$(cat "$curl_temp_output.err")
                            curl_output=$(cat "$curl_temp_output")
                            rm -f "$curl_temp_output" "$curl_temp_output.err"


                            # Check curl exit code first, then HTTP status code
                            if [ $curl_status -eq 0 ]; then
                                # Curl itself succeeded (got an HTTP response)
                                echo "$(date '+%Y-%m-%d %H:%M:%S'): SUCCESS: Nomad job stop request sent successfully for job '${job_name}'. HTTP Status: $http_code. API Response: ${curl_output:-<none>}"
                            else
                                # Curl failed (network error, DNS error, --fail triggered by HTTP 4xx/5xx)
                                # Check for common Nomad errors (like 404 Not Found) using grep on the error output
                                if echo "$curl_err" | grep -q -E '404 Not Found|job not found'; then
                                    echo "$(date '+%Y-%m-%d %H:%M:%S'): ERROR: Failed to stop Nomad job '${job_name}'. Job not found (404) or derivation incorrect. Check Nomad logs and container name. Curl exit code: $curl_status. HTTP Status: $http_code. Error: ${curl_err}"
                                elif echo "$curl_err" | grep -q 'Could not resolve host'; then
                                    echo "$(date '+%Y-%m-%d %H:%M:%S'): ERROR: Failed to send Nomad job stop request for job '${job_name}'. Could not resolve Nomad host '$NOMAD_ENDPOINT'. Curl exit code: $curl_status. Error: ${curl_err}"
                                elif echo "$curl_err" | grep -q -E '401 Unauthorized|403 Forbidden|invalid Nomad token'; then
                                     echo "$(date '+%Y-%m-%d %H:%M:%S'): ERROR: Failed to send Nomad job stop request for job '${job_name}'. Authentication failed (401/403). Check NOMAD_TOKEN. Curl exit code: $curl_status. HTTP Status: $http_code. Error: ${curl_err}"
                                else
                                    echo "$(date '+%Y-%m-%d %H:%M:%S'): ERROR: Failed to send Nomad job stop request for job '${job_name}'. Curl exit code: $curl_status. HTTP Status: $http_code. Error: ${curl_err}"
                                fi
                            fi
                        fi
                    fi
                    # --- End Nomad Job Stop Logic ---

                    # Remove container from tracking AFTER attempting the API call, regardless of success/failure
                    echo "$(date '+%Y-%m-%d %H:%M:%S'): INFO: Removing container ${container_name:-${short_id}} from active monitoring (stop attempted)."
                    unset_state "$container_id" "last_bytes"
                    unset_state "$container_id" "last_time"

                fi # End idle duration check
            fi # End significant activity check
        fi # End first time seen check
    done # End container loop < "$docker_ps_output"

    # --- Cleanup State for containers that disappeared ---
    # List currently tracked IDs (based on last_time files)
    list_tracked_ids "last_time" | while IFS= read -r tracked_id || [ -n "$tracked_id" ]; do
        # Skip empty lines
        [ -z "$tracked_id" ] && continue
        # Check if the tracked ID was found in the current docker ps output
        # Use grep -Fx to match the whole line exactly
        if ! grep -q -Fx "$tracked_id" "$found_ids_file"; then
             # Container is no longer running or matching the filter
             tracked_short_id=$(echo "$tracked_id" | cut -c 1-12)
             # We don't know the name anymore, just use the ID
             echo "$(date '+%Y-%m-%d %H:%M:%S'): INFO: Container (${tracked_short_id}) is no longer running or matching filter. Removing from tracking."
             unset_state "$tracked_id" "last_bytes"
             unset_state "$tracked_id" "last_time"
        fi
    done
    # Clean up the temporary found IDs file
    rm -f "$found_ids_file"

    sleep "$CHECK_INTERVAL"
done

echo "$(date '+%Y-%m-%d %H:%M:%S'): --- Nomad Idle Job Stopper Exiting ---"
# The cleanup trap will run automatically here
exit 0
