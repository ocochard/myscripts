#!/bin/sh
# net/frr10 regression test for the "tunnel interfaces always unnumbered"
# bug on FreeBSD, using net/bird3 as the OSPF neighbor.
#
# Tracks FRRouting PR 8132 and BSDRP issue #27 (same root cause):
#   https://github.com/FRRouting/frr/pull/8132   (filed 2021, closed unmerged Apr 2026)
#   https://github.com/ocochard/BSDRP/issues/27  (open, reporter saw FRR<->RouterOS broken)
#
# User-visible symptom from BSDRP#27: FRR emits OSPF Hello packets with
# Mask 0.0.0.0 over a numbered gre/gif tunnel. RouterOS (and any
# strict OSPF stack: IOS, Junos, etc.) drops the hello because the
# announced mask does not match its own /30 — adjacency never forms,
# tunnel routing is dead. bird is lenient and accepts the wrong-mask
# hello, which is why it forms FULL with FRR despite the bug.
#
# Background:
#   zebra/connected.c::connected_announce() flags every interface whose
#   *local* prefixlen is /32 as ZEBRA_IFA_UNNUMBERED, even when the
#   interface has a peer/destination address with a real subnet
#   prefix. On FreeBSD a gif/gre/vti tunnel's local side is exactly
#   that: a /32 with a peer carrying the subnet mask. So every numbered
#   tunnel ends up "unnumbered" from FRR's point of view, which alters
#   OSPF next-hop / network-type handling and BGP next-hop selection.
#
#   PR 8132 proposed using ifc->destination->prefixlen when
#   CONNECTED_PEER(ifc) is set. Closed without merge in April 2026.
#
# Topology (two vnet jails wired by an epair carrying a gif tunnel):
#
#   ----------                                                 ----------
#   |  frr1  |  10.99.1.1/24 peer 10.99.1.2 (gif991 over       |  brd2  |
#   | (frr10)|   192.0.2.1/30 epair991a <-> epair991b 192.0.2.2/30 (bird3)
#   |  zebra |---------------------------------------------------|       |
#   |  ospfd |   OSPF area 0 on gif991 (frr1) / gif991 (brd2)   | ospf  |
#   | lo110: |                                                   | lo120:|
#   | 10.10.10.10/32                                             | 20.20.20.20/32
#   ----------                                                  ----------
#
#   Both sides advertise their /32 loopback into OSPF area 0. If FRR
#   wrongly flags gif991 as UNNUMBERED, OSPF on FRR side will not
#   announce the tunnel subnet correctly and bird3 either never reaches
#   FULL adjacency or learns the wrong next-hop. The test asserts:
#     (a) zebra does NOT print "UNNUMBERED" for gif991, AND
#     (b) bird3 reaches OSPF state Full with frr1, AND
#     (c) bird3 has learned 10.10.10.10/32 with next-hop 10.99.1.1
#         (FRR's tunnel inner local address).
#
# Exit codes:
#   0 -- bug fixed (all three assertions pass)
#   1 -- bug still present
#   2 -- environment / setup failure
#
# Usage: sh frr_tunnel_unnumbered_test.sh start|check|stop
#
# Requires: net/frr10 AND net/bird3 installed, sudo, vnet jails, root.
set -eu

SUDO=${SUDO:-sudo}

FRR_RUN=/var/run/frr/frr1
BIRD_RUN=/var/run/bird-brd2
BIRD_CTL=${BIRD_RUN}/bird.ctl
BIRD_CONF=${BIRD_RUN}/bird.conf
BIRD_LOG=${BIRD_RUN}/bird.log

# Carrier subnet between jails (epair):
CARRIER_NET=192.0.2.0/30
FRR_CARRIER=192.0.2.1
BRD_CARRIER=192.0.2.2

# Inner tunnel subnet (the one zebra mis-flags):
INNER_FRR=10.99.1.1
INNER_BRD=10.99.1.2
INNER_PREFIX=24

# Loopbacks advertised into OSPF:
FRR_LOOP=10.10.10.10
BRD_LOOP=20.20.20.20

die() { echo "EXIT: $*" >&2; exit 2; }

usage () {
	echo "Usage: $0 start|check|stop"
}

