#!/bin/sh
# Bench time spend to buildworld
# Used to compare performance of AMD Epyc and ARM Ampere
# So, using a cross-compilation target of RISCV, avoiding local target optimisation

set -eu
sudo=""

# Function definitions
die() {
  echo -n "EXIT: " >&2
  echo "$@" >&2
  exit 1
}

usage() {
  echo "$0 [-h] [-v] [-m working-directory]" >&2;
  echo -e "\t-h: emit this message, then exit" >&2
  echo -e "\t-m: Use this working directory in place of ramdisk" >&2
  echo -e "\t-v: enable execution tracing" >&2
  exit $1
}

### main

ramdisk=""

while getopts "hm:v" arg; do
  case "$arg" in
  h)  usage 0 ;;
  m)  ramdisk="$OPTARG" ;;
  v)  set -x ;;
  *)  usage 1 ;;
  esac
done
shift $(( OPTIND - 1 ))

if [ $(id -u) -ne 0 ]; then
  if which -s sudo; then
    sudo="sudo -E"
  else
    die "Need to start as root because sudo not found"
  fi
fi

if which -s nproc; then
  cpus=$(nproc)
else
  # Deprecated
  cpus=$(sysctl -n kern.smp.cpus)
fi

# Initial number of jobs
# - AMD Epyc has 32c and 64t
# - Ampere MtCollins has 160 (80 x 2) cores
# To be able to compare them, we need:
# 1. to start using the same number
# 2. but not a so small number
if [ ${cpus} -ge 32 ]; then
  job=16
else
  job=4
fi

runs=3		# Number of iteration for each bench

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

physmem=""
freespace=""

if [ -z "${ramdisk}" ]; then
  echo "Using RAMdisk (tmpfs) for source and work directories"
  # ramdisk usage
  physmem=$(sysctl -n hw.physmem)
  if [ ${physmem} -lt 17105900000 ]; then
    die "Need a minimum of 16G RAM"
  fi
  ramdisk="/usr/obj/ramdisk"	# RAM disk (tmpfs) directory
  ${sudo} mkdir -p ${ramdisk}
  ${sudo} chown ${USER} ${ramdisk}
  if mount | grep -q ${ramdisk}; then
    # Previous run detection
    echo "WARNING: Detected already mounted ${ramdisk}"
    echo "Don't forget to unmount it next time!"
  else
    # Build in a tmpfs, avoid benching hard disk i/o
    # XXX How to avoid swap usage ? Should we disable it
    ${sudo} mount -t tmpfs tmpfs ${ramdisk}
  fi
  elif [ -d "${ramdisk}" ]; then
  freespace=$(df -g ${ramdisk} | awk 'END{print $4}')
  if [ ${freespace} -lt 16 ]; then
    die "Need a minimum of 16G disk space on ${ramdisk}"
  fi
fi

srcdir="${ramdisk}/src"		# FreeBSD source directory
tmpdir=/tmp/buildbench.$(date -u '+%Y%m%d%H%M')
mkdir -p ${tmpdir}

# --depth 1 should imply --single-branch by default
# Consume about 1.2G of space
if ! [ -d ${srcdir} ]; then
  mkdir -p ${srcdir}
  git clone --depth 1 --branch main --single-branch https://git.freebsd.org/src.git ${srcdir}
else
  echo "WARNING: Already source directory"
fi

cd ${srcdir}
gitrev=$(git rev-parse --short HEAD)
gitdate=$(git log -1 --format=%ai)

# Init gnuplot data file
for i in real user sys; do
  echo "#index median minimum maximum" > ${tmpdir}/gnuplot.$i.data
done

