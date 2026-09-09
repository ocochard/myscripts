#!/bin/sh
# net/pimd PIM-SM regression lab using vnet jails
#
# Exercises the FreeBSD-specific code paths of pimd that no upstream CI
# covers: upstream's own test suite (pimd/test/*.sh) is Linux-only, it is
# built on network namespaces, veth pairs and `unshare`, so on FreeBSD it
# cannot even start.  Everything asserted here goes through routesock.c
# (RPF lookups over the PF_ROUTE socket) and the kern.c BSD branches,
# rather than netlink.c and the Linux ones.
#
# What makes this possible on FreeBSD:
#   - sys/netinet/ip_mroute.c is fully VNET-ized (V_viftable, V_numvifs,
#     V_ip_mrouter, V_multicast_register_if), so each vnet jail owns a
#     private multicast forwarding cache and vif table.
#   - prison_priv_check() grants PRIV_NETINET_MROUTE, PRIV_NETINET_RAW and
#     PRIV_NET_BPF unconditionally to jails with their own network stack
#     (sys/kern/kern_jail.c), so pimd's raw IGMP/PIM sockets and its
#     MRT_INIT setsockopt() work inside a jail with no allow.raw_sockets.
#   - ip_mroute.ko has to be loaded from the host: a jail cannot kldload.
#
# Topology, one vnet jail per box, all links /24:
#
#    ED1            R1             R2             R3            ED2
#  (sender)     (FHR / DR)     (BSR + RP)        (LHR)       (receiver)
#     |              |              |              |              |
#     +--10.0.1.0/24-+-10.0.12.0/24-+-10.0.23.0/24-+--10.0.3.0/24-+
#      .10        .1   .1        .2   .2        .3   .1        .10
#     epair101a/b     epair112a/b    epair123a/b    epair203a/b
#
# Unicast routing is static on purpose: pimd cannot read distance/metric
# from the kernel anyway (it uses the values from pimd.conf), so adding
# bird or frr here would only add a dependency and a second thing to
# debug.  The RP is pinned to R1's side of the R1-R2 link (10.0.12.2) so
# the expected RP address is deterministic instead of "highest active IP".
#
# Multicast then has to survive the full PIM-SM sequence: ED2's IGMP
# report reaches R3, R3 sends a (*,G) join toward the RP, ED1's first
# packet makes R1 PIM-register-encapsulate to R2, R2 decapsulates and
# forwards down the shared tree, and with spt-threshold set low the
# routers then switch to the shortest path tree.
#
# Two scenarios share that topology, they differ only in which pimd.conf
# each router gets and which assertions run:
#
#   rpt        R2 is BSR and RP, ED2 joins, traffic has to reach it over
#              the shared tree.  Takes about 90s.
#   keepalive  R1 is BSR and RP for its own directly connected source and
#              nobody joins the group, which is the setup of
#              https://github.com/troglobit/pimd/issues/251.  The (S,G)
#              entries then have an empty outgoing interface list, and
#              pimd used to restart the entry timer only for entries that
#              had outgoing interfaces: every source was aged out a few
#              seconds after a cache miss had recreated it, so sources
#              kept appearing and disappearing while they were sending.
#              Takes about 5 minutes, it has to outlive PIM_DATA_TIMEOUT
#              (210s).
#
# The scenarios cannot run in parallel: they use the same jail names and
# epairs, and net.inet.ip.mcast.loop is a host-global sysctl.
#
# Usage:
#   ./pimd_test.sh start [scenario]   build the lab, start pimd on R1/R2/R3
#   ./pimd_test.sh check [scenario]   run the assertions (start must have run)
#   ./pimd_test.sh run   [scenario]   start + check + stop, exit 0 if all pass
#   ./pimd_test.sh stop               tear everything down
#
# where scenario is "rpt" (default), "keepalive", or "all" for run.
#
# Requires: root (via sudo), VIMAGE kernel, ip_mroute.ko, and a built
# pimd tree in $PIMD_SRC (./autogen.sh && ./configure && gmake).

set -eu

SUDO=${SUDO:-sudo}
PIMD_SRC=${PIMD_SRC:-$HOME/pimd}
WORKDIR=${WORKDIR:-/tmp/pimd-test}
GROUP=${GROUP:-225.1.2.3}
SCENARIO=${SCENARIO:-rpt}

