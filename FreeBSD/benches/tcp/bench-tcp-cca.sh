#!/bin/sh
# Benching FreeBSD TCP stacks and congestion control algos mix
# Simple dummy measurement on loopback interface:
# No emulation of latency/drop/congestion, CCA should not impact
# Only stuff like TCP slow start
#
# To do:
# - IPv6
# - Mix of send/receive with different stack
# - CPU usage measurement

set -euo pipefail

expect_tcp="freebsd rack bbr"		# Expected TCP stack to test
avail_tcp=""				# Available TCP stacks
expect_cca="cubic htcp cdg chd dctcp vegas newreno"	# Expected CCA to test
avail_cca=""					# Available CC algos
run=3						# Number of run of each bench (3 minimum)
tmpdir=""
report=""
port=5002
time=30
true=0
false=1

if which nproc > /dev/null 2>&1; then
	cpus=$(nproc)
else
	cpus=$(sysctl -n kern.smp.cpu)
fi
# Trying to kept the server and client into same NUMA domain
# XXX cpuset seems doesn't comply to it
if [ $cpus -ge 4 ]; then
	afs=0
	afc=2
elif [ $cpus -ge 2 ]; then
	afs=0
	afc=1
else
	afs=0	# cpu server affinity
	afc=0	# cpu client affinity
fi

iperf3_server_cmd="iperf3 --server --bind 127.0.0.1 --port $port --one-off --daemon \
--format g --affinity $afs"
iperf3_client_cmd="iperf3 --client 127.0.0.1 --port $port --time $time --format g \
--affinity $afc --zerocopy"
iperf_server_cmd="cpuset -c -l $afs iperf --server --bind 127.0.0.1 --port $port --enhanced \
--daemon --format g"
iperf_client_cmd="cpuset -c -l $afc iperf --client 127.0.0.1 --port $port --enhanced --time $time \
--format g"

die() {
	echo -n "EXIT: " >&2
	echo "$@" >&2
	exit 1
}

sys_check() {
	# Rack need kernel 'options TCPHPTS' (not enabled by default)
	if ! [ -r /boot/kernel/tcphpts.ko ]; then
		sysctl kern.conftxt | grep -q TCPHPTS || die "Need High Precision Timer (TCPHPTS) kernel option"
	fi
	local avail=$(sysctl -n net.inet.tcp.functions_available)
	if ! echo $avail | grep -q rack; then
		echo $avail
		die "Need RACK stack available"
	fi
	#sysctl -n net.inet.tcp.functions_available | grep -q rack || die "Need RACK stack available"
	which -s iperf3 || die "need benchmarks/iperf3"
	which -s iperf || die "need benchmarks/iperf"
	which -s sudo || die "need sudo"
}

sys_info() {
	# Generate system info
	# Purpose: Is there some TCP custom tuning enabled ?
	# Get system.make first, revert to plan
	# planar | system | chassis
	# System Information: system
	# Base Board (or Module): planar
	# System Enclosure or Chassis: chassis
	# "                                " (all spaces)
	# "To Be Filled By O.E.M."
	# "empty"
	# for i in chassis planar system; do
	#maker=$(kenv smbios.system.maker)
	(
		echo "# System info"
		echo "## dmesg"
		echo '```'
		cat /var/run/dmesg.boot
		echo '```'
		echo "## TCP sysctl"
		echo '```'
		sysctl net.inet.tcp
		echo '```'
	) > ${tmpdir}/sysinfo.md
}

socket_listening() {
	# Check if listenning
	if sockstat -ln4 | grep -q "127.0.0.1:$port"; then
		return $true
	else
		return $false
	fi
}

# XXX Need to factorize _open and close
wait_socket_open () {
	local timeout=5
	local i=0
	while ! socket_listening; do
		sleep 1
		i=$(( i + 1))
		if [ $i -eq $timeout ]; then
			die "[ERROR] Timeout ($timeout seconds) reached while waiting to open socket"
		fi
	done
}

wait_socket_close () {
	local timeout=5
	local i=0
	while socket_listening; do
		sleep 1
		i=$(( i + 1))
		if [ $i -eq $timeout ]; then
			die "[ERROR] Timeout (%timeout seconds) reached while waiting to close socket"
		fi
	done
}

