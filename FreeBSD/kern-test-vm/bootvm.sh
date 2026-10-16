#!/bin/sh
# Boot the kern-test guest once with the named kernel and print what
# rc.local logged between KTVM-BEGIN and KTVM-END.
#
#   sudo ./bootvm.sh [-i img] [-c cpus] [-m mem] kernel-name
set -eu

IMG=/zroot/vm/kern-test.img
VM=kerntest
CPUS=4
MEM=4G
FIRMWARE=/usr/local/share/uefi-firmware/BHYVE_UEFI.fd
while getopts "i:c:m:" o; do
	case "$o" in
	i) IMG=$OPTARG ;;
	c) CPUS=$OPTARG ;;
	m) MEM=$OPTARG ;;
	*) exit 1 ;;
	esac
done
shift $((OPTIND - 1))
KNAME=${1:-kernel}
[ "$(id -u)" -eq 0 ] || { echo "$0: must be root" >&2; exit 1; }

# Pick the kernel for this boot.
MD=$(mdconfig -a -t vnode -f "$IMG")
MNT=$(mktemp -d /tmp/kvm.XXXXXX)
mount "/dev/${MD}p2" "$MNT"
[ -f "$MNT/boot/$KNAME/kernel" ] || { echo "no kernel $KNAME" >&2; umount "$MNT"; mdconfig -du "$MD"; exit 1; }
sed -i '' "s/^kernel=.*/kernel=\"$KNAME\"/" "$MNT/boot/loader.conf"
rm -f "$MNT/root/results"
rm -f "$MNT/root/results"
umount "$MNT"
mdconfig -du "$MD"
rmdir "$MNT"

kldload -n vmm nmdm
LOG=$(mktemp /tmp/kvm-console.XXXXXX)
bhyvectl --destroy --vm="$VM" 2>/dev/null || true
# Raw, no echo, set before anything reads the B side: a tty echoes, so
# the guest's own output came back to it as keystrokes and parked the
# loader at its OK prompt.  See ../frr-topotest-vm/runvm.sh.
timeout 1 cat "/dev/nmdm-$VM-B" >/dev/null 2>&1 || true
( stty -f "/dev/nmdm-$VM-B" raw -echo 2>/dev/null || true ) &
( stty -f "/dev/nmdm-$VM-B" raw -echo 2>/dev/null
  cat "/dev/nmdm-$VM-B" >"$LOG" ) &
LOGPID=$!
rc=0
timeout 600 bhyve -c "$CPUS" -m "$MEM" -A -H -P -u \
	-l bootrom,"$FIRMWARE" \
	-s 0:0,hostbridge -s 1:0,lpc \
	-s 4:0,virtio-blk,"$IMG" \
	-l com1,"/dev/nmdm-$VM-A" "$VM" || rc=$?
bhyvectl --destroy --vm="$VM" 2>/dev/null || true
sleep 1
pkill -P "$LOGPID" 2>/dev/null || true
kill "$LOGPID" 2>/dev/null || true
echo "==> bhyve exit $rc, console log $LOG"
MD=$(mdconfig -a -t vnode -f "$IMG")
MNT=$(mktemp -d /tmp/kvm.XXXXXX)
mount -o ro "/dev/${MD}p2" "$MNT"
cat "$MNT/root/results" 2>/dev/null || echo "==> no /root/results: the test did not run"
cp "$MNT/root/results" "/tmp/kvm-results.$KNAME" 2>/dev/null || true
umount "$MNT"
mdconfig -du "$MD"
rmdir "$MNT"
