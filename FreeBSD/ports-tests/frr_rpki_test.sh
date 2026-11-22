#!/bin/sh
# net/frr10 RPKI revalidation and IPv6 neighbor-route regression lab.
#
# Two vnet jails wired by an epair:
#
#   --------  192.0.2.1/30            192.0.2.2/30  --------
#   | rpk1 |  2001:db8:98::1/64   2001:db8:98::2/64 | rpk2 |  RTR cache
#   | BGP  |---------epair981a<-->epair981b---------| BGP  |  127.0.0.1:3323
#   |65001 |                                        |65002 |  (frr_rpki_rtrd.py)
#   --------                                        --------
#
# rpk1 originates 10.0.0.0/24 10.0.1.0/24 10.2.0.0/24 10.3.0.0/24 10.4.0.0/24.
# rpk2 has soft-reconfiguration inbound and an inbound route-map denying
# RPKI invalid routes. The VRP set is changed step by step and each step
# asserts the result in rpk2's Loc-RIB:
#
#   (a) initial sync: the BGP session is up before the cache is reachable,
#       and the first VRP set makes 10.2.0.0/24 invalid. It must be dropped
#       once the sync completes (routes accepted while RPKI was "not used").
#   (b) a new VRP makes 10.4.0.0/24 invalid: dropped. The top of the table
#       is a holder node (10.0.0.0/21, no bgp_dest), where the unpatched
#       subtree lookup gave up, so no VRP change was ever applied.
#   (c) the VRP is replaced by a matching one: 10.4.0.0/24 must come back,
#       although only the Adj-RIB-In holds it. Needs (b) to have passed.
#   (d) a VRP 10.0.0.0/23 maxlen 24 from another AS: 10.0.0.0/24 and
#       10.0.1.0/24 dropped. The subtree root itself is a holder node.
#   (e) a 50176-VRP burst overflows bgpd's sync socket; its last VRP makes
#       10.3.0.0/24 invalid: dropped. Only conclusive when bgpd logged the
#       overflow, so the log is checked too.
#   The validation state that "show bgp" prints is computed when shown, so
#   the checks assert what the inbound policy did: route present or absent.
#   (f) zebra: after rpk2 resolves rpk1's IPv6 address through ND, zebra must
#       not hold a kernel 2001:db8:98::1/128 route built from the neighbor
#       cache entry (RTF_LLDATA from the routing socket).
#
# Exit codes: 0 all pass, 1 a check failed, 2 setup failure.
# Usage: sh frr_rpki_test.sh run|start|stop
# Requires: net/frr10 (RPKI option) installed, python3, sudo, vnet jails.
set -eu

SUDO=${SUDO:-sudo}
HERE=$(cd "$(dirname "$0")" && pwd)
RTRD=${HERE}/frr_rpki_rtrd.py

DAEMONDIR=/usr/local/lib/frr
[ -x ${DAEMONDIR}/zebra ] || DAEMONDIR=/usr/local/sbin

RUN=/var/run/frr
VRPS=${RUN}/rpk2/vrps.csv
RTRD_PID=${RUN}/rpk2/rtrd.pid
TIMEOUT=${TIMEOUT:-30}
FAILED=0

die() { echo "EXIT: $*" >&2; exit 2; }
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; FAILED=$((FAILED + 1)); }

vty() {
	# $1: jail, rest: vtysh command
	j=$1; shift
	${SUDO} jexec $j vtysh --vty_socket ${RUN}/$j.sock -c "$*" 2>/dev/null
}