iperf_bench() {
	local t=$1	# TCP stack
	local c=$2	# CC algo
	local r=$3	# run
	# Using the same port, to fails if previous run isn't correctly stopped
	# Bind to core 0 and 2 by default to avoid Hyper threading

	if socket_listening; then
		die "[ERROR] Socket already listening before starting"
	fi

	if ! ${iperf3_server_cmd}; then
		die "[ERROR] starting iperf3 server"
	fi

	# Sometimes iperf3 need time to bind the socket
	wait_socket_open
	if ! ${iperf3_client_cmd} --logfile ${tmpdir}/log/iperf3_client.$t.$c.$r.log; then
		echo "Error starting iperf3 client, log file:"
		cat ${tmpdir}/log/iperf3_client.$t.$c.$r.log
		die "Can't continue"
	fi
	wait_socket_close

	# Iperf 2
	# Need to use sudo for cpuset
	sudo ${iperf_server_cmd}
	wait_socket_open

	sudo ${iperf_client_cmd} --output ${tmpdir}/log/iperf_client.$t.$c.$r.log
	sudo pkill iperf || die "Error killing iperf server"

	wait_socket_close
}

load_cca() {
	# Load all congestion control algorithms kernel modules
	for i in ${expect_cca}; do
		sudo kldload cc_$i > /dev/null 2>&1 || true
	done
}

bench() {
	local t=$1	# TCP stack
	local c=$2	# CCS algo
	for i in $(jot $run); do
		echo "bench $i with tcp $t and cc $c"
		iperf_bench $t $c $i
	done
}

bench_tcp() {
	for t in ${avail_tcp}; do
		sudo sysctl net.inet.tcp.functions_default=$t > /dev/null 2>&1
		bench_cca $t
	done
}

bench_cca() {
	local tcp=$1	# TCP stack
	cd $tmpdir
	for c in ${avail_cca}; do
		sudo sysctl net.inet.tcp.cc.algorithm=$c > /dev/null
		bench $tcp $c
	done
}

gen_ministat () {
	cd $tmpdir
	# XXX Should avoid re-using avail_tcp and avail_cca here and use ls
	# Extract data from iperf's log files
	for t in ${avail_tcp}; do
		for c in ${avail_cca}; do
			# no extension : contains list of results set (3 minimum)
			#                no ext, because filename diplayed by ministat
			# ministat.* contains ministat graph output
			grep receive ${tmpdir}/log/iperf3_client.$t.$c.*.log | tr -s ' ' | cut -d ' ' -f 7 > ${tmpdir}/iperf3.$t.$c
			tail -qn1 ${tmpdir}/log/iperf_client.$t.$c.*.log | tr -s ' ' | cut -d ' ' -f 7 > ${tmpdir}/iperf.$t.$c
			# Comparing iperf2 vs iperf3
			ministat -s iperf.$t.$c iperf3.$t.$c > ${tmpdir}/ministat.iperfvs.$t.$c
		done # cca
	done # tcp
	# Now that we have data, we could play with them
	for t in ${avail_tcp}; do
		# Comparing CCA between them (same TCP stack)
		ministat -s $(ls iperf3.$t.*) > ${tmpdir}/ministat.iperf3.$t
		ministat -s $(ls iperf.$t.*) > ${tmpdir}/ministat.iperf.$t
	done
	# Now we could compare TCP between them (using same CCA)
	for c in ${avail_cca}; do
		ministat -s $(ls iperf3.*.$c) >  ${tmpdir}/ministat.iperf3.$c
		ministat -s $(ls iperf.*.$c) >  ${tmpdir}/ministat.iperf.$c
	done
}

