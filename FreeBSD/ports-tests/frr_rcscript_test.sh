#!/bin/sh
# net/frr10 regression test for the rc.d "restart" bug on FreeBSD.
#
# Runs directly on the host (no jail): drives the INSTALLED rc.d script
# via service(8) with the real watchfrr + daemons. frr is only used for
# testing on this host, so touching the host rc is acceptable. The
# config is network-inert (no interfaces, no networks advertised) so
# zebra/ospfd never install routes or send packets.
#
# Bug: "service frr restart" (no daemon argument, watchfrr enabled)
# only stopped and started watchfrr itself. Restarting watchfrr does
# NOT bounce the daemons it supervises -- it just re-attaches to the
# ones still running (upstream frrinit.sh's own reload comment: "restart
# watchfrr to pick up added daemons. NB: This will NOT cause the other
# daemons to be restarted."). So mgmtd/zebra/ospfd kept their original
# PIDs across a restart and were never actually cycled -- config changes
# were silently ignored.
#
# The two known workarounds proved the diagnosis: both
#   service frr stop; service frr start
#   service frr restart all          (watchfrr's -r hook path)
# fully cycle the stack, while a bare "service frr restart" did not.
#
# Fix (files/frr.in "restart" case): when frr_daemons=watchfrr (the
# no-arg case) stop watchfrr AND every managed daemon, then start
# watchfrr -- mirroring upstream frrinit.sh "restart". The "restart all"
# / single-daemon path is unchanged.
#
# Detection: PID identity. A real restart gives each daemon a new PID.
# Under the bug the real daemons keep their PIDs (only watchfrr's
# changes). We assert the real daemons' PIDs change on a bare restart.
#
# Exit codes:
#   0 -- rc restart behaves correctly (bug fixed)
#   1 -- bug still present (restart did not cycle the daemons)
#   2 -- environment / setup failure
#
# Usage: sh frr_rcscript_test.sh start|check|stop|run
#   run = start; check; stop  (self-contained)
#
# Requires: net/frr10 installed, sudo, root. NOT for a host with a
# production frr instance -- it stops/starts the host's frr service.
set -eu

SUDO=${SUDO:-sudo}
PREFIX=${PREFIX:-/usr/local}
ETCDIR=${ETCDIR:-${PREFIX}/etc/frr}
JRUN=/var/run/frr

# Real daemons to assert PID-cycling on. watchfrr is managed separately
# (it is always restarted; the bug was that these were NOT).
REAL_DAEMONS="mgmtd zebra ospfd"

die() { echo "EXIT: $*" >&2; exit 2; }
usage() { echo "Usage: $0 start|check|stop|run"; }

check_req() {
	which vtysh >/dev/null 2>&1 || die "net/frr10 not installed: vtysh not found"
	[ -x ${PREFIX}/sbin/watchfrr ] || die "net/frr10 not installed: watchfrr missing"
	[ -x /usr/local/etc/rc.d/frr ] || die "rc.d/frr not installed (USE_RC_SUBR)"
	id frr >/dev/null 2>&1 || die "frr user missing (package not fully installed)"
}

# Guard: refuse to run if frr is enabled in the BASE rc.conf (a real
# production instance). Our own /etc/rc.conf.d/frr is ignored -- a
# leftover from a crashed run is cleaned, not treated as production.
guard_not_production() {
	${SUDO} rm -f "${RC_CONF_D}" 2>/dev/null || true
	for f in /etc/rc.conf /etc/rc.conf.local; do
		[ -r "$f" ] || continue
		if ${SUDO} grep -Eq '^[[:space:]]*frr_enable="?YES"?' "$f"; then
			die "frr_enable=YES in $f -- refusing to touch a production frr"
		fi
	done
}

pid_of() {
	${SUDO} sh -c "cat ${JRUN}/$1.pid 2>/dev/null | tr -d '[:space:]'" 2>/dev/null || true
}

alive() { # pid -> 0 if a live process
	[ -n "$1" ] && ${SUDO} kill -0 "$1" 2>/dev/null
}

snapshot_pids() {
	for d in watchfrr ${REAL_DAEMONS}; do
		echo "$d=$(pid_of "$d")"
	done
}

getpid() { echo "$1" | sed -n "s/^$2=//p"; }

RC_CONF_D=/etc/rc.conf.d/frr

write_conf() {
	${SUDO} mkdir -p "${ETCDIR}" "${JRUN}" /etc/rc.conf.d
	# service(8) scrubs the environment (env -i), so frr_enable and
	# frr_daemons cannot be passed via the caller's env. Drop them in
	# /etc/rc.conf.d/frr, which load_rc_config sources (handles the
	# spaces in frr_daemons cleanly). Removed again in stop().
	${SUDO} sh -c "cat > '${RC_CONF_D}'" <<EOF
frr_enable="YES"
frr_daemons="${REAL_DAEMONS}"
EOF
	${SUDO} sh -c "printf 'service integrated-vtysh-config\n' > '${ETCDIR}/vtysh.conf'"
	# Network-inert: only a router-id, no interfaces, no networks. zebra
	# and ospfd start and stay idle; nothing hits the host FIB or wire.
	${SUDO} sh -c "cat > '${ETCDIR}/frr.conf'" <<EOF
log syslog informational
!
router ospf
 ospf router-id 127.0.0.99
!
EOF
	${SUDO} chown -R frr:frr "${ETCDIR}"
}

