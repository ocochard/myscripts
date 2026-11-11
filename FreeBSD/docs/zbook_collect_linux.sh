#!/bin/sh
# Collect hardware data on Ubuntu for the FreeBSD ZBook Ultra G1a docs.
# Run as root. Plays a short tone on the speakers at low volume.
# Output: /tmp/zbook-linux.tar.gz
set -u
O=/tmp/zbook-linux
rm -rf "$O"; mkdir -p "$O"
cd "$O" || exit 1

uname -a > uname.txt
dmesg > dmesg.txt
lspci -nnk > lspci.txt 2>&1
lsusb > lsusb.txt 2>&1
lsmod > lsmod.txt

# Which driver binds each ACPI device
for d in /sys/bus/acpi/devices/*; do
	hid=$(cat "$d/hid" 2>/dev/null) || continue
	path=$(cat "$d/path" 2>/dev/null)
	st=$(cat "$d/status" 2>/dev/null)
	phys=""; drv=""
	for p in "$d"/physical_node*; do
		[ -e "$p" ] || continue
		phys="$phys $(basename "$(readlink -f "$p")")"
		[ -e "$p/driver" ] && drv="$drv $(basename "$(readlink -f "$p/driver")")"
	done
	echo "$hid $path status=$st phys=[$phys ] driver=[$drv ]"
done | sort > acpi-drivers.txt

# I2C clients and their drivers
for c in /sys/bus/i2c/devices/*; do
	n=$(cat "$c/name" 2>/dev/null)
	drv=$( [ -e "$c/driver" ] && basename "$(readlink -f "$c/driver")" )
	echo "$(basename "$c") name=$n driver=$drv"
done > i2c-clients.txt

# ACPI tables, decompiled with the SSDTs as externals
mkdir acpi && (cd acpi && acpidump > acpi.dat 2>/dev/null && acpixtract -a acpi.dat >/dev/null 2>&1 &&
	iasl -e ssdt*.dat -d dsdt.dat > iasl-dsdt.log 2>&1;
	for s in ssdt*.dat; do iasl -d "$s" >/dev/null 2>&1; done)

# Audio state
cat /proc/asound/cards > asound-cards.txt
for f in /proc/asound/card*/codec#*; do cp "$f" "codec-$(echo "$f" | tr '/#' '__')"; done
amixer -c 0 contents > amixer-c0.txt 2>&1
aplay -l > aplay-l.txt 2>&1
ls /lib/firmware/cirrus 2>/dev/null | grep -i cs35l54 > fw-cirrus-cs35l54.txt
dmesg | grep -iE "cs35l|cirrus|scodec|hda" > dmesg-audio.txt

# CS35L54 regmap dumps: idle, then during playback
R=/sys/kernel/debug/regmap
mount | grep -q debugfs || mount -t debugfs none /sys/kernel/debug
for r in $R/*cs35l54*; do
	[ -e "$r/registers" ] && cat "$r/registers" > "regmap-idle-$(basename "$r").txt"
done
CARD=$(aplay -l 2>/dev/null | awk -F'[ :]' '/ALC245|Analog/ {print $2; exit}')
speaker-test -D "plughw:${CARD:-0},0" -c 2 -t sine -f 440 -l 3 > speaker-test.txt 2>&1 &
ST=$!
sleep 2
for r in $R/*cs35l54*; do
	[ -e "$r/registers" ] && cat "$r/registers" > "regmap-play-$(basename "$r").txt"
done
wait $ST

# I2C trace of a full amp driver probe (unbind/bind every amp)
T=/sys/kernel/tracing
[ -d $T ] || T=/sys/kernel/debug/tracing
echo 0 > $T/tracing_on; echo > $T/trace
echo 1 > $T/events/i2c/enable
echo 1 > $T/tracing_on
D=/sys/bus/i2c/drivers/cs35l56-hda
for c in "$D"/i2c-*; do
	[ -e "$c" ] || continue
	n=$(basename "$c")
	echo "$n" > "$D/unbind"
	echo "$n" > "$D/bind"
done
sleep 5
speaker-test -D "plughw:${CARD:-0},0" -c 2 -t sine -f 440 -l 1 >/dev/null 2>&1
echo 0 > $T/tracing_on
cp $T/trace i2c-trace-probe-play.txt
echo 0 > $T/events/i2c/enable
dmesg | tail -100 > dmesg-after-rebind.txt

cd /tmp && tar czf zbook-linux.tar.gz zbook-linux && echo "Done: /tmp/zbook-linux.tar.gz"
