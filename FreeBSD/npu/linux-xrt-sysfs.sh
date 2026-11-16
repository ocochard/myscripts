#!/bin/sh
#
# Build a minimal Linux /sys for a Linux userland under linuxlator (by
# default /compat/ubuntu) so that Linux XRT and its amdxdna plugin find
# the NPU driven by the FreeBSD amdxdna port.
#
# linsysfs has no bus/pci/drivers/ and no attributes for the NPU, so
# this mounts a tmpfs on <root>/sys and fills it with the entries XRT
# reads, taken from the FreeBSD sysctls:
#   dev.amdxdna.<unit>.%location    PCI domain:bus:slot:function
#   dev.amdxdna.<unit>.%pnpinfo     vendor, device, subvendor, subdevice
#   sys.device.amdxdna<unit>.<attr> driver attributes (LinuxKPI sysfs)
# The values do not change while the driver is loaded; rerun after
# reloading amdxdna.
#
# Usage: linux-xrt-sysfs.sh [linux root]   (as root)

set -eu

root=${1:-/compat/ubuntu}
sys=$root/sys
linsys=/compat/linux/sys

if [ "$(id -u)" -ne 0 ]; then
	echo "run as root" >&2
	exit 1
fi
if ! sysctl -q dev.amdxdna.0.%location >/dev/null; then
	echo "amdxdna is not loaded" >&2
	exit 1
fi

mkdir -p "$sys"
if mount -p | awk -v m="$sys" '$2 == m { found = 1 } END { exit !found }'; then
	umount "$sys"
fi
mount -t tmpfs tmpfs "$sys"

# CPU topology files glibc and OpenMP read (sysconf, affinity).
mkdir -p "$sys/devices/system/cpu"
ncpu=$(sysctl -n hw.ncpu)
for f in online possible present; do
	if [ -r "$linsys/devices/system/cpu/$f" ]; then
		cat "$linsys/devices/system/cpu/$f" > "$sys/devices/system/cpu/$f"
	else
		echo "0-$((ncpu - 1))" > "$sys/devices/system/cpu/$f"
	fi
done

mkdir -p "$sys/bus/pci/devices" "$sys/bus/pci/drivers/amdxdna"

unit=0
while sysctl -q "dev.amdxdna.$unit.%location" >/dev/null; do
	loc=$(sysctl -n "dev.amdxdna.$unit.%location")
	pnp=$(sysctl -n "dev.amdxdna.$unit.%pnpinfo")
	dbsf=$(echo "$loc" | sed -E 's/.*dbsf=pci([0-9]+):([0-9]+):([0-9]+):([0-9]+).*/\1 \2 \3 \4/')
	set -- $dbsf
	bdf=$(printf "%04x:%02x:%02x.%x" "$1" "$2" "$3" "$4")
	dev=$sys/devices/pci0000:00/$bdf

	mkdir -p "$dev/accel/accel$unit"
	for kv in vendor:vendor device:device subvendor:subsystem_vendor \
	    subdevice:subsystem_device class:class; do
		key=${kv%%:*}
		file=${kv#*:}
		echo "$pnp" | tr ' ' '\n' | sed -n "s/^$key=//p" > "$dev/$file"
	done
	for attr in revision device_type vbnv fw_version; do
		sysctl -n "sys.device.amdxdna$unit.$attr" > "$dev/$attr" 2>/dev/null || :
	done
	echo "accel$unit" > "$dev/accel/accel$unit/uevent"

	ln -s "../../../devices/pci0000:00/$bdf" "$sys/bus/pci/devices/$bdf"
	ln -s "../../../../devices/pci0000:00/$bdf" "$sys/bus/pci/drivers/amdxdna/$bdf"
	ln -s "../../../bus/pci/drivers/amdxdna" "$dev/driver"

	echo "amdxdna$unit: $bdf -> /dev/accel/accel$unit"
	unit=$((unit + 1))
done
