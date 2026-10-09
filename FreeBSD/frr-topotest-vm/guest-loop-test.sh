#!/bin/sh
# Loop one topotest until the kernel dies, recording the iteration so the
# count survives the panic. Default: the test that was in flight when the
# fib_algo callout use-after-free fired.
TEST=${1:-multicast_pim_dr_nondr_test}
MAX=${2:-30}
cd /root/frr/tests/topotests || exit 1
i=1
while [ "$i" -le "$MAX" ]; do
	echo "$TEST iteration $i started $(date '+%H:%M:%S')" > /root/loop-iter
	sync
	timeout 1800 python3 -m pytest "$TEST" -q > "/root/log-loop.txt" 2>&1
	echo "$TEST iteration $i rc=$? done $(date '+%H:%M:%S')" >> /root/loop-history
	sync
	i=$((i + 1))
done
echo "LOOP-DONE after $MAX iterations" > /root/loop-iter
sync