while [ ${job} -le $((cpus * 2)) ]; do
  for j in $(seq ${runs}); do
    echo "Jobs: ${job}, run: $j/${runs}"
    # Forcing GENERIC kernel, no custom MAKE_CONF/SRCCONF/SRC_ENV_CONF
    echo "Cleanup..."
    env __MAKE_CONF=/dev/null SRC_ENV_CONF=/dev/null MAKEOBJDIRPREFIX=${ramdisk} TARGET_ARCH=riscv64 \
      make SRCCONF=/dev/null clean > /dev/null 2>&1
    echo "Build..."
    # Write log into ram disk to avoid benching local disk speed
    if ! env __MAKE_CONF=/dev/null SRC_ENV_CONF=/dev/null MAKEOBJDIRPREFIX=${ramdisk} TARGET_ARCH=riscv64 \
        time -ao ${tmpdir}/buildbench.${job}.time make -j ${job} \
        SRCCONF=/dev/null buildworld > ${ramdisk}/buildbench.${job}.$j.log; then
      echo "ERROR, last log line:"
      tail -n 100 ${ramdisk}/buildbench.${job}.$j.log
      exit 1
    fi
  done # for j

  # Stats extractions to be ready to use by ministat
  # time output example:
  #         0.00 real         0.00 user         0.00 sys
  # real is 2, user is 4 and sys is 6
  timepos=2

  for t in real user sys; do
    cut -w -f $timepos ${tmpdir}/buildbench.${job}.time > ${tmpdir}/buildbench.${job}.$t
    timepos=$((timepos + 2))

    ministat -qn ${tmpdir}/buildbench.${job}.$t > ${tmpdir}/buildbench.${job}.$t.ministat
    # ministat output example:
    #    N           Min           Max        Median           Avg        Stddev
    #x   3       4230.49       4243.08        4231.5     4235.0233     6.9955295
    # Min is 3, Max is 4, Median is 5
    min=$(cut -w -f 3 ${tmpdir}/buildbench.${job}.$t.ministat)
    max=$(cut -w -f 4 ${tmpdir}/buildbench.${job}.$t.ministat)
    med=$(cut -w -f 5 ${tmpdir}/buildbench.${job}.$t.ministat)
    echo "${job} $med $min $max" >> ${tmpdir}/gnuplot.$t.data
  done # for t

  # multiply job per 2
  job=$(( job * 2 ))
done # while $job

# Gnuplot example file

machine=$(uname -m)
version=$(uname -r)
versionU=$(uname -U)
model=$(sysctl -n hw.model)
# Number of physical cores online
cores=$(sysctl -n kern.smp.cores)
# Number of SMT threads online per core
tpc=$(sysctl -n kern.smp.threads_per_core)
# Number of CPUs online
cpus=$(sysctl -n kern.smp.cpus)
ram=$(sysctl -n hw.physmem)
ram=$((ram / 1024 / 1024 / 1024))	# convert byte into GB
if [ -n "${physmem}" ]; then
  mediatype="tmpfs"
else
  mediatype="${ramdisk}"
fi

cat > ${tmpdir}/gnuplot.plt <<EOF
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

set title noenhanced "Job numbers' impact on 'make TARGET_ARCH=riscv64 buildworld' execution time\n${model} (cores: ${cores}, thread per core: ${tpc}, Total CPUs: ${cpus}) with ${ram} GB RAM\n src and obj on ${mediatype}"
set xlabel font "Gill Sans,16"
set xlabel noenhanced "FreeBSD/${machine} ${version} (${versionU}) building main sources cloned at ${gitrev} (${gitdate})"
set ylabel "Time to build in seconds, median of 3 benches"

set xtics 1
set key on inside top right
plot "gnuplot.real.data" using 2:3:4:xticlabels(1) with histogram notitle, \
  ''using 0:( \$2 + 80 ):2 with labels notitle
EOF

echo "Benches done"
echo "You can generate a graph.png with gnuplot:"
echo "pkg install gnuplot"
echo "cd ${tmpdir}"
echo "gnuplot gnuplot.plt"

sleep 5
if [ -n "${physmem}" ]; then
  # physmem set only for tmpfs usage
  if ! ${sudo} umount ${ramdisk}; then
    echo "ERROR: Failed to umount ${ramdisk}, processes using it:"
    fstat ${ramdisk}
  fi
else
  echo "Workdir ${ramdisk} could be deleted now"
fi