# keepalive: groups the source blasts at, and how long the entries must
# survive.  KEEP_SECONDS has to exceed PIM_DATA_TIMEOUT in src/pimd.h.
KEEP_GROUP=${KEEP_GROUP:-239.1.1.5}
KEEP_NUM=${KEEP_NUM:-3}
KEEP_SECONDS=${KEEP_SECONDS:-240}

# pimd debug flags, e.g. DEBUG="-l debug -d mrt,rpf" or "-l debug -d all"
DEBUG=${DEBUG:-"-l debug -d mrt,rpf,pim_register,pim_bootstrap"}

PIMD="$PIMD_SRC/src/pimd"
PIMCTL="$PIMD_SRC/src/pimctl"
MPING="$WORKDIR/mping"
# mping joins the group it sends to, which would give the (S,G) entries a
# leaf and hide the bug the keepalive scenario is after.  That scenario
# needs a source that only sends, so it gets its own little sender.
MSEND="$WORKDIR/msend"

BOXES="ed1 r1 r2 r3 ed2"
ROUTERS="r1 r2 r3"
EPAIRS="epair101 epair112 epair123 epair203"

# Source and RP addresses the assertions expect
SRC_ADDR=10.0.1.10
RP_ADDR=10.0.12.2

# Replies the sender must get back before the stream counts as forwarded.
# The first seconds are always lost while PIM registers the source with
# the RP and the receiver's join climbs the tree.
MIN_REPLIES=${MIN_REPLIES:-20}

die() { echo -n "EXIT: " >&2; echo "$@" >&2; exit 1; }
print() { printf "\033[7m>> %-76s\033[0m\n" "$1"; }
dprint() { printf "\033[2m%-76s\033[0m\n" "$1"; }

FAILED=0
ok()   { printf "  \033[32mok\033[0m    %s\n" "$1"; }
fail() { printf "  \033[31mFAIL\033[0m  %s\n" "$1"; FAILED=$((FAILED + 1)); }

usage() {
	echo "usage: $0 start|check|run [rpt|keepalive] | run all | stop"
}

set_scenario() {
	case ${1:-$SCENARIO} in
	rpt|keepalive) SCENARIO=${1:-$SCENARIO} ;;
	*) usage; exit 2 ;;
	esac
}

# Interfaces each box owns, "a" and "b" ends of the epairs above
ifaces() {
	case $1 in
	ed1) echo "epair101a" ;;
	r1)  echo "epair101b epair112a" ;;
	r2)  echo "epair112b epair123a" ;;
	r3)  echo "epair123b epair203a" ;;
	ed2) echo "epair203b" ;;
	esac
}

# Interfaces renamed once the jail owns them, "<old> <new>" pairs.
#
# R2's link to R1 deliberately carries an uppercase letter, and r2.conf
# then names that interface in its bsr-candidate and rp-candidate lines.
# pimd lowercases every token it reads from the .conf (next_word() in
# src/config.c), while the kernel keeps the name as it is, so a
# case-sensitive lookup silently fails to resolve the interface: pimd
# falls back to the highest active address and advertises the wrong RP.
# Assertion 3 catches that, because it demands the RP be $RP_ADDR rather
# than whatever address happens to be numerically highest.
# See https://github.com/troglobit/pimd/pull/252.
renames() {
	case $1 in
	r2) echo "epair112b Epair112b" ;;
	*)  echo "" ;;
	esac
}

# "<interface> <address>/<prefixlen>" pairs to configure per box
addrs() {
	case $1 in
	ed1) echo "epair101a 10.0.1.10/24" ;;
	r1)  echo "epair101b 10.0.1.1/24 epair112a 10.0.12.1/24" ;;
	r2)  echo "Epair112b 10.0.12.2/24 epair123a 10.0.23.2/24" ;;
	r3)  echo "epair123b 10.0.23.3/24 epair203a 10.0.3.1/24" ;;
	ed2) echo "epair203b 10.0.3.10/24" ;;
	esac
}

# Static unicast routes, "<destination> <gateway>" pairs.  pimd needs a
# unicast RPF answer for every source and for the RP.
routes() {
	case $1 in
	ed1) echo "default 10.0.1.1" ;;
	r1)  echo "10.0.23.0/24 10.0.12.2 10.0.3.0/24 10.0.12.2" ;;
	r2)  echo "10.0.1.0/24 10.0.12.1 10.0.3.0/24 10.0.23.3" ;;
	r3)  echo "10.0.1.0/24 10.0.23.2 10.0.12.0/24 10.0.23.2" ;;
	ed2) echo "default 10.0.3.1" ;;
	esac
}

