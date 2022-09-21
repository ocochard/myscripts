#!/bin/sh
# Bench time spend to buildworld & kernel
# /etc/src.conf (or make.conf):
# WITHOUT_LLVM_ASSERTIONS=yes
# WITH_MALLOC_PRODUCTION=yes
# MALLOC_PRODUCTION=yes
#

set -eu

CPUS=$(sysctl -n kern.smp.cpus)
if [ $CPUS -le 4 ]; then
	JOBS=1
else
	JOBS=4
fi
RUNS=3
TMPFS="/usr/obj/ramdisk"
SRCDIR="/usr/src"

mkdir -p $TMPFS
if mount | grep -q $TMPFS; then
	echo "Detected already mounted $TMPFS"
	echo "Don't forget to unmount it next time!"
else
	mount -t tmpfs tmpfs $TMPFS
fi

cd $SRCDIR

while [ $JOBS -lt $((CPUS * 2)) ]; do
	for j in $(seq $RUNS); do
		echo Jobs: $JOBS / run: $j
		# Forcing default kernel and no custom MAKE_CONF
		echo "Cleanup..."
		env __MAKE_CONF=/dev/null MAKEOBJDIRPREFIX=$TMPFS \
			make clean > /dev/null
		echo "Build..."
		env __MAKE_CONF=/dev/null MAKEOBJDIRPREFIX=$TMPFS \
			/usr/bin/time -h -o buildbench.$JOBS.$j.time make -j $JOBS \
				KERNCONF=GENERIC buildworld buildkernel > buildbench.$JOBS.$j.log
		cat buildbench.$JOBS.$j.time
	done
	JOBS=$(( JOBS * 2 ))
done

umount $TMPFS
