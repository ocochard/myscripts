#!/bin/sh
# Bench time spend to buildworld & kernel
set -eu

# Variables definitions

CPUS=$(sysctl -n kern.smp.cpus)
if [ $CPUS -le 4 ]; then
	JOBS=1
else
	JOBS=4
fi

RUNS=3						# Number of iteration for each bench
RAMDISK="/usr/obj/ramdisk"	# RAM disk (tmpfs) directory
SRCDIR="$RAMDISK/src"		# FreeBSD source directory

# Function definitions

# A usefull function (from: http://code.google.com/p/sh-die/)
die() { echo -n "EXIT: " >&2; echo "$@" >&2; exit 1; }

### System check ###

## Dependencies

# git
which -s git || die "git not available (used to download FreeBSD sources)"

## Space needed ##
# - 1.2G for sources
# - 10G for obj dir
# - 1G free to compile
# => 16G minimum to build from RAM, or more if ZFS in use?
# ZFS cache could render useless the storage of sources in RAM

PHYSMEM=$(sysctl -n hw.physmem)
if [ $PHYSMEM -lt 17105900000 ]; then
	die "Need a minimum of 16G RAM"
	# XXX Or switch to non-tmpfs
fi

mkdir -p $RAMDISK

TMPDIR=$(mktemp -d /tmp/buildbench.XXXXXX)

if mount | grep -q $RAMDISK; then
	# Previous run detection
	echo "Detected already mounted $RAMDISK"
	echo "Don't forget to unmount it next time!"
else
	# Build in a tmpfs, avoid benching hard disk i/o
	# XXX How to avoid swap usage ?
	mount -t tmpfs tmpfs $RAMDISK
fi

# --depth 1 should imply --single-branch by default
# Consume about 1.2G of space
mkdir -p $SRCDIR
git clone --depth 1 --branch main --single-branch https://git.freebsd.org/src.git $SRCDIR

cd $SRCDIR
GITREV=$(git rev-parse --short HEAD)
GITDATE=$(git log -1 --format=%ai)

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
			make SRCCONF=/dev/null clean > /dev/null 2>&1
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

	for t in real user sys; do
		cut -w -f $timepos $TMPDIR/buildbench.$JOBS.time > $TMPDIR/buildbench.$JOBS.$t
		timepos=$((timepos + 2))

		ministat -qn $TMPDIR/buildbench.$JOBS.$t > $TMPDIR/buildbench.$JOBS.$t.ministat
		# ministat output example:
		#    N           Min           Max        Median           Avg        Stddev
		#x   3       4230.49       4243.08        4231.5     4235.0233     6.9955295
		# Min is 3, Max is 4, Median is 5
		min=$(cut -w -f 3 $TMPDIR/buildbench.$JOBS.$t.ministat)
		max=$(cut -w -f 4 $TMPDIR/buildbench.$JOBS.$t.ministat)
		med=$(cut -w -f 5 $TMPDIR/buildbench.$JOBS.$t.ministat)
		echo "$JOBS $med $min $max" >> $TMPDIR/gnuplot.$t.data
	done # for t

	# multiply job per 2
	JOBS=$(( JOBS * 2 ))
done # while JOBS

# Gnuplot example file

MACHINE=$(uname -m)
VERSION=$(uname -r)
VERSIONU=$(uname -U)
MODEL=$(sysctl -n hw.model)
# Number of physical cores online
CORES=$(sysctl -n kern.smp.cores)
# Number of SMT threads online per core
TPC=$(sysctl -n kern.smp.threads_per_core)
# Number of CPUs online
CPUS=$(sysctl -n kern.smp.cpus)
RAM=$(sysctl -n hw.physmem)
RAM=$((RAM / 1024 / 1024 / 1024))	# convert byte into GB

cat > $TMPDIR/gnuplot.plt <<EOF
# Gnuplot script file for plotting data from bench lab

set yrange [0:*]
set decimalsign locale
set terminal png truecolor size 1920,1080 font "Gill Sans,22"
set output 'graph.png'
set grid back
set border 3 back linestyle 80
set tics nomirror
set style fill solid 1.0 border -1
set style histogram errorbars gap 2 lw 2
set boxwidth 0.9 relative

set title noenhanced "Job numbers' impact on 'make buildworld buildkernel' execution time\n$MODEL (cores: $CORES, thread per core: $TPC, Total CPUs: $CPUS) with $RAM GB RAM"
set xlabel font "Gill Sans,16"
set xlabel noenhanced "FreeBSD/$MACHINE $VERSION ($VERSIONU) building main sources cloned at $GITREV ($GITDATE)"
set ylabel "Time to build in seconds, median of 3 benches"

set xtics 1
set key on inside top right
plot "gnuplot.real.data" using 2:3:4:xticlabels(1) with histogram notitle, \
  ''using 0:( \$2 + 80 ):2 with labels notitle
EOF

echo "Benches done"
echo "You can generate a graph.png with gnuplot:"
echo "pkg install gnuplot"
echo "cd $TMPDIR"
echo "gnuplot gnuplot.plt"

umount $RAMDISK
