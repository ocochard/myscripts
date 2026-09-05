#!/bin/sh
# Build the minimal bhyve guest that fbsd-quality loads modules into.
#
# WHICH KERNEL GOES IN THE IMAGE — THIS IS THE EASY THING TO GET WRONG
# --------------------------------------------------------------------
# A kernel module only loads into a kernel with a compatible
# __FreeBSD_version; kldload rejects a mismatch outright. The agent builds its
# module against the SOURCE TREE, so the guest kernel must come from that
# TREE — not from the running host, and not from a downloaded release image.
#
# Host and tree routinely differ: you might be running 15.1-RELEASE with a
# 16-head checkout, or (as observed on this very host) running 1600020 while
# /usr/src is already at 1600022 after a git pull. Copying /boot/kernel in
# either case produces an image that silently rejects every module the bench
# builds.
#
# So by default this script uses the kernel built FROM THE TREE, under
# /usr/obj. It only falls back to /boot/kernel when the tree's version and the
# running kernel's version actually match, and it refuses (rather than
# guessing) when it cannot find a matching kernel.
#
# WHY /rescue AS THE ENTIRE USERLAND
# ----------------------------------
# /rescue is ~12 MB of statically linked binaries and includes everything the
# guest script needs (sh, mount, kldload, kldunload, dmesg, shutdown, mkdir).
# Static means no /lib, no /usr, no ldconfig — so the image stays tiny and
# there is nothing to keep in sync with the host.
#
# The guest never compiles anything: the host builds the .ko and shares it in
# over virtio-9p (read-only). No toolchain, no /usr/src in the image.
#
# Usage:
#   sudo ./mkimage.sh [-o out.img] [-s size] [-k /boot/kernel] [-r /rescue]
set -eu

OUT=${OUT:-/zroot/vm/fbsdq.img}
SIZE=${SIZE:-1400m}      # ESP 40m + dump 640m + root ~700m
DUMPSZ=${DUMPSZ:-640m}   # swap/dump slice; holds a guest minidump
SRC=${SRC:-/usr/src}
KERNEL=${KERNEL:-}          # empty => derive from $SRC (see below)
RESCUE=${RESCUE:-/rescue}

usage() {
	cat <<EOF
usage: $0 [-o image] [-s size] [-S srcdir] [-k kerneldir] [-r rescuedir]

  -o  output image path          (default: $OUT)
  -s  image size                 (default: $SIZE)
  -D  dump/swap slice size       (default: $DUMPSZ)
  -S  source tree the bench uses (default: $SRC)
  -k  kernel dir to copy         (default: derived from -S via /usr/obj)
  -r  static userland to copy    (default: $RESCUE)

The guest kernel MUST match the source tree the agent builds modules against,
which is often NOT the running host kernel. By default the kernel is taken
from the object tree for -S; pass -k only if you know better.

Must run as root (mdconfig/newfs/mount).
EOF
	exit 1
}

while getopts "o:s:D:S:k:r:h" o; do
	case "$o" in
	o) OUT=$OPTARG ;;
	s) SIZE=$OPTARG ;;
	D) DUMPSZ=$OPTARG ;;
	S) SRC=$OPTARG ;;
	k) KERNEL=$OPTARG ;;
	r) RESCUE=$OPTARG ;;
	*) usage ;;
	esac
done

[ "$(id -u)" -eq 0 ] || { echo "$0: must be root" >&2; exit 1; }
[ -d "$SRC/sys" ] || { echo "$0: not a source tree: $SRC" >&2; exit 1; }
[ -d "$RESCUE" ] || { echo "$0: no rescue dir: $RESCUE" >&2; exit 1; }

# Version the AGENT'S MODULES will target: read it from the tree, because that
# is what sys/module.h stamps into every .ko built from it.
SRC_VER=$(awk '/^#define[[:space:]]+__FreeBSD_version/{print $3}' \
	"$SRC/sys/sys/param.h" 2>/dev/null)
HOST_VER=$(sysctl -n kern.osreldate)
[ -n "$SRC_VER" ] || { echo "$0: cannot read __FreeBSD_version from $SRC" >&2; exit 1; }

echo "==> source tree $SRC is __FreeBSD_version $SRC_VER"
echo "==> running host is        __FreeBSD_version $HOST_VER"

