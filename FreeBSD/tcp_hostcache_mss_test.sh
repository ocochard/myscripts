#!/usr/local/bin/bash
#
# Regression test: a stale TCP hostcache MTU clamps the advertised MSS
#
# Reproduces the reported bug where a FreeBSD server whose path MTU is
# 9000 answers a SYN with "mss 1440" instead of "mss 8940", because a
# stale hostcache entry still holds MTU 1500 for that peer.
#
# ---------------------------------------------------------------------
# Mechanism (read out of sys/netinet on 16.0-CURRENT)
#
#   tcp_mssopt()                        sys/netinet/tcp_input.c:~3994
#       maxmtu = tcp_maxmtu6(inc, NULL);    /* 9000, live route/ifp */
#       thcmtu = tcp_hc_getmtu(inc);        /* 1500, from hostcache */
#       if (maxmtu && thcmtu)
#               mss = min(maxmtu, thcmtu) - min_protoh;
#
#   tcp_hc_getmtu()                     sys/netinet/tcp_hostcache.c:417
#       returns the cached hc_mtu verbatim; it is never revalidated
#       against the current interface or route MTU.
#
# Once hc_mtu is 1500, every later SYN-ACK to that peer is clamped to
#       1500 - sizeof(ip6_hdr) - sizeof(tcphdr) = 1500 - 40 - 20 = 1440
# even though the live path is 9000 again. That is the reported MSS.
#
# NOTE ON SCOPE -- read this before trusting the result.
#
# This test reproduces the *symptom*, not the reporter's cause. It shows
# that once hc_mtu is 1500, the SYN-ACK MSS is clamped to 1440 on a live
# 9000 path and nothing revalidates it. It does NOT explain how a 1500
# got into the reporter's cache.
#
# That gap matters, because the report describes no router and an
# end-to-end 9000 path, and this test uses a router. The router is
# scaffolding to manufacture the 1500 deterministically -- it is not a
# claim about the reporter's LAN.
#
# Why a router is unavoidable here. The only callers of
# tcp_hc_updatemtu() are the ICMPv6 PTB handler (tcp_subr.c:~3366), the
# ICMPv4 needfrag handler (~3174) and SCTP. Two further things were
# checked and ruled out by experiment:
#
#   * Connection teardown cannot write an MTU. tcp_discardcb()
#     (tcp_subr.c:~2521) bzero's its metrics and never sets hc_mtu, and
#     tcp_hc_update() only stores hc_mtu when non-zero (~550).
#   * Two hosts on one link cannot poison it either. Tried directly:
#     server link 9000, client link 1500, large transfer -- the
#     hostcache stayed EMPTY. A host does not run PMTUD against its own
#     link, so no PTB is generated and hc_mtu is never written.
#     (A route -mtu pin does not populate it either.)
#
# Conclusion, and the useful finding for the bug report: on a pure
# two-host 9000 path with nothing in between, FreeBSD CANNOT populate
# hc_mtu at all. The reporter's cache nevertheless holds 1500, so
# something on their path did emit an ICMPv6 PTB (tunnel, VPN, an L3
# hop, or a transient reconfiguration), or the entry outlived a topology
# change -- entries live 3600s, and note their EXP 3600. Their topology
# description is therefore incomplete; the kernel-side gap below is
# independent of which of those it was.
#
# ---------------------------------------------------------------------
# Topology: three vnet jails, because the bug needs a *router*. Two
# directly-connected hosts never exchange ICMPv6 "packet too big", so a
# 2-jail setup cannot populate the hostcache at all.
#
#   hcsrv                    hcrtr                     hccli
#   2001:db8:1::1/64 --- ::254 | ::254 --- 2001:db8:2::1/64
#        (9000)                |                    (9000)
#                     downstream link MTU is
#                     temporarily lowered to 1500
#
# Both host links stay at 9000 so the client advertises mss 8940 and the
# server therefore emits full-size segments. Lowering only the router's
# downstream link makes it a genuine mid-path bottleneck: the router
# generates a real ICMPv6 PTB(1500), and FreeBSD's PMTUD commits 1500 to
# the server's hostcache. Restoring the link to 9000 restores the L3
# path -- but not the cached value.
#
# Usage:
#   ./tcp_hostcache_mss_test.sh          # run the test
#   ./tcp_hostcache_mss_test.sh -k       # keep jails afterwards
#   ./tcp_hostcache_mss_test.sh -c       # clean leftovers and exit
#
# ("PTB" throughout = ICMPv6 Packet Too Big, type 2, RFC 8201: the
#  message a router sends back when a packet exceeds the next link's
#  MTU. IPv6 routers may not fragment, so this is how PMTUD learns.
#  The IPv4 equivalent is ICMP frag-needed, type 3 code 4.)
#
# Exit: 0 = no bug (MSS correct), 1 = bug reproduced, 2 = inconclusive.

