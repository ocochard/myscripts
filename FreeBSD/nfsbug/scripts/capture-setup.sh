#!/bin/sh
# capture-setup.sh — arm continuous NFSv4.1 recovery-trace + packet capture, then mount EFS.
#
# Run ON the FreeBSD EC2 instance (needs sudo). Reproduces the NFS4ERR_BADSESSION
# permanent wedge with full evidence:
#   - kernel NFSCL_DEBUG lines (vfs.nfs.debuglevel=1) streamed via syslog to a file
#     that survives the wedge (dmesg has no -w on this FreeBSD and its ring rotates).
#   - tcpdump ring buffer on the efs-proxy loopback port.
# After it wedges (minutes to hours), pull /tmp/nfsdbg.log + /tmp/efs_lo0.pcap*.
#
# Usage: sudo sh capture-setup.sh <fs-id> [mountpoint]
#   e.g. sudo sh capture-setup.sh fs-XXXXXXXXXXXXXXXXX /efs

set -e
FSID="${1:?usage: capture-setup.sh <fs-id> [mountpoint]}"
MP="${2:-/efs}"

echo "=== enable NFS client debug (NFSCL_DEBUG level 1) ==="
sysctl vfs.nfs.debuglevel=1

echo "=== stream NFS recovery debug lines from syslog to /tmp/nfsdbg.log ==="
# kern.debug -> /var/log/messages (see /etc/syslog.conf). tail -F survives log rotation.
pkill -f 'tail -F /var/log/messages' 2>/dev/null || true
nohup sh -c 'tail -F /var/log/messages | grep --line-buffered -iE \
  "badsession|create session|aft exch|aft createsess|Marked defunct|Filling in new|Got err|Initiate recovery|fop=|failed seq|check NFS clients|exchangeid|clientid" \
  > /tmp/nfsdbg.log 2>&1' >/dev/null 2>&1 &
sleep 1

echo "=== start tcpdump ring on lo0 (6 x 50MB) ==="
pkill -f 'tcpdump.*efs_lo0' 2>/dev/null || true
nohup tcpdump -i lo0 -n -s 0 -U -C 50 -W 6 -w /tmp/efs_lo0.pcap >/tmp/tcpdump.log 2>&1 &
sleep 2

logger -t EFSTEST "===MOUNT_ATTEMPT_START==="
echo "=== mount EFS (retry once for the efs-proxy startup race) ==="
/usr/local/sbin/mount_efs "$FSID" "$MP" -o tls,iam 2>&1 || {
	echo "first attempt lost the proxy race, retrying in 2s"; sleep 2
	/usr/local/sbin/mount_efs "$FSID" "$MP" -o tls,iam 2>&1
}

echo "=== state ==="
mount | grep "$MP" || { echo "NOT mounted"; exit 1; }
nfsstat -c -E | grep -A1 ExchangeId
echo
echo "Armed. Watch for the wedge with: sh watch-wedge.sh"
echo "Healthy baseline should be ExchangeId=1 CreateSess=1."