# Locate a kernel built from THIS tree. MAKEOBJDIRPREFIX layout is
# /usr/obj<srcpath>/<arch>.<arch>/sys/<CONF>/kernel
if [ -z "$KERNEL" ]; then
	OBJ="${MAKEOBJDIRPREFIX:-/usr/obj}${SRC}/$(uname -m).$(uname -p)/sys"
	CAND=""
	if [ -d "$OBJ" ]; then
		# Prefer a NODEBUG kernel: smaller image, faster boot.
		for c in $(ls -1 "$OBJ" 2>/dev/null | grep -- -NODEBUG) \
		         $(ls -1 "$OBJ" 2>/dev/null); do
			[ -f "$OBJ/$c/kernel" ] && { CAND="$OBJ/$c"; break; }
		done
	fi
	if [ -n "$CAND" ]; then
		KERNEL=$CAND
		echo "==> using kernel built from the tree: $KERNEL"
	elif [ "$SRC_VER" = "$HOST_VER" ]; then
		KERNEL=/boot/kernel
		echo "==> no obj kernel; host matches the tree, using $KERNEL"
	else
		cat >&2 <<EOF
$0: cannot find a kernel matching $SRC.

  tree: $SRC_VER
  host: $HOST_VER   (/boot/kernel — NOT usable, versions differ)

Modules built from $SRC will not load into the running host kernel, so an
image made from /boot/kernel would reject every module the bench produces.

Build a kernel from the tree first:
  cd $SRC && make -j\$(sysctl -n hw.ncpu) buildkernel KERNCONF=GENERIC-NODEBUG

...or pass -k <dir> explicitly if you have one elsewhere.
EOF
		exit 1
	fi
fi
[ -d "$KERNEL" ] || { echo "$0: no kernel dir: $KERNEL" >&2; exit 1; }

# Sanity: does the chosen kernel actually carry the tree's version? Catches a
# stale obj tree, which otherwise fails later as a baffling kldload error.
if [ -f "$KERNEL/kernel" ]; then
	K_VER=$(strings -a "$KERNEL/kernel" 2>/dev/null |
		sed -n 's/.*FreeBSD \([0-9][0-9]*\.[0-9]*\)-\([A-Z]*\).*/\1-\2/p' |
		head -1)
	[ -n "$K_VER" ] && echo "==> kernel image reports: $K_VER"
fi

KVER=$SRC_VER
echo "==> building guest for __FreeBSD_version $KVER"

MNT=$(mktemp -d /tmp/fbsdq-mkimage.XXXXXX)
MD=""

cleanup() {
	set +e
	[ -n "$MD" ] && {
		umount "$MNT/dev" 2>/dev/null
		umount "$MNT" 2>/dev/null
		mdconfig -du "$MD" 2>/dev/null
	}
	rmdir "$MNT" 2>/dev/null
}
trap cleanup EXIT INT TERM

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"

echo "==> creating $SIZE image at $OUT"
truncate -s "$SIZE" "$OUT"
MD=$(mdconfig -a -t vnode -f "$OUT")

# GPT + UEFI ESP + UFS root. UEFI because bhyve's BHYVE_UEFI.fd is the least
# fussy boot path on -CURRENT (no grub-bhyve, no userboot shim).
echo "==> partitioning /dev/$MD"
gpart create -s gpt "/dev/$MD" >/dev/null
gpart add -t efi -l fbsdq-esp -s 40m "/dev/$MD" >/dev/null
# A swap slice that doubles as the DUMP DEVICE. Without one a panicking guest
# has nowhere to write a core, so savecore(8) has nothing to recover and
# kgdb-level debugging is impossible. Sized to hold a dump of the guest's RAM;
# --memory defaults to 512M in vmrunner.py, and minidumps are far smaller than
# full RAM, so 640m is comfortable. Costs nothing until used (sparse file).
gpart add -t freebsd-swap -l fbsdq-dump -s "$DUMPSZ" "/dev/$MD" >/dev/null
gpart add -t freebsd-ufs -l fbsdq-root "/dev/$MD" >/dev/null

newfs_msdos -F 32 -c 1 "/dev/${MD}p1" >/dev/null 2>&1
newfs -U -L fbsdqroot "/dev/${MD}p3" >/dev/null

mount "/dev/${MD}p3" "$MNT"

