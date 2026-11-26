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

# Kernels with a bounded retry: a short deadline keeps the waits below short.
bounded=0
if sysctl -q compat.linuxkpi.fault_retry_timeout > /dev/null 2>&1; then
	bounded=1
	echo "fault_retry_timeout default: $(sysctl -n compat.linuxkpi.fault_retry_timeout) s"
	sysctl -q compat.linuxkpi.fault_retry_timeout=5
fi

# kill -9 of a thread retrying in the populate loop (handler mode 3)
echo "== kill -9 while retrying (handler returns NOPAGE, inserts nothing)"
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

if [ $bounded = 1 ]; then
	echo "== bounded retry (fault_retry_timeout=5)"
	# Never served: the fault must fail after the deadline.
	s=$(date +%s)
	./spin_test st > /root/b1.log 2>&1 &
	p=$!
	sleep 2
	cpu=$(ps -o %cpu= -p $p | tr -d ' ')
	wait $p; rc=$?
	echo "  never served: exit status $rc ($( [ $rc -gt 128 ] && kill -l $((rc - 128)) )) after $(( $(date +%s) - s )) s, cpu while waiting ${cpu}%"
	# Short-lived refusal: 50 NOPAGE answers, then the page.
	sysctl -q debug.lkpi_fault.mode=4 debug.lkpi_fault.refusals=50
	s=$(date +%s)
	./spin_test st > /root/b2.log 2>&1; rc=$?
	echo "  50 refusals then insert: exit status $rc after $(( $(date +%s) - s )) s: $(cat /root/b2.log)"
	# Deadline 0: fail at once.
	sysctl -q compat.linuxkpi.fault_retry_timeout=0 debug.lkpi_fault.refusals=1
	./spin_test st > /root/b3.log 2>&1; rc=$?
	echo "  timeout 0, 1 refusal: exit status $rc ($( [ $rc -gt 128 ] && kill -l $((rc - 128)) ))"
	sysctl -q compat.linuxkpi.fault_retry_timeout=5
fi
sysctl -q debug.lkpi_fault.mode=0
echo "== kernel messages"
dmesg | grep -E "lkpi_fault|linuxkpi:|panic|lock order reversal" | tail -20
sync
