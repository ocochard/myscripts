#!/bin/sh
# Standalone reproducer: panic FreeBSD by destroying a VNET jail while a
# fib_algo rebuild callout is still pending on that jail's routing table.
#
# THE RACE
# --------
# fib_algo (sys/net/route/fib_algo.c) keeps a per-fib "struct fib_data" whose
# rebuild callout is initialised with the RIB's lock:
#
#	callout_init_rm(&fd->fd_callout, &rh->rib_lock, 0)   fib_algo.c:1222
#
# A route change calls schedule_fd_rebuild() -> schedule_callout(), arming that
# callout a few tens of milliseconds out. Teardown
# (schedule_destroy_fd_instance) only does:
#
#	callout_stop(&fd->fd_callout)                        fib_algo.c:1085
#	fib_epoch_call(destroy_fd_instance_epoch, ...)
#
# callout_stop() does not wait. A callout that has already fired and is blocked
# on rib_lock still runs afterwards -- and rib_lock lives inside the rib_head,
# which VNET teardown frees (rtables_destroy, SI_SUB_PROTO_DOMAIN) independently
# of the epoch that covers fib_data. The callout then write-locks freed memory:
#
#	panic: page fault
#	_rm_wlock() / _mtx_lock_spin_cookie() <- softclock_call_cc()
#	c_func = handle_fd_callout, c_lock = fd_rh->rib_lock
#
# So: add routes, then destroy the jail inside the callout delay window.
#
# Needs a dump device -- it is meant to crash the machine.
#
#   ./fib-algo-vnet-panic.sh [iterations] [routes-per-iteration]
set -u

ITER=${1:-500}
ROUTES=${2:-300}
JAIL=${JAIL:-fibpanic}
STATE=${STATE:-/root/fib-panic-iter}

[ "$(id -u)" -eq 0 ] || { echo "$0: must be root" >&2; exit 1; }
if ! sysctl -Nq net.route.algo >/dev/null 2>&1; then
	echo "$0: no net.route.algo tree; this kernel has no fib_algo" >&2
	exit 1
fi

echo "==> dump device: $(dumpon -l)"
echo "==> $ITER iterations, $ROUTES routes each, jail $JAIL"
sysctl -n net.route.algo.inet.algo 2>/dev/null | sed 's/^/==> current inet algo: /'

i=1
while [ "$i" -le "$ITER" ]; do
	# The iteration number is on disk BEFORE the risky part, so the count
	# survives the panic.
	echo "iteration $i started $(date '+%H:%M:%S')" > "$STATE"
	sync

	jail -r "$JAIL" >/dev/null 2>&1
	jail -c name="$JAIL" host.hostname="$JAIL" path=/ vnet persist >/dev/null || {
		echo "jail create failed" >&2; exit 1; }

	# A route needs a reachable gateway; lo0 in a fresh VNET gives one
	# without any epair plumbing.
	jexec "$JAIL" /sbin/ifconfig lo0 inet 127.0.0.1/8 up

	# Enough route churn to make fib_algo evaluate and schedule a rebuild
	# (bsearch4 is what it picks for a table this size).
	jexec "$JAIL" /bin/sh -c \
	    "i=1; while [ \$i -le $ROUTES ]; do \
	        /sbin/route -nq add -net 10.\$((i / 250)).\$((i % 250)).0/24 127.0.0.1; \
	        i=\$((i + 1)); done"

	# No sleep here on purpose: the callout is armed tens of milliseconds
	# out, and this destroys the rib underneath it.
	jail -r "$JAIL" >/dev/null 2>&1

	i=$((i + 1))
done

echo "survived $ITER iterations" > "$STATE"
sync
echo "==> no panic after $ITER iterations"
