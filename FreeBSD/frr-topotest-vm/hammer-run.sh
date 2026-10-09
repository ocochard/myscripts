#!/bin/sh
# Run one of the two wedge probes under load and stop the moment it stalls.
#
# A wedge is "no worker advanced for STALL seconds", measured across all of
# them: the bug stops every interface operation at once, while a single worker
# starving on ifnet_detach_sx under contention is normal and does not count.
#
#   drain  (default) hammer-epoch-drain: clone+destroy an interface, which is
#          if_detach_internal() -> NET_EPOCH_DRAIN_CALLBACKS(), the exact path
#          `ifconfig <epair> vnet <jid>` wedges in, minus jails and epairs.
#          ~500 cycles/s against a few per second in a topotest run.
#          A wedge here stalls every interface operation on the machine.
#   bind   hammer-sched-bind: only sched_bind(9), via cpuctl(4) ioctls, with
#          no epoch and no network stack. ~500k binds/s. A wedge here stalls
#          one process and leaves the machine usable -- the cheap way to test
#          whether the scheduler alone is enough to explain the hang.
#   vnet   hammer-vnet-move: the reported operation itself -- VNET jail,
#          epair, SIOCSIFVNET (if_vmove_loan()), jail_remove. Slowest of the
#          three and the only one that leaves vnet0; use -t 180.
#
# Every probe writes a heartbeat before the syscall under test, so a stall is
# detected by AGE of the last attempt, never by process state.
#
# -c adds hammer-epoch-churn workers: other code queueing net-epoch callbacks
# while the drains run, as zebra, pimd, bridges and tcpdump do in a topotest.
# The spec is a comma list of mode:count, "@j" running that mode inside VNET
# jails, e.g. -c ifa:2,mcast:2,route:2,bpf:2,bridge:2,ifa@j:2,route@j:2.
# Churn workers never take ifnet_detach_sx, so they are NOT counted towards a
# stall: their progress would mask a wedge. The minute report shows the
# epoch callback rate (kern.epoch.stats.epoch_calls), which is what -c is for.
#
#   sudo ./hammer-run.sh [-m drain|bind|vnet] [-w workers] [-l hogs]
#                        [-t stall-seconds] [-d duration] [-i ifkind]
#                        [-c churn-spec]
#
# Run it in the VM. On a workstation a drain wedge costs a hard reset.
set -u

MODE=drain
WORKERS=0			# 0: hw.ncpu
HOGS=-1				# -1: hw.ncpu, to oversubscribe like the report
STALL=60
DURATION=0			# 0: until wedged or interrupted
WEDGEFILE=${WEDGEFILE:-/root/HAMMER-WEDGED}
IFKIND=lo
CHURN=
DIR=$(dirname "$0")

while getopts c:d:i:l:m:t:w: o; do
	case $o in
	c) CHURN=$OPTARG ;;
	d) DURATION=$OPTARG ;;
	i) IFKIND=$OPTARG ;;
	l) HOGS=$OPTARG ;;
	m) MODE=$OPTARG ;;
	t) STALL=$OPTARG ;;
	w) WORKERS=$OPTARG ;;
	*) echo "see the comment at the top of $0" >&2; exit 2 ;;
	esac
done

[ "$(id -u)" -eq 0 ] || { echo "$0: must be root" >&2; exit 1; }
NCPU=$(sysctl -n hw.ncpu)
[ "$WORKERS" -gt 0 ] 2>/dev/null || WORKERS=$NCPU
[ "$HOGS" -ge 0 ] 2>/dev/null || HOGS=$NCPU

LIBS=
case $MODE in
drain)	SRC=hammer-epoch-drain; ARGS="-i $IFKIND" ;;
bind)	SRC=hammer-sched-bind;  ARGS="-r"
	kldstat -m cpuctl >/dev/null 2>&1 || kldload cpuctl || exit 1 ;;
vnet)	SRC=hammer-vnet-move;   ARGS=""; LIBS=-ljail
	# Slower than the others: a jail and a vnet are built and torn down
	# per iteration. Give it -t 180 or it will trip on contention.
	[ "$(sysctl -n kern.features.vimage 2>/dev/null)" = 1 ] ||
	    { echo "$0: kernel has no VIMAGE" >&2; exit 1; } ;;
*)	echo "$0: unknown mode $MODE" >&2; exit 2 ;;
esac

build() {
	if [ ! -x "$DIR/$1" ] || [ "$DIR/$1.c" -nt "$DIR/$1" ]; then
		cc -O2 -Wall -o "$DIR/$1" "$DIR/$1.c" $2 || exit 1
	fi
}
BIN=$DIR/$SRC
build "$SRC" "$LIBS"
if [ -n "$CHURN" ]; then
	build hammer-epoch-churn -ljail
	case $CHURN in
	*bridge*) kldstat -m if_bridge >/dev/null 2>&1 ||
	    kldload if_bridge || exit 1 ;;
	esac
fi

HB=$(mktemp -d "${TMPDIR:-/tmp}/hammer.XXXXXX") || exit 1
rm -f "$WEDGEFILE"
WPIDS=
HPIDS=
CPIDS=

