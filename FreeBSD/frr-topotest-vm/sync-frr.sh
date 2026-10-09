#!/bin/sh
# Ship the host's FRR working tree into the guest and build it there.
#
# Uses the 9p share rather than scp: the tree is ~235 MB and the share is
# already mounted at /mnt/host in the guest.
#
#   ./sync-frr.sh [guest-ip]
set -eu

GUEST=${1:-$(cat /zroot/vm/frrtopo.ip 2>/dev/null || echo 192.168.100.78)}
SRC=${SRC:-/home/olivier/frr}
SHARE=${SHARE:-/zroot/vm/share}
KEY=${KEY:-/home/olivier/.ssh/id_ed25519_frrvm}
SSH="ssh -i $KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

# Root, like mkvm.sh and runvm.sh: the 9p share lives under /zroot/vm, which
# is root-owned. The key path is absolute so ssh still finds it as root.
[ "$(id -u)" -eq 0 ] || { echo "$0: must be root (sudo $0)" >&2; exit 1; }

echo "==> packing $SRC"
tar czf "$SHARE/frr.tar.gz" -C "$(dirname "$SRC")" "$(basename "$SRC")"
cp "$(dirname "$0")/guest-build-frr.sh" "$SHARE/"

echo "==> building in the guest (a couple of minutes)"
$SSH "root@$GUEST" 'sh /mnt/host/guest-build-frr.sh > /root/build.log 2>&1' ||
	{ $SSH "root@$GUEST" 'tail -20 /root/build.log'; exit 1; }
$SSH "root@$GUEST" 'ls -l /usr/local/sbin/pimd /usr/local/bin/vtysh'
