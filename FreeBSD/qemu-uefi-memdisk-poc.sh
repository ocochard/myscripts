#!/bin/sh
# UEFI netboot PoC #2: firmware -> iPXE -> memdisk_uefi -> FreeBSD installer
#
# Boots an UNMODIFIED FreeBSD release ISO entirely from RAM, fetched over HTTP.
# No DHCP-supplied boot config, no local media, no changes to the image.
#
# Verified end to end on FreeBSD 16 host, qemu 11.1.0, guest FreeBSD 15.1-RELEASE.
# Companion to qemu-uefi-ipxe-poc.sh; see ../iPXE.md sec.7d for the theory.
#
# How it differs from qemu-uefi-ipxe-poc.sh: that one chainloads a payload,
# this one hands the whole disk image to memdisk_uefi, which republishes it
# as a UEFI RAM disk + ACPI NVDIMM so the kernel can still reach it after
# ExitBootServices().
#
# The four non-obvious requirements:
#   1. -device virtio-rng-pci is REQUIRED or the firmware never sends DHCP
#      (the TLS-enabled EDK2 network stack blocks on entropy)     iPXE.md sec.9
#   2. memdisk_uefi must be built against an iPXE from BEFORE 2026-01-13:
#      commit e61c636 added the FILE_SECBOOT macro, which memdisk_uefi does
#      not define because it never includes iPXE's compiler.h     (see below)
#   3. the image is served over HTTP, not TFTP -- 500+ MB over TFTP is painful
#   4. at the loader prompt use the RELATIVE-path README form and do NOT set
#      vfs.root.mountfrom: the root is autodetected by filesystem label
#      (cd9660 for an ISO, UFS for a memstick), never /dev/spa0
#   5. run lsdev FIRST.  Not cosmetic: without it the kernel fails to mount
#      root with error 19 (measured 2/2 fail without, 2/2 pass with).  It is
#      not a timing effect -- a 3 s sleep in its place still fails, so the
#      device enumeration itself is what matters.  Not documented upstream.
#
# Interactive: this script stops at the loader prompt and prints the three
# lines to type. Run with -a to drive them automatically via expect(1).
#
# Usage:
#   ./qemu-uefi-memdisk-poc.sh [-a] [image]
#
#   -a            drive the loader prompt automatically via expect(1)
#   image         one of:  15.1-iso        (default, PASSES)
#                          16.0-memstick   (PASSES)
#                          16.0-iso        (FAILS -- broken GPT, see below)
#                          <url>           any other image URL
#
# Measured results (FreeBSD 16 host, qemu 11.1.0):
#
#   15.1-iso       PASS   root via cd9660 label /dev/iso9660/15_1_RELEASE_...
#   16.0-memstick  PASS   root via UFS label   /dev/ufs/FreeBSD_Install
#   16.0-iso       FAIL   "ran out of disks to try after 1 disks tried"
#
# The 16.0 bootonly ISO failure is a FreeBSD release-engineering bug, NOT a
# memdisk_uefi bug: its GPT entry 2 (efi) points at LBA 59 (0x3B), but the
# FAT12 filesystem actually lives at LBA 80 (0xa000) -- the same place 15.1
# puts it.  LBA 59 is all zeros, so EDK2's PartitionDxe correctly refuses to
# publish a filesystem handle and nothing is bootable.  Off by 21 sectors,
# exactly the padding that disappeared from the layout between 15.1 and 16.
# Patching that one field (59 -> 80, then fixing the two GPT CRCs) makes the
# same ISO boot.  Use the memstick instead; it is unaffected.
#
# Note the memstick is MBR, not GPT, and that is fine: EDK2 handles MBR via
# PartitionInstallMbrChildHandles.  It needs "harddisk" rather than "iso",
# and its root is UFS rather than cd9660.

set -eu

arch=x86_64
mem=8G                  # image lives in RAM; needs headroom while loading
httpport=8000