set -euo pipefail

SRV=hcsrv
RTR=hcrtr
CLI=hccli

SRV_NET=2001:db8:1
CLI_NET=2001:db8:2
SRV_IP="${SRV_NET}::1"
SRV_GW="${SRV_NET}::254"
CLI_IP="${CLI_NET}::1"
CLI_GW="${CLI_NET}::254"

BIG_MTU=9000
SMALL_MTU=1500
PROTOH=60				# ip6_hdr(40) + tcphdr(20)
EXPECT_MSS=$((BIG_MTU - PROTOH))	# 8940
BUG_MSS=$((SMALL_MTU - PROTOH))		# 1440

KEEP=0
PORT_SEQ=5300
PCAP=$(mktemp -t hcmss)

# Progress goes to stderr: probe_mss() returns the MSS on stdout via
# $(...), so chatty stdout would be captured as the result.
msg()  { printf '\n=== %s\n' "$*" >&2; }
info() { printf '    %s\n' "$*" >&2; }

usage() {
	sed -n '3,/^$/p' "$0" | sed -n '/^#/p' | sed 's/^# \{0,1\}//'
	exit 0
}

purge_stale() {
	for j in "$SRV" "$RTR" "$CLI"; do
		jls -j "$j" >/dev/null 2>&1 && jail -r "$j" 2>/dev/null || true
	done
	sleep 1
	for e in $(ifconfig -g epair 2>/dev/null || true); do
		if ifconfig "$e" 2>/dev/null | grep -qE "2001:db8:(1|2)::"; then
			ifconfig "$e" destroy 2>/dev/null || true
		fi
	done
}

cleanup() {
	if [ "$KEEP" = 1 ]; then
		msg "keeping $SRV/$RTR/$CLI (-k); remove later with -c"
		rm -f "$PCAP"
		return
	fi
	msg "cleanup"
	for j in "$SRV" "$RTR" "$CLI"; do
		jls -j "$j" >/dev/null 2>&1 && jail -r "$j" 2>/dev/null || true
	done
	# Interfaces handed to a vnet jail come back to the host when the
	# jail dies, but not instantly -- destroying too early races the
	# teardown and leaks the pair. Wait for them to reappear, then
	# destroy the 'a' sides (which takes the 'b' peers with them).
	for _ in $(seq 1 30); do
		jls -j "$SRV" >/dev/null 2>&1 || jls -j "$RTR" >/dev/null 2>&1 || \
		jls -j "$CLI" >/dev/null 2>&1 || break
		sleep 0.2
	done
	sleep 1
	for e in ${EP_SRV:-} ${EP_CLI:-}; do
		ifconfig "$e" destroy 2>/dev/null || true
	done
	# Belt and braces: sweep anything of ours that survived the above.
	for e in $(ifconfig -g epair 2>/dev/null || true); do
		case " ${EP_SRV:-} ${EP_SRV_B:-} ${EP_CLI:-} ${EP_CLI_B:-} " in
		*" $e "*) ifconfig "$e" destroy 2>/dev/null || true ;;
		esac
	done
	rm -f "$PCAP"
}

while getopts kch opt; do
	case "$opt" in
	k) KEEP=1 ;;
	c) purge_stale; echo "leftovers cleaned"; exit 0 ;;
	h|*) usage ;;
	esac
done

[ "$(id -u)" = 0 ] || { echo "ERROR: must run as root" >&2; exit 1; }
[ "$(sysctl -n kern.features.vimage 2>/dev/null)" = 1 ] || \
	{ echo "ERROR: kernel lacks VIMAGE" >&2; exit 1; }
command -v tcpdump >/dev/null || { echo "ERROR: tcpdump missing" >&2; exit 1; }
kldstat -q -m if_epair || kldload if_epair

purge_stale
trap cleanup EXIT INT TERM

#
# 1. Topology
#
msg "creating topology: $SRV --($BIG_MTU)-- $RTR --($BIG_MTU)-- $CLI"

EP_SRV=$(ifconfig epair create); EP_SRV_B="${EP_SRV%a}b"
EP_CLI=$(ifconfig epair create); EP_CLI_B="${EP_CLI%a}b"
for i in "$EP_SRV" "$EP_SRV_B" "$EP_CLI" "$EP_CLI_B"; do ifconfig "$i" up; done

