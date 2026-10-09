#!/bin/sh
# Wait for the epair-vnet wedge, then collect DDB state from the LIVE system.
#
# Why DDB and not a dump: a dump taken with debug.kdb.panic=1 prints the panic
# out the serial console, so "what each CPU was running" is polluted by uart
# interrupt work -- that artifact sent the first analysis down a dead end. DDB
# entered with debug.kdb.enter=1 prints no panic and stops the machine where it
# stands.
#
# Wedge signature: a process matching PAT older than WEDGE_AGE seconds. Plain
# state RJ is NOT the signature -- that is just "running, jailed", which
# healthy jailed processes show.
#
#   sudo ./ddb-on-wedge.sh [poll-seconds] [wedge-age-seconds]
#   sudo WEDGEFILE=/root/HAMMER-WEDGED PAT='[h]ammer-epoch-drain' \
#       ./ddb-on-wedge.sh 15             # alongside hammer-run.sh
#
# Before stopping the guest it also snapshots every vCPU from the host side
# (bhyvectl: RIP, RFLAGS, pending event, exit and IPI counters), twice, 5s
# apart: whether the bound CPU's vCPU is halted, and whether it is still
# taking IPIs, is visible there without the guest's cooperation.
#
# DUMP=1 then takes a dump from DDB and resets, so savecore collects it on the
# next boot: this DDB has no `show runq`, and the bound CPU's struct tdq can
# only be read with kgdb. Needs room in the guest's /var/crash.
set -u

POLL=${1:-60}
WEDGE_AGE=${2:-120}
# Process whose age is the wedge signature; a bare ERE for awk, self-excluding.
PAT=${PAT:-[i]fconfig .* vnet }
# Alternative signature: a file the guest creates when it detects the wedge
# itself (hammer-run.sh does). When set, PAT is only used for context.
WEDGEFILE=${WEDGEFILE:-}
VM=${VM:-frrtopo}
GUEST=${GUEST:-192.168.100.78}
KEY=${KEY:-/home/olivier/.ssh/id_ed25519_frrvm}
CON=/dev/nmdm-$VM-B
LOG=${LOG:-/zroot/vm/$VM-console.log}
OUT=${OUT:-/zroot/vm/share/ddb-wedge-$(date +%Y%m%d-%H%M%S).txt}
DUMP=${DUMP:-0}
SSH="ssh -i $KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5"

[ "$(id -u)" -eq 0 ] || { echo "$0: must be root (console + sysctl)" >&2; exit 1; }

if [ -n "$WEDGEFILE" ]; then
	# hammer-run.sh writes this file when a heartbeat stops advancing. Age
	# of the process is useless there: every hammer worker is old by then,
	# only one of them has stopped making progress.
	echo "==> waiting for $WEDGEFILE in the guest"
	while :; do
		$SSH "root@$GUEST" "test -f $WEDGEFILE" 2>/dev/null && break
		sleep "$POLL"
	done
	PID=$($SSH "root@$GUEST" "awk '/^pid /{print \$2; exit}' $WEDGEFILE" 2>/dev/null)
else
	echo "==> waiting for a wedge ($PAT older than ${WEDGE_AGE}s)"
	while :; do
		stuck=$($SSH "root@$GUEST" "ps -ax -o etimes,command 2>/dev/null | awk '/$PAT/ { if (\$1+0 >= $WEDGE_AGE) c++ } END { print c+0 }'" 2>/dev/null)
		[ "${stuck:-0}" -ge 1 ] && break
		sleep "$POLL"
	done
	PID=$($SSH "root@$GUEST" "ps -ax -o etimes,pid,command | awk '/$PAT/ {print \$1, \$2}' | sort -rn | head -1 | cut -d' ' -f2" 2>/dev/null)
fi

