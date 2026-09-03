#!/bin/sh
# UEFI netboot PoC: firmware -> iPXE (PE image) -> autoexec.ipxe -> FreeBSD
#
# Verified end to end on FreeBSD with qemu 11.1.0.
# See ../iPXE.md for why each piece is needed.
#
# The three non-obvious requirements:
#   1. bootfile= must be a PE image (ipxe.efi), never a .ipxe script  (iPXE.md sec.2)
#   2. -device virtio-rng-pci is REQUIRED or the firmware never even
#      sends DHCP: the TLS-enabled network stack needs entropy         (iPXE.md sec.9)
#   3. the script is delivered as autoexec.ipxe next to ipxe.efi on
#      the same TFTP dir -- no EMBED= rebuild needed                   (iPXE.md sec.5e)

set -eu

arch=x86_64
mem=8G
workdir=$(cd "$(dirname "$0")" && pwd)/ipxe-poc
mkdir -p "$workdir"

# --- UEFI firmware ---------------------------------------------------------
# Needs the *bundled qemu* blob or the edk2-qemu port; both work.
for f in \
  /usr/local/share/qemu/edk2-${arch}-code.fd \
  /usr/local/share/edk2-qemu/QEMU_UEFI_CODE-${arch}.fd \
  /opt/homebrew/Cellar/qemu/*/share/qemu/edk2-${arch}-code.fd \
  /usr/share/qemu/edk2-${arch}-code.fd
do
  [ -f "$f" ] && { efi=$f; break; }
done
[ -n "${efi:-}" ] || { echo "no edk2 ${arch} firmware found" >&2; exit 1; }

# Writable NVRAM copy (boot options are persisted here).
for v in /usr/local/share/qemu/edk2-i386-vars.fd \
         /usr/local/share/edk2-qemu/QEMU_UEFI_VARS-${arch}.fd
do
  [ -f "$v" ] && { varstpl=$v; break; }
done
[ -n "${varstpl:-}" ] || { echo "no edk2 vars template found" >&2; exit 1; }
cp "$varstpl" "$workdir/vars.fd"
chmod u+w "$workdir/vars.fd"

# --- iPXE: the PE image the firmware will actually load --------------------
if [ ! -f "$workdir/ipxe.efi" ]; then
  if [ -f /usr/local/share/ipxe/ipxe.efi-${arch} ]; then
    cp /usr/local/share/ipxe/ipxe.efi-${arch} "$workdir/ipxe.efi"
  else
    echo "install net/ipxe (pkg install ipxe) or drop an ipxe.efi in $workdir" >&2
    exit 1
  fi
fi

# --- the script, delivered as autoexec.ipxe -------------------------------
# Static addressing = qemu SLIRP defaults, so iPXE needs no DHCP of its own.
cat > "$workdir/autoexec.ipxe" <<'EOF'
#!ipxe
set net0/ip 10.0.2.15
set net0/netmask 255.255.255.0
set net0/gateway 10.0.2.2
set net0/dns 10.0.2.3
ifopen net0
echo === autoexec.ipxe running ===
initrd https://download.freebsd.org/ftp/releases/ISO-IMAGES/15.1/FreeBSD-15.1-RELEASE-amd64-mini-memstick.img
chain https://bapt.nours.eu/memdisk harddisk raw
EOF

# --- empty target disk ----------------------------------------------------
[ -f "$workdir/disk.img" ] || truncate -s 4G "$workdir/disk.img"

echo "firmware: $efi"
echo "tftp dir: $workdir (bootfile=ipxe.efi, script=autoexec.ipxe)"
echo

exec qemu-system-${arch} -m "$mem" -boot n \
  -drive if=pflash,unit=0,readonly=on,format=raw,file="$efi" \
  -drive if=pflash,unit=1,format=raw,file="$workdir/vars.fd" \
  -netdev user,id=net0,tftp="$workdir",bootfile=ipxe.efi \
  -device virtio-net-pci,netdev=net0 \
  -device virtio-rng-pci \
  -drive if=virtio,file="$workdir/disk.img",format=raw,media=disk \
  -display none -serial mon:stdio
