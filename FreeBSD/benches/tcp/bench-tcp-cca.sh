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
		echo "## OS version"
		echo '```'
		uname -a
		echo '```'
		echo "## dmesg"
		echo '```'
		cat /var/run/dmesg.boot
		echo '```'
		echo "## TCP sysctl"
		echo '```'
		sysctl net.inet.tcp
		echo '```'
	) > ${tmpdir}/sysinfo.md
	(
		echo "## System info"
		echo "[sysinfo](sysinfo.md)"
	) >> $report
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

	if ! iperf3 --server --bind 127.0.0.1 --port $port --one-off --daemon \
		--format g --affinity $afs; then
		die "[ERROR] starting iperf3 server"
	fi

	# Sometimes iperf3 need time to bind the socket
	wait_socket_open
	if ! iperf3 --client 127.0.0.1 --port $port --time $time --format g \
		--affinity $afc --zerocopy --logfile ${tmpdir}/log/iperf3_client.$t.$c.$r.log; then
		echo "Error starting iperf3 client, log file:"
		cat ${tmpdir}/log/iperf3_client.$t.$c.$r.log
		echo "And for debug purpose, the server log file:"
		cat ${tmpdir}/log/iperf3_server.$t.$c.$r.log
		die "Can't continue"
	fi
	if [ -r ${tmpdir}/iperf3_server.pid ]; then
		echo "Warning, client ended but iperf3 server is still running"
		kill $(cat ${tmpdir}/iperf3_server.pid)
	fi
	wait_socket_close

	# Iperf 2
	sudo cpuset -c -l $afs iperf --server --bind 127.0.0.1 --port $port --enhanced \
		--daemon --format g
	wait_socket_open

	sudo cpuset -c -l $afc iperf --client 127.0.0.1 --port $port --enhanced --time $time \
		--format g --output ${tmpdir}/log/iperf_client.$t.$c.$r.log
	sudo pkill iperf || die "Error killing iperf server"

	wait_socket_close

}

load_cca() {
	# Load all congestion control algorithms kernel modules
	for i in ${expect_cca}; do
		sudo kldload cc_$i || true
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
	if [ $(echo "${avail_tcp}" | wc -w) -gt 1 ]; then
		echo "## Comparing impact of TCP stacks (same Congestion Control Algorithm)" >> $report
		cd $tmpdir
		for c in ${avail_cca}; do
			iperf3_ministat_args=""
			iperf_ministat_args=""
			for t in ${avail_tcp}; do
				# Prevent to display full dir in ministat report (so ministat need
				# to start from $tmpdir)
				iperf3_ministat_args="${iperf3_ministat_args} iperf3.$t.$c"
				iperf_ministat_args="${iperf_ministat_args} iperf.$t.$c"
			done
			echo '```' >> ${tmpdir}/iperf3.$c.md
			ministat -s ${iperf3_ministat_args} >> ${tmpdir}/iperf3.$c.md
			echo '```' >> ${tmpdir}/iperf3.$c.md
			echo '```' >> ${tmpdir}/iperf.$c.md
			ministat -s ${iperf_ministat_args} >> ${tmpdir}/iperf.$c.md
			echo '```' >> ${tmpdir}/iperf.$c.md
			(
			echo "- CCA: $c, Congestion Control Algos impact:"
			echo "  - [iperf 3](iperf3.$c.md)"
			echo "  - [iperf 2](iperf.$c.md)"
			) >> $report
		done
	fi
	echo "## Comparing iperf 2 vs 3 (same TCP and CCA)" >> $report
	for tcp; do
		echo
	done
}

