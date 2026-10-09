#!/bin/sh
# Minimal probe: move an epair into a VNET jail, repeatedly.
# Hunting a hang seen during topotest setup on main-n289791:
#   ifconfig <epair> vnet <jid> stuck in state RJ, 0 CPU, kernel stack
#   mi_switch <- sched_ule_bind <- epoch_drain_callbacks <- if_detach_internal
# The iteration is on disk before each attempt so a hang names it.
set -u
ITER=${1:-200}
JAIL=${JAIL:-vmovetest}
STATE=${STATE:-/root/epair-vnet-iter}
i=1
while [ "$i" -le "$ITER" ]; do
	echo "iteration $i started $(date '+%H:%M:%S')" > "$STATE"; sync
	jail -r "$JAIL" >/dev/null 2>&1
	jail -c name="$JAIL" host.hostname="$JAIL" path=/ vnet persist >/dev/null || exit 1
	jid=$(jls -j "$JAIL" jid)
	e=$(ifconfig epair create) || exit 1
	# The operation under test, with a watchdog: if it does not return in
	# 60s it is the hang, and the iteration number is already recorded.
	if ! timeout 60 ifconfig "$e" vnet "$jid"; then
		echo "HANG or failure at iteration $i on $e -> jid $jid" >> "$STATE"
		sync
		exit 2
	fi
	jail -r "$JAIL" >/dev/null 2>&1
	i=$((i + 1))
done
echo "survived $ITER iterations" > "$STATE"; sync
