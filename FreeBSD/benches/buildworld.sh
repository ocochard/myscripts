#!/bin/sh
# Bench time spend to buildworld & kernel
# User are expected to have downloaded src in /usr/src
# cd /usr
set -eu

# Variables definitions

CPUS=$(sysctl -n kern.smp.cpus)
if [ $CPUS -le 4 ]; then
	JOBS=1
else
	JOBS=4
fi
RUNS=3

### System check ###

## Space needed ##
# - 1.2G for sources
# - 10G for obj dir
# - 1G free to compile
# => 16G minimum to build from RAM

PHYSMEM=$(sysctl -n hw.physmem)
if [ $PHYSMEM -lt 17105900000 ]; then
	echo "Need a minimum of 16G RAM"
	exit 1
fi

## tooling ##

# git

RAMDISK="/usr/obj/ramdisk"
SRCDIR="$RAMDISK/src"

mkdir -p $RAMDISK

TMPDIR=$(mktemp -d /tmp/buildbench.XXXXXX)
if mount | grep -q $RAMDISK; then
	# Previous run detection
	echo "Detected already mounted $RAMDISK"
	echo "Don't forget to unmount it next time!"
else
	# Build in a tmpfs, avoid benching hard disk i/o
	mount -t tmpfs tmpfs $RAMDISK
fi

# --depth 1 should imply --single-branch by default
# Consume about 1.2G of space
mkdir -p $SRCDIR
git clone --depth 1 --branch main --single-branch https://git.freebsd.org/src.git $SRCDIR

cd $SRCDIR

echo "Result in $TMPDIR"

# Init gnuplot data file
for i in real user sys; do
	echo "#index median minimum maximum" > $TMPDIR/gnuplot.$i.data
done

while [ $JOBS -le $((CPUS * 2)) ]; do
	for j in $(seq $RUNS); do
		echo "Jobs: $JOBS, run: $j/$RUNS"
		# Forcing GENERIC kernel, no custom MAKE_CONF/SRCCONF/SRC_ENV_CONF
		echo "Cleanup..."
		env __MAKE_CONF=/dev/null SRC_ENV_CONF=/dev/null MAKEOBJDIRPREFIX=$RAMDISK \
			make SRCCONF=/dev/null clean > /dev/null
		echo "Build..."
		# Write log into ram disk to avoid benching local disk speed
		env __MAKE_CONF=/dev/null SRC_ENV_CONF=/dev/null MAKEOBJDIRPREFIX=$RAMDISK \
			time -ao $TMPDIR/buildbench.$JOBS.time make -j $JOBS \
				KERNCONF=GENERIC SRCCONF=/dev/null buildworld buildkernel > $RAMDISK/buildbench.$JOBS.$j.log
	done # for j

	# Stats extractions to be ready to use by ministat
	# time output example:
	#         0.00 real         0.00 user         0.00 sys
	# real is 2, user is 4 and sys is 6
	timepos=2
	# ministat -qn output
	# real is 3, user is 4, sys is 4
	# x   3           112           134           124     123.33333     11.015141
	minipos=3

	for t in real user sys; do
		cut -w -f $timepos $TMPDIR/buildbench.$JOBS.time > $TMPDIR/buildbench.$JOBS.$t
		timepos=$((timepos + 2))

		ministat -qn $TMPDIR/buildbench.$JOBS.$t > $TMPDIR/buildbench.$JOBS.$t.ministat
		min=$(cut -w -f $minipos $TMPDIR/buildbench.$JOBS.$t.ministat)
		max=$(cut -w -f $minipos $TMPDIR/buildbench.$JOBS.$t.ministat)
		med=$(cut -w -f $minipos $TMPDIR/buildbench.$JOBS.$t.ministat)
		echo "$JOBS $med $min $max" >> $TMPDIR/gnuplot.$t.data
		minipos=$((minipos + 1))
	done # for t

	# multiply job per 2
	JOBS=$(( JOBS * 2 ))
done # while JOBS
umount $RAMDISK

