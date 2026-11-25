#!/bin/sh
# Boot a kern-test-vm image in QEMU (q35, UEFI) with three PCIe hot-plug
# root ports, once per kernel, and run pci_hotplug_bars_qemu_guest.sh in
# the guest (copied into the image at each boot).  The script hot-plugs
# a bochs-display into root port 2 when the guest prints CASE2-READY.
#
#   sudo ./pci_hotplug_bars_qemu.sh image kernel-name...
#
# Make the image first, with each kernel under its own name:
#   sudo ../kern-test-vm/mkvm.sh -o image -k obj/kernel:kernel.base ... \
#       -t dir-with-run.sh     # run.sh = pci_hotplug_bars_qemu_guest.sh
set -u

IMG=$1
shift
CODE=/usr/local/share/edk2-qemu/QEMU_UEFI_CODE-x86_64.fd
VARS_TEMPLATE=/usr/local/share/edk2-qemu/QEMU_UEFI_VARS-x86_64.fd
[ "$(id -u)" -eq 0 ] || { echo "$0: must be root" >&2; exit 1; }

for KNAME; do
	MD=$(mdconfig -a -t vnode -f "$IMG")
	MNT=$(mktemp -d /tmp/qvm.XXXXXX)
	mount "/dev/${MD}p2" "$MNT"
	sed -i '' "s/^kernel=.*/kernel=\"$KNAME\"/" "$MNT/boot/loader.conf"
	# FreeBSD's native hot-plug handler is off: see the guest script.
	grep -q '^hw.pci.enable_pcie_hp=' "$MNT/boot/loader.conf" ||
	    echo 'hw.pci.enable_pcie_hp="0"' >> "$MNT/boot/loader.conf"
	grep -E '^(kernel|hw.pci.enable_pcie_hp)=' "$MNT/boot/loader.conf"
	cp "$(dirname "$0")/pci_hotplug_bars_qemu_guest.sh" "$MNT/root/test/run.sh"
	rm -f "$MNT/root/results"
	umount "$MNT"
	mdconfig -du "$MD"
	rmdir "$MNT"

	VARS=$(mktemp /tmp/qvm-vars.XXXXXX)
	cp "$VARS_TEMPLATE" "$VARS"
	LOG=/tmp/qvm-console.$KNAME
	MON=/tmp/qvm-mon.$KNAME
	rm -f "$LOG" "$MON"
	timeout -s KILL 1500 qemu-system-x86_64 -machine q35 \
	    -accel tcg,thread=multi -smp 4 -m 4G -nodefaults -vga none \
	    -display none \
	    -drive if=pflash,format=raw,readonly=on,file="$CODE" \
	    -drive if=pflash,format=raw,file="$VARS" \
	    -drive file="$IMG",format=raw,if=none,id=d0 \
	    -device virtio-blk-pci,drive=d0,bus=pcie.0,addr=0x5 \
	    -global ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off \
	    -device pcie-root-port,id=rp1,bus=pcie.0,addr=0x10,chassis=1,slot=1 \
	    -device pci-testdev,bus=rp1,addr=0.0,multifunction=on,membar=2M \
	    -device pci-testdev,bus=rp1,addr=0.1,membar=64M \
	    -device pcie-root-port,id=rp2,bus=pcie.0,addr=0x11,chassis=2,slot=2,pref64-reserve=64M,mem-reserve=32M \
	    -device pcie-root-port,id=rp3,bus=pcie.0,addr=0x12,chassis=3,slot=3,mem-reserve=4M \
	    -device pci-testdev,bus=rp3,membar=1T \
	    -serial file:"$LOG" -monitor unix:"$MON",server,nowait &
	QPID=$!

	# Hot-plug once the guest is waiting for it.
	i=0
	while kill -0 $QPID 2>/dev/null; do
		if grep -q CASE2-READY "$LOG" 2>/dev/null; then
			sleep 2
			echo 'device_add bochs-display,bus=rp2,id=hp2' |
			    nc -N -U "$MON" >/dev/null
			echo "==> $KNAME: hot-plugged bochs-display"
			break
		fi
		i=$((i + 1))
		[ $i -gt 1200 ] && break
		sleep 1
	done
	wait $QPID
	echo "==> $KNAME: qemu exit $?, console $LOG"
	rm -f "$VARS" "$MON"

	MD=$(mdconfig -a -t vnode -f "$IMG")
	MNT=$(mktemp -d /tmp/qvm.XXXXXX)
	mount -o ro "/dev/${MD}p2" "$MNT"
	cp "$MNT/root/results" "/tmp/qvm-results.$KNAME" 2>/dev/null ||
	    echo "==> $KNAME: no /root/results"
	umount "$MNT"
	mdconfig -du "$MD"
	rmdir "$MNT"
done
