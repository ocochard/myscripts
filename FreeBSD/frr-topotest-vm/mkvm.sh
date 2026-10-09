#!/bin/sh
# Build the bhyve guest that runs the FRR topotests.
#
# WHY A VM AT ALL
# ---------------
# The FreeBSD topotests (FRR PR 23475) drive VNET jails and epair(4) in tight
# create/destroy loops, which is the path that panics -CURRENT. On this
# workstation a panic cannot be captured and there is no way to add a dump
# device: nda0 has 7.5K of free space, the netdump config in /etc/rc.conf can
# never arm because rge(4)/RTL8125 has no DEBUGNET support ("dumpon: Unable to
# configure netdump because the interface driver does not yet support
# netdump"), and a ZFS zvol cannot be a dump device -- zvol_cdevsw has no
# .d_dump and OpenZFS answers no GEOM::kerneldump attribute.
#
# Inside a guest none of that applies: the virtual disk is a plain vtbd, so an
# ordinary freebsd-swap slice IS a dump device, and a panic costs a guest
# reboot instead of the workstation.
#
# WHY THE GUEST IS A COPY OF THE RUNNING HOST
# -------------------------------------------
# Not `make installworld` from /usr/src: that tree and /usr/obj are read-only
# NFS from bigone, and whenever that obj tree lags the source (it did by a week
# when this was written) install rules try to REBUILD and die on the read-only
# mount -- first
# regenerating bsdxml.h, then wanting a compiler that is not there
# ("/tmp/makerXXXX: cc: not found").
#
# Copying the live host sidesteps all of it and is what you actually want to
# test: the guest then runs the EXACT kernel this workstation runs, so
# /usr/lib/debug/boot/kernel/kernel.debug on the host symbolises the guest's
# vmcore with nothing further to line up.
#
# GENERIC-NODEBUG keeps KDB and DDB (std.nodebug only drops INVARIANTS and
# WITNESS), so `sysctl debug.kdb.panic=1` in the guest proves the dump path
# works before a real panic depends on it.
#
# Usage:
#   sudo ./mkvm.sh [-o image] [-s size] [-D dumpsize]
set -eu

IMG=${IMG:-/zroot/vm/frr-topotest.img}
SIZE=${SIZE:-40G}
DUMPSZ=${DUMPSZ:-10G}
VMHOST=${VMHOST:-frrtopo}
KEY=${KEY:-/home/olivier/.ssh/id_ed25519_frrvm}
KEYOWNER=${KEYOWNER:-olivier}
ROOTPW=${ROOTPW:-topotest}

usage() {
	cat <<USAGE
usage: $0 [-o image] [-s size] [-D dumpsize] [-n hostname]

  -o  output image      (default: $IMG)
  -s  total image size  (default: $SIZE, sparse)
  -D  swap/dump slice   (default: $DUMPSZ, must exceed a guest minidump)
  -n  guest hostname    (default: $VMHOST)

Must run as root (mdconfig/gpart/newfs/mount).
USAGE
	exit 1
}

while getopts "o:s:D:n:h" o; do
	case "$o" in
	o) IMG=$OPTARG ;;
	s) SIZE=$OPTARG ;;
	D) DUMPSZ=$OPTARG ;;
	n) VMHOST=$OPTARG ;;
	*) usage ;;
	esac
done

[ "$(id -u)" -eq 0 ] || { echo "$0: must be root" >&2; exit 1; }
[ -f /boot/kernel/kernel ] || { echo "$0: no /boot/kernel/kernel" >&2; exit 1; }

echo "==> guest will run this host's kernel: $(uname -v | cut -c1-70)"
echo "==> __FreeBSD_version $(sysctl -n kern.osreldate)"

if ! zfs list -H -o name zroot/vm >/dev/null 2>&1; then
	echo "==> creating dataset zroot/vm"
	zfs create -o mountpoint=/zroot/vm zroot/vm
fi
mkdir -p "$(dirname "$IMG")"

MNT=$(mktemp -d /tmp/frrvm.XXXXXX)
ESPMNT=$(mktemp -d /tmp/frrvm-esp.XXXXXX)
MD=""

