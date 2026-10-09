#!/bin/sh
# Run the WHOLE topotest suite, one directory at a time, crash-resumable.
#
# One directory per pytest invocation rather than one big run: a kernel panic
# or a wedged ifnet operation then costs one directory, not the whole sweep,
# and /root/sweep-current names the directory it happened in (written and
# sync'd BEFORE the run starts, so it survives a panic).
#
# Finished directories land in /root/sweep-results and are skipped when the
# script is re-run, so after a crash just start it again.
#
#   sh /mnt/host/guest-sweep.sh [timeout-seconds] [glob]
set -u

TMO=${1:-1200}
GLOB=${2:-}
cd /root/frr/tests/topotests || exit 1
: >> /root/sweep-results

for d in ${GLOB:-*}; do
	[ -d "$d" ] || continue
	# pytest.ini norecursedirs, plus dirs with no tests.
	case "$d" in
	.git|example_munet|example_test|example_topojson_test|lib|munet|docker|high_ecmp|pim_slow_convergence)
		continue ;;
	esac
	ls "$d"/test_*.py >/dev/null 2>&1 || continue
	grep -q "^$d " /root/sweep-results && continue

	echo "$d started $(date '+%F %H:%M:%S')" > /root/sweep-current
	sync
	start=$(date +%s)

	# No timeout(1), and no setsid(1) either.
	#
	# timeout(1) on FreeBSD becomes the process reaper for what it starts,
	# so a helper the test leaves behind -- bgp_bmp leaves
	# lib/bmp_collector/bmpserver.py alive in its jail -- gets reparented
	# onto timeout, which then waits on it forever (observed: stuck 2h25m
	# against a 20 minute cap). And setsid(1) does not exist in the FreeBSD
	# base system, so reaching for it silently turned every run into
	# "setsid: not found", rc=127 in 5 seconds.
	#
	# Plain background + an explicit deadline: orphans go to init rather
	# than to this script, and `wait` returns as soon as pytest itself is
	# gone. The cleanup below deals with whatever it left running.
	python3 -m pytest "$d" -q > "/root/logs/$d.log" 2>&1 &
	pid=$!
	rc=0
	waited=0
	while kill -0 "$pid" 2>/dev/null; do
		if [ "$waited" -ge "$TMO" ]; then
			kill -TERM "$pid" 2>/dev/null
			sleep 5
			kill -KILL "$pid" 2>/dev/null
			rc=124
			break
		fi
		sleep 5
		waited=$((waited + 5))
	done
	if [ "$rc" = 0 ]; then
		wait "$pid"
		rc=$?
	else
		wait "$pid" 2>/dev/null
	fi

	echo "$d rc=$rc $(( $(date +%s) - start ))s" >> /root/sweep-results
	sync

	# Helpers and jails a killed or crashed test leaves behind, which would
	# otherwise fail the next directory for the wrong reason.
	pkill -f bmp_collector/bmpserver.py 2>/dev/null
	pkill -f exabgp 2>/dev/null
	pkill -f mcast-tester.py 2>/dev/null
	for j in $(jls -N name 2>/dev/null | tail -n +2); do
		jail -r "$j" 2>/dev/null
	done

	# A kernel-stuck interface operation cannot be killed by timeout(1) and
	# holds the ifnet lock, so every later directory would fail for the
	# wrong reason. Stop and say so instead of producing garbage.
	if pgrep -f "ifconfig .* vnet " >/dev/null 2>&1; then
		echo "WEDGED after $d: ifconfig vnet stuck in the kernel" \
		    > /root/sweep-current
		sync
		exit 2
	fi
done

echo "SWEEP-DONE $(date '+%F %H:%M:%S')" > /root/sweep-current
sync