cleanup() {
	# A wedged worker ignores signals: it is stuck in the kernel. That is
	# the point -- leave it for procstat(1) and ddb-on-wedge.sh.
	kill $HPIDS $WPIDS $CPIDS 2>/dev/null
	rm -rf "$HB"
}
trap 'cleanup; exit 130' INT TERM

i=0
while [ "$i" -lt "$WORKERS" ]; do
	"$BIN" $ARGS -f "$HB/hb.$i" &
	WPIDS="$WPIDS $!"
	i=$((i + 1))
done
# Churn workers: k makes each one's addresses unique within a vnet.
k=0
for item in $(echo "$CHURN" | tr , ' '); do
	m=${item%%:*}
	n=${item#*:}
	[ "$n" = "$item" ] && n=1
	J=
	case $m in *@j) J=-j; m=${m%@j} ;; esac
	i=0
	while [ "$i" -lt "$n" ]; do
		"$DIR/hammer-epoch-churn" -m "$m" -k "$k" $J -f "$HB/churn.$k" &
		CPIDS="$CPIDS $!"
		i=$((i + 1))
		k=$((k + 1))
	done
done
i=0
while [ "$i" -lt "$HOGS" ]; do
	( while :; do :; done ) & HPIDS="$HPIDS $!"
	i=$((i + 1))
done

echo "==> mode=$MODE workers=$WORKERS hogs=$HOGS ncpu=$NCPU stall=${STALL}s"
[ -n "$CHURN" ] && echo "==> churn=$CHURN ($(echo $CPIDS | wc -w | tr -d ' ') workers)"
echo "==> heartbeats in $HB"

START=$(date +%s)
LASTREPORT=$START
LASTTOTAL=-1
LASTMOVED=$START
LASTCALLS=$(sysctl -n kern.epoch.stats.epoch_calls)
while :; do
	sleep 5
	NOW=$(date +%s)
	# Progress is measured ACROSS ALL WORKERS, not per worker. Under
	# contention a single worker can wait a minute for ifnet_detach_sx
	# while the machine is perfectly healthy -- measured, and it cost a
	# false positive. The wedge being hunted stops everyone at once.
	total=$(cat "$HB"/hb.* 2>/dev/null | awk '{s += $1 + 1} END {print s+0}')
	if [ "$total" != "$LASTTOTAL" ]; then
		LASTTOTAL=$total
		LASTMOVED=$NOW
	fi
	if [ $((NOW - LASTMOVED)) -ge "$STALL" ]; then
		# The worker that has been waiting longest is the one inside the
		# operation under test; the rest are queued behind it.
		line=$(cat "$HB"/hb.* 2>/dev/null | sort -k3 | head -1)
		pid=$(echo "$line" | awk '{print $4+0}')
		age=$((NOW - $(echo "$line" | awk '{print $3+0}')))
		echo "==> WEDGED: no worker advanced for $((NOW - LASTMOVED))s"
		echo "    oldest: pid $pid, last attempt ${age}s ago"
		echo "    heartbeat: $line"
		# Marker first, and synced: ddb-on-wedge.sh polls for it, and the
		# machine may be about to stop every interface operation.
		{
			echo "pid $pid"
			echo "no progress for $((NOW - LASTMOVED))s at $(date)"
			echo "oldest heartbeat $line"
			echo "total cycles $total"
		} > "$WEDGEFILE"
		sync
		ps -p "$pid" -o pid,state,etimes,wchan,command
		procstat -kk "$pid"
		procstat -t "$pid"
		procstat -akk | grep -E 'epoch_drain|if_detach|sx_xlock' | head -40
		echo "==> workers and heartbeats left in place for inspection:"
		echo "    $HB   (kill $WPIDS $HPIDS $CPIDS when done)"
		# Stop the load so the machine is as quiet as possible for DDB.
		kill $HPIDS $CPIDS 2>/dev/null
		exit 1
	fi
	# Workers that exited without stalling (an error, or -n reached).
	alive=0
	for p in $WPIDS; do kill -0 "$p" 2>/dev/null && alive=$((alive + 1)); done
	if [ "$alive" -eq 0 ]; then
		echo "==> all workers exited; no stall"
		cleanup
		exit 0
	fi
	if [ $((NOW - LASTREPORT)) -ge 60 ]; then
		LASTREPORT=$NOW
		total=$(cat "$HB"/hb.* 2>/dev/null | awk '{s += $1 + 1} END {print s+0}')
		calls=$(sysctl -n kern.epoch.stats.epoch_calls)
		rate="epoch_calls $(( (calls - LASTCALLS) / 60 ))/s"
		LASTCALLS=$calls
		if [ -n "$CPIDS" ]; then
			churn=$(cat "$HB"/churn.* 2>/dev/null | awk '{s += $1} END {print s+0}')
			calive=0
			for p in $CPIDS; do kill -0 "$p" 2>/dev/null && calive=$((calive + 1)); done
			rate="$rate, churn $churn ops, $calive churn workers alive"
		fi
		echo "==> $((NOW - START))s: $total iterations, $alive workers alive, $rate"
	fi
	if [ "$DURATION" -gt 0 ] && [ $((NOW - START)) -ge "$DURATION" ]; then
		total=$(cat "$HB"/hb.* 2>/dev/null | awk '{s += $1 + 1} END {print s+0}')
		echo "==> survived ${DURATION}s, $total iterations, no stall"
		cleanup
		exit 0
	fi
done
