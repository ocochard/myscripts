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

# File to be downloaded by PXE
# https://boot.netboot.xyz/ipxe/netboot.xyz.efi
# Here we are using a very simple PXE config file to chain
cat <<EOF >chain.ipxe
#!ipxe
initrd https://download.freebsd.org/snapshots/ISO-IMAGES/15.0/FreeBSD-15.0-CURRENT-amd64-20250313-cabf76fde836-275921-mini-memstick.img
chain https://bapt.nours.eu/memdisk harddisk raw
EOF

pxe="chain.ipxe"
# Testing netboot
download=""
if ! [ -f netboot.xyz.efi ]; then
  for d in fetch wget curl; do
    download=$d
    which -s $d && break
  done
  ${download} https://boot.netboot.xyz/ipxe/netboot.xyz.efi
fi
pxe="netboot.xyz.efi"

# NIC with qemu as DHCP and TFTP server for PXE boot

qpxe="-netdev user,id=net0,tftp=$(pwd),bootfile=${pxe} -device virtio-net-pci,netdev=net0"

# Empty disk
if ! [ -f disk.img ]; then
  truncate -s 4G disk.img
fi

qdisk="-drive if=virtio,file=disk.img,format=raw,media=disk"

#qconsole="-display none -serial mon:stdio"
qconsole=""

qemu-system-${arch} -m 4G -boot n ${qefi} ${qpxe} ${qdisk} ${qconsole}

