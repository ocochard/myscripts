#!/bin/sh
# Guest side of pci_hotplug_bars_qemu.sh.  Runs from rc.local in the
# kern-test-vm image and checks the three cases of the PR 133 review on
# the QEMU layout the host script builds:
#
#   pci0:0:16:0 root port 1: pci-testdev f0 (BAR2 2 MB) + f1 (BAR2 64 MB)
#   pci0:0:17:0 root port 2: empty at boot, 64-bit prefetchable window;
#                            the host hot-plugs a bochs-display there
#   pci0:0:18:0 root port 3: pci-testdev with a 1 TB BAR2 that firmware
#                            cannot place
#
# Case 1: a forced BAR must not take a sibling function's firmware range.
# Case 2: a 32-bit BAR must not be placed above 4 GB.
# Case 3: a failed early reservation must not clear the decode bits of a
#         function whose other BAR is assigned.

RP1=pci0:0:16:0
RP2=pci0:0:17:0
RP3=pci0:0:18:0

secbus() {
	echo $(( (0x$(pciconf -r "$1" 0x18 | tr -d " ") >> 8) & 0xff ))
}

devname() {
	pciconf -l | awk -v s="@$1:" 'index($1, s) { split($1, a, "@"); print a[1] }'
}

show() {
	# pciconf -lb prints the kernel's copy of the BARs; also print the
	# registers themselves.
	for s; do
		pciconf -lb "$s"
		echo "    command=0x$(pciconf -r -h "$s" 0x4 | tr -d " ")" \
		    "BAR regs 0x10-0x24: $(pciconf -r "$s" 0x10:0x24)"
	done
}

slot_power_on() {
	off=$(pciconf -lc "$1" | sed -n 's/.*cap 10\[\([0-9a-f]*\)\].*/\1/p')
	reg=$(printf '0x%x' $((0x$off + 0x18)))
	ctl=0x$(pciconf -r -h "$1" $reg | tr -d " ")
	pciconf -w -h "$1" $reg $(( ctl & ~0x400 ))
	echo "  $1 slot control $ctl -> 0x$(pciconf -r -h "$1" $reg | tr -d " ")"
}

windows() {
	echo "  $1 ($(devname "$1")): io/sec 0x$(pciconf -r "$1" 0x1c)" \
	    "mem 0x$(pciconf -r "$1" 0x20) pmem 0x$(pciconf -r "$1" 0x24)" \
	    "pmem-hi 0x$(pciconf -r "$1" 0x28)-0x$(pciconf -r "$1" 0x2c)"
}

replug() {
	# Delete the root port and rescan: pci_add_children() runs again on
	# the BAR values now in config space.
	devctl delete -f "$(devname "$1")"
	devctl rescan pci0
	sleep 3
}

echo "=== layout at boot"
pciconf -l | grep -E '@pci0:0:1[678]:0:|vendor=0x1b36 device=0x0005|vendor=0x1234'
for rp in $RP1 $RP2 $RP3; do windows $rp; done

echo "=== CASE2: hot-plug a 32-bit prefetchable BAR into a window above 4 GB"
B2=$(secbus $RP2)
echo "CASE2-READY bus $B2"
# The loader sets hw.pci.enable_pcie_hp=0, so nothing reacts to the
# hot-plug event: re-add the root port to enumerate the new device.
sleep 15
slot_power_on $RP2
sleep 2
replug $RP2
show pci0:$B2:0:0
windows $RP2
n2=$(devname pci0:$B2:0:0)
[ -n "$n2" ] && devinfo -u | grep -w -e "$n2" -e "$(devname $RP2)"

echo "=== CASE1: forced BAR against a sibling's firmware BAR"
B1=$(secbus $RP1)
echo "--- before"
show pci0:$B1:0:0 pci0:$B1:0:1
pciconf -w pci0:$B1:0:0 0x18 0
pciconf -w pci0:$B1:0:0 0x1c 0
replug $RP1
echo "--- after zeroing f0 BAR2 and re-adding"
show pci0:$B1:0:0 pci0:$B1:0:1
windows $RP1

echo "=== CASE3: assigned BAR0 plus an unassigned BAR2 that cannot fit"
B3=$(secbus $RP3)
mem=0x$(pciconf -r $RP3 0x20 | tr -d " ")
base=$(( (mem & 0xfff0) << 16 ))
printf '  root port 3 memory window base 0x%x\n' $base
pciconf -w pci0:$B3:0:0 0x10 $base
pciconf -w pci0:$B3:0:0 0x18 0
pciconf -w pci0:$B3:0:0 0x1c 0
cmd=0x$(pciconf -r -h pci0:$B3:0:0 0x4 | tr -d " ")
pciconf -w -h pci0:$B3:0:0 0x4 $(( cmd | 0x2 ))
echo "--- before (BAR0 assigned, BAR2 0, memory decode on)"
show pci0:$B3:0:0
replug $RP3
echo "--- after re-adding"
show pci0:$B3:0:0

echo "=== kernel messages"
dmesg | grep -E 'pci[0-9]+:|pcib[0-9]+:|bytes of rid|failed' | tail -n 40