bench_cca() {
	local tcp=$1	# TCP stack
	iperf3_ministat_args=""
	iperf_ministat_args=""
	cd $tmpdir
	for c in ${avail_cca}; do
		sudo sysctl net.inet.tcp.cc.algorithm=$c > /dev/null
		bench $tcp $c
		# iperf3
		grep receive ${tmpdir}/log/iperf3_client.$tcp.$c.*.log | tr -s ' ' | cut -d ' ' -f 7 >> ${tmpdir}/iperf3.$tcp.$c
		iperf3_ministat_args="${iperf3_ministat_args} iperf3.$tcp.$c"
		echo '```' >> ${tmpdir}/iperf3.$tcp.$c.md
		ministat -n iperf3.$tcp.$c >> ${tmpdir}/iperf3.$tcp.$c.md
		echo '```' >> ${tmpdir}/iperf3.$tcp.$c.md
		# iperf
		tail -qn1 ${tmpdir}/log/iperf_client.$tcp.$c.*.log | tr -s ' ' | cut -d ' ' -f 7 >> ${tmpdir}/iperf.$tcp.$c
		iperf_ministat_args="${iperf_ministat_args} ${tmpdir}/iperf.$tcp.$c"
		echo '```' >> ${tmpdir}/iperf.$tcp.$c.md
		ministat -n iperf.$tcp.$c >> ${tmpdir}/iperf.$tcp.$c.md
		echo '```' >> ${tmpdir}/iperf.$tcp.$c.md
		# iperf2 vs iperf3
		echo '```' >> ${tmpdir}/iperfvs.$tcp.$c.md
		ministat -s iperf.$tcp.$c iperf3.$tcp.$c > ${tmpdir}/iperfvs.$tcp.$c.md
		echo '```' >> ${tmpdir}/iperfvs.$tcp.$c.md
	done
	# compare CCAs for each TCP stack
	echo "## Comparing impact of Congestion Control Algorithms (same TCP stack)" >> $report
	echo '```' >> ${tmpdir}/iperf3.$tcp.md
	ministat -s ${iperf3_ministat_args} >> ${tmpdir}/iperf3.$tcp.md
	echo '```' >> ${tmpdir}/iperf3.$tcp.md
	echo '```' >> ${tmpdir}/iperf.$tcp.md
	ministat -s ${iperf_ministat_args} >> ${tmpdir}/iperf.$tcp.ministat
	echo '```' >> ${tmpdir}/iperf.$tcp.md
	(
		echo "- TCP stack: $tcp, Congestion Control Algos impact:"
		echo "  - [iperf 3](iperf3.$tcp.md)"
		echo "  - [iperf 2](iperf.$tcp.md)"
		echo "  - [iperf 2 vs iperf 3](iperfvs.$tcp.$c.md)"
	) >> $report
}

#### main
prev_tcp=$(sysctl -n net.inet.tcp.functions_default)
prev_cc=$(sysctl -n net.inet.tcp.cc.algorithm)
sys_check
load_cca
tmpdir=$(mktemp -t tcpbench -d || die "Can't generate tmp dir")
mkdir -p ${tmpdir}/log
report=${tmpdir}/README.md
cd ${tmpdir}
(
	echo "# Impact of TCP stacks and Congestion Control Algo mix"
	echo "## Concept"
	echo "Dummy iperf2/iperf3 benches using localhost interface, no latency/drop emulated, so should get equivalent result"
) >> $report
sys_info

avail_tcp=$(sysctl -n net.inet.tcp.functions_available | awk 'NF>0 && NR>2 {print $1;next}')
# Need to remove rack and bbr from this list, they are instable on head
avail_tcp=$(echo ${avail_tcp} | sed 's/rack//g;s/bbr//g')
avail_cca=$(sysctl -n net.inet.tcp.cc.available | awk 'NF>0 && NR>2 {print $1;next}')
echo "TCP stacks available: ${avail_tcp}" >> $report
echo "CC Algos available: ${avail_cca}" >> $report

# Duration estimation
nt=$(echo ${avail_tcp} | wc -w)
nt=$(echo $nt)	# remove space
nc=$(echo ${avail_cca} | wc -w)
nc=$(echo $nc)	# remove space
benches=$(( nt * nc ))
tduration=$(( (nt * nc * time * 2 ) / 60 ))
msg="Running a total of $benches runs: $nt TCP stacks * $nc CCAs * 2 (iperf3 and iperf2) * $time seconds for an estimated duration of $tduration minutes"
echo "$msg" | tee -a $report

# Run
bench_tcp
echo "Done, results in $report"

# restore previous default TCP and CCA
sudo sysctl net.inet.tcp.functions_default=${prev_tcp} > /dev/null 2>&1
sudo sysctl net.inet.tcp.cc.algorithm=${prev_cc} > /dev/null 2>&1
