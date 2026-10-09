#!/bin/sh
# Run every PIM topotest one at a time, hunting the reported FreeBSD panic.
#
# The point is to survive the crash: the name of the test being run is written
# to /root/pim-current and sync'd BEFORE the test starts, so after the guest
# panics and reboots that file still names the culprit. Finished tests are
# appended to /root/pim-results, and the sweep skips them on the next run, so
# rerunning this script after a panic resumes where it stopped.
cd /root/frr/tests/topotests || exit 1
: >> /root/pim-results

for d in pim_* multicast_pim*; do
	[ -d "$d" ] || continue
	case "$d" in pim_slow_convergence) continue ;; esac          # in norecursedirs
	grep -q "^$d " /root/pim-results && continue                 # already done
	echo "$d" > /root/pim-current
	sync
	start=$(date +%s)
	timeout 900 python3 -m pytest "$d" -q > "/root/log-$d.txt" 2>&1
	rc=$?
	echo "$d rc=$rc $(( $(date +%s) - start ))s" >> /root/pim-results
	sync
done
echo "SWEEP-DONE" > /root/pim-current
sync