jname() { echo "pimd_$1"; }

jrun() { j=$1; shift; ${SUDO} jexec "$(jname "$j")" "$@"; }

pimctl() { j=$1; shift; jrun "$j" "$PIMCTL" -u "$WORKDIR/$j.sock" "$@"; }

# Retry a command until it succeeds or $1 seconds have passed.  PIM is
# slow by design (hello 30s, bootstrap 60s; shortened in the configs
# below), so every assertion polls instead of sleeping a fixed amount.
wait_for() {
	timeout=$1
	shift
	while [ "$timeout" -gt 0 ]; do
		if "$@" >/dev/null 2>&1; then
			return 0
		fi
		sleep 1
		timeout=$((timeout - 1))
	done
	return 1
}

check_req() {
	[ "$(id -u)" -eq 0 ] || ${SUDO} -n true 2>/dev/null || \
		die "need root or passwordless sudo"
	[ "$(sysctl -n kern.features.vimage 2>/dev/null || echo 0)" = "1" ] || \
		die "kernel has no VIMAGE support, cannot create vnet jails"
	[ -x "$PIMD" ] || die "$PIMD not found, build it first (PIMD_SRC=$PIMD_SRC)"
	[ -x "$PIMCTL" ] || die "$PIMCTL not found, build it first"
	[ -f "$PIMD_SRC/test/mping.c" ] || die "$PIMD_SRC/test/mping.c not found"
	# ip_mroute is a module on GENERIC and a jail may not kldload
	${SUDO} kldload -n ip_mroute 2>/dev/null || \
		die "cannot load ip_mroute.ko, kernel has no multicast routing"
}

# net.inet.ip.mcast.loop must be 0 for any PIM router on FreeBSD.
#
# phyint_send() in sys/netinet/ip_mroute.c copies the sysctl into every
# packet it forwards (imo.imo_multicast_loop = !!in_mcast_loop), and
# ip_output() then loops that packet straight back into ip_input() -
# "even if we are not a member of the group".  The router therefore
# receives its own forwarded traffic on the interface it just sent it
# out of, ip_mdq() raises IGMPMSG_WRONGVIF for it, and pimd answers the
# wrong-iif upcall with a PIM Assert.  The neighbour asserts back, pimd
# loses the election against itself and prunes the oif, which installs an
# MFC entry with an empty outgoing interface list and black-holes the
# group.  Measured here: 4 of 60 packets delivered with the sysctl at its
# default of 1, 40 of 40 with it set to 0.
#
# The sysctl is a plain global, not VNET-ized (in_mcast_loop in
# sys/netinet/in_mcast.c has no CTLFLAG_VNET), so it cannot be set per
# jail: the value has to be changed on the host, and is restored by stop.
MCAST_LOOP_SAVED="$WORKDIR/mcast_loop.saved"

disable_mcast_loop() {
	sysctl -n net.inet.ip.mcast.loop > "$MCAST_LOOP_SAVED"
	${SUDO} sysctl -q net.inet.ip.mcast.loop=0
}

restore_mcast_loop() {
	[ -f "$MCAST_LOOP_SAVED" ] || return 0
	${SUDO} sysctl -q net.inet.ip.mcast.loop="$(cat "$MCAST_LOOP_SAVED")"
}

# R2 is the only BSR and RP candidate, pinned to its 10.0.12.2 address so
# the RP address does not depend on interface ordering.  The intervals are
# the RFC minimum (10s) rather than the 60s default, and spt-threshold is
# low, so the lab converges in tens of seconds instead of minutes.
# spt-threshold is deliberately left at the pimd default (switch to the
# shortest path tree on the first packet).  Setting it to a non-zero
# packet count instead makes the routers switch away from the shared tree
# in the middle of the measured stream, and the traffic then stalls for
# one Join/Prune period (~60s) before it recovers - real behaviour, but it
# belongs in an SPT-specific test, not in this one.
#
# The keepalive scenario moves both candidacies to R1, so the router that
# is DR for $SRC_ADDR is also the RP for the groups that source sends to.
# It also asks for spt-threshold infinity, like the pimd.conf in issue
# #251, to keep the RP on the shared tree.
write_configs() {
	if [ "$SCENARIO" = keepalive ]; then
		cat <<-EOF > "$WORKDIR/r1.conf"
		# R1: DR for $SRC_ADDR *and* RP for the groups it sends to
		spt-threshold infinity
		bsr-candidate epair101b priority 1 interval 10
		rp-candidate epair101b priority 20 interval 10
		group-prefix 224.0.0.0 masklen 4
		EOF

		: > "$WORKDIR/r2.conf"
		: > "$WORKDIR/r3.conf"
		return
	fi

	cat <<-EOF > "$WORKDIR/r1.conf"
	# R1: first hop router for $SRC_ADDR, no BSR/RP role
	EOF

	cat <<-EOF > "$WORKDIR/r2.conf"
	# R2: bootstrap router and rendezvous point for all of 224.0.0.0/4
	# Epair112b is spelled with an uppercase letter on purpose, see renames()
	bsr-candidate Epair112b priority 1 interval 10
	rp-candidate Epair112b priority 20 interval 10
	group-prefix 224.0.0.0 masklen 4
	EOF

	cat <<-EOF > "$WORKDIR/r3.conf"
	# R3: last hop router for the receiver LAN
	EOF
}

