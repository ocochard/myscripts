#!/bin/sh
# Build a throwaway bhyve guest that boots a given kernel, runs a test
# program from rc.local, prints the results on the serial console and
# powers off.  Derived from ../frr-topotest-vm/mkvm.sh: the userland is a
# copy of the running host, the root is newfs -j, the console is serial.
# No network: the test and its results travel inside the image.
#
#   sudo ./mkvm.sh -k /path/kernel[:name] [-k ...] -t /path/test-dir [-o img]
#
# Each -k installs a kernel as /boot/<name>/kernel (name defaults to
# "kernel"); bootvm.sh picks one per boot.  -t copies a directory to
# /root/test in the guest; its run.sh is what rc.local runs.
set -eu

IMG=/zroot/vm/kern-test.img
SIZE=6G
KERNELS=""
TESTDIR=""

while getopts "k:t:o:s:" o; do
	case "$o" in
	k) KERNELS="$KERNELS $OPTARG" ;;
	t) TESTDIR=$OPTARG ;;
	o) IMG=$OPTARG ;;
	s) SIZE=$OPTARG ;;
	*) echo "usage: $0 -k kernel[:name] ... -t testdir [-o img]" >&2
	   exit 1 ;;
	esac
done
[ "$(id -u)" -eq 0 ] || { echo "$0: must be root" >&2; exit 1; }
[ -n "$KERNELS" ] && [ -n "$TESTDIR" ] || { echo "$0: need -k and -t" >&2; exit 1; }

MNT=$(mktemp -d /tmp/kvm.XXXXXX)
ESP=$(mktemp -d /tmp/kvm-esp.XXXXXX)
MD=""
cleanup() {
	set +e
	umount "$ESP" 2>/dev/null
	umount "$MNT" 2>/dev/null
	[ -n "$MD" ] && mdconfig -du "$MD"
	rmdir "$MNT" "$ESP" 2>/dev/null
}
trap cleanup EXIT INT TERM

rm -f "$IMG"
truncate -s "$SIZE" "$IMG"
MD=$(mdconfig -a -t vnode -f "$IMG")
gpart create -s gpt "/dev/$MD" >/dev/null
gpart add -t efi -l ktvm-esp -s 40m "/dev/$MD" >/dev/null
gpart add -t freebsd-ufs -l ktvm-root "/dev/$MD" >/dev/null
newfs_msdos -F 32 -c 1 "/dev/${MD}p1" >/dev/null 2>&1
newfs -j "/dev/${MD}p2" >/dev/null
mount "/dev/${MD}p2" "$MNT"

# The base system only, by name: unlike the frr host, this root dataset
# holds 225G, so a copy of everything on it does not fit any image.
echo "==> copying the host base system"
tar -c -f - -C / --exclude ./boot/kernel --exclude './boot/kernel.*' \
    --exclude ./boot/loader.conf.d --exclude ./usr/lib/debug \
    ./bin ./sbin ./lib ./libexec ./etc ./boot \
    ./usr/bin ./usr/sbin ./usr/lib ./usr/libexec ./usr/share \
    | tar -x -f - -C "$MNT"
mkdir -p "$MNT/dev" "$MNT/var" "$MNT/root" "$MNT/tmp" "$MNT/usr/local" "$MNT/home"
mtree -deU -f /etc/mtree/BSD.var.dist -p "$MNT/var" >/dev/null
mtree -deU -f /etc/mtree/BSD.root.dist -p "$MNT" >/dev/null
chmod 1777 "$MNT/tmp"

# Kernels only, no modules: the host's modules are from another build and
# a GENERIC kernel boots in bhyve without any.
klist=""
for k in $KERNELS; do
	src=${k%%:*}
	name=kernel
	case "$k" in *:*) name=${k#*:} ;; esac
	mkdir -p "$MNT/boot/$name"
	cp "$src" "$MNT/boot/$name/kernel"
	klist="$klist $name"
	echo "==> /boot/$name/kernel from $src"
done

mount -t msdosfs "/dev/${MD}p1" "$ESP"
mkdir -p "$ESP/EFI/BOOT"
cp /boot/loader.efi "$ESP/EFI/BOOT/BOOTX64.EFI"
umount "$ESP"

cat > "$MNT/etc/fstab" <<FSTAB
/dev/gpt/ktvm-root	/	ufs	rw	1	1
FSTAB
cat > "$MNT/etc/rc.conf" <<RCCONF
hostname="kern-test"
sendmail_enable="NONE"
background_fsck="NO"
fsck_y_enable="YES"
RCCONF
# See ../frr-topotest-vm/mkvm.sh for why each of these is needed.
cat > "$MNT/boot/loader.conf" <<LOADER
console="comconsole"
beastie_disable="YES"
autoboot_delay="-1"
kernels="$klist"
kernel="kernel"
vfs.root.mountfrom="ufs:/dev/gpt/ktvm-root"
LOADER

mkdir -p "$MNT/root/test"
cp -R "$TESTDIR"/. "$MNT/root/test/"
cat > "$MNT/etc/rc.local" <<'RCLOCAL'
#!/bin/sh
# Run the test once per boot, on the console, then power off.
# Also into /root/results, which bootvm.sh reads back from the image: the
# console capture is a convenience, the file is the record.
{
	echo "KTVM-BEGIN kernel=$(sysctl -n kern.bootfile) $(uname -v)"
	(cd /root/test && sh ./run.sh) 2>&1
	echo "KTVM-END rc=$?"
} | tee /root/results
sync
poweroff
RCLOCAL
dd if=/dev/random of="$MNT/entropy" bs=4096 count=1 status=none
dd if=/dev/random of="$MNT/boot/entropy" bs=4096 count=1 status=none
sync
echo "==> $IMG ready, kernels:$klist"