# --------------------------------------------------------------------
start() {
	check_req
	guard_not_production
	write_conf
	svc start
	sleep 3
	echo "started; next: sh $0 check"
}

# frr_enable / frr_daemons come from /etc/rc.conf.d/frr (see write_conf).
svc() { ${SUDO} /usr/sbin/service frr "$@"; }

# --------------------------------------------------------------------
check() {
	rc=0

	echo "------ initial PIDs ------"
	before=$(snapshot_pids); echo "${before}"
	echo "--------------------------"
	for d in watchfrr ${REAL_DAEMONS}; do
		p=$(getpid "${before}" "$d")
		alive "$p" || { echo "FAIL setup: $d not running after start"; rc=1; }
	done
	[ ${rc} -eq 0 ] || { echo "OVERALL: FAIL (setup)"; exit 1; }

	# ---- Assertion 1: bare "service frr restart" cycles real daemons.
	echo ">>> service frr restart"
	svc restart || true
	sleep 4
	after=$(snapshot_pids); echo "${after}"
	unchanged=0
	for d in ${REAL_DAEMONS}; do
		pb=$(getpid "${before}" "$d"); pa=$(getpid "${after}" "$d")
		if ! alive "$pa"; then
			echo "FAIL (1): $d not running after restart"; rc=1
		elif [ "${pb}" = "${pa}" ]; then
			echo "FAIL (1): $d PID unchanged (${pb}) -- restart did NOT cycle it"
			unchanged=$((unchanged+1)); rc=1
		else
			echo "PASS (1): $d cycled ${pb} -> ${pa}"
		fi
	done
	[ ${unchanged} -eq 0 ] || \
		echo "         -> this is the rc.d restart bug (watchfrr-only restart)"

	# ---- Assertion 2: "service frr restart all" also cycles daemons
	#      (watchfrr's -r hook path / the else branch).
	echo ">>> service frr restart all"
	mid=$(snapshot_pids)
	svc restart all || true
	sleep 4
	after2=$(snapshot_pids); echo "${after2}"
	for d in ${REAL_DAEMONS}; do
		pm=$(getpid "${mid}" "$d"); pa=$(getpid "${after2}" "$d")
		if ! alive "$pa"; then
			echo "FAIL (2): $d not running after 'restart all'"; rc=1
		elif [ "${pm}" = "${pa}" ]; then
			echo "FAIL (2): $d PID unchanged on 'restart all'"; rc=1
		else
			echo "PASS (2): $d cycled on 'restart all' ${pm} -> ${pa}"
		fi
	done

	# ---- Assertion 3: stop; start = fully-running stack (workaround).
	echo ">>> service frr stop; service frr start"
	svc stop || true
	sleep 3
	for d in watchfrr ${REAL_DAEMONS}; do
		p=$(pid_of "$d")
		if alive "$p"; then echo "FAIL (3): $d still running (pid $p) after stop"; rc=1; fi
	done
	svc start || true
	sleep 4
	final=$(snapshot_pids); echo "${final}"
	for d in watchfrr ${REAL_DAEMONS}; do
		p=$(getpid "${final}" "$d")
		if alive "$p"; then echo "PASS (3): $d running after stop;start (pid $p)"
		else echo "FAIL (3): $d not running after stop;start"; rc=1; fi
	done

	if [ ${rc} -eq 0 ]; then
		echo "OVERALL: PASS -- rc.d restart cycles the full daemon set"
	else
		echo "OVERALL: FAIL -- rc.d restart bug reproduces"
	fi
	exit ${rc}
}

# --------------------------------------------------------------------
stop() {
	svc stop 2>/dev/null || true
	# Belt-and-suspenders: kill any stragglers from our set.
	for d in watchfrr ${REAL_DAEMONS}; do
		p=$(pid_of "$d"); alive "$p" && ${SUDO} kill "$p" 2>/dev/null || true
	done
	${SUDO} rm -f ${JRUN}/*.pid 2>/dev/null || true
	# Remove our rc.conf.d override so the host is left as we found it.
	${SUDO} rm -f "${RC_CONF_D}" 2>/dev/null || true
}

run() { start; check; }

case "${1:-}" in
	start) start ;;
	check) check ;;
	stop)  stop ;;
	run)   trap 'stop' EXIT INT TERM; run ;;
	*)     usage; exit 2 ;;
esac
