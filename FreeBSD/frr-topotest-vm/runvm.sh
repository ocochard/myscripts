#!/bin/sh
# Start the FRR topotest guest under bhyve, and keep it running across the
# reboots a panic causes.
#
# The guest is bridged onto the LAN (rge0) so it can reach pkg(8); it takes a
# DHCP lease, and its MAC is fixed so `arp -an | grep $MAC` on the host finds
# the address again after every reboot.
#
# Console is nmdm by default, not stdio: a non-tty stdin makes bhyve see EOF on
# com1 and the guest never boots. The console is also where a panic prints, so
# it is logged to $LOG unless -n.
#
#   sudo ./runvm.sh            # run in the foreground, logging the console
#   cu -l /dev/nmdm-frrtopo-B  # attach to it (stop the logger first: -n)
set -eu

VM=${VM:-frrtopo}
IMG=${IMG:-/zroot/vm/frr-topotest.img}
# 12 of the host's 16 cores, and 42G of its 59.7 GiB.
#
# That leaves ~17 GiB for the host, which has NO SWAP -- so ZFS ARC must be
# capped or it will grow into the gap and leave nothing to reclaim under
# pressure (it was uncapped at 11.4 GiB when this was set):
#     sysctl vfs.zfs.arc_max=6G        # runtime
#     vfs.zfs.arc_max=6G in /etc/sysctl.conf to persist
# bhyve does not pre-wire guest memory, so the guest only costs what it
# actually touches.
CPUS=${CPUS:-12}
MEM=${MEM:-42G}
UPLINK=${UPLINK:-rge0}
MAC=${MAC:-58:9c:fc:10:00:01}
FIRMWARE=${FIRMWARE:-/usr/local/share/uefi-firmware/BHYVE_UEFI_CODE.fd}
VARSTORE=${VARSTORE:-/zroot/vm/$VM-vars.fd}
VARSEED=${VARSEED:-/usr/local/share/uefi-firmware/BHYVE_UEFI_VARS.fd}
SHARE=${SHARE:-/zroot/vm/share}
SHARENAME=${SHARENAME:-host}
LOG=${LOG:-/zroot/vm/$VM-console.log}
LOGGER=1

while getopts "c:m:i:nh" o; do
	case "$o" in
	c) CPUS=$OPTARG ;;
	m) MEM=$OPTARG ;;
	i) IMG=$OPTARG ;;
	n) LOGGER=0 ;;
	*) echo "usage: $0 [-c cpus] [-m mem] [-i image] [-n]" >&2; exit 1 ;;
	esac
done

[ "$(id -u)" -eq 0 ] || { echo "$0: must be root" >&2; exit 1; }
[ -f "$IMG" ] || { echo "$0: no image: $IMG (run mkvm.sh)" >&2; exit 1; }
[ -f "$FIRMWARE" ] || { echo "$0: no UEFI firmware: $FIRMWARE" >&2; exit 1; }
# Split code/vars, with a writable per-VM varstore. The combined
# BHYVE_UEFI.fd has nowhere to keep EFI variables, and a guest that reboots
# then comes back with the firmware spinning and no console output at all.
if [ ! -f "$VARSTORE" ]; then
	[ -f "$VARSEED" ] || { echo "$0: no varstore seed: $VARSEED" >&2; exit 1; }
	cp "$VARSEED" "$VARSTORE"
	echo "==> created varstore $VARSTORE"
fi

kldload -n vmm nmdm if_bridge if_tuntap
sysctl -q net.link.tap.up_on_open=1

# Reuse the bridge that already has the uplink, if there is one: creating a
# second bridge on the same member is rejected, and silently making one without
# the uplink would leave the guest with no route off the box.
BRIDGE=""
MADEBRIDGE=0
for b in $(ifconfig -g bridge 2>/dev/null); do
	if ifconfig "$b" | grep -q "member: $UPLINK "; then BRIDGE=$b; break; fi
done
if [ -z "$BRIDGE" ]; then
	BRIDGE=$(ifconfig bridge create)
	ifconfig "$BRIDGE" addm "$UPLINK" up
	MADEBRIDGE=1
	echo "==> created $BRIDGE with member $UPLINK (removed again on exit)"
else
	echo "==> reusing $BRIDGE (member $UPLINK)"
fi

# SHARE=none turns the 9p device off; it is the first thing to drop when a
# boot misbehaves, being the only non-essential device on the bus.
if [ "$SHARE" = none ]; then
	ninep=""
else
	mkdir -p "$SHARE"
	ninep="-s 6:0,virtio-9p,$SHARENAME=$SHARE"
fi

TAP=$(ifconfig tap create)
ifconfig "$BRIDGE" addm "$TAP"
ifconfig "$TAP" up
echo "==> $TAP on $BRIDGE, guest mac $MAC"

