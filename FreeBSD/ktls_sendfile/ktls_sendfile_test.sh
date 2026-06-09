#!/bin/sh
#
# Drive ktls_sendfile_server against itself: generate a cert and a random
# > 128 KiB file, start the server, fetch the file N times with curl over
# TLS, and report how many fetches came back with a wrong sha256.
#
# Exits 0 if every fetch matched, 1 if any fetch was corrupted, 2 on setup
# error. Intended to be run on FreeBSD 15.0 where the bug reproduces; on
# unaffected systems (14.x, 16.x as of this writing) all fetches match.

set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
SERVER=${SERVER:-$SCRIPT_DIR/ktls_sendfile_server}
PORT=${PORT:-14443}
SIZE_MB=${SIZE_MB:-4}        # well above the reported 128 KiB threshold
ITERATIONS=${ITERATIONS:-50}
KTLS=${KTLS:-1}              # 0 to pass -n (KTLS disabled) as a control
WORKDIR=$(mktemp -d -t ktls_sendfile)

cleanup() {
    [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null || true
    [ -n "${SERVER_PID:-}" ] && wait "$SERVER_PID" 2>/dev/null || true
    rm -rf "$WORKDIR"
}
trap cleanup EXIT INT TERM

if [ ! -x "$SERVER" ]; then
    echo "server binary not found: $SERVER" >&2
    echo "run 'make' first" >&2
    exit 2
fi
if ! command -v curl >/dev/null; then
    echo "curl required" >&2
    exit 2
fi
if ! command -v openssl >/dev/null; then
    echo "openssl required" >&2
    exit 2
fi

echo "workdir: $WORKDIR"
cd "$WORKDIR"

# Self-signed cert (valid 1 day, no passphrase).
openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem \
            -days 1 -nodes -subj /CN=localhost >/dev/null 2>&1

# Random payload — random data so any corruption hits the hash.
dd if=/dev/urandom of=test.bin bs=1m count="$SIZE_MB" status=none
EXPECT=$(sha256 -q test.bin)
echo "test file: ${SIZE_MB} MiB, sha256=$EXPECT"

SERVER_ARGS="-c cert.pem -k key.pem -f test.bin -p $PORT"
if [ "$KTLS" = "0" ]; then
    SERVER_ARGS="$SERVER_ARGS -n"
    echo "KTLS: disabled (-n, control run)"
else
    echo "KTLS: enabled (default — bug-prone path)"
fi

"$SERVER" $SERVER_ARGS >server.log 2>&1 &
SERVER_PID=$!

# Wait for the listening socket to come up. sockstat would be cleaner but
# isn't available in every minimal install; a TCP connect probe is portable.
i=0
until nc -z 127.0.0.1 "$PORT" 2>/dev/null; do
    i=$((i + 1))
    if [ $i -gt 50 ]; then
        echo "server did not start within 5s" >&2
        cat server.log >&2
        exit 2
    fi
    sleep 0.1
done

# Stat counters before/after, so the report includes how much KTLS traffic
# the kernel actually processed.
STATS_BEFORE=$(sysctl -n kern.ipc.tls.stats.enable_calls 2>/dev/null || echo 0)

echo "running $ITERATIONS fetches against https://127.0.0.1:$PORT/"
fail=0
i=0
while [ $i -lt "$ITERATIONS" ]; do
    i=$((i + 1))
    curl -sk "https://127.0.0.1:$PORT/" -o out.bin
    got=$(sha256 -q out.bin)
    if [ "$got" != "$EXPECT" ]; then
        fail=$((fail + 1))
        echo "MISMATCH on iteration $i: got=$got" >&2
        # Keep the first corrupt sample for post-mortem.
        [ -f corrupt.bin ] || cp out.bin corrupt.bin
    fi
done

STATS_AFTER=$(sysctl -n kern.ipc.tls.stats.enable_calls 2>/dev/null || echo 0)
DELTA=$((STATS_AFTER - STATS_BEFORE))

echo "---"
echo "kern.ipc.tls.stats.enable_calls delta: $DELTA (expected ~$ITERATIONS if KTLS active)"
echo "fetches:    $ITERATIONS"
echo "mismatches: $fail"

if [ "$fail" -gt 0 ]; then
    echo "FAIL — KTLS + sendfile corruption reproduced"
    echo "first corrupt sample kept at: $WORKDIR/corrupt.bin"
    trap - EXIT  # leave $WORKDIR for inspection
    kill "$SERVER_PID" 2>/dev/null || true
    exit 1
fi

echo "PASS — no corruption seen"
exit 0