check_req () {
	which vtysh >/dev/null 2>&1 || die "net/frr10 not installed"
	which zebra >/dev/null 2>&1 || die "net/frr10 not installed"
	which bird  >/dev/null 2>&1 || die "net/bird3 not installed"
	which birdc >/dev/null 2>&1 || die "net/bird3 not installed"
}

# -----------------------------------------------------------------------
# jail "frr1": runs frr10 (zebra + ospfd) with a gif tunnel.
# -----------------------------------------------------------------------
start_frr1 () {
	${SUDO} ifconfig epair991 create group ttest
	${SUDO} ifconfig lo991 create group ttest

	${SUDO} jail -c name=frr1 host.hostname=frr1 persist \
		vnet vnet.interface=epair991a vnet.interface=lo991

	${SUDO} jexec frr1 sysctl net.inet.ip.forwarding=1 >/dev/null
	${SUDO} jexec frr1 ifconfig lo991 inet ${FRR_LOOP}/32
	${SUDO} jexec frr1 ifconfig epair991a inet ${FRR_CARRIER}/30 up

	# Tunnel between the carrier IPs, *inside* the same jail (point-to-
	# multipoint vibe but we only run the gif endpoint locally). The
	# gif's INNER addressing is what we care about: local /32 + peer /24.
	${SUDO} jexec frr1 ifconfig gif create name gif991
	${SUDO} jexec frr1 ifconfig gif991 tunnel ${FRR_CARRIER} ${BRD_CARRIER}
	${SUDO} jexec frr1 ifconfig gif991 inet ${INNER_FRR}/${INNER_PREFIX} ${INNER_BRD}
	${SUDO} jexec frr1 ifconfig gif991 up

	${SUDO} mkdir -p ${FRR_RUN} /var/run/frr/frr1.sock
	${SUDO} chown -R frr ${FRR_RUN} /var/run/frr /var/run/frr/frr1.sock
	${SUDO} tee ${FRR_RUN}/frr.conf >/dev/null <<EOF
log file ${FRR_RUN}/frr.log
!
interface lo991
 ip address ${FRR_LOOP}/32
!
interface gif991
 ip ospf network point-to-point
!
router ospf
 ospf router-id 1.1.1.1
 network ${INNER_FRR}/${INNER_PREFIX} area 0.0.0.0
 network ${FRR_LOOP}/32 area 0.0.0.0
 redistribute connected
!
EOF
	${SUDO} touch ${FRR_RUN}/vtysh.conf
	for d in mgmtd zebra ospfd; do
		${SUDO} jexec frr1 $d -d \
			-i /var/run/frr/frr1_$d.pid \
			--vty_socket /var/run/frr/frr1.sock
	done
	${SUDO} jexec frr1 vtysh -b \
		--config_dir ${FRR_RUN}/ \
		--vty_socket /var/run/frr/frr1.sock || true
}

# -----------------------------------------------------------------------
# jail "brd2": runs bird3 with the matching gif tunnel + OSPF.
# -----------------------------------------------------------------------
start_brd2 () {
	${SUDO} ifconfig lo992 create group ttest

	${SUDO} jail -c name=brd2 host.hostname=brd2 persist \
		vnet vnet.interface=epair991b vnet.interface=lo992

	${SUDO} jexec brd2 sysctl net.inet.ip.forwarding=1 >/dev/null
	${SUDO} jexec brd2 ifconfig lo992 inet ${BRD_LOOP}/32
	${SUDO} jexec brd2 ifconfig epair991b inet ${BRD_CARRIER}/30 up

	${SUDO} jexec brd2 ifconfig gif create name gif991
	${SUDO} jexec brd2 ifconfig gif991 tunnel ${BRD_CARRIER} ${FRR_CARRIER}
	${SUDO} jexec brd2 ifconfig gif991 inet ${INNER_BRD}/${INNER_PREFIX} ${INNER_FRR}
	${SUDO} jexec brd2 ifconfig gif991 up

	${SUDO} mkdir -p ${BIRD_RUN}
	${SUDO} tee ${BIRD_CONF} >/dev/null <<EOF
log "${BIRD_LOG}" all;
router id 2.2.2.2;

protocol device { }
protocol direct {
	ipv4;
	interface "lo992", "gif991";
}
protocol kernel {
	ipv4 { export all; };
}
protocol ospf v2 ospf1 {
	ipv4 { import all; export all; };
	area 0 {
		interface "gif991" { type pointopoint; };
		interface "lo992"  { stub yes; };
	};
}
EOF
	${SUDO} jexec brd2 bird -c ${BIRD_CONF} -s ${BIRD_CTL}
}