cleanup() {
	set +e
	[ -n "${LOGPID:-}" ] && { pkill -P "$LOGPID" 2>/dev/null; kill "$LOGPID" 2>/dev/null; }
	bhyvectl --destroy --vm="$VM" 2>/dev/null
	ifconfig "$BRIDGE" deletem "$TAP" 2>/dev/null
	ifconfig "$TAP" destroy 2>/dev/null
	# Leave the host's interfaces as they were found: a bridge this script
	# did not create belongs to someone else and stays.
	if [ "$MADEBRIDGE" = 1 ]; then
		ifconfig "$BRIDGE" destroy 2>/dev/null
		echo "==> stopped, $TAP and $BRIDGE removed"
	else
		echo "==> stopped, $TAP removed ($BRIDGE was not ours)"
	fi
}
trap cleanup EXIT INT TERM

bhyvectl --destroy --vm="$VM" 2>/dev/null || true

LOGPID=""
if [ "$LOGGER" = 1 ]; then
	echo "==> console log: $LOG"
	# In a loop: bhyve closes the master side on every guest reset, the
	# reader sees EOF and exits. Without the loop the log stops at the
	# first panic -- exactly the boot worth reading.
	#
	# Each pass sets raw/-echo before reopening (see below for why): the
	# nmdm pair is torn down on a reset and comes back with default
	# termios, icanon and echo on. Left that way, the line discipline
	# held the guest's output until a newline and echoed it back as
	# input; the console stalled and a `shutdown -r` hung halfway, sshd
	# already gone. Both opens wait in ttydcd until bhyve has the A side.
	( while :; do
		stty -f "/dev/nmdm-$VM-B" raw -echo 2>/dev/null
		cat "/dev/nmdm-$VM-B" >> "$LOG" || true
		sleep 1
	done ) &
	LOGPID=$!
fi

if [ -n "$ninep" ]; then
	echo "==> 9p share $SHARE as \"$SHARENAME\""
	echo "    in the guest: kldload p9fs virtio_p9fs && mkdir -p /mnt/host &&"
	echo "                  mount -t p9fs -o trans=virtio $SHARENAME /mnt/host"
fi
# THE nmdm B SIDE MUST BE RAW WITH ECHO OFF.
#
# It is a tty, and a tty echoes by default. A plain `cat` reader (unlike cu(1))
# leaves the line discipline alone, so every byte the guest printed came back
# to it as console INPUT. That feedback loop made the guest look broken in
# half a dozen ways: the loader saw "a key has already been pressed" and sat
# at the OK prompt echoing its own output at itself (55 MB of "unknown
# command"), and getty answered its own banner with "Login incorrect".
# The console reader sets it on every (re)open, and the boot loop below sets it
# for each bhyve start, which also covers -n. There is no foreground stty here:
# before bhyve opens the A side it would block in ttydcd and nothing would boot.

# Drain what is still queued: nmdm keeps unread input across VM restarts, and
# the guest reads it as keystrokes at the loader and at getty.
timeout 1 cat "/dev/nmdm-$VM-B" >/dev/null 2>&1 || true

echo "==> booting $VM ($CPUS cpus, $MEM); console /dev/nmdm-$VM-B"
while :; do
	# In the background: opening the B side blocks in ttydcd until bhyve
	# opens the A side, so on a cold start a foreground stty never returns
	# and bhyve never starts. It completes the moment bhyve is up.
	( stty -f "/dev/nmdm-$VM-B" raw -echo 2>/dev/null || true ) &
	bhyve -c "$CPUS" -m "$MEM" -A -H -P -u -w \
		-l bootrom,"$FIRMWARE","$VARSTORE" \
		-s 0:0,hostbridge \
		-s 1:0,lpc \
		-s 2:0,virtio-net,"$TAP",mac="$MAC" \
		-s 4:0,virtio-blk,"$IMG" \
		$ninep \
		-l com1,"/dev/nmdm-$VM-A" \
		"$VM"
	rc=$?
	# A guest reset leaves /dev/vmm/$VM behind for a moment. Starting the
	# next bhyve before it is gone produces a VM that spins forever with no
	# console output at all -- which is exactly what every panic looked
	# like until this wait was added.
	n=0
	while [ -e "/dev/vmm/$VM" ] && [ "$n" -lt 30 ]; do
		bhyvectl --destroy --vm="$VM" 2>/dev/null
		sleep 1
		n=$((n + 1))
	done
	case "$rc" in
	0) echo "==> guest rebooted, restarting" ;;
	1) echo "==> guest powered off"; break ;;
	2) echo "==> guest halted"; break ;;
	3) echo "==> triple fault"; break ;;
	*) echo "==> bhyve exited $rc"; break ;;
	esac
done
