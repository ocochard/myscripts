#!/bin/sh
# Guest side (kern-test-vm): load the test module, run the scenarios.
# rc.local tees our stdout into /root/results.  fault_test writes to its own
# file: a child stuck in the kernel keeps that file open, not rc.local's pipe.
cd /root/test || exit 1
echo "kernel: $(uname -v | awk '{print $4}')"
kldload ./lkpi_fault.ko && echo "lkpi_fault.ko loaded" || echo "kldload FAILED"
./fault_test > /root/fault.log 2>&1
cat /root/fault.log
echo "== kernel messages"
dmesg | grep -E "lkpi_fault|panic|lock order reversal" | tail -20
sync
