#!/usr/local/bin/bash
#
# Boot an Arista vEOS-lab qcow2 image under FreeBSD bhyve.
#
# The vEOS-lab disk holds no bootloader: it is a single ext4 "eos_flash"
# partition containing boot-config and vEOS-lab.swi.  On KVM the Aboot ISO
# boots first, then kexecs the EOS kernel out of the SWI.  That kexec step
# does not survive bhyve (the second kernel inherits the emulated interrupt
# controllers and hangs in check_timer), so this script loads the EOS kernel
# and initrd straight out of the SWI with grub-bhyve, reproducing the kernel
# command line Aboot would have generated.
#
# One guest workaround is needed: the EOS initrd runs "flashrom -Q" to probe
# the SPI flash chip, which reads an unbacked guest-physical address and makes
# bhyve abort with "vm_run error -1, errno 14" (EFAULT).  A small cpio overlay
# is appended to the initrd to replace /bin/flashrom with a stub.
#
# Requires: sysutils/grub2-bhyve, emulators/qemu-tools (qemu-img), root.

set -euo pipefail

QCOW=${QCOW:-$HOME/vEOS64-lab-4.36.1F.qcow2}
WORK=${WORK:-$HOME/veos-bhyve}
VM=${VM:-veos}
CPUS=${CPUS:-2}
MEM=${MEM:-4096}
TAP=${TAP:-tap100}
BRIDGE=${BRIDGE:-}

usage() {
    cat <<EOF
Usage: $0 [-q qcow2] [-w workdir] [-n vmname] [-c cpus] [-m mem_mb] [-t tap] [-b bridge]

Environment variables of the same name may be used instead of the flags.
Console is attached to stdio; "~." or destroying the VM from another
terminal (bhyvectl --destroy --vm=$VM) exits.
EOF
    exit 1
}

while getopts "q:w:n:c:m:t:b:h" opt; do
    case "$opt" in
        q) QCOW=$OPTARG ;;
        w) WORK=$OPTARG ;;
        n) VM=$OPTARG ;;
        c) CPUS=$OPTARG ;;
        m) MEM=$OPTARG ;;
        t) TAP=$OPTARG ;;
        b) BRIDGE=$OPTARG ;;
        *) usage ;;
    esac
done

[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 1; }
[ -f "$QCOW" ] || { echo "no such image: $QCOW" >&2; exit 1; }

RAW=$WORK/$(basename "${QCOW%.qcow2}").raw
KERNEL=$WORK/linux-i386
INITRD=$WORK/initrd-veos-bhyve.img

mkdir -p "$WORK"
kldload -n vmm nmdm

# 1. qcow2 -> raw (bhyve has no qcow2 backend)
if [ ! -f "$RAW" ]; then
    echo "==> converting $QCOW to raw"
    qemu-img convert -O raw "$QCOW" "$RAW"
fi

# 2. pull the EOS kernel + initrd out of the SWI on the flash partition
if [ ! -f "$KERNEL" ] || [ ! -f "$INITRD" ]; then
    echo "==> extracting kernel and initrd from vEOS-lab.swi"
    kldload -n ext2fs
    md=$(mdconfig -a -t vnode -f "$RAW")
    mnt=$(mktemp -d)
    trap 'umount "$mnt" 2>/dev/null || true; rmdir "$mnt" 2>/dev/null || true; mdconfig -du "$md" 2>/dev/null || true' EXIT
    mount -t ext2fs -o ro "/dev/${md}s2" "$mnt"
    unzip -oq "$mnt/vEOS-lab.swi" linux-i386 initrd-i386 -d "$WORK"
    umount "$mnt"; rmdir "$mnt"; mdconfig -du "$md"
    trap - EXIT

    # cpio overlay neutralising flashrom, appended to the vendor initrd
    stub=$(mktemp -d)
    mkdir -p "$stub/bin"
    printf '#!/bin/sh\nexit 1\n' > "$stub/bin/flashrom"
    chmod 755 "$stub/bin/flashrom"
    (cd "$stub" && find . | cpio -o -H newc --quiet) > "$WORK/flashrom-stub.cpio"
    rm -rf "$stub"
    cat "$WORK/initrd-i386" "$WORK/flashrom-stub.cpio" > "$INITRD"
fi

# 3. grub-bhyve boot files.  The command line mirrors what Aboot's boot0
#    builds for platform=veos; dmamem=0M is what keeps the EOS kernel from
#    trying to reserve a CMA region it cannot get.
cat > "$WORK/device.map" <<EOF
(hd0) $RAW
EOF
cat > "$WORK/grub.cfg" <<EOF
linux (host)$KERNEL nmi_watchdog=panic tsc=reliable pcie_ports=native reboot=p usb-storage.delay_use=0 pti=off watchdog.stop_on_reboot=0 mds=off nohz=off SWI=flash:/vEOS-lab.swi CONSOLESPEED=9600 console=ttyS0 Aboot=Aboot-veos-8.0.2-32351763 platform=veos log_buf_len=2M systemd.show_status=0 loglevel=4 dmamem=0M
initrd (host)$INITRD
boot
EOF

# 4. Management1 interface
sysctl -q net.link.tap.up_on_open=1
ifconfig "$TAP" >/dev/null 2>&1 || ifconfig "$TAP" create
[ -n "$BRIDGE" ] && { ifconfig "$BRIDGE" >/dev/null 2>&1 || ifconfig "$BRIDGE" create; \
    ifconfig "$BRIDGE" addm "$TAP" 2>/dev/null || true; }

# 5. run
bhyvectl --destroy --vm="$VM" 2>/dev/null || true
echo "==> loading kernel"
grub-bhyve -m "$WORK/device.map" -M "$MEM" -r host -d "$WORK" "$VM"
echo "==> starting $VM (${CPUS} vcpu, ${MEM}M)"
bhyve -c "$CPUS" -m "${MEM}M" -A -H -P -u -w \
    -s 0:0,hostbridge \
    -s 1:0,lpc \
    -s 2:0,virtio-blk,"$RAW" \
    -s 3:0,virtio-net,"$TAP" \
    -l com1,stdio \
    "$VM"
rc=$?
bhyvectl --destroy --vm="$VM" 2>/dev/null || true
exit $rc