echo "==> installing kernel from $KERNEL"
mkdir -p "$MNT/boot/kernel" "$MNT/boot/defaults"
# COPY ONLY THE KERNEL AND MODULES.
#
# An obj kernel directory is NOT shaped like /boot/kernel: it also holds every
# intermediate build product. Measured here: 1.5 GB total, of which the kernel
# plus all .ko files are 16 MB. A recursive copy therefore fills any sanely
# sized image with .o and .meta files ("No space left on device", the whole
# build having been faithfully copied). Take exactly what boots.
cp -p "$KERNEL/kernel" "$MNT/boot/kernel/"
KO_N=0
for ko in "$KERNEL"/*.ko; do
	[ -f "$ko" ] || continue
	cp -p "$ko" "$MNT/boot/kernel/"
	KO_N=$((KO_N + 1))
done
echo "    kernel + $KO_N modules ($(du -sh "$MNT/boot/kernel" | awk '{print $1}'))"

for m in p9fs virtio_p9fs virtio_blk; do
	[ -f "$MNT/boot/kernel/$m.ko" ] && continue
	# Not in the obj kernel dir (e.g. -k pointed at a bare kernel): take it
	# from the tree's module build, NEVER from the running host's /boot —
	# a version-mismatched .ko fails to load exactly like the bench's own
	# modules would.
	FOUND=$(find "${MAKEOBJDIRPREFIX:-/usr/obj}${SRC}" -name "$m.ko" \
		-type f 2>/dev/null | head -1)
	if [ -n "$FOUND" ]; then
		cp -p "$FOUND" "$MNT/boot/kernel/"
		echo "    + $m.ko (from obj tree)"
	else
		echo "    ! $m.ko NOT FOUND in the obj tree — the guest may be" >&2
		echo "      unable to mount the 9p share" >&2
	fi
done

# The loader is userland-ish and version-tolerant, but prefer the tree's build
# when present so the whole image comes from one source.
LOADER_SRC=""
for cand in "${MAKEOBJDIRPREFIX:-/usr/obj}${SRC}/$(uname -m).$(uname -p)/stand" /boot; do
	[ -f "$cand/loader.efi" ] && { LOADER_SRC=$cand; break; }
	F=$(find "$cand" -name loader.efi -type f 2>/dev/null | head -1)
	[ -n "$F" ] && { LOADER_SRC=$(dirname "$F"); break; }
done
echo "==> loader from ${LOADER_SRC:-<none>}"
[ -f /boot/defaults/loader.conf ] && cp -p /boot/defaults/loader.conf "$MNT/boot/defaults/"
[ -d /boot/lua ] && cp -Rp /boot/lua "$MNT/boot/" 2>/dev/null || true

echo "==> installing static userland from $RESCUE"
mkdir -p "$MNT/rescue" "$MNT/bin" "$MNT/sbin" "$MNT/etc" "$MNT/dev" \
         "$MNT/mnt" "$MNT/tmp" "$MNT/var/run" "$MNT/var/log"
# PRESERVE HARDLINKS. /rescue is ~150 names hardlinked to ONE ~20 MB static
# binary: `du` says 12 MB, but cp(1) -R breaks the links and writes 150
# separate copies — 3.0 GB, which overflows any sane image. tar keeps them.
( cd "$RESCUE" && tar -cf - . ) | ( cd "$MNT/rescue" && tar -xpf - )
echo "    /rescue: $(du -sh "$MNT/rescue" | awk '{print $1}') " \
     "($(stat -f %l "$MNT/rescue/sh" 2>/dev/null) links on sh — hardlinks intact)"
# /bin/sh must exist: init execs it, and it is what the console script runs in.
ln -sf /rescue/sh "$MNT/bin/sh"
ln -sf /rescue/init "$MNT/sbin/init"
for b in kldload kldunload kldstat mount umount dmesg shutdown reboot mkdir \
         ls cat echo sleep ps sync; do
	[ -e "$RESCUE/$b" ] && ln -sf "/rescue/$b" "$MNT/bin/$b" || true
done

echo "==> writing configuration"
cat > "$MNT/etc/fstab" <<EOF
/dev/gpt/fbsdq-root	/	ufs	rw	1 1
/dev/gpt/fbsdq-dump	none	swap	sw	0 0
EOF

# Boot straight to a root shell on the serial console: no getty, no login, no
# rc scripts. vmrunner.py drives that shell by typing at it, so the faster and
# dumber the boot, the better.
cat > "$MNT/boot/loader.conf" <<EOF
autoboot_delay="0"
beastie_disable="YES"
boot_serial="YES"
comconsole_speed="115200"
console="comconsole"
# Preloaded so the bench never depends on the guest finding them at runtime.
p9fs_load="YES"
virtio_p9fs_load="YES"
EOF

# init runs this instead of /etc/rc: print a marker vmrunner can match, then
# hand over an interactive shell.
# NOTE: /rescue has sysctl but NOT uname, so the handshake uses
# kern.osreldate — which is also the exact number kldload compares against a
# module's __FreeBSD_version, so it is the more useful value anyway.
cat > "$MNT/etc/rc" <<'EOF'
#!/rescue/sh
/rescue/mount -a 2>/dev/null

# Arm the dump device BEFORE anything can panic. Optional feature: if a module
# panics the guest, the core lands on the swap slice and survives the reboot,
# so vmrunner.py can recover it with savecore(8) and the agent may inspect it
# with kgdb on the HOST (the guest has no debugger — /rescue has savecore but
# not kgdb, and there is no /lib for a dynamic one).
/rescue/dumpon /dev/gpt/fbsdq-dump 2>/dev/null && \
	echo "FBSDQ-DUMPDEV-ARMED" || echo "FBSDQ-DUMPDEV-FAILED"

# Recover a core left by the PREVIOUS boot, if any. /var/crash is on the root
# filesystem, which is shared into the host via the disk image, so the host
# can extract it afterwards.
/rescue/mkdir -p /var/crash 2>/dev/null
if /rescue/savecore -C /dev/gpt/fbsdq-dump >/dev/null 2>&1; then
	# NB: /rescue has no tr(1) (nor uname) — keep this to plain ls output.
	/rescue/savecore /var/crash /dev/gpt/fbsdq-dump >/dev/null 2>&1 && \
		echo "FBSDQ-CORE-SAVED" && /rescue/ls /var/crash
fi

/rescue/kldstat -q -m p9fs   || /rescue/kldload p9fs        2>/dev/null
/rescue/kldstat -q -m virtio_p9fs || /rescue/kldload virtio_p9fs 2>/dev/null
echo
echo "FBSDQ-GUEST-READY $(/rescue/sysctl -n kern.osreldate)"
exec /rescue/sh
EOF
chmod 0755 "$MNT/etc/rc"

# Stamp the version so a mismatch between image and /usr/src is diagnosable.
echo "$KVER" > "$MNT/etc/fbsdq-kernel-version"

echo "==> installing UEFI boot loader"
mkdir -p "$MNT/tmp/esp"
mount -t msdosfs "/dev/${MD}p1" "$MNT/tmp/esp"
mkdir -p "$MNT/tmp/esp/EFI/BOOT"
if [ -n "$LOADER_SRC" ] && [ -f "$LOADER_SRC/loader.efi" ]; then
	cp "$LOADER_SRC/loader.efi" "$MNT/tmp/esp/EFI/BOOT/BOOTX64.EFI"
else
	echo "$0: WARNING: no loader.efi found; image will not boot" >&2
fi
umount "$MNT/tmp/esp"
rmdir "$MNT/tmp/esp"

sync
umount "$MNT"
mdconfig -du "$MD"
MD=""

echo "==> done: $OUT ($(du -h "$OUT" | awk '{print $1}'))"
echo
echo "Guest kernel __FreeBSD_version: $KVER"
echo "Modules built against a different tree will be REJECTED by kldload,"
echo "so rebuild this image whenever the host kernel is updated."
echo
echo "Smoke test:"
echo "  sudo bhyve -c 1 -m 512M -A -H -P \\"
echo "    -l bootrom,/usr/local/share/uefi-firmware/BHYVE_UEFI.fd \\"
echo "    -s 0,hostbridge -s 1,virtio-blk,$OUT \\"
echo "    -s 2,virtio-9p,fbsdqbench=/tmp,ro -s 31,lpc -l com1,stdio fbsdq-smoke"
echo "  (expect 'FBSDQ-GUEST-READY $KVER'; ~# to exit: shutdown -p now)"
