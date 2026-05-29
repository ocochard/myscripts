#!/bin/sh
# net/bird2 regression test for non-default FIB support (no jails / no vnet).
#
# Tracks FreeBSD PR 279662:
#   https://bugs.freebsd.org/bugzilla/show_bug.cgi?id=279662
#
# Background:
#   Since bird 2.15 the default net/bird2 flavor talks to the kernel via
#   netlink. With the netlink flavor, "protocol kernel { kernel table N; }"
#   was ignored: routes were always installed in FIB 0 and routes living
#   in non-default FIBs were never learned. The @rtsock flavor has always
#   honored the directive.
#
# What this test does:
#   - Requires sysctl net.fibs >= 2.
#   - Creates one cloned loopback lo901 (10.99.1.1/24) bound to FIB 1.
#   - Installs a manual kernel route 10.55.0.0/24 in FIB 1 via
#     `route add -fib 1 ... -iface lo901` so bird has something to learn.
#   - Starts a single bird instance with one kernel protocol bound to
#     FIB 1 ("kernel table 1") that:
#       * imports kernel routes from FIB 1 into bird's master4 (learn);
#       * exports bird routes back into kernel FIB 1.
#     Plus a static protocol injecting 10.123.0.0/24 into bird's master4.
#   - The `check` subcommand then verifies:
#       (a) bird learned 10.55.0.0/24 from kernel FIB 1 (inbound);
#       (b) kernel FIB 1 now contains 10.123.0.0/24 (outbound).
#
# Bug layering:
#   - PR 279662 fixed the *export* path in src commit f34aca55adef
#     (2024-06, MFC'd into 15.x).
#   - The *learn* (import) path was still broken on the netlink flavor
#     because handle_rtm_dump() in sys/netlink/route/rt.c passed the
#     constant RT_TABLE_UNSPEC to the per-FIB dumper instead of the
#     loop index, so an UNSPEC dump returned FIB 0 N times. Fixed in
#     src commit 33acf0f26b49 (2026-05-22, main only at this writing;
#     not yet MFC'd to stable/15 / releng/15.0).
#
# Observed:
#   FreeBSD 15.0-RELEASE-p9 + bird2 netlink : learn FAILS, export PASSES.
#   FreeBSD 16-CURRENT pre-33acf0f          : same as above.
#   FreeBSD main with 33acf0f               : both PASS.
#   net/bird2@rtsock everywhere             : both PASS.
#
# Usage: sh bird_fib_test.sh start|check|stop
set -eu

SUDO=${SUDO:-sudo}
RUNDIR=/var/run/bird-fibtest
CONF=${RUNDIR}/bird.conf
CTL=${RUNDIR}/bird.ctl
LOG=/var/log/bird-fibtest.log
FIB=1
LO_LOCAL=lo901          # carries 10.99.1.1/24 (router) - in FIB ${FIB}
KERNEL_IN_FIB1=10.55.0.0/24      # manually installed in FIB 1 via `route add -fib 1`
STATIC_TO_FIB1=10.123.0.0/24     # bird's static route, should land in FIB 1
NEXTHOP=10.99.1.2       # bogus host on the lo901 subnet so the static is resolvable

die() { echo "EXIT: $*" >&2; exit 1; }

usage () {
	echo "Usage: $0 start|check|stop"
}

check_req () {
	which bird   >/dev/null 2>&1 || die "net/bird2 not installed: bird not found"
	which birdc  >/dev/null 2>&1 || die "net/bird2 not installed: birdc not found"
	fibs=$(sysctl -n net.fibs 2>/dev/null || echo 1)
	[ "${fibs}" -ge 2 ] || die "kernel built with net.fibs=${fibs}, need >=2 (set net.fibs=2 in /boot/loader.conf and reboot)"
	# Identify which flavor is installed; useful for the report.
	if pkg query %n bird2 >/dev/null 2>&1; then
		flavor=$(pkg query %n bird2)
		echo "Installed package: ${flavor}"
	fi
}

write_conf () {
	${SUDO} mkdir -p "${RUNDIR}"
	cat <<EOF | ${SUDO} tee "${CONF}" >/dev/null
# bird config for multi-FIB regression test
log "${LOG}" all;
log stderr all;

router id 10.99.1.1;

protocol device {
	scan time 10;
}

# Import the directly-connected network from lo901.
protocol direct {
	ipv4;
	interface "${LO_LOCAL}";
}

# Single kernel protocol bound to FIB ${FIB}. With a buggy netlink build
# this is the code path that misbehaves: routes living in kernel FIB ${FIB}
# should be imported into bird (learn), and bird's static route should be
# installed into kernel FIB ${FIB} (export). bird 2.x refuses two kernel
# protocols on the same bird table, so we only declare one here.
protocol kernel kernel${FIB} {
	learn;
	kernel table ${FIB};
	ipv4 {
		import all;
		export all;
	};
}

# A static route that bird should push down into kernel FIB ${FIB}.
protocol static static_to_fib${FIB} {
	ipv4;
	route ${STATIC_TO_FIB1} via ${NEXTHOP};
}
EOF
}

