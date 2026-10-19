#!/bin/sh
# Run the EFS-reset reproducer for DURATION seconds; results in /root/run-<kernel>.
DURATION=${1:-200}
K=$(sysctl -n kern.bootfile | cut -d/ -f3)
OUT=/root/run-$K; rm -rf $OUT; mkdir -p $OUT
kldstat -q -m dtrace || kldload dtraceall
dtrace -q -x switchrate=10hz -o $OUT/trace.log -s /root/nfsrecov.d &
DT=$!
python3 /root/efs-reset-proxy.py --start 20 --period 120 --gap 15 > $OUT/proxy.log 2>&1 &
PX=$!
sleep 2
mount_nfs -o nfsv4,minorversion=1,hard,timeo=600,retrans=2,oneopenown,port=2050 127.0.0.1:/ /mnt/t
vmstat -m | grep "NFSCL session" > $OUT/sessions.txt
end=$(( $(date +%s) + DURATION ))
while [ $(date +%s) -lt $end ]; do
	t0=$(date +%s)
	timeout 150 cat /mnt/t/WORKING > /dev/null || echo "$(date +%T) probe FAIL" >> $OUT/probe.log
	dt=$(( $(date +%s) - t0 ))
	[ $dt -ge 2 ] && echo "$(date +%T) probe stalled ${dt}s" >> $OUT/probe.log
	sleep 1
done
vmstat -m | grep "NFSCL session" >> $OUT/sessions.txt
nfsstat -c -E | grep -A1 ExchangeId > $OUT/nfsstat.txt
umount /mnt/t; kill $PX $DT; wait 2>/dev/null
echo "done: $OUT"
