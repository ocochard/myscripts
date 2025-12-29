#!/bin/sh
# Measuring fast.com download speed with curl
# Fixed version for accurate high-speed measurements

# --- 1. TOKEN EXTRACTION AND VALIDATION ---

# First, dynamically discover the current JavaScript filename from fast.com's HTML.
# Fast.com changes their JavaScript filename regularly (e.g., app-ed402d.js, app-0bffe1.js).
# 1. 'curl -s https://fast.com': Downloads the HTML page.
# 2. 'grep -o ...': Extracts the JavaScript filename (e.g., 'app-0bffe1.js').
# 3. 'head -1': Takes only the first match.
# 4. 'tr -d '\n\r'': Removes any newline or carriage return characters.
js_file=$(curl -s https://fast.com | grep -o 'app-[^"]*\.js' | head -1 | tr -d '\n\r')

# Check if the JavaScript filename was successfully retrieved.
if [ -z "$js_file" ]; then
  echo "Failed to retrieve JavaScript filename from fast.com"
  exit 1
fi

# Extract the unique token required by the fast.com API from their main JavaScript file.
# 1. 'curl -s ...': Downloads the JavaScript content silently.
# 2. 'grep -o ...': Extracts the token string literal (e.g., 'token:"abcdef..."').
# 3. 'cut -f2 -d'"': Extracts the token value itself by splitting at the quote.
# 4. 'head -1': Takes the first token found.
# 5. 'tr -d '\n\r'': Removes any newline or carriage return characters to ensure the token is a single line, preventing URL errors.
token=$(curl -s "https://fast.com/$js_file" | grep -o 'token:"[^"]*' | cut -f2 -d'"' | head -1 | tr -d '\n\r')

# Check if the token was successfully retrieved.
if [ -z "$token" ]; then
  echo "Empty token"
  exit 1
fi

echo "Starting speed test..." >&2

# --- 2. THROUGHPUT MONITOR FUNCTION (Replaces 'pv') ---

# Function to monitor the data transfer rate using the 'dd' utility.
monitor_dd() {
  # DD_PID holds the Process ID of the shell running the dd command.
  DD_PID="$1"
  # Loop repeatedly while the 'dd' process is still running.
  while kill -INFO "$DD_PID" 2>/dev/null; do
    # 'kill -INFO $DD_PID': Sends the INFO signal (equivalent to Ctrl+T) to the dd process.
    # This signal forces 'dd' to print its current transfer rate and status to the terminal (stderr).
    sleep 2
   done
}

# --- 3. CONCURRENT DOWNLOAD PIPELINE (The Generator) ---

# First, get all URLs at once and store them
urls=$(curl -s "https://api.fast.com/netflix/speedtest?https=true&token=$token" | grep -o 'https[^"]*')

# Count the URLs for user feedback
url_count=$(echo "$urls" | wc -l | tr -d ' ')
echo "Found $url_count download servers, starting concurrent downloads..." >&2

# The outer parenthesis '( ... )' puts all the enclosed commands into a single sub-shell,
# and the pipe '|' connects its aggregated output to the next block (the monitor).
(
  # Process all URLs and launch ALL background downloads BEFORE any blocking operations
  echo "$urls" | while read url; do
    if [ -n "$url" ]; then
      # POSIX-compliant string substitution using 'sed' to change the URL endpoint.
      # The first request is a small 2KB chunk (0-2048 bytes).
      first=$(echo "$url" | sed 's/speedtest/speedtest\/range\/0-2048/')
      # Increased to 100MB chunks (0-104857600 bytes) for high-speed connections (was 25MB).
      # This reduces overhead and better saturates gigabit+ connections.
      next=$(echo "$url" | sed 's/speedtest/speedtest\/range\/0-104857600/')

      # Start a new background process '( ... ) &' for each URL to run ALL tests truly concurrently.
      (
        # Perform the initial, small request.
        # '-H ...' sets necessary headers to mimic a browser and prevent rejection by the server.
        # Note: The output of this curl command is NOT redirected, so it flows out to the main pipeline.
        curl -s -H 'Referer: https://fast.com/' -H 'Origin: https://fast.com' "$first"

        i=1
        # Increased to 15 iterations for better sustained measurement (was 10).
        while [ "$i" -le 15 ]; do
          # Perform the large download request. The output also flows to the main pipeline.
          curl -s -H 'Referer: https://fast.com/' -H 'Origin: https://fast.com' "$next"
          i=$((i + 1))
        done
      ) & # '&' runs this entire download sequence concurrently with others.
    fi
  done

  # CRITICAL: Wait for ALL background downloads to complete before closing the pipe
  wait
) | {
  # --- 4. THROUGHPUT MONITOR EXECUTION (The Receiver) ---
  # This block receives all the combined data from the concurrent background processes via the pipe.
  # Get the Process ID of the current shell block. This PID will be used to signal 'dd'.
  SHELL_PID=$$

  # Start the monitoring function in the background.
  monitor_dd "$SHELL_PID" &
  MONITOR_PID=$! # Store the PID of the background monitor process.

  # The core speed measurement tool.
  # 'dd of=/dev/null' reads all the data piped from the left side and discards it.
  # While running, it is the foreground process that receives the INFO signals from monitor_dd.
  # Run dd, but pipe its standard error (where the speed is printed) to awk.
  # We use 'exec 2>&1' to temporarily redirect stderr to stdout for dd,
  # allowing us to pipe the status messages.
  dd of=/dev/null 2>&1 | awk '
    /bytes transferred/ {
      # More robust parsing for FreeBSD dd output
      # FreeBSD dd format: "X bytes transferred in Y secs (Z bytes/sec)"
      # Scan through all fields to find bytes/sec value
      rate_bytes = 0
      for (i = 1; i <= NF; i++) {
        if ($i ~ /bytes\/sec/ || $i ~ /bytes\/sec\)/) {
          # Found the bytes/sec field, extract number from previous field
          rate_field = $(i-1)
          # Remove parentheses and any non-numeric characters
          gsub(/[^0-9]/, "", rate_field)
          if (length(rate_field) > 0) {
            rate_bytes = rate_field + 0
            break
          }
        }
      }

      if (rate_bytes > 0) {
        # --- Calculation ---
        # 1. Convert Bytes/sec to Bits/sec (Multiply by 8)
        # 2. Convert Bits/sec to Megabits/sec (Divide by 1024 * 1024)
        rate_mbit = rate_bytes * 8 / 1048576
        # --- Formatting and Display ---
        if (rate_mbit >= 1024) {
          # If rate is 1024 Mbit/s or higher (1 Gbit/s), display in Gbit/s
          rate_gbit = rate_mbit / 1024
          printf "Download Rate: %.2f Gbit/s\n", rate_gbit
        } else {
          # Otherwise, display in Mbit/s
          printf "Download Rate: %.2f Mbit/s\n", rate_mbit
        }
      }
    }
    # Print the original dd status lines for debugging
    { print }
  '

  # Clean up: Kill the background monitoring function when the data transfer (dd) is complete.
  kill "$MONITOR_PID" 2>/dev/null
}
# The final result (transfer rate) is displayed periodically on the terminal (stderr)
# by the 'dd' process until all downloads are finished
