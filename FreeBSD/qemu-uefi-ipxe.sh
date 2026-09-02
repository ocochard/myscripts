#!/bin/sh
# Testing EFI and iPXE with TFTP boot
# VM setup:
# EFI boot method
# NIC with qemu as DHCP server serving a specific small-network-boot-file using TFTP
# Empty disk (to be used to test the installation of the small-network-boot-file)

arch=x86_64

# EFI:
# This file could be anywere depending of the OS and qemu version
paths="
/opt/homebrew/Cellar/qemu/*/share/qemu/edk2-${arch}-code.fd
/Applications/UTM.app/Contents/Resources/qemu/edk2-${arch}-code.fd
/usr/local/share/qemu/edk2-${arch}-code.fd
/usr/share/qemu/edk2-${arch}-code.fd
"
efi=""
for path in ${paths}; do
  # Use ls to handle wildcards, suppress errors
  for found in $(ls $path 2>/dev/null); do
    if [ -f "$found" ]; then
      efi="$found"
    fi
  done
done

qefi="-drive if=pflash,readonly=on,format=raw,file=${efi}"

# Payload iPXE will chain to. Must be a PE image ("MZ"). Default is
# netboot.xyz.efi; override with e.g. PAYLOAD=fbsd-loader.efi.
#
# NOT usable here: memdisk (16-bit BIOS bzImage, no UEFI build - chaining it
# gives "Could not boot: Exec format error"), so the old
# "initrd memstick.img / chain memdisk harddisk raw" recipe is BIOS-only.
payload="${PAYLOAD:-netboot.xyz.efi}"

if ! [ -f "${payload}" ]; then
  for d in fetch wget curl; do
    which -s $d && { download=$d; break; }
  done
  [ -n "${download:-}" ] || { echo "no fetch/wget/curl found" >&2; exit 1; }
  case "${payload}" in
    netboot.xyz.efi) ${download} https://boot.netboot.xyz/ipxe/netboot.xyz.efi ;;
    *) echo "missing payload ${payload}" >&2; exit 1 ;;
  esac
fi

if [ "$(od -A n -c -N 2 "${payload}" | tr -d ' ')" != "MZ" ]; then
  echo "warning: ${payload} is not a PE image (no MZ header); chain will fail" >&2
fi

# iPXE script, fetched over TFTP by iPXE itself (see delivery method below).
# 10.0.2.2 is qemu SLIRP's gateway, which also serves TFTP from $(pwd).
cat <<EOF >boot.ipxe
#!ipxe
echo === qemu-uefi-ipxe.sh ===
dhcp || goto fail
echo Got \${net0/ip}
chain tftp://10.0.2.2/${payload} || goto fail
:fail
echo SCRIPT FAILED
shell
EOF

# Why iPXE boots from a local ESP and not over the network:
#
#  1. FreeBSD's packaged edk2 has no usable UEFI network stack, so "-boot n"
#     is a silent no-op that falls through to the EFI Shell. (Not detectable
#     by grepping the .fd - the DXE volume is LZMA-compressed. Verify by
#     running "ifconfig -l" in the EFI Shell: it prints nothing.)
#  2. Even with a working stack, SLIRP's single unconditional bootfile= would
#     hand iPXE back to iPXE forever - it cannot match DHCP option 77.
#
# Booting ipxe.efi from an ESP solves both. iPXE then runs its OWN DHCP,
# picks up bootfile=boot.ipxe, and needs no EMBED= rebuild.
# See ~/myscripts/FreeBSD/iPXE.md sections 5d, 8 and 9.
ipxe_efi="/usr/local/share/ipxe/ipxe.efi-${arch}"
if ! [ -f "${ipxe_efi}" ]; then
  echo "missing ${ipxe_efi} - install the ipxe package: pkg install ipxe" >&2
  exit 1
fi
mkdir -p esp/EFI/BOOT
cp "${ipxe_efi}" esp/EFI/BOOT/BOOTX64.EFI

qesp="-drive file=fat:rw:esp,format=raw,if=virtio"

# NIC: qemu SLIRP acts as DHCP + TFTP server for iPXE (not for the firmware)

qpxe="-netdev user,id=net0,tftp=$(pwd),bootfile=boot.ipxe -device virtio-net-pci,netdev=net0"

# Empty disk
if ! [ -f disk.img ]; then
  truncate -s 4G disk.img
fi

qdisk="-drive if=virtio,file=disk.img,format=raw,media=disk"

#qconsole="-display none -serial mon:stdio"
qconsole=""

# No "-boot n": the firmware boots the ESP, and iPXE does the networking.
qemu-system-${arch} -m 4G ${qefi} ${qesp} ${qpxe} ${qdisk} ${qconsole}

