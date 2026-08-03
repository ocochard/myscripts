#!/bin/sh
# watch-wedge.sh — poll for the NFSv4.1 permanent wedge on an EFS mount.
#
# Run ON the instance, or via ssh in a loop from a workstation. Emits a line
# only on state change. Distinguishes:
#   - transient BADSESSION (recovers in ~1s, counters advance, still readable)
#   - PERMANENT wedge (Badsession looping steady-state, counters frozen, /efs unreadable)
#
# Healthy steady state: EI/CS advancing slowly, badsession_loops=0, efs_readable=Y.
# Permanent wedge:      EI/CS frozen, badsession_loops climbing fast, efs_readable=N.
#
# Usage: sh watch-wedge.sh [mountpoint]   (Ctrl-C to stop)

MP="${1:-/efs}"
prev=""
while true; do
	loops=$(sudo grep -c "Badsession looping" /tmp/nfsdbg.log 2>/dev/null || echo 0)
	recov=$(sudo grep -c "Initiate recovery" /tmp/nfsdbg.log 2>/dev/null || echo 0)
	# bounded read so this poller itself never wedges permanently
	rd=$(timeout 6 sudo ls "$MP" >/dev/null 2>&1 && echo Y || echo N)
	cnt=$(nfsstat -c -E 2>/dev/null | grep -A1 ExchangeId | tail -1 | awk '{print $1"/"$2}')
	out="EI/CS=$cnt recoveries=$recov badsession_loops=$loops efs_readable=$rd"
	if [ "$out" != "$prev" ]; then
		printf '%s  %s\n' "$(date -u +%H:%M:%S)" "$out"
		prev="$out"
	fi
	sleep 3
done