# path=/ : we only need the network stack; commands run from the host FS.
jail -c name="$SRV" host.hostname="$SRV" persist vnet \
	vnet.interface="$EP_SRV" path=/ >/dev/null
jail -c name="$RTR" host.hostname="$RTR" persist vnet \
	vnet.interface="$EP_SRV_B" vnet.interface="$EP_CLI" path=/ >/dev/null
jail -c name="$CLI" host.hostname="$CLI" persist vnet \
	vnet.interface="$EP_CLI_B" path=/ >/dev/null

for j in "$SRV" "$RTR" "$CLI"; do jexec "$j" ifconfig lo0 up; done

# Both host links at BIG_MTU so the client advertises the large MSS and
# the server actually emits full-size segments.
jexec "$SRV" ifconfig "$EP_SRV"   inet6 "${SRV_IP}/64"  mtu "$BIG_MTU" up
jexec "$RTR" ifconfig "$EP_SRV_B" inet6 "${SRV_GW}/64"  mtu "$BIG_MTU" up
jexec "$RTR" ifconfig "$EP_CLI"   inet6 "${CLI_GW}/64"  mtu "$BIG_MTU" up
jexec "$CLI" ifconfig "$EP_CLI_B" inet6 "${CLI_IP}/64"  mtu "$BIG_MTU" up

jexec "$RTR" sysctl -q net.inet6.ip6.forwarding=1 >/dev/null
jexec "$SRV" route -6 add default "$SRV_GW" >/dev/null
jexec "$CLI" route -6 add default "$CLI_GW" >/dev/null

# Wait out DAD, else the addresses are still tentative.
for _ in $(seq 1 60); do
	if ! jexec "$SRV" ifconfig "$EP_SRV" inet6 | grep -q tentative && \
	   ! jexec "$CLI" ifconfig "$EP_CLI_B" inet6 | grep -q tentative; then
		break
	fi
	sleep 0.1
done

jexec "$SRV" sysctl -q net.inet.tcp.hostcache.enable=1 >/dev/null
jexec "$SRV" sysctl -q net.inet.tcp.hostcache.purgenow=1 >/dev/null

jexec "$SRV" ping6 -c 2 -q "$CLI_IP" >/dev/null 2>&1 || \
	{ echo "ERROR: no connectivity across the router" >&2; exit 1; }
info "routed connectivity ok; server hostcache purged"

#
# Helpers
#
hc_line() {
	jexec "$SRV" sysctl -n net.inet.tcp.hostcache.list 2>/dev/null \
		| grep "$CLI_IP" || true
}

hc_mtu() {
	jexec "$SRV" sysctl -n net.inet.tcp.hostcache.list 2>/dev/null \
		| awk -v ip="$CLI_IP" '$1 == ip {print $2}' | head -1
}

show_hostcache() {
	local l; l=$(hc_line)
	[ -n "$l" ] && info "hostcache: $l" || info "hostcache: no entry for $CLI_IP"
}

# Advertised MSS in the server's SYN-ACK, captured on the client side so
# the server's stack is left untouched.
probe_mss() {
	local tag="$1" mss port
	PORT_SEQ=$((PORT_SEQ + 1)); port=$PORT_SEQ

	# NB: do NOT filter with "tcp[tcpflags] & tcp-syn" over IPv6. bpf
	# cannot compute a fixed TCP offset past variable-length extension
	# headers, and tcpdump rejects it outright ("expression rejects all
	# packets"), which silently captures nothing. Filter on the port and
	# select the SYN-ACK while parsing.
	jexec "$CLI" tcpdump -i "$EP_CLI_B" -c 4 -n -w "$PCAP" \
		"ip6 and tcp port $port" >/dev/null 2>&1 &
	local dumppid=$!
	sleep 1

	jexec "$SRV" sh -c "nc -6 -l $port >/dev/null 2>&1 &"
	sleep 0.5
	jexec "$CLI" nc -6 -w 2 -z "$SRV_IP" "$port" >/dev/null 2>&1 || true

	# Bounded wait: -c may never be reached, so never block on it.
	local i=0
	while kill -0 "$dumppid" 2>/dev/null && [ "$i" -lt 40 ]; do
		sleep 0.1; i=$((i + 1))
	done
	kill "$dumppid" 2>/dev/null || true
	wait "$dumppid" 2>/dev/null || true
	jexec "$SRV" pkill -f "nc -6 -l $port" 2>/dev/null || true

	mss=$(tcpdump -r "$PCAP" -n 2>/dev/null \
		| grep "${SRV_IP}\.${port} >" \
		| grep 'Flags \[S\.\]' \
		| sed -n 's/.*mss \([0-9]*\).*/\1/p' | head -1)
	[ -n "$mss" ] || mss="none"
	info "$tag: server advertised mss $mss"
	printf '%s\n' "$mss"
}

