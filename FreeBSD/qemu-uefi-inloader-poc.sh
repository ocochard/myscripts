#!/bin/sh
# Boot a stock FreeBSD memstick over the network using the D59415..D59421
# loader
#
# The patched loader.efi speaks iPXE's download protocol itself: iPXE only
# chainloads it, and the loader then fetches the memstick straight into RAM,
# registers it, and boots.  Nothing is typed at the loader prompt.
#
# Both files are fetched over HTTPS from their public homes; the memstick is
# the stock published snapshot, unmodified.
#
# THIS IS THE RECOMMENDED WAY to iPXE-boot a FreeBSD disk image under UEFI.
#
# The other two scripts here are the routes this one supersedes: both need an
# external memdisk payload to republish the image to the kernel, and each has
# a catch -- qemu-uefi-ipxe-poc.sh chainloads a third-party memdisk service,
# qemu-uefi-memdisk-poc.sh needs memdisk_uefi.elf built against a pre-2026
# iPXE plus nvdimm.ko loaded by hand at the prompt.  Here the loader speaks
# iPXE's download protocol natively, so there is no payload to build, no
# module to load, and nothing to type.  Keep them for the comparison and for
# the case where you cannot replace the loader; prefer this one otherwise.
#
# See ./iPXE.md sec.7d for the memdisk_uefi route it replaces.

# Requirements:
# - qemu
# - ipxe

set -eu

loader=https://people.freebsd.org/~olivier/iPXE/loader.D59415.efi

# 15.1-RELEASE by default. Override with IMAGE= to try another memstick, e.g.
# the 16.0 snapshot below (snapshots expire, so the date will need bumping):
#   snap=FreeBSD-16.0-CURRENT-amd64-20260824-74019bc3ea91-288532
#   IMAGE=https://download.freebsd.org/ftp/snapshots/ISO-IMAGES/16.0/$snap-mini-memstick.img.xz
image=${IMAGE:-https://download.freebsd.org/releases/amd64/amd64/ISO-IMAGES/15.1/FreeBSD-15.1-RELEASE-amd64-mini-memstick.img.xz}

arch=x86_64
mem=8G                  # the image lives in RAM; 726MB plus headroom
workdir=$(mktemp -d /tmp/d59415.XXXXXX)
trap 'rm -rf "$workdir"' EXIT INT TERM

# iPXE hardcodes "file:autoexec.ipxe", so this must keep that exact name.
# memdisk= is for a disk image (a memstick); an ISO would use memcd=.
cat > "$workdir/autoexec.ipxe" <<EOF
#!ipxe
dhcp
echo === chainloading patched loader.efi ===
chain $loader memdisk=$image
echo Boot failed, press a key
prompt
EOF

cp /usr/local/share/ipxe/ipxe.efi-${arch} "$workdir/ipxe.efi"

for f in /usr/local/share/qemu/edk2-${arch}-code.fd \
         /usr/local/share/edk2-qemu/QEMU_UEFI_CODE-${arch}.fd
do [ -f "$f" ] && { efi=$f; break; }; done
for v in /usr/local/share/qemu/edk2-i386-vars.fd \
         /usr/local/share/edk2-qemu/QEMU_UEFI_VARS-${arch}.fd
do [ -f "$v" ] && { varstpl=$v; break; }; done
cp "$varstpl" "$workdir/vars.fd"; chmod u+w "$workdir/vars.fd"

# -device virtio-rng-pci is REQUIRED: the TLS-enabled EDK2 network stack
# blocks on entropy and never sends DHCP without it.  SLIRP gives the guest
# working outbound NAT, which is what reaches people.freebsd.org.
exec qemu-system-${arch} -m $mem -boot n \
  -drive if=pflash,unit=0,readonly=on,format=raw,file="$efi" \
  -drive if=pflash,unit=1,format=raw,file="$workdir/vars.fd" \
  -netdev user,id=net0,tftp="$workdir",bootfile=ipxe.efi \
  -device virtio-net-pci,netdev=net0 \
  -device virtio-rng-pci \
  -display none -serial mon:stdio