gen_report () {
	# Generate Markdown formated report
	cd $tmpdir
	(
	echo "# Impact of TCP stacks and Congestion Control Algo mix"
	echo "## Concept"
	echo "Dummy iperf2/iperf3 benches using localhost interface (client -> server), no latency neither drop emulated,"
	echo "server bind to one cpu and client to another. So should expect equivalent result."
	echo "-  TCP stacks available: $(echo ${avail_tcp} | tr ' ' ',')"
	echo "-  CC Algos available: $(echo ${avail_cca} | tr '\n' ',')"
	echo "## System info"
	echo "### FreeBSD kernel"
	echo '```'
	sysctl -n kern.version
	echo '```'
	echo "### CPU"
	echo model: $(sysctl -n hw.model)
	echo $(sysctl -n kern.smp.cores) cores, $(sysctl -n kern.smp.threads_per_core)\
	   	threads per core, $(sysctl -n kern.smp.cpus) total CPUs
	echo "### iperf versions and arguments"
	echo "#### iperf3"
	echo "Version:"
	echo '```'
	iperf3 --version
	echo '```'
	echo "Server arguments:"
	echo '```'
	echo ${iperf3_server_cmd}
	echo '```'
	echo "Client arguments:"
	echo '```'
	echo ${iperf3_client_cmd}
	echo '```'
	echo "#### iperf2"
	echo "Version:"
	echo '```'
	iperf --version
	echo '```'
	echo "Server arguments:"
	echo '```'
	echo ${iperf_server_cmd}
	echo '```'
	echo "Client arguments:"
	echo '```'
	echo ${iperf_client_cmd}
	echo '```'
	if [ -r sysinfo.md ];then
		echo "### Verbose"
		echo "[sysinfo](sysinfo.md)"
	fi
	) >> $report
	echo "## Comparing impact of Congestion Control Algorithms (same TCP stack)" >> $report
	for t in ${avail_tcp}; do
		(
		echo "### TCP stack: $t"
		echo "#### iperf3"
		echo '```'
		cat  ministat.iperf3.$t
		echo '```'
		echo "#### iperf2"
		echo '```'
		cat ministat.iperf.$t
		echo '```'
		echo "#### iperf2 vs iperf3"
		) >> $report
		for c in  ${avail_cca}; do
			(
			echo "##### CCA: $c"
			echo '```'
			cat ministat.iperfvs.$t.$c
			echo '```'
			) >> $report
		done
	done # For each TCP stack
	echo "## Comparing impact of TCP stacks (same Congestion Control Algorithms)" >> $report
	for c in ${avail_cca}; do
		(
		echo "### CCA stack: $c"
		echo "#### iperf3"
		echo '```'
		cat  ministat.iperf3.$c
		echo '```'
		echo "#### iperf2"
		echo '```'
		cat ministat.iperf.$c
		echo '```'
		) >> $report
	done # For each CCA
	# cleanup
	rm ${tmpdir}/ministat.*
	rm ${tmpdir}/iperf*
}

#### main

prev_tcp=$(sysctl -n net.inet.tcp.functions_default)
prev_cc=$(sysctl -n net.inet.tcp.cc.algorithm)

avail_tcp=$(sysctl -n net.inet.tcp.functions_available | awk 'NF>0 && NR>2 {print $1;next}')
avail_tcp=$(echo ${avail_tcp})
avail_cca=$(sysctl -n net.inet.tcp.cc.available | awk 'NF>0 && NR>2 {print $1;next}')

if [ $# -eq 1 ]; then
	echo "Directory given, generate report only"
	if ! [ -d "$1"/log ]; then
		die "$1 is not a directory"
	fi
	tmpdir=$1
	report=${tmpdir}/README.md
	rm -f $report
	gen_ministat
	gen_report
	exit 0
else
	tmpdir=$(mktemp -t tcpbench -d || die "Can't generate tmp dir")
	mkdir -p ${tmpdir}/log
	report=${tmpdir}/README.md
fi

cd ${tmpdir}

sys_check
load_cca
sys_info

# Duration estimation
nt=$(echo ${avail_tcp} | wc -w)
nt=$(echo $nt)	# remove space
nc=$(echo ${avail_cca} | wc -w)
nc=$(echo $nc)	# remove space
benches=$(( nt * nc ))
tduration=$(( (nt * nc * time * 2 ) / 60 ))
echo "Running a total of $benches runs: $nt TCP stacks * $nc CCAs * 2 (iperf3 and iperf2) * $time seconds for an estimated duration of $tduration minutes"

# Run
bench_tcp
gen_ministat
gen_report

# restore previous default TCP and CCA
sudo sysctl net.inet.tcp.functions_default=${prev_tcp} > /dev/null 2>&1
sudo sysctl net.inet.tcp.cc.algorithm=${prev_cc} > /dev/null 2>&1

echo "Done, results in $report"