# A sender that never joins anything: sends $KEEP_NUM UDP streams to
# consecutive groups starting at $KEEP_GROUP, five packets per second
# each, until it is killed.
build_msend() {
	cat <<-'EOF' > "$WORKDIR/msend.c"
	#include <arpa/inet.h>
	#include <netinet/in.h>
	#include <stdio.h>
	#include <stdlib.h>
	#include <string.h>
	#include <sys/socket.h>
	#include <time.h>

	int main(int argc, char *argv[])
	{
		struct sockaddr_in sin;
		struct in_addr ifa;
		unsigned char ttl = 5;
		char buf[64] = "msend";
		uint32_t base;
		int sd, i, num;

		if (argc != 4) {
			fprintf(stderr, "usage: %s <src-ip> <first-group> <num>\n", argv[0]);
			return 1;
		}

		if (inet_pton(AF_INET, argv[1], &ifa) != 1)
			return 1;
		if (inet_pton(AF_INET, argv[2], &sin.sin_addr) != 1)
			return 1;
		base = ntohl(sin.sin_addr.s_addr);
		num = atoi(argv[3]);

		sd = socket(AF_INET, SOCK_DGRAM, 0);
		if (sd < 0)
			return 1;
		if (setsockopt(sd, IPPROTO_IP, IP_MULTICAST_IF, &ifa, sizeof(ifa)))
			return 1;
		setsockopt(sd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, sizeof(ttl));

		memset(&sin, 0, sizeof(sin));
		sin.sin_family = AF_INET;
		sin.sin_port = htons(4321);

		while (1) {
			struct timespec ts = { 0, 200000000L };

			for (i = 0; i < num; i++) {
				sin.sin_addr.s_addr = htonl(base + i);
				sendto(sd, buf, sizeof(buf), 0,
				       (struct sockaddr *)&sin, sizeof(sin));
			}
			nanosleep(&ts, NULL);
		}

		return 0;
	}
	EOF

	cc -O2 -o "$MSEND" "$WORKDIR/msend.c" || die "failed building $WORKDIR/msend.c"
}

