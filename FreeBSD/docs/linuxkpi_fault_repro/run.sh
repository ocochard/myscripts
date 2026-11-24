#!/bin/sh
# Guest side (kern-test-vm): load the test module, run the scenarios.
# rc.local tees our stdout into /root/results.  Test programs write to their
# own files: a process stuck in the kernel keeps that file open, not
# rc.local's pipe.
cd /root/test || exit 1
echo "kernel: $(uname -v | awk '{print $4}')"
kldload ./lkpi_fault.ko && echo "lkpi_fault.ko loaded" || echo "kldload FAILED"
./fault_test > /root/fault.log 2>&1
cat /root/fault.log

# kill -9 of a thread spinning in the populate loop (handler mode 3)
echo "== kill -9 while spinning (handler returns NOPAGE, inserts nothing)"
sysctl -q debug.lkpi_fault.mode=3
for c in st mt-worker mt-main; do
	./spin_test $c > /root/spin-$c.log 2>&1 &
	p=$!
	sleep 3
	echo "  $c: pid $p, $(ps -o nlwp= -p $p | tr -d ' ') thread(s), cpu $(ps -o %cpu= -p $p | tr -d ' ')%"
	kill -9 $p
	n=0
	while kill -0 $p 2>/dev/null && [ $n -lt 10 ]; do sleep 1; n=$((n + 1)); done
	if kill -0 $p 2>/dev/null; then
		echo "    STILL ALIVE 10 s after kill -9"
		procstat -kk $p | tail -n +2 | awk '{print "      " $2, $3, $4}' | head -3
	else
		echo "    gone ${n} s after kill -9"
	fi
done
sysctl -q debug.lkpi_fault.mode=0
echo "== kernel messages"
dmesg | grep -E "lkpi_fault|panic|lock order reversal" | tail -20
sync
