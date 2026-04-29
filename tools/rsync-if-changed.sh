#!/bin/sh

INTERVAL=300  # 5 minutes

usage() {
    echo "Usage: $0 <src> <dst>"
    echo "Example: $0 ~/.certificates server:/dir/certificates"
    exit 1
}

[ $# -eq 2 ] || usage

SRC="$1"
DST="$2"

[ -e "$SRC" ] || { echo "Error: source '$SRC' does not exist"; exit 1; }

# Ensure trailing slash on directories so rsync copies contents, not the dir itself
[ -d "$SRC" ] && SRC="${SRC%/}/"

echo "Syncing '$SRC' -> '$DST' every ${INTERVAL}s (Ctrl-C to stop)..."

while true; do
    rsync -a "$SRC" "$DST"
    sleep "$INTERVAL"
done