create_box() {
	box=$1
	name=$(jname "$box")

	if [ "$(jls -d -j "$name" dying 2>/dev/null || true)" = "true" ]; then
		die "previous jail $name stuck dying, see FreeBSD bug 264981"
	fi

	set -- $(ifaces "$box")
	vnetargs=""
	for i in "$@"; do
		# The "a" end creates both ends of the pair
		case $i in
		*a) ${SUDO} ifconfig "${i%a}" create group pimd >/dev/null ;;
		esac
		vnetargs="$vnetargs vnet.interface=$i"
	done

	# shellcheck disable=SC2086
	${SUDO} jail -c name="$name" host.hostname="$box" persist vnet $vnetargs

	set -- $(renames "$box")
	while [ $# -ge 2 ]; do
		jrun "$box" ifconfig "$1" name "$2"
		shift 2
	done

	set -- $(addrs "$box")
	while [ $# -ge 2 ]; do
		jrun "$box" ifconfig "$1" inet "$2" up
		shift 2
	done

	set -- $(routes "$box")
	while [ $# -ge 2 ]; do
		jrun "$box" route -q add "$1" "$2" >/dev/null
		shift 2
	done

	case $box in
	r*) jrun "$box" sysctl -q net.inet.ip.forwarding=1 >/dev/null ;;
	esac
}

destroy_box() {
	box=$1
	name=$(jname "$box")

	jls -j "$name" jid >/dev/null 2>&1 || return 0
	${SUDO} jail -r "$name" 2>/dev/null || true
}

start() {
	check_req

	if jls -j "$(jname r1)" jid >/dev/null 2>&1; then
		die "lab already running, run '$0 stop' first"
	fi

	# Owned by the invoking user: pimd runs as root and can still drop its
	# PID file and control socket in here, but mping is built unprivileged.
	mkdir -p "$WORKDIR"

	print "Building mping (multicast ping) from the pimd tree ..."
	cc -O2 -o "$MPING" "$PIMD_SRC/test/mping.c" || \
		die "failed building $PIMD_SRC/test/mping.c"

	print "Disabling multicast loopback on the host (restored by stop) ..."
	disable_mcast_loop

	print "Creating vnet jails and links ..."
	write_configs
	for box in $BOXES; do
		create_box "$box"
	done

	print "Starting pimd on R1, R2 and R3 ..."
	for r in $ROUTERS; do
		# shellcheck disable=SC2086
		${SUDO} daemon -f -p "$WORKDIR/$r.daemon.pid" \
			-o "$WORKDIR/$r.log" \
			jexec "$(jname "$r")" "$PIMD" -i "$r" -n $DEBUG \
			-f "$WORKDIR/$r.conf" \
			-p "$WORKDIR/$r.pid" \
			-u "$WORKDIR/$r.sock"
	done

	if [ "$SCENARIO" = keepalive ]; then
		print "Starting the source on ED1, $KEEP_NUM groups from $KEEP_GROUP ..."
		build_msend
		${SUDO} daemon -f -p "$WORKDIR/msend.pid" -o "$WORKDIR/msend.log" \
			jexec "$(jname ed1)" "$MSEND" "$SRC_ADDR" "$KEEP_GROUP" "$KEEP_NUM"
	fi

	print "Lab is up ($SCENARIO).  Poke at it with:"
	echo "  ${SUDO} jexec $(jname r2) $PIMCTL -u $WORKDIR/r2.sock show pim detail"
	echo "  ${SUDO} jexec $(jname r3) netstat -gn"
	echo "  ${SUDO} jexec $(jname ed2) $MPING -r -i epair203b $GROUP"
	echo "  tail -f $WORKDIR/r1.log"
}

# --- assertions -------------------------------------------------------

has_neighbor() { pimctl "$1" show neighbor 2>/dev/null | grep -q "$2"; }
has_rp()       { pimctl "$1" show rp 2>/dev/null | grep -q "$2"; }
has_mrt()      { pimctl "$1" show mrt 2>/dev/null | grep -q "$2"; }
has_mfc()      { jrun "$1" netstat -gn 2>/dev/null | grep -q "$2"; }

# Every (S,G) the source is sending to, one per line, as pimctl shows them
sources() { pimctl r1 show mrt 2>/dev/null | awk -v s="$SRC_ADDR" '$1 == s { print $2 }'; }
all_sources_up() { [ "$(sources | wc -l)" -eq "$KEEP_NUM" ]; }

# "<group> <entry timer>" per (S,G), read out of the detailed dump.  The
# entry timer is the only reliable witness: an entry that is recreated by
# the next cache miss 1.5s later looks exactly like one that was never
# deleted if all you count is table rows, but a recreated entry always
# comes back with its timer at 0.
source_timers() {
	pimctl r1 show mrt detail 2>/dev/null | awk -v s="$SRC_ADDR" '
		$1 == s   { grp = $2; next }
		grp == "" { next }
		/TIMERS/  { want = 1; next }
		want      { print grp, $1; grp = ""; want = 0 }
	'
}

check() {
	jls -j "$(jname r1)" jid >/dev/null 2>&1 || die "lab is not running, run '$0 start'"

	case $SCENARIO in
	keepalive) check_keepalive; return $? ;;
	esac

	print "1. pimd is alive on every router"
	for r in $ROUTERS; do
		if pimctl "$r" show status >/dev/null 2>&1; then
			ok "$r: pimd answers on its pimctl socket"
		else
			fail "$r: pimd not answering, see $WORKDIR/$r.log"
		fi
	done
	[ "$FAILED" -eq 0 ] || return 1

	print "2. PIM neighbors are discovered over the epairs"
	if wait_for 60 has_neighbor r1 10.0.12.2; then
		ok "r1 sees r2 (10.0.12.2)"
	else
		fail "r1 never saw r2, PIM hello is not crossing epair112"
	fi
	if wait_for 60 has_neighbor r2 10.0.23.3; then
		ok "r2 sees r3 (10.0.23.3)"
	else
		fail "r2 never saw r3, PIM hello is not crossing epair123"
	fi
	if wait_for 60 has_neighbor r3 10.0.23.2; then
		ok "r3 sees r2 (10.0.23.2)"
	else
		fail "r3 never saw r2"
	fi

	print "3. The RP set is distributed by the bootstrap router"
	for r in $ROUTERS; do
		if wait_for 90 has_rp "$r" "$RP_ADDR"; then
			ok "$r learned RP $RP_ADDR"
		else
			fail "$r never learned RP $RP_ADDR (BSR/cand-RP path)"
		fi
	done

	# mping echoes every packet back to the group, so a reply proves both
	# the (10.0.1.10,G) tree towards ED2 and the (10.0.3.10,G) tree back.
	# Its own exit code demands *every* packet be answered, which no PIM
	# network can do while it is still converging - the first packets are
	# what builds the tree.  Count the replies instead and require the
	# stream to be flowing rather than perfect.
	print "4. Multicast is forwarded from ED1 to ED2 through the RP"
	jrun ed2 "$MPING" -r -i epair203b -t 5 -W 90 "$GROUP" \
		>"$WORKDIR/receiver.log" 2>&1 &
	receiver=$!
	sleep 2
	jrun ed1 "$MPING" -s -i epair101a -t 5 -c 40 -w 60 "$GROUP" \
		>"$WORKDIR/sender.log" 2>&1 || true
	kill "$receiver" 2>/dev/null || true
	wait "$receiver" 2>/dev/null || true

	replies=$(awk '/packets transmitted/ { print $4 }' "$WORKDIR/sender.log")
	replies=${replies:-0}
	if [ "$replies" -ge "$MIN_REPLIES" ]; then
		ok "ED1 -> $GROUP -> ED2, $replies replies"
	else
		fail "only $replies replies, want >= $MIN_REPLIES, see $WORKDIR/sender.log"
	fi

	print "5. pimd installed the route it claims to have"
	if has_mrt r3 "$GROUP"; then
		ok "r3 has $GROUP in its multicast routing table"
	else
		fail "r3 has no $GROUP entry in 'pimctl show mrt'"
	fi
	if has_mrt r1 "$SRC_ADDR"; then
		ok "r1 has an (S,G) for source $SRC_ADDR"
	else
		fail "r1 has no (S,G) for $SRC_ADDR"
	fi

	print "6. The kernel MFC in each vnet agrees with pimd"
	if has_mfc r3 "$GROUP"; then
		ok "r3 kernel has an MFC entry for $GROUP"
	else
		fail "r3 kernel MFC is empty, pimd never pushed the route down"
	fi
	if has_mfc r1 "$GROUP"; then
		ok "r1 kernel has an MFC entry for $GROUP"
	else
		fail "r1 kernel MFC is empty"
	fi

	echo
	if [ "$FAILED" -eq 0 ]; then
		print "RESULT: PASS"
		return 0
	fi
	print "RESULT: FAIL ($FAILED assertion(s))"
	for r in $ROUTERS; do
		dprint "--- $r: pimctl show pim detail ---"
		pimctl "$r" show pim detail 2>&1 | tail -40 || true
	done
	return 1
}