cleanup() {
	set +e
	umount "$ESPMNT" 2>/dev/null
	umount "$MNT" 2>/dev/null
	[ -n "$MD" ] && mdconfig -du "$MD" 2>/dev/null
	rmdir "$MNT" "$ESPMNT" 2>/dev/null
}
trap cleanup EXIT INT TERM

echo "==> creating $SIZE sparse image at $IMG"
[ -f "$IMG" ] && { chflags -R noschg "$IMG" 2>/dev/null; rm -f "$IMG"; }
truncate -s "$SIZE" "$IMG"
MD=$(mdconfig -a -t vnode -f "$IMG")
echo "    /dev/$MD"

# GPT: ESP + a swap slice that doubles as the dump device + UFS root. Labels,
# not device names: the guest sees vtbd0 while the host sees md0, and only the
# labels are stable across both.
echo "==> partitioning"
gpart create -s gpt "/dev/$MD" >/dev/null
gpart add -t efi          -l frrvm-esp  -s 40m       "/dev/$MD" >/dev/null
gpart add -t freebsd-swap -l frrvm-dump -s "$DUMPSZ" "/dev/$MD" >/dev/null
gpart add -t freebsd-ufs  -l frrvm-root               "/dev/$MD" >/dev/null

newfs_msdos -F 32 -c 1 "/dev/${MD}p1" >/dev/null 2>&1
# -j, not -U: this guest exists to panic, and a soft-updates filesystem that
# crashes gets mounted rw while a BACKGROUND fsck is still repairing it. That
# was not theoretical here -- the first crashed boot came up with dhclient
# dying on SIGSEGV and casper failing at pdfork. A journal replays before the
# mount, and rc.conf turns the background check off as well.
newfs -j -L frrvmroot "/dev/${MD}p3" >/dev/null
mount "/dev/${MD}p3" "$MNT"

# --one-file-system keeps this on the root dataset, so /home, /usr/src,
# /usr/obj, /var/crash, /boot/efi and the rest of the separately mounted tree
# are skipped without naming them. What is named below is what lives ON the
# root dataset and has no business in the guest.
cat > "$MNT/.exclude" <<EXCLUDE
./usr/local
./usr/ports
./boot/kernel.old
./boot/kernel.orig
./boot/loader.conf.d
./usr/lib/debug
./var/cache
./var/backups
./var/db/freebsd-update
# The package DATABASE without /usr/local is poison: pkg believes every host
# package (frr10 included) is installed and skips their files, so
# `pkg install python3` registers a package with no python in it.
./var/db/pkg
./var/log
./var/run
./root
./tmp
./.exclude
EXCLUDE

echo "==> copying the host userland (a few minutes)"
tar -c -f - -C / --one-file-system -X "$MNT/.exclude" . | tar -x -f - -C "$MNT"
rm -f "$MNT/.exclude"

# Recreate what the excludes left out, with the modes the base system wants.
for d in root tmp var/log var/run var/crash usr/local home; do
	mkdir -p "$MNT/$d"
done
chmod 1777 "$MNT/tmp"
chmod 700 "$MNT/root"

echo "==> ESP"
mount -t msdosfs "/dev/${MD}p1" "$ESPMNT"
mkdir -p "$ESPMNT/EFI/BOOT"
cp /boot/loader.efi "$ESPMNT/EFI/BOOT/BOOTX64.EFI"
umount "$ESPMNT"

echo "==> guest configuration"
cat > "$MNT/etc/fstab" <<FSTAB
# Device		Mountpoint	FStype	Options	Dump	Pass#
/dev/gpt/frrvm-root	/		ufs	rw	1	1
/dev/gpt/frrvm-dump	none		swap	sw	0	0
# runvm.sh's virtio-9p share. failok so a VM started without it still boots.
host			/mnt/host	p9fs	rw,trans=virtio,late,failok	0	0
FSTAB
mkdir -p "$MNT/mnt/host"

