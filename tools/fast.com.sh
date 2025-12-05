#!/bin/sh
# Measuring fast.com download speed with curl

# --- 1. TOKEN EXTRACTION AND VALIDATION ---

# Extract the unique token required by the fast.com API from their main JavaScript file.
# 1. 'curl -s ...': Downloads the JavaScript content silently.
# 2. 'grep -o ...': Extracts the token string literal (e.g., 'token:"abcdef..."').
# 3. 'cut -f2 -d'"': Extracts the token value itself by splitting at the quote.
# 4. 'tr -d '\n\r'': Removes any newline or carriage return characters to ensure the token is a single line, preventing URL errors.
token=$(curl -s https://fast.com/app-ed402d.js | grep -o 'token:"[^"]*' | cut -f2 -d'"' | tr -d '\n\r')

# Check if the token was successfully retrieved.
if [ -z "$token" ]; then
  echo "Empty token"
  exit 1
fi

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

# The outer parenthesis '( ... )' puts all the enclosed commands into a single sub-shell,
# and the pipe '|' connects its aggregated output to the next block (the monitor).
(
  # Get the list of actual download URLs from the API using the extracted token.
  curl -s "https://api.fast.com/netflix/speedtest?https=true&token=$token" | \
  # Extract the 'url' values from the API's JSON response (assuming simplified grep,
  # but a full script might use 'jq -r .[].url' for robustness).
  grep -o 'https[^"]*' | \

  # Read each URL one by one from the pipeline.
  while read url; do
    # POSIX-compliant string substitution using 'sed' to change the URL endpoint.
    # The first request is a small 2KB chunk (0-2048 bytes).
    first=$(echo "$url" | sed 's/speedtest/speedtest\/range\/0-2048/')
    # The subsequent requests are large 25MB chunks (0-26214400 bytes) to saturate the connection.
    next=$(echo "$url" | sed 's/speedtest/speedtest\/range\/0-26214400/')

    # Start a new background process '( ... ) &' for each URL to run the tests concurrently.
    (
      # Perform the initial, small request.
      # '-H ...' sets necessary headers to mimic a browser and prevent rejection by the server.
      # Note: The output of this curl command is NOT redirected, so it flows out to the main pipeline.
      curl -s -H 'Referer: https://fast.com/' -H 'Origin: https://fast.com' "$first"

      i=1
      # Loop 10 times for the large download chunks to ensure a significant data transfer.
      while [ "$i" -le 10 ]; do
        # Perform the large download request. The output also flows to the main pipeline.
        curl -s -H 'Referer: https://fast.com/' -H 'Origin: https://fast.com' "$next"
        i=$((i + 1))
      done
    ) & # '&' runs this entire download sequence concurrently with others.
  done
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
  dd of=/dev/null

   # Clean up: Kill the background monitoring function when the data transfer (dd) is complete.
  kill "$MONITOR_PID" 2>/dev/null
}
# The final result (transfer rate) is displayed periodically on the terminal (stderr)
# by the 'dd' process until all downloads are finished