# --- image selection ------------------------------------------------------
# img_mode is memdisk_uefi's argument: "iso" for a CD image, "harddisk" for a
# disk/memstick image.  img_root is the mount line the automated run waits
# for -- it differs because a memstick roots on UFS and an ISO on cd9660.
sel=15.1-iso
for a in "$@"; do
  case "$a" in
    -a) ;;
    *)  sel=$a ;;
  esac
done

base_rel=https://download.freebsd.org/ftp/releases/ISO-IMAGES/15.1
base_snap=https://download.freebsd.org/ftp/snapshots/ISO-IMAGES/16.0
snap=FreeBSD-16.0-CURRENT-amd64-20260824-74019bc3ea91-288532

case "$sel" in
  15.1-iso)
    img_url="$base_rel/FreeBSD-15.1-RELEASE-amd64-bootonly.iso"
    img_sha=3e74120a59512cefc35840443bdd05087c8a010a27cf8a6fbb4f7450824f092e
    img_file=fbsd15.iso;      img_mode=iso;      img_root=cd9660 ;;
  16.0-memstick)
    img_url="$base_snap/$snap-mini-memstick.img"
    img_sha=30eb693cdc0fb52fe2ac81441d2c55558cdd1673ff2a83202fa85c9e8842e6c2
    img_file=fbsd16.img;      img_mode=harddisk; img_root=ufs ;;
  16.0-iso)
    img_url="$base_snap/$snap-bootonly.iso"
    img_sha=e262c3d12bd93098dcacf217758cb6ba6afa3ee5f84d3cd20a0d6db1a3a95b6d
    img_file=fbsd16.iso;      img_mode=iso;      img_root=cd9660
    echo "NOTE: 16.0-iso is EXPECTED TO FAIL (broken GPT; see header)" >&2 ;;
  http://*|https://*)
    img_url="$sel"; img_sha=""
    img_file=$(basename "$sel")
    # .img/.raw are disk images; anything else is treated as a CD image.
    case "$img_file" in
      *.img|*.raw) img_mode=harddisk; img_root=ufs ;;
      *)           img_mode=iso;      img_root=cd9660 ;;
    esac ;;
  *)
    echo "unknown image: $sel" >&2
    echo "use 15.1-iso | 16.0-memstick | 16.0-iso | <url>" >&2
    exit 1 ;;
esac

# iPXE commit immediately BEFORE e61c636 "[build] Define a mechanism for
# marking Secure Boot permissibility" (2026-01-13), which introduced
# FILE_SECBOOT.  memdisk_uefi's efi_download.h include then fails with
# "unknown type name 'FILE_SECBOOT'" because iPXE force-includes compiler.h
# in its own build and memdisk_uefi does not.  Upstream bug; pinning keeps
# memdisk_uefi's source unmodified.
ipxe_pin="e61c636bf358a2c8b53290bacf16f73e0c548781~1"

auto=0
[ "${1:-}" = "-a" ] && auto=1

workdir=$(cd "$(dirname "$0")" && pwd)/memdisk-poc
build=$workdir/build
mkdir -p "$workdir" "$build"

need() { which -s "$1" || { echo "missing: $1 ($2)" >&2; exit 1; }; }
need git   "pkg install git"
need gmake "pkg install gmake"
need clang "base system"
need python3 "pkg install python3"
[ $auto -eq 1 ] && need expect "pkg install expect"

# --- lld-link -------------------------------------------------------------
# memdisk_uefi links a PE, not an ELF, so it needs the MSVC-style lld driver.
# FreeBSD base ships ld.lld but no lld-link; the llvm* ports ship lld-linkNN.
# Match the major version to base clang where possible.
if which -s lld-link; then
  lldbin=""
else
  cmaj=$(clang --version | sed -n 's/.*clang version \([0-9]*\).*/\1/p' | head -1)
  ll=""
  for c in "$cmaj" 22 21 19; do
    [ -x "/usr/local/bin/lld-link$c" ] && { ll=/usr/local/bin/lld-link$c; break; }
  done
  [ -n "$ll" ] || { echo "no lld-link found: pkg install llvm$cmaj" >&2; exit 1; }
  lldbin=$build/lldbin
  mkdir -p "$lldbin"
  ln -sf "$ll" "$lldbin/lld-link"