# Issue #251: R1 is the DR for the directly connected source and the RP
# for the groups it sends to, and nobody ever joins them, so the (S,G)
# entries have an empty outgoing interface list and no kernel MFC entry.
# Their only sign of life is the IGMPMSG_NOCACHE upcall the kernel raises
# every UPCALL_EXPIRE (1.5s on FreeBSD), and process_cache_miss() has to
# restart the entry timer from it.  When it does not, age_routes() deletes
# each entry within one TIMER_INTERVAL of its creation and the table
# content is different every time you look at it.
check_keepalive() {
	print "1. pimd is alive on R1"
	if pimctl r1 show status >/dev/null 2>&1; then
		ok "r1: pimd answers on its pimctl socket"
	else
		fail "r1: pimd not answering, see $WORKDIR/r1.log"
		return 1
	fi

	print "2. R1 elected itself RP for the groups its source sends to"
	if wait_for 90 has_rp r1 10.0.1.1; then
		ok "r1 is the RP (10.0.1.1)"
	else
		fail "r1 never became RP, see $WORKDIR/r1.log"
		return 1
	fi

	print "3. R1 learns all $KEEP_NUM sources"
	if wait_for 60 all_sources_up; then
		ok "r1 has (S,G) entries for $(sources | tr '\n' ' ')"
	else
		fail "r1 only has $(sources | wc -l | tr -d ' ')/$KEEP_NUM (S,G) entries"
		return 1
	fi

	print "4. The sources stay put for ${KEEP_SECONDS}s while they keep sending"
	deadline=$(($(date +%s) + KEEP_SECONDS))
	samples=0
	missing=0
	dead=0
	worst=$KEEP_NUM
	while [ "$(date +%s)" -lt "$deadline" ]; do
		timers=$(source_timers)
		n=$(echo "$timers" | grep -c . || true)
		samples=$((samples + 1))

		if [ "$n" -ne "$KEEP_NUM" ]; then
			missing=$((missing + 1))
			[ "$n" -lt "$worst" ] && worst=$n
		fi

		# An entry whose keepalive timer is 0 is one age_routes()
		# run away from being deleted, however fast the next cache
		# miss brings it back
		if echo "$timers" | awk '$2 == 0 { found = 1 } END { exit !found }'; then
			dead=$((dead + 1))
		fi

		sleep 5
	done

	if [ "$missing" -eq 0 ]; then
		ok "all $KEEP_NUM sources present in every one of $samples samples"
	else
		fail "sources vanished in $missing of $samples samples, down to $worst/$KEEP_NUM"
	fi

	if [ "$dead" -eq 0 ]; then
		ok "every (S,G) kept a running entry timer in all $samples samples"
	else
		fail "(S,G) entry timer was 0, so the entry was being deleted and recreated, in $dead of $samples samples"
	fi

	if [ "$FAILED" -ne 0 ]; then
		dprint "--- r1: pimctl show mrt detail ---"
		pimctl r1 show mrt detail 2>&1 | tail -40 || true
		dprint "--- cache misses logged on r1: $(${SUDO} grep -c "Cache miss" "$WORKDIR/r1.log" 2>/dev/null || echo 0) ---"
	fi

	echo
	if [ "$FAILED" -eq 0 ]; then
		print "RESULT: PASS"
		return 0
	fi
	print "RESULT: FAIL ($FAILED assertion(s))"
	return 1
}