#
# 2. Baseline
#
msg "step 1: baseline on a clean hostcache"
show_hostcache
MSS_BEFORE=$(probe_mss "baseline")

#
# 3. Create a genuine mid-path bottleneck -> real ICMPv6 PTB
#
msg "step 2: shrinking the router downstream link to $SMALL_MTU"
jexec "$RTR" ifconfig "$EP_CLI" mtu "$SMALL_MTU"
info "router egress mtu = $SMALL_MTU (hosts still $BIG_MTU)"

# Server must push enough data to emit full-size segments and take the
# PTB. The client advertised mss 8940, so it will.
jexec "$CLI" sh -c "nc -6 -l 5299 >/dev/null 2>&1 &"
sleep 0.5
jexec "$SRV" sh -c \
	"dd if=/dev/zero bs=32k count=32 2>/dev/null | nc -6 -w 5 $CLI_IP 5299" \
	>/dev/null 2>&1 || true
sleep 1
jexec "$CLI" pkill -f "nc -6 -l 5299" 2>/dev/null || true

show_hostcache
PTB=$( (jexec "$RTR" netstat -sp icmp6 2>/dev/null || true) \
	| grep -i "packet too big" | head -1 | tr -s ' \t' ' ' || true)
info "router icmp6 PTB:${PTB:- none counted}"

POISONED=$(hc_mtu)
if [ "${POISONED:-0}" != "$SMALL_MTU" ]; then
	msg "INCONCLUSIVE"
	info "PMTUD did not commit $SMALL_MTU (hostcache mtu=${POISONED:-none})"
	info "without a poisoned entry there is nothing to regress on"
	exit 2
fi
info "hostcache poisoned with mtu $SMALL_MTU by a real ICMPv6 PTB"

#
# 4. Restore the full-MTU path
#
msg "step 3: restoring the router downstream link to $BIG_MTU"
jexec "$RTR" ifconfig "$EP_CLI" mtu "$BIG_MTU"
jexec "$SRV" ping6 -c 2 -q "$CLI_IP" >/dev/null 2>&1 || true
info "L3 path is $BIG_MTU end to end again"
show_hostcache

#
# 5. Verdict
#
msg "step 4: re-probing the advertised MSS on the restored path"
MSS_AFTER=$(probe_mss "after restore")

msg "result"
info "expected MSS on a $BIG_MTU path : $EXPECT_MSS"
info "baseline MSS                    : $MSS_BEFORE"
info "MSS after PTB + path restore    : $MSS_AFTER"
show_hostcache

if [ "$MSS_AFTER" = "none" ]; then
	echo "INCONCLUSIVE: no SYN-ACK captured (harness problem, not a verdict)." >&2
	exit 2
fi

if [ "$MSS_AFTER" = "$EXPECT_MSS" ]; then
	echo
	echo "PASS: server advertised mss $MSS_AFTER on the restored ${BIG_MTU} path."
	echo "      The stale hostcache entry did not clamp the MSS."
	exit 0
fi

echo
echo "FAIL: server advertised mss $MSS_AFTER, expected $EXPECT_MSS."
if [ "$MSS_AFTER" = "$BUG_MSS" ]; then
	echo
	echo "      $BUG_MSS == $SMALL_MTU - $PROTOH: the stale hostcache MTU is"
	echo "      clamping the SYN-ACK MSS even though the live path is $BIG_MTU."
	echo "      tcp_mssopt() takes min(maxmtu=$BIG_MTU, thcmtu=$SMALL_MTU), and"
	echo "      tcp_hc_getmtu() never revalidates hc_mtu against the current"
	echo "      interface/route MTU. This is the reported bug."
	echo
	echo "      Cross-check (the reporter's own workaround):"
	echo "        jexec $SRV sysctl net.inet.tcp.hostcache.enable=0"
	echo "        jexec $SRV sysctl net.inet.tcp.hostcache.purgenow=1"
	echo "      then re-probe: the MSS returns to $EXPECT_MSS."
fi
exit 1