echo "==> wedged. pid ${PID:-unknown}. collecting before stopping the machine"
{
	echo "=== wedge detected $(date) ==="
	[ -n "$WEDGEFILE" ] && $SSH "root@$GUEST" "cat $WEDGEFILE" 2>/dev/null
	$SSH "root@$GUEST" "ps -ax -o pid,state,etimes,command | grep '$PAT' | head -40" 2>/dev/null
	echo "=== procstat of pid ${PID:-unknown} ==="
	[ -n "$PID" ] && $SSH "root@$GUEST" "procstat -kk $PID; procstat -t $PID" 2>/dev/null
	echo "=== every thread in epoch_drain_callbacks ==="
	$SSH "root@$GUEST" "procstat -akk | grep -E 'epoch_drain|if_detach|sx_xlock' | head -40" 2>/dev/null
} > "$OUT" 2>&1

vcpu_snapshot() {
	echo "=== vCPU snapshot $(date +%T) ==="
	for c in $(bhyvectl --vm="$VM" --get-active-cpus 2>/dev/null |
	    grep -oE '[0-9]+(-[0-9]+)?' | awk -F- '{for (i=$1; i<=($2==""?$1:$2); i++) print i}'); do
		echo "--- vcpu $c"
		bhyvectl --vm="$VM" --cpu="$c" --get-rip --get-rflags --get-intinfo 2>&1
		bhyvectl --vm="$VM" --cpu="$c" --get-stats 2>&1 |
		    grep -E 'hlt was intercepted|ipis (sent|received)|external interrupt|vcpu total runtime|number of NMI|vm exits$|total number of vm exits'
	done
}
{ vcpu_snapshot; sleep 5; vcpu_snapshot; } >> "$OUT" 2>&1

# The thread id DDB needs. procstat -t prints TID in column 2.
TID=$([ -n "$PID" ] && $SSH "root@$GUEST" "procstat -t $PID | awk 'NR==2 {print \$2}'" 2>/dev/null)
echo "==> stuck tid: ${TID:-unknown}"
echo "=== stuck tid: ${TID:-unknown} ===" >> "$OUT"

MARK=$(wc -c < "$LOG" | tr -d ' ')

echo "==> entering DDB (no panic message, machine stops where it stands)"
$SSH "root@$GUEST" 'nohup sysctl debug.kdb.enter=1 >/dev/null 2>&1 &' >/dev/null 2>&1
sleep 8

# Drive DDB over the console. The B side is already raw/-echo (runvm.sh).
send() {
	printf '%s\r' "$1" > "$CON"
	sleep "${2:-4}"
}

send ""
# Without this the DDB pager stops every long output with --More-- and eats
# the next commands as pager input. It cost a whole capture here.
send "set \$lines 0" 3
send "show all pcpu" 12
send "ps" 15
[ -n "$TID" ] && { send "show thread $TID" 6; send "bt $TID" 8; send "show lockchain $TID" 6; }
# The thread that holds the lock is the one inside the drain; name it too.
send "show alllocks" 8
send "show sleepq" 6
send "show all chains" 8

echo "==> DDB output appended to $OUT"
tail -c +"$MARK" "$LOG" | tr -d '\r' >> "$OUT"

if [ "$DUMP" = 1 ]; then
	echo "==> dumping from DDB, then reset (savecore runs on the next boot)"
	DMARK=$(wc -c < "$LOG" | tr -d ' ')
	send "dump" 5
	i=0
	while [ "$i" -lt 180 ] && ! tail -c +"$DMARK" "$LOG" |
	    grep -qE 'Dump complete|Dump failed|dump failed|Insufficient space'; do
		sleep 10
		i=$((i + 1))
	done
	tail -c +"$DMARK" "$LOG" | tr -d '\r' >> "$OUT"
	send "reset" 2
	echo "==> done. guest reset; vmcore will be in /var/crash after boot."
	exit 0
fi
# Leave it stopped: resuming hides the state and the box is wedged anyway.
echo "==> done. guest is STOPPED IN DDB."
echo "    continue:  printf 'c\\r' > $CON"
echo "    dump too:  printf 'panic\\r' > $CON   (then savecore on next boot)"
echo "    give up:   sudo bhyvectl --force-reset --vm=$VM"