fi

# --- sources --------------------------------------------------------------
# The Makefile hardcodes ../edk2 and ../ipxe relative to memdisk_uefi/,
# so all three must be siblings.
[ -d "$build/edk2" ] || {
  echo "== fetching edk2 headers (sparse) =="
  git clone --depth 1 --filter=blob:none --sparse \
      https://github.com/tianocore/edk2.git "$build/edk2"
  ( cd "$build/edk2" && git sparse-checkout set MdePkg/Include )
}

[ -d "$build/ipxe" ] || {
  echo "== fetching iPXE (full history: we need a pinned old commit) =="
  git clone https://github.com/ipxe/ipxe.git "$build/ipxe"
}
( cd "$build/ipxe" && git checkout --quiet "$ipxe_pin" )

[ -d "$build/memdisk_uefi" ] || {
  echo "== fetching memdisk_uefi =="
  git clone --depth 1 https://github.com/russor/memdisk_uefi.git "$build/memdisk_uefi"
}

# --- build ----------------------------------------------------------------
# Output is named .elf but is actually PE32+ -- that is the whole point:
# UEFI LoadImage() only accepts PE.  See iPXE.md sec.2.
if [ ! -f "$build/memdisk_uefi/memdisk_uefi.elf" ]; then
  echo "== building memdisk_uefi =="
  ( cd "$build/memdisk_uefi" && PATH="${lldbin:+$lldbin:}$PATH" gmake )
fi
file "$build/memdisk_uefi/memdisk_uefi.elf" | grep -q 'PE32+' \
  || { echo "build produced a non-PE image" >&2; exit 1; }

# --- payload --------------------------------------------------------------
img=$workdir/$img_file
if [ ! -f "$img" ]; then
  echo "== fetching $(basename "$img_url") =="
  fetch -o "$img" "$img_url"
fi
if [ -n "$img_sha" ]; then
  echo "== verifying image is unmodified =="
  got=$(sha256 -q "$img")
  [ "$got" = "$img_sha" ] || { echo "checksum mismatch: $got" >&2; exit 1; }
else
  echo "== no known checksum for $img_file, skipping verification =="
fi

# --- firmware -------------------------------------------------------------
for f in /usr/local/share/qemu/edk2-${arch}-code.fd \
         /usr/local/share/edk2-qemu/QEMU_UEFI_CODE-${arch}.fd \
         /usr/share/qemu/edk2-${arch}-code.fd
do [ -f "$f" ] && { efi=$f; break; }; done
[ -n "${efi:-}" ] || { echo "no edk2 firmware found" >&2; exit 1; }

for v in /usr/local/share/qemu/edk2-i386-vars.fd \
         /usr/local/share/edk2-qemu/QEMU_UEFI_VARS-${arch}.fd
do [ -f "$v" ] && { varstpl=$v; break; }; done
[ -n "${varstpl:-}" ] || { echo "no edk2 vars template found" >&2; exit 1; }
cp "$varstpl" "$workdir/vars.fd"; chmod u+w "$workdir/vars.fd"

# --- iPXE binary (the firmware's TFTP bootfile) ---------------------------
[ -f "$workdir/ipxe.efi" ] || {
  [ -f /usr/local/share/ipxe/ipxe.efi-${arch} ] \
    || { echo "pkg install ipxe" >&2; exit 1; }
  cp /usr/local/share/ipxe/ipxe.efi-${arch} "$workdir/ipxe.efi"
}
cp "$build/memdisk_uefi/memdisk_uefi.elf" "$workdir/"

# --- iPXE script ----------------------------------------------------------
# Static addressing = qemu SLIRP defaults, so no DHCP is involved at all.
# 10.0.2.2 is the host as seen from the guest, where our HTTP server runs.
# Explicit http:// URLs rather than ${cwduri}: iPXE arrived via TFTP, and
# ${cwduri} would pull the 521 MB ISO over TFTP too.
cat > "$workdir/autoexec.ipxe" <<EOF
#!ipxe
set net0/ip 10.0.2.15
set net0/netmask 255.255.255.0
set net0/gateway 10.0.2.2
set net0/dns 10.0.2.3
ifopen net0
echo === memdisk_uefi: fetching image into RAM ===
boot http://10.0.2.2:${httpport}/memdisk_uefi.elf http://10.0.2.2:${httpport}/${img_file} ${img_mode}
echo Boot failed, press a key
prompt
EOF