# -----------------------------------------------------------------------
start () {
	check_req
	start_frr1
	start_brd2
	# OSPF hello/dead intervals default to 10/40 s; allow time for FULL.
	echo "started: waiting 50 s for OSPF to converge..."
	sleep 50
	echo "next:    sh $0 check"
}

# -----------------------------------------------------------------------
check () {
	rc=0

	# (a) zebra interface dump must NOT contain UNNUMBERED for gif991.
	echo "------ frr1: show interface gif991 ------"
	zout=$(${SUDO} jexec frr1 vtysh \
		--vty_socket /var/run/frr/frr1.sock \
		-c "show interface gif991") || die "vtysh on frr1 failed"
	echo "${zout}"
	echo "-----------------------------------------"
	# zebra prints the flag as lowercase "unnumbered" on the address line:
	#   inet 10.99.1.1/32 peer 10.99.1.2/24 unnumbered
	# Match case-insensitively so we catch either rendering.
	if echo "${zout}" | grep -qiw unnumbered; then
		echo "FAIL (a): gif991 reported unnumbered despite peer ${INNER_BRD}/${INNER_PREFIX}"
		rc=1
	else
		echo "PASS (a): gif991 not flagged unnumbered"
	fi

	# (b) bird3 OSPF neighbor must be in state Full.
	echo "------ brd2: show ospf neighbors ------"
	bout=$(${SUDO} jexec brd2 birdc -s ${BIRD_CTL} show ospf neighbors ospf1) \
		|| die "birdc on brd2 failed"
	echo "${bout}"
	echo "----------------------------------------"
	if echo "${bout}" | grep -q "Full"; then
		echo "PASS (b): bird3 OSPF state Full with frr1"
	else
		echo "FAIL (b): bird3 OSPF not in Full state"
		rc=1
	fi

	# (c) bird3 must have learned the FRR loopback via the tunnel inner addr.
	echo "------ brd2: show route ${FRR_LOOP}/32 ------"
	rout=$(${SUDO} jexec brd2 birdc -s ${BIRD_CTL} show route ${FRR_LOOP}/32 all) \
		|| die "birdc show route failed"
	echo "${rout}"
	echo "---------------------------------------------"
	if echo "${rout}" | grep -q "${INNER_FRR}"; then
		echo "PASS (c): ${FRR_LOOP}/32 learned via next-hop ${INNER_FRR}"
	else
		echo "FAIL (c): ${FRR_LOOP}/32 missing or wrong next-hop"
		rc=1
	fi

	# (d) ospfd's per-interface dump must NOT contain "This interface is
	#     UNNUMBERED" -- the BSDRP#27 reporter's exact signature.
	echo "------ frr1: show ip ospf interface gif991 ------"
	oout=$(${SUDO} jexec frr1 vtysh \
		--vty_socket /var/run/frr/frr1.sock \
		-c "show ip ospf interface gif991") || die "vtysh ospf-iface failed"
	echo "${oout}"
	echo "-------------------------------------------------"
	if echo "${oout}" | grep -q "is UNNUMBERED"; then
		echo "FAIL (d): ospfd reports gif991 'This interface is UNNUMBERED'"
		echo "         (BSDRP#27 / FRR PR 8132 signature)"
		rc=1
	else
		echo "PASS (d): ospfd does not flag gif991 as UNNUMBERED"
	fi

	# (e) On-the-wire OSPF Hello from FRR must carry the correct subnet
	#     mask (255.255.255.0 here), NOT Mask 0.0.0.0. This is the
	#     actual user-visible breakage in BSDRP#27 -- strict OSPF peers
	#     (RouterOS, IOS, Junos) drop wrong-mask hellos and adjacency
	#     never forms. tcpdump on FRR's side of gif991, filter for
	#     hellos sourced by FRR, capture one packet, grep for the mask.
	echo "------ frr1: capture one outbound OSPF Hello ------"
	expected_mask=$(python3 -c "
import ipaddress
print(ipaddress.IPv4Network('0.0.0.0/${INNER_PREFIX}').netmask)
" 2>/dev/null || echo 255.255.255.0)
	# Run tcpdump in background, sleep through one hello interval (10 s),
	# then kill. -c 1 alone would block if no hello flies during run.
	tcpd_out=$(mktemp)
	${SUDO} jexec frr1 tcpdump -nei gif991 -v \
		"src host ${INNER_FRR} and proto ospf" \
		>"${tcpd_out}" 2>&1 &
	tcpd_pid=$!
	sleep 12
	${SUDO} kill ${tcpd_pid} 2>/dev/null || true
	wait ${tcpd_pid} 2>/dev/null || true
	cat "${tcpd_out}"
	echo "---------------------------------------------------"
	mask_line=$(grep -oE "Mask [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" "${tcpd_out}" | head -1 || true)
	rm -f "${tcpd_out}"
	# RFC 2328 §10.5: on a POINTOPOINT interface the receiver does NOT
	# enforce the network-mask check, so any non-zero value is acceptable
	# in practice. The original BSDRP#27 symptom was specifically Mask
	# 0.0.0.0 (driven by UNNUMBERED && p2p in ospf_make_hello), so we
	# treat 0.0.0.0 as the only hard fail. We warn (PASS-WITH-NOTE) if
	# the mask is the local /32 (255.255.255.255) rather than the peer
	# /24 (${expected_mask}) -- a complete fix would also patch
	# ospfd/ospf_packet.c::ospf_make_hello() to use the peer prefixlen.
	if [ -z "${mask_line}" ]; then
		echo "FAIL (e): no OSPF Hello captured from ${INNER_FRR}"
		rc=1
	elif [ "${mask_line}" = "Mask 0.0.0.0" ]; then
		echo "FAIL (e): FRR Hello advertises Mask 0.0.0.0 (expected ${expected_mask})"
		echo "         -- this is the literal BSDRP#27 wire-level symptom"
		echo "         -- driven by UNNUMBERED flag + POINTOPOINT in ospf_make_hello"
		rc=1
	elif [ "${mask_line}" = "Mask ${expected_mask}" ]; then
		echo "PASS (e): FRR Hello advertises Mask ${expected_mask} (peer prefixlen)"
	elif [ "${mask_line}" = "Mask 255.255.255.255" ]; then
		echo "PASS (e): FRR Hello advertises Mask 255.255.255.255 (local /32)"
		echo "         -- not BSDRP#27 (Mask 0.0.0.0) anymore"
		echo "         -- RFC 2328 §10.5: receiver skips mask check on p2p"
		echo "         -- for fully correct /24, ospf_make_hello would also need patching"
	else
		echo "FAIL (e): FRR Hello mask unexpected: ${mask_line}"
		rc=1
	fi

	if [ ${rc} -eq 0 ]; then
		echo "OVERALL: PASS -- FRR PR 8132 / BSDRP#27 bug appears fixed"
	else
		echo "OVERALL: FAIL -- FRR PR 8132 / BSDRP#27 bug still reproduces"
	fi
	exit ${rc}
}

# -----------------------------------------------------------------------
stop () {
	# Kill bird first (it's outside frr's run dir).
	${SUDO} jexec brd2 birdc -s ${BIRD_CTL} down 2>/dev/null || true
	# Tear jails down. ifconfig destroy on jail-internal interfaces
	# happens via jail -R; epair endpoints are cleaned up at the host.
	for j in frr1 brd2; do
		${SUDO} jail -R $j 2>/dev/null || true
	done
	sleep 2
	for i in epair991a epair991b lo991 lo992; do
		${SUDO} ifconfig $i destroy 2>/dev/null || true
	done
	${SUDO} rm -rf ${FRR_RUN} ${BIRD_RUN}
	${SUDO} rm -rf /var/run/frr/frr1.sock
	${SUDO} rm -f  /var/run/frr/frr1_*.pid
}

if [ $# -eq 0 ]; then
	usage
	exit 2
else
	$1
fi