stop() {
	for r in $ROUTERS; do
		[ -f "$WORKDIR/$r.pid" ] && \
			${SUDO} pkill -F "$WORKDIR/$r.pid" 2>/dev/null || true
	done
	${SUDO} pkill -f "$PIMD -i" 2>/dev/null || true
	${SUDO} pkill -f "$MPING" 2>/dev/null || true
	${SUDO} pkill -f "$MSEND" 2>/dev/null || true

	for box in $BOXES; do
		destroy_box "$box"
	done

	# Jails can linger in the dying state and hold their interfaces
	sleep 1
	for e in $EPAIRS; do
		for end in a b; do
			${SUDO} ifconfig "$e$end" destroy 2>/dev/null || true
		done
		${SUDO} ifconfig "$e" destroy 2>/dev/null || true
	done

	restore_mcast_loop
	${SUDO} rm -rf "$WORKDIR"
}

run_one() {
	rc=0
	start
	check || rc=$?
	if [ "$rc" -ne 0 ]; then
		# stop() wipes the work directory, keep what failed
		saved="$WORKDIR.$SCENARIO.failed"
		${SUDO} rm -rf "$saved"
		${SUDO} cp -a "$WORKDIR" "$saved" 2>/dev/null || true
		echo "pimd logs and traffic captures kept in $saved"
	fi
	stop
	return $rc
}

run() {
	rc=0

	if [ "${1:-}" = all ]; then
		for s in rpt keepalive; do
			set_scenario "$s"
			print "===== scenario: $s ====="
			run_one || rc=$?
		done
		exit $rc
	fi

	set_scenario "${1:-}"
	run_one || rc=$?
	exit $rc
}

if [ $# -eq 0 ]; then
	usage
	exit 2
fi

cmd=$1
shift
case $cmd in
start|check) set_scenario "${1:-}"; $cmd ;;
run)         run "${1:-}" ;;
stop)        stop ;;
*)           usage; exit 2 ;;
esac