start () {
	check_req
	# Refuse to start if anything is already running.
	if [ -S "${CTL}" ]; then
		die "control socket ${CTL} already exists - run '$0 stop' first"
	fi

	# Create a loopback clone bound to FIB ${FIB} to carry the router IP.
	${SUDO} ifconfig "${LO_LOCAL}" create  || die "cannot create ${LO_LOCAL}"
	${SUDO} ifconfig "${LO_LOCAL}" fib "${FIB}"
	${SUDO} ifconfig "${LO_LOCAL}" inet 10.99.1.1/24 up

	# Manually inject a static route into kernel FIB ${FIB} so that bird's
	# kernel protocol (with `learn`) has something non-trivial to import.
	${SUDO} route -4 add -fib "${FIB}" "${KERNEL_IN_FIB1}" -iface "${LO_LOCAL}" >/dev/null

	echo "---- FIB ${FIB} routes ----"
	netstat -4 -rn -F "${FIB}"

	write_conf
	${SUDO} bird -c "${CONF}" -s "${CTL}"
	# Give bird a beat to converge.
	sleep 2
	echo "bird started; logs in ${LOG}; run '$0 check' to verify."
}

check () {
	[ -S "${CTL}" ] || die "bird control socket ${CTL} missing - did you run start?"

	pass=0
	fail=0

	echo "==== bird: routes learned from kernel ===="
	# Routes that bird imported via kernel protocols. If the netlink bug
	# bites, the 10.99.2.0/24 route (only in FIB ${FIB}) will be absent.
	${SUDO} birdc -s "${CTL}" "show route protocol kernel${FIB}" || true

	if ${SUDO} birdc -s "${CTL}" "show route protocol kernel${FIB}" 2>/dev/null \
	    | grep -q "${KERNEL_IN_FIB1%/*}"; then
		echo "PASS: bird learned ${KERNEL_IN_FIB1} from kernel FIB ${FIB}"
		pass=$((pass+1))
	else
		echo "FAIL: bird did NOT learn ${KERNEL_IN_FIB1} from kernel FIB ${FIB}"
		fail=$((fail+1))
	fi

	echo "==== kernel FIB ${FIB}: routes pushed by bird ===="
	netstat -4 -rn -F "${FIB}" || true

	if netstat -4 -rn -F "${FIB}" | awk '{print $1}' | grep -q "^${STATIC_TO_FIB1%/*}"; then
		echo "PASS: kernel FIB ${FIB} contains ${STATIC_TO_FIB1} (pushed by bird)"
		pass=$((pass+1))
	else
		echo "FAIL: kernel FIB ${FIB} does NOT contain ${STATIC_TO_FIB1}"
		fail=$((fail+1))
	fi

	echo "==== summary: ${pass} pass / ${fail} fail ===="
	if [ "${fail}" -gt 0 ]; then
		echo "---- tail of ${LOG} ----"
		${SUDO} tail -n 40 "${LOG}" 2>/dev/null || true
		exit 1
	fi
}

stop () {
	if [ -S "${CTL}" ]; then
		${SUDO} birdc -s "${CTL}" down 2>/dev/null || true
		sleep 1
	fi
	${SUDO} pkill -f "bird -c ${CONF}" 2>/dev/null || true
	# Best-effort cleanup; destroying lo901 also removes routes that
	# referenced it, so order doesn't matter much.
	${SUDO} route -4 delete -fib "${FIB}" "${KERNEL_IN_FIB1}" 2>/dev/null || true
	${SUDO} route -4 delete -fib "${FIB}" "${STATIC_TO_FIB1}" 2>/dev/null || true
	${SUDO} ifconfig "${LO_LOCAL}" destroy 2>/dev/null || true
	${SUDO} rm -f "${CONF}" "${CTL}"
	${SUDO} rm -rf "${RUNDIR}"
	echo "cleaned up."
}

if [ $# -eq 0 ]; then
	usage
	exit 2
fi
case "$1" in
	start|check|stop) "$1" ;;
	*) usage; exit 2 ;;
esac