# --- HTTP server ----------------------------------------------------------
python3 -m http.server "$httpport" --bind 127.0.0.1 \
    --directory "$workdir" > "$workdir/http.log" 2>&1 &
httppid=$!
trap 'kill $httppid 2>/dev/null' EXIT INT TERM
sleep 2
kill -0 $httppid 2>/dev/null || { echo "http server died" >&2; exit 1; }

qemu_args="-m $mem -boot n
  -drive if=pflash,unit=0,readonly=on,format=raw,file=$efi
  -drive if=pflash,unit=1,format=raw,file=$workdir/vars.fd
  -netdev user,id=net0,tftp=$workdir,bootfile=ipxe.efi
  -device virtio-net-pci,netdev=net0
  -device virtio-rng-pci
  -display none -serial mon:stdio"

if [ $auto -eq 0 ]; then
  cat <<'EOM'

=== At the FreeBSD boot menu, press 3 (Escape to loader prompt), then type:

    lsdev
    load boot/kernel/kernel
    load boot/kernel/nvdimm.ko
    boot

    nvdimm.ko is NOT in GENERIC, and after ExitBootServices() the UEFI RAM
    disk is only reachable through it.  Relative paths, exactly as shown.

    The lsdev is REQUIRED, not cosmetic: skip it and the kernel fails to
    mount root with error 19.  Replacing it with a delay does not help.

    Do NOT set vfs.root.mountfrom -- the loader autodetects the root by
    filesystem label and gets it right (an ISO roots on cd9660, e.g.
    /dev/iso9660/15_1_RELEASE_AMD64_BO; a memstick on UFS, e.g.
    /dev/ufs/FreeBSD_Install).  Overriding it with cd9660:/dev/spa0 fails
    to mount with error 19.

    Exit qemu with: Ctrl-a x

EOM
  echo "    image: $img_file  (memdisk_uefi mode: $img_mode, root: $img_root)"
  echo
  # shellcheck disable=SC2086
  exec qemu-system-${arch} $qemu_args
fi

# --- automated variant ----------------------------------------------------
exp=$workdir/drive.exp
{
  echo 'set timeout 400'
  echo "spawn qemu-system-${arch} $(echo $qemu_args | tr -s ' ')"
  echo "set img_root \"$img_root\""
  cat <<'EOF'
# "ran out of disks" means memdisk_uefi found no bootable filesystem on the
# RAM disk -- distinct from the loader never appearing.  This is the 16.0
# bootonly.iso failure: its GPT points the ESP at an empty LBA.
expect {
  -re {ran out of disks} {
      puts "\n### FAIL: no bootable ESP on the RAM disk (broken GPT?)"; exit 4 }
  -re {Autoboot in|Welcome to FreeBSD} { send "3"; exp_continue }
  "OK " { }
  timeout { puts "\n### FAIL: no loader prompt"; exit 2 }
}
sleep 1
# lsdev is required -- see note 5 in the header.
send "lsdev\r";                        expect "OK "
send "load boot/kernel/kernel\r";      expect "OK "
send "load boot/kernel/nvdimm.ko\r";   expect "OK "
send "boot\r"
expect {
  -re {nvdimm_acpi_root0}    { puts "\n### NVDIMM ROOT DEVICE ATTACHED"; exp_continue }
  -re "Trying to mount root from $img_root" {
      puts "\n### ROOT IS $img_root AS EXPECTED"; exp_continue }
  -re {mountroot>}           { puts "\n### FAIL: root not mounted"; exit 3 }
  -re {Console type}         { puts "\n### PASS: installer reached"; exit 0 }
  timeout                    { puts "\n### FAIL: timeout"; exit 2 }
}
EOF
} > "$exp"
expect "$exp"