# Validation state of a prefix in rpk2's Loc-RIB, "absent" when not there.
state() {
	vty rpk2 "show bgp ipv4 unicast $1 json" | jq -r '
		if (.paths // []) | length == 0 then "absent"
		else (.paths[0].rpkiValidationState // "unset") end'
}

# Wait until state of $1 is $2; print the last state seen.
wait_state() {
	i=0
	while [ $i -lt ${TIMEOUT} ]; do
		s=$(state $1)
		[ "$s" = "$2" ] && break
		sleep 1
		i=$((i + 1))
	done
	echo "$s"
}

expect() {
	# $1: label, $2: prefix, $3: expected state
	s=$(wait_state $2 "$3")
	if [ "$s" = "$3" ]; then
		pass "$1: $2 $s"
	else
		fail "$1: $2 is '$s', expected '$3'"
	fi
}

set_vrps() {
	# stdin: VRP lines; then tell the cache to serve the new serial
	${SUDO} tee ${VRPS} >/dev/null
	if [ -f ${RTRD_PID} ]; then
		${SUDO} pkill -HUP -F ${RTRD_PID}
	fi
}

check_req() {
	[ -x ${DAEMONDIR}/bgpd ] || die "net/frr10 not installed"
	[ -f /usr/local/lib/frr/modules/bgpd_rpki.so ] || die "frr10 built without RPKI"
	which python3 jq >/dev/null || die "python3 and jq required"
	[ -f ${RTRD} ] || die "${RTRD} missing"
}

start_jail() {
	# $1: jail, $2: epair end, $3: v4, $4: v6, $5: daemons
	${SUDO} jail -c name=$1 host.hostname=$1 persist vnet vnet.interface=$2
	${SUDO} jexec $1 ifconfig lo0 inet 127.0.0.1/8 up
	${SUDO} jexec $1 ifconfig $2 inet $3/30 up
	${SUDO} jexec $1 ifconfig $2 inet6 -ifdisabled
	${SUDO} jexec $1 ifconfig $2 inet6 $4/64
	${SUDO} mkdir -p ${RUN}/$1 ${RUN}/$1.sock
	${SUDO} touch ${RUN}/$1/vtysh.conf
	${SUDO} chown -R frr ${RUN}/$1 ${RUN}/$1.sock
	for d in $5; do
		args=""
		[ $d = bgpd ] && args="-M rpki"
		${SUDO} jexec $1 ${DAEMONDIR}/$d -d ${args} \
			-i ${RUN}/$1_$d.pid --vty_socket ${RUN}/$1.sock \
			</dev/null >/dev/null 2>&1
	done
	${SUDO} jexec $1 vtysh -b --config_dir ${RUN}/$1/ \
		--vty_socket ${RUN}/$1.sock >/dev/null 2>&1 || true
}

start() {
	check_req
	jls -j rpk1 >/dev/null 2>&1 && die "lab already running, run: sh $0 stop"
	echo "frr10 under test: $(pkg query %v frr10)"
	${SUDO} ifconfig epair981 create >/dev/null
	${SUDO} mkdir -p ${RUN}/rpk1 ${RUN}/rpk2
	${SUDO} tee ${RUN}/rpk1/frr.conf >/dev/null <<EOF
log file ${RUN}/rpk1/frr.log
!
router bgp 65001
 bgp router-id 192.0.2.1
 no bgp ebgp-requires-policy
 no bgp network import-check
 neighbor 192.0.2.2 remote-as 65002
 neighbor 192.0.2.2 timers 1 3
 neighbor 192.0.2.2 timers connect 1
 address-family ipv4 unicast
  network 10.0.0.0/24
  network 10.0.1.0/24
  network 10.2.0.0/24
  network 10.3.0.0/24
  network 10.4.0.0/24
 exit-address-family
!
EOF
	${SUDO} tee ${RUN}/rpk2/frr.conf >/dev/null <<EOF
log file ${RUN}/rpk2/frr.log
debug rpki
!
router bgp 65002
 bgp router-id 192.0.2.2
 no bgp ebgp-requires-policy
 neighbor 192.0.2.1 remote-as 65001
 neighbor 192.0.2.1 timers 1 3
 neighbor 192.0.2.1 timers connect 1
 address-family ipv4 unicast
  neighbor 192.0.2.1 soft-reconfiguration inbound
  neighbor 192.0.2.1 route-map RPKI in
 exit-address-family
!
route-map RPKI deny 10
 match rpki invalid
!
route-map RPKI permit 20
!
rpki
 rpki retry_interval 2
 rpki cache tcp 127.0.0.1 3323 preference 1
exit
!
EOF
	start_jail rpk1 epair981a 192.0.2.1 2001:db8:98::1 "mgmtd zebra bgpd"
	start_jail rpk2 epair981b 192.0.2.2 2001:db8:98::2 "mgmtd zebra bgpd"
}

start_rtrd() {
	${SUDO} jexec rpk2 daemon -o ${RUN}/rpk2/rtrd.log \
		python3 -I ${RTRD} ${VRPS} 127.0.0.1 3323 ${RTRD_PID}
	i=0
	while [ ! -f ${RTRD_PID} ] && [ $i -lt 10 ]; do sleep 1; i=$((i + 1)); done
	[ -f ${RTRD_PID} ] || die "RTR cache did not start, see ${RUN}/rpk2/rtrd.log"
}

run() {
	start
	# KEEP=1 leaves the lab up for inspection, then: sh $0 stop
	[ -n "${KEEP:-}" ] || trap stop EXIT INT TERM

	# BGP up and all routes in before the cache exists (RPKI "not used")
	expect "setup" 10.2.0.0/24 unset
	expect "setup" 10.4.0.0/24 unset

	echo "AS65099,10.2.0.0/24,24" | set_vrps
	start_rtrd
	expect "(a) initial sync, invalid dropped" 10.2.0.0/24 absent
	expect "(a) initial sync, others" 10.0.0.0/24 "not found"

	printf 'AS65099,10.2.0.0/24,24\nAS65099,10.4.0.0/24,24\n' | set_vrps
	before=${FAILED}
	expect "(b) invalid dropped, holder at table top" 10.4.0.0/24 absent
	b_ok=$([ ${FAILED} -eq ${before} ] && echo 1 || echo 0)

	VRP3='AS65099,10.2.0.0/24,24\nAS65001,10.4.0.0/24,24\n'
	printf "${VRP3}" | set_vrps
	if [ ${b_ok} -eq 1 ]; then
		expect "(c) denied route revalidated" 10.4.0.0/24 valid
	else
		echo "SKIP (c) denied route revalidated: not conclusive as (b) failed"
	fi

	VRP4="${VRP3}AS65099,10.0.0.0/23,24\n"
	printf "${VRP4}" | set_vrps
	expect "(d) holder subtree root" 10.0.0.0/24 absent
	expect "(d) holder subtree root" 10.0.1.0/24 absent

	{
		printf "${VRP4}"
		jot -w %d 196 0 | while read a; do
			jot -w "AS64999,100.$a.%d.0/24,24" 256 0
		done
		echo "AS65099,10.3.0.0/24,24"
	} | set_vrps
	TIMEOUT=60 expect "(e) overflow burst" 10.3.0.0/24 absent
	if ${SUDO} grep -qE "Socket overflow detected|Could not write to rpki_sync_socket_rtr" \
	    ${RUN}/rpk2/frr.log; then
		echo "     bgpd sync socket overflowed: (e) is conclusive"
	else
		echo "     WARN no sync socket overflow logged: (e) is not conclusive"
	fi

	${SUDO} jexec rpk2 ping6 -q -c 2 2001:db8:98::1 >/dev/null ||
		fail "(f) setup: no IPv6 reachability to rpk1"
	sleep 2
	if vty rpk2 "show ipv6 route json" | jq -e 'has("2001:db8:98::1/128")' >/dev/null; then
		fail "(f) zebra holds a route for neighbor cache entry 2001:db8:98::1/128"
	else
		pass "(f) no route from neighbor cache entry 2001:db8:98::1/128"
	fi

	[ ${FAILED} -eq 0 ] || { echo "RESULT: FAIL (${FAILED})"; return 1; }
	echo "RESULT: PASS"
}

stop() {
	trap - EXIT INT TERM
	[ -f ${RTRD_PID} ] && ${SUDO} pkill -F ${RTRD_PID} 2>/dev/null || true
	for j in rpk1 rpk2; do
		${SUDO} jail -R $j 2>/dev/null || true
	done
	# the epair comes back to the host once the vnet is gone
	i=0
	while jls -d -j rpk1 >/dev/null 2>&1 || jls -d -j rpk2 >/dev/null 2>&1; do
		[ $i -lt 20 ] || break
		sleep 1
		i=$((i + 1))
	done
	i=0
	while [ $i -lt 10 ]; do
		ends=$(ifconfig -l | tr ' ' '\n' | grep '^epair981[ab]$' || true)
		[ -z "${ends}" ] && break
		for e in ${ends}; do
			${SUDO} ifconfig $e destroy 2>/dev/null || true
		done
		sleep 1
		i=$((i + 1))
	done
	${SUDO} rm -rf ${RUN}/rpk1 ${RUN}/rpk2 ${RUN}/rpk1.sock ${RUN}/rpk2.sock
	${SUDO} rm -f ${RUN}/rpk1_*.pid ${RUN}/rpk2_*.pid
}

case "${1:-}" in
run|start|stop) $1 ;;
*) echo "Usage: $0 run|start|stop"; exit 2 ;;
esac