# dumpdev=AUTO takes the first swap device, which is the slice above; savecore
# then runs from /etc/rc on the next boot, before anything can fill /var.
cat > "$MNT/etc/rc.conf" <<RCCONF
hostname="$VMHOST"
ifconfig_vtnet0="DHCP"
sshd_enable="YES"
sendmail_enable="NONE"
sendmail_submit_enable="NO"
sendmail_outbound_enable="NO"
sendmail_msp_queue_enable="NO"
clear_tmp_enable="YES"
# Finish checking the filesystem BEFORE it is used, every time: see newfs -j.
background_fsck="NO"
fsck_y_enable="YES"
dumpdev="AUTO"
dumpdir="/var/crash"
savecore_enable="YES"
crashinfo_enable="YES"
# The topotest harness kldloads these itself; having them here means a load
# failure shows up at boot instead of halfway through a test run.
# ip_mroute: GENERIC does not set MROUTING, so nothing loads it. Without it
# MRT_INIT returns EOPNOTSUPP, pimd never opens its mroute socket -- which is
# also where it reads IGMP -- and every PIM test fails having learned no
# groups, with nothing in the output saying why.
kld_list="if_epair if_bridge p9fs virtio_p9fs ip_mroute"
RCCONF

# debugger_on_panic=0: nobody watches the console during an unattended test
# run, so a panic must dump and reboot on its own rather than sit at db>. DDB
# is still compiled in when you do want to drive it by hand.
cat > "$MNT/etc/sysctl.conf" <<SYSCTL
debug.debugger_on_panic=0
kern.panic_reboot_wait_time=5
SYSCTL

# kernels="kernel": defaults/loader.conf lists "kernel kernel.old", and after
# a panic the loader silently fell back to the host's /boot/kernel.old -- a
# March kernel under a September userland, which came up with casper failing
# ("Invalid pdflags at fork 0x4": PD_NOWAITPID postdates it), dhclient dying on
# SIGSEGV and no network at all. kernel.old is excluded from the copy as well;
# this makes a missing kernel fail loudly instead of booting something stale.
# beastie_disable + autoboot_delay=0: the loader menu polls the console, and
# ANY byte sitting in the nmdm buffer -- a stray keystroke typed at a previous
# boot, which nmdm keeps queued across VM restarts -- stops the countdown and
# parks the loader at the menu forever, looking exactly like a hang. With the
# menu off the loader boots immediately and ignores the junk.
cat > "$MNT/boot/loader.conf" <<LOADER
console="comconsole"
beastie_disable="YES"
autoboot_delay="0"
kernels="kernel"
vfs.root.mountfrom="ufs:/dev/gpt/frrvm-root"
LOADER

cp /etc/resolv.conf "$MNT/etc/resolv.conf"

# Host identity that must not be cloned.
rm -f "$MNT/etc/ssh/ssh_host_"*
rm -f "$MNT/var/db/dhclient.leases."* 2>/dev/null || true
: > "$MNT/etc/rc.conf.local" 2>/dev/null || true
rm -f "$MNT/etc/rc.conf.local"

# Key auth for the driving host, password only on the serial console: the guest
# sits on the LAN bridge, where a password-accepting sshd would be exposed.
if [ ! -f "$KEY" ]; then
	echo "==> generating $KEY"
	su -m "$KEYOWNER" -c "ssh-keygen -t ed25519 -N '' -C 'frr topotest vm' -f $KEY" >/dev/null
fi
mkdir -p "$MNT/root/.ssh"
chmod 700 "$MNT/root/.ssh"
cat "$KEY.pub" > "$MNT/root/.ssh/authorized_keys"
chmod 600 "$MNT/root/.ssh/authorized_keys"
sed -i '' -e 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' \
	"$MNT/etc/ssh/sshd_config"
echo "$ROOTPW" | pw -R "$MNT" usermod root -h 0

# A guest with no entropy stalls early in boot. Both files are what this host
# uses: /entropy for rc.d/random, /boot/entropy for the loader. They are
# cloned from the host, so overwrite them rather than hand the guest a copy of
# the host's seed.
dd if=/dev/random of="$MNT/entropy" bs=4096 count=1 status=none
chmod 600 "$MNT/entropy"
dd if=/dev/random of="$MNT/boot/entropy" bs=4096 count=1 status=none
chmod 600 "$MNT/boot/entropy"

sync
echo "==> done"
df -h "$MNT" | tail -1
echo "    image:   $IMG"
echo "    key:     $KEY"
echo "    console root password: $ROOTPW"
echo "    start:   sudo ./runvm.sh"
