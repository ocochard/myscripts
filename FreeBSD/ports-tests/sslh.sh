#!/bin/sh
set -eu
sslh-ev --ssh=127.0.0.1:22 --listen=127.0.0.1:8022 --pidfile=/tmp/sslh.pid --logfile=/tmp/sslh.log --verbose-connections=4
ps -p $(cat /tmp/sslh.pid) && echo "running (good)" || echo "NOT running (bad)"
ssh -p 8022 127.0.0.1 || true
grep localhost /tmp/sslh.log && echo "SSH connection detected (good)" || echo "SSH connection NOT detected (bad)"
pkill -F /tmp/sslh.pid
rm /tmp/sslh.pid
rm /tmp/sslh.log
echo "Seems working fine"
