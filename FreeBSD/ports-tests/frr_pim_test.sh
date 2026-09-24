#!/bin/sh
# net/frr10 PIM-SM regression lab: does FRR's pimd actually route multicast
# on FreeBSD?
#
# The port disabled pimd for years with the comment "PIMD and PBRD compile
# but doesn't work on FreeBSD", so enabling it needs more than a build: the
# question is whether the daemon drives FreeBSD's ip_mroute(4) to the point
# where a packet sent by a host on one LAN comes out on another.  Nothing
# short of a real data-plane check answers that, because every piece of PIM
# state FRR prints is FRR's own opinion of what it asked the kernel for.
#
# So this lab asserts in two registers.  Assertions (a)-(e) read FRR's view
# (neighbors, RP, IGMP, the shared tree, the Register), which is what tells
# a human *where* a failure is.  Assertions (f) and (g) read the kernel's:
# netstat -g for the multicast forwarding cache the daemon installed, and a
# receiver counting UDP packets that a sender three hops away emitted.  (g)
# is the only one that cannot pass by accident.
#
# Topology, one vnet jail per box, all links /24, unicast routing static so
# that a multicast failure is never a unicast failure in disguise:
#
#   src            r1              r2              r3            rcv
#  (sender)       (FHR)        (RP, static)       (LHR)       (receiver)
#     |             |               |               |             |
#     +-10.60.1.0/24+-10.60.12.0/24-+-10.60.23.0/24-+-10.60.3.0/24+
#     .10         .1  .1          .2  .2          .3  .1        .10
#     epair960a/b     epair961a/b     epair962a/b     epair963a/b
#                                 lo960
#                             10.60.255.2/32  <- the RP address
#
#   src and rcv run no routing daemon at all: they are hosts, and the only
#   thing asked of them is that one sends to 239.60.1.1:5601 and the other
#   joins the group and counts what arrives.  r1/r2/r3 run mgmtd + zebra +
#   pimd.  The RP lives on a loopback in r2 rather than on a link, so that
#   reaching it exercises the unicast RPF lookup the Register needs.
#
# Two pieces of host state this needs, both given back by "stop":
#
#   ip_mroute.ko   a jail cannot kldload, and sys/netinet/ip_mroute.c is
#                  VNET-ized, so the host loads it once and every jail gets
#                  its own forwarding cache.
#
#   net.inet.ip.mcast.loop=0   NOT VNET-ized, hence a host global.  Left at
#                  1, a router loops every packet it forwards back into
#                  ip_input(), the copy arrives on the wrong vif, and the
#                  kernel answers with a WRONGVIF upcall; the same trap
#                  costs the net/pimd lab 36 of 40 packets (see the note in
#                  ~/pimd/test/lab.sh).  The sender sets IP_MULTICAST_LOOP
#                  off for its own socket, but that says nothing about what
#                  r1/r2/r3 do with a packet they forward.
#
# Exit codes:
#   0 -- PIM-SM works: every assertion passed
#   1 -- at least one assertion failed (check prints which, and its evidence)
#   2 -- environment / setup failure
#
# Usage: sh frr_pim_test.sh start|check|stop|run [scenario]
#
#   run = start, check, stop, propagating check's exit code.  start leaves
#   the lab up for hand inspection; the hints it prints are what to type.
#   "run all" walks every scenario in turn and fails if any of them does.
#
# Scenarios, and what each one is for:
#
#   rpt         (default) The five boxes in a line, as drawn above.  The last
#               hop router reaches both the RP and the source through the same
#               interface, which is the easy case and the one that shook out
#               the four defects listed below.
#
#   rp-offpath  The same boxes, plus a direct r1-r3 link, and unicast routing
#               arranged so that r3 reaches the *source* over that link while
#               it reaches the *RP* through r2.  Traffic down the shared tree
#               therefore arrives on an interface that is not the RPF
#               interface towards the source -- ordinary PIM-SM, and the case
#               the rpt scenario cannot produce because there the two
#               coincide.  r3 additionally has spt-switchover set to
#               infinity-and-beyond, so the shared tree is the only path and a
#               router that quietly drops RPT traffic cannot be rescued by
#               switching to the source tree a moment later.
#
#               This is the shape greptile flagged on FRR PR #23455: a
#               NOCACHE upcall for a source whose RPF interface is not the one
#               the packet came in on.  Whatever happens here is what happens
#               to every real network where the RP is not on the shortest path
#               to the sources.
#
# What this lab found on 16.0-CURRENT with frr 10.7.1.  PIM-SM did not work on
# FreeBSD for four separate reasons, none of which a build or a "show" command
# would have surfaced; all four are patched in the port, and all twelve
# assertions pass as of frr10-10.7.1_7.  Each entry below is what the lab
# reported, and check still names any of them from the logs and the kernel's
# counters if you run it against a build that lacks the fix.
#
#   1. pimd could not bind its IGMP socket at all, on any interface:
#        "Could not bind IGMP socket for 10.60.3.1 on epair963a:
#         Can't assign requested address(49)"
#      pim_igmp_sock_add() (pimd/pim_igmp.c) binds a raw IGMP socket with a
#      struct sockaddr_in it never zeroes.  FreeBSD's rip_bind() resolves the
#      address with ifa_ifwithaddr_fib_check(), which compares all sa_len
#      bytes (sa_equal(), sys/net/route.h), sin_zero included -- so stack
#      garbage there makes the lookup miss a perfectly local address.  Linux
#      compares sin_addr only, which is why upstream never saw it.
#      files/patch-pimd_pim__igmp.c, one memset.
#
#   2. ... and it still heard nothing back.  FRR does not parse IGMP from
#      those per-interface sockets at all (pim_igmp_read() drains and
#      discards); the packets it acts on arrive on the *mroute* socket, where
#      pim_mroute_msg() dispatches IPPROTO_IGMP to process_igmp_packet(buf,
#      ifindex).  pim_mroute_set() asked for that ifindex with IP_PKTINFO
#      only -- no BSD IP_RECVIF branch, unlike pim_socket_mcast() which sets
#      both, which is why adjacency worked while IGMP did not.  ifindex
#      stayed -1, if_lookup_by_index(-1) returned NULL, every report dropped
#      without a log line.  Gained (c), (d) and the MFC on the RP and LHR.
#
#   3. No register vif, so no Register.  pimreg is an internal pseudo
#      interface (pim_if_create_pimreg(), hardcoded vif index 0) with no
#      address of its own, and BSD adds a vif by local address:
#      pim_mroute_add_vif() bailed with "unnumbered interfaces are not
#      supported on this platform", so the FHR dropped its (S,G) traffic into
#      a vif that did not exist.  Lending the register vif another PIM
#      interface's address, the way net/pimd's update_reg_vif() does, gets the
#      kernel to create it and to raise the IGMPMSG_WHOLEPKT upcall FRR
#      already handles.  Then the Register still went nowhere: pim_msg_send()
#      builds its own IP header and pim_reg_sock() creates the socket with
#      IPPROTO_RAW, which implies IP_HDRINCL on Linux but not on BSD, so
#      rip_output() prepended a second header and every Register left as IP
#      protocol 255 with the RP answering "protocol 255 unreachable".
#      files/patch-pimd_pim__sock.c, one IP_HDRINCL.  Gained (e2).
#
#   4. The data plane then stopped one hop short of the receiver.  BSD's
#      mfc_find() matches the source exactly (in_hosteq(),
#      sys/netinet/ip_mroute.c): there is no wildcard mfc, so the (*,G) entry
#      forwards nothing and the kernel raises a NOCACHE for each new source
#      instead.  pim_mroute_nocache_forward_existing() returned early when
#      there was no (S,G) upstream -- the normal state on a last hop router
#      whose receivers joined (*,G) -- leaving an unresolved kernel entry with
#      iif VIFI_INVALID.  Linux never asks: ipmr_cache_find_any() resolves the
#      same lookup against its wildcard entry.  Creating the (S,G) from the
#      (*,G), the way the WHOLEPKT path already does for an LHR, gained (g).
#
#      And with traffic finally flowing, the counters were still zero: BSD
#      gates SIOCGETSGCNT on PRIV_NETINET_MROUTE (X_mrt_ioctl()) and pimd has
#      dropped to the frr user, so pim_mroute_update_counters() got EPERM
#      every 30 s and the keepalive timer and SPT switchover decision ran
#      blind -- which breaks a stream minutes in, long after a short
#      data-plane check would have passed.  Raising privileges around the
#      ioctl, as every other privileged call in that file does, gained (h).
#      Both live in files/patch-pimd_pim__mroute.c together with (2) and (3).
#
# The lab exits 0 on a patched build.  Nothing here encodes a failure as
# expected, so it keeps its value as a regression test rather than a snapshot.
#
# Requires: net/frr10 built WITH pimd (sbin/pimd present), sudo, a VIMAGE
# kernel, python3.
set -eu

SUDO=${SUDO:-sudo}
PYTHON=${PYTHON:-/usr/local/bin/python3}

JPFX=frrpim_
ROUTERS="r1 r2 r3"
FRRRUN=/var/run/frr
LABDIR=/tmp/frr_pim_test
SAVED_LOOP=${LABDIR}/mcast.loop.saved

# The group, and the port the sender and receiver agree on.  239/8 is
# administratively scoped, so nothing here can leak somewhere meaningful.
GROUP=239.60.1.1
UDP_PORT=5601

SRC_ADDR=10.60.1.10
R1_LAN=10.60.1.1
R1_CORE=10.60.12.1
R2_CORE=10.60.12.2
R2_EDGE=10.60.23.2
R3_CORE=10.60.23.3
R3_LAN=10.60.3.1
RCV_ADDR=10.60.3.10
RP_ADDR=10.60.255.2

# The direct r1-r3 link, which only the rp-offpath scenario builds.
R1_DIRECT=10.60.13.1
R3_DIRECT=10.60.13.3

SCENARIOS="rpt rp-offpath"
SCENARIO_FILE=${LABDIR}/scenario
# Every epair any scenario can create, so stop can tear down whatever is
# there without being told which scenario it is cleaning up after.
ALL_EPAIRS="960 961 962 963 964"

# PIM's default 30 s hello would make "start" a minute-long wait for an
# adjacency; 5 s is the same protocol, sooner.  Everything else is left at
# its default on purpose -- a lab that tunes the timers it depends on stops
# testing the timers.
HELLO=5

RCV_LOG=${LABDIR}/rcv.log
SND_PID=${LABDIR}/sender.pid
RCV_PID=${LABDIR}/receiver.pid
SND_PY=${LABDIR}/sender.py
RCV_PY=${LABDIR}/receiver.py

# How long (g) watches the receiver's log.  The sender emits 2 packets/s,
# so a working data plane moves this many in that window; one packet would
# do, and the threshold is low on purpose to keep a loaded host from
# failing an otherwise working lab.
DATA_WINDOW=10
DATA_MIN=4

die() { echo "EXIT: $*" >&2; exit 2; }

usage() {
	echo "Usage: $0 start|check|stop|run [${SCENARIOS# } | all]"
	echo "       scenario defaults to rpt"
}

# What differs between scenarios, in one place: which links exist, which
# interface the last hop router should see each tree on, and whether it is
# allowed to leave the shared tree.
scenario_vars() {
	SCENARIO=$1
	case "${SCENARIO}" in
	rpt)
		LAB_EPAIRS="960 961 962 963"
		LHR_RPT_IIF=epair962b
		LHR_SRC_IIF=epair962b
		LHR_SPT_OFF=no
		;;
	rp-offpath)
		LAB_EPAIRS="960 961 962 963 964"
		LHR_RPT_IIF=epair962b
		LHR_SRC_IIF=epair964b
		LHR_SPT_OFF=yes
		;;
	*)
		die "unknown scenario '${SCENARIO}' (have: ${SCENARIOS}, all)"
		;;
	esac
}

# vtysh in a router jail.  Every daemon logs its socket-buffer gripe to
# stderr at connect time, which is noise here, not evidence.
vt() {
	_j=$1; shift
	${SUDO} jexec ${JPFX}${_j} vtysh \
		--config_dir ${FRRRUN}/${JPFX}${_j} \
		--vty_socket ${FRRRUN}/${JPFX}${_j}.sock \
		-c "$*" </dev/null 2>/dev/null
}

# The kernel's own answer, from inside a jail: the vif table and the
# multicast forwarding cache ip_mroute(4) holds for that vnet.
kmroute() { ${SUDO} jexec ${JPFX}$1 netstat -g 2>/dev/null; }

check_req() {
	[ "$(id -u)" = 0 ] || ${SUDO} -n true 2>/dev/null || \
		echo "note: sudo may prompt for a password"
	which vtysh >/dev/null 2>&1 || die "net/frr10 not installed"
	# The whole point of the lab.  A stock net/frr10 package has no pimd:
	# the port passed --disable-pimd until the PIM option was added.
	[ -x /usr/local/sbin/pimd ] || die "no /usr/local/sbin/pimd -- net/frr10 was built without PIM.
    Rebuild it (PIM enabled in net/frr10) and install:
      sudo pkg add -f /usr/local/poudriere/data/packages/builder-default/All/frr10-*.pkg"
	[ -x "${PYTHON}" ] || die "${PYTHON} not found (set PYTHON=)"
	[ "$(sysctl -n kern.features.vimage 2>/dev/null || echo 0)" = 1 ] || \
		die "kernel has no VIMAGE: vnet jails unavailable"
	${SUDO} kldstat -qm ip_mroute || ${SUDO} kldload ip_mroute || \
		die "cannot load ip_mroute.ko"
}

# --------------------------------------------------------------------------
# The two hosts.  Both are plain python: a lab that generated its multicast
# with a port would be testing that port too.
# --------------------------------------------------------------------------
write_helpers() {
	mkdir -p ${LABDIR}
	cat > ${SND_PY} <<'PYEOF'
# Send one UDP datagram to a group every 0.5 s, out of one named address.
# IP_MULTICAST_LOOP off: what this socket hands its own host is not what
# the lab is asking about, and a looped copy would be indistinguishable
# from a forwarded one at the receiver if src and rcv ever shared a jail.
import socket, sys, time

group, port, srcaddr = sys.argv[1], int(sys.argv[2]), sys.argv[3]
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 16)
s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF, socket.inet_aton(srcaddr))
s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_LOOP, 0)
s.bind((srcaddr, 0))
n = 0
while True:
    n += 1
    s.sendto(("frr-pim-test %d" % n).encode(), (group, port))
    time.sleep(0.5)
PYEOF
	cat > ${RCV_PY} <<'PYEOF'
# Join a group on one interface address and append a line per datagram.
# The join is the IGMP report the last hop router has to turn into a (*,G)
# Join, so this process is half of assertion (c) as well as all of (g); it
# has to stay alive for the whole lab, not just for the counting window.
import socket, struct, sys

group, port, ifaddr, logpath = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("", port))
s.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP,
             struct.pack("4s4s", socket.inet_aton(group), socket.inet_aton(ifaddr)))
log = open(logpath, "a", buffering=1)
while True:
    data, addr = s.recvfrom(2048)
    log.write("%s %s\n" % (addr[0], data.decode(errors="replace")))
PYEOF
}

# --------------------------------------------------------------------------
# Boxes.  A jail here is "persist + vnet", its interfaces handed over at
# creation, which is why every epair is created on the host first.
# --------------------------------------------------------------------------
mkjail() {
	# mkjail <name> <if> [<if> ...]
	_n=$1; shift
	if [ "$(jls -d -j ${JPFX}${_n} dying 2>/dev/null)" = "true" ]; then
		echo "BUG: jail ${JPFX}${_n} stuck dying"
		echo "https://bugs.freebsd.org/bugzilla/show_bug.cgi?id=264981"
		exit 2
	fi
	_vif=""
	for _i in "$@"; do _vif="${_vif} vnet.interface=${_i}"; done
	# shellcheck disable=SC2086
	${SUDO} jail -c name=${JPFX}${_n} host.hostname=${JPFX}${_n} persist \
		vnet ${_vif}
}

start_hosts() {
	# src and rcv: an address, a default route, nothing else.
	mkjail src epair960a
	${SUDO} jexec ${JPFX}src ifconfig epair960a inet ${SRC_ADDR}/24 up
	${SUDO} jexec ${JPFX}src route -q add default ${R1_LAN}

	mkjail rcv epair963b
	${SUDO} jexec ${JPFX}rcv ifconfig epair963b inet ${RCV_ADDR}/24 up
	${SUDO} jexec ${JPFX}rcv route -q add default ${R3_LAN}
}

# Each router: interfaces up, static unicast routes, then the daemons.  The
# routes go in before zebra starts so that zebra reads them from the kernel
# at init and pimd's RPF lookups have an answer from its first hello.
start_r1() {
	if [ "${SCENARIO}" = rp-offpath ]; then
		mkjail r1 epair960b epair961a epair964a
	else
		mkjail r1 epair960b epair961a
	fi
	${SUDO} jexec ${JPFX}r1 sysctl -q net.inet.ip.forwarding=1
	${SUDO} jexec ${JPFX}r1 ifconfig epair960b inet ${R1_LAN}/24 up
	${SUDO} jexec ${JPFX}r1 ifconfig epair961a inet ${R1_CORE}/24 up
	${SUDO} jexec ${JPFX}r1 route -q add ${RP_ADDR}/32 ${R2_CORE}
	${SUDO} jexec ${JPFX}r1 route -q add 10.60.23.0/24 ${R2_CORE}
	_r1_extra=""
	if [ "${SCENARIO}" = rp-offpath ]; then
		# The receiver's subnet is reached directly, not through the
		# RP: that is what puts the shared tree and the source tree on
		# different interfaces at the other end.
		${SUDO} jexec ${JPFX}r1 ifconfig epair964a inet ${R1_DIRECT}/24 up
		${SUDO} jexec ${JPFX}r1 route -q add 10.60.3.0/24 ${R3_DIRECT}
		_r1_extra="interface epair964a
 ip pim
 ip pim hello ${HELLO}
!"
	else
		${SUDO} jexec ${JPFX}r1 route -q add 10.60.3.0/24 ${R2_CORE}
	fi
	frr_conf r1 <<EOF
interface epair960b
 ip pim
 ip pim hello ${HELLO}
 ip igmp
!
interface epair961a
 ip pim
 ip pim hello ${HELLO}
!
${_r1_extra}
router pim
 rp ${RP_ADDR} 239.0.0.0/8
!
EOF
	frr_start r1
}

start_r2() {
	${SUDO} ifconfig lo960 create group frrpim
	mkjail r2 epair961b epair962a lo960
	${SUDO} jexec ${JPFX}r2 sysctl -q net.inet.ip.forwarding=1
	${SUDO} jexec ${JPFX}r2 ifconfig lo960 inet ${RP_ADDR}/32 up
	${SUDO} jexec ${JPFX}r2 ifconfig epair961b inet ${R2_CORE}/24 up
	${SUDO} jexec ${JPFX}r2 ifconfig epair962a inet ${R2_EDGE}/24 up
	${SUDO} jexec ${JPFX}r2 route -q add 10.60.1.0/24 ${R1_CORE}
	${SUDO} jexec ${JPFX}r2 route -q add 10.60.3.0/24 ${R3_CORE}
	# ip pim on the RP loopback: the RP address has to belong to a
	# PIM interface for pimd to agree that it is the RP.
	frr_conf r2 <<EOF
interface lo960
 ip pim
!
interface epair961b
 ip pim
 ip pim hello ${HELLO}
!
interface epair962a
 ip pim
 ip pim hello ${HELLO}
!
router pim
 rp ${RP_ADDR} 239.0.0.0/8
!
EOF
	frr_start r2
}

start_r3() {
	if [ "${SCENARIO}" = rp-offpath ]; then
		mkjail r3 epair962b epair963a epair964b
	else
		mkjail r3 epair962b epair963a
	fi
	${SUDO} jexec ${JPFX}r3 sysctl -q net.inet.ip.forwarding=1
	${SUDO} jexec ${JPFX}r3 ifconfig epair962b inet ${R3_CORE}/24 up
	${SUDO} jexec ${JPFX}r3 ifconfig epair963a inet ${R3_LAN}/24 up
	# The RP is always reached through r2.  Where the *source* is reached
	# is what the scenario changes.
	${SUDO} jexec ${JPFX}r3 route -q add ${RP_ADDR}/32 ${R2_EDGE}
	${SUDO} jexec ${JPFX}r3 route -q add 10.60.12.0/24 ${R2_EDGE}
	_r3_extra=""
	_r3_spt=""
	if [ "${SCENARIO}" = rp-offpath ]; then
		${SUDO} jexec ${JPFX}r3 ifconfig epair964b inet ${R3_DIRECT}/24 up
		${SUDO} jexec ${JPFX}r3 route -q add 10.60.1.0/24 ${R1_DIRECT}
		_r3_extra="interface epair964b
 ip pim
 ip pim hello ${HELLO}
!"
		# Stay on the shared tree.  Without this the router would join
		# the source tree on the first packet, the traffic would arrive
		# on the source's RPF interface instead, and a router that drops
		# RPT traffic would still look healthy a few seconds later.
		_r3_spt=" spt-switchover infinity-and-beyond"
	else
		${SUDO} jexec ${JPFX}r3 route -q add 10.60.1.0/24 ${R2_EDGE}
	fi
	# The receiver LAN needs both: ip igmp to hear the membership report,
	# ip pim for the interface to be a vif the kernel can forward out of.
	frr_conf r3 <<EOF
interface epair962b
 ip pim
 ip pim hello ${HELLO}
!
interface epair963a
 ip pim
 ip pim hello ${HELLO}
 ip igmp
 ip igmp version 3
!
${_r3_extra}
router pim
 rp ${RP_ADDR} 239.0.0.0/8
${_r3_spt}
!
EOF
	frr_start r3
}

# Config file for one router, read on stdin, plus the run/socket dirs the
# daemons and vtysh expect to own.
frr_conf() {
	_n=$1
	_run=${FRRRUN}/${JPFX}${_n}
	${SUDO} mkdir -p ${_run} ${FRRRUN}/${JPFX}${_n}.sock
	{ echo "log file ${_run}/frr.log"; echo "!"; cat; } | \
		${SUDO} tee ${_run}/frr.conf >/dev/null
	${SUDO} touch ${_run}/vtysh.conf
	${SUDO} chown -R frr ${_run} ${FRRRUN}/${JPFX}${_n}.sock
}

frr_start() {
	_n=$1
	for _d in mgmtd zebra pimd; do
		${SUDO} jexec ${JPFX}${_n} ${_d} -d \
			-i ${FRRRUN}/${JPFX}${_n}_${_d}.pid \
			--vty_socket ${FRRRUN}/${JPFX}${_n}.sock || \
			die "${_d} failed to start in ${JPFX}${_n}"
	done
	# -b pushes the file above into the running daemons.  It returns
	# non-zero on any rejected line, which is worth failing on: a command
	# FRR renamed between majors would otherwise leave a half-configured
	# router and a mystery in check.
	${SUDO} jexec ${JPFX}${_n} vtysh -b \
		--config_dir ${FRRRUN}/${JPFX}${_n}/ \
		--vty_socket ${FRRRUN}/${JPFX}${_n}.sock || \
		die "vtysh -b rejected the config for ${JPFX}${_n} (see above)"
}

start_traffic() {
	: > ${RCV_LOG}
	${SUDO} jexec ${JPFX}rcv daemon -p ${RCV_PID} -o ${LABDIR}/receiver.out \
		${PYTHON} ${RCV_PY} ${GROUP} ${UDP_PORT} ${RCV_ADDR} ${RCV_LOG}
	${SUDO} jexec ${JPFX}src daemon -p ${SND_PID} -o ${LABDIR}/sender.out \
		${PYTHON} ${SND_PY} ${GROUP} ${UDP_PORT} ${SRC_ADDR}
}

# --------------------------------------------------------------------------
start() {
	check_req
	write_helpers
	echo "${SCENARIO}" > ${SCENARIO_FILE}

	# Host state, saved before it is taken.  See the header.
	sysctl -n net.inet.ip.mcast.loop > ${SAVED_LOOP}
	${SUDO} sysctl -q net.inet.ip.mcast.loop=0

	for _e in ${LAB_EPAIRS}; do
		${SUDO} ifconfig epair${_e} create group frrpim >/dev/null
	done

	start_hosts
	start_r1
	start_r2
	start_r3
	start_traffic

	# One hello interval is enough for an adjacency; the IGMP report and
	# the Join it triggers are immediate.  Twice that, to leave room for
	# the Register and the RP's answer on a busy host.
	_wait=$((HELLO * 4))
	echo "started [${SCENARIO}]: sender and receiver running, waiting ${_wait}s for PIM to converge"
	sleep ${_wait}
	echo
	echo "next:  sh $0 check          (assertions, exit 0 = PIM-SM works)"
	echo "       sh $0 stop           (tear down, restore host sysctl)"
	echo
	echo "by hand, e.g.:"
	echo "  ${SUDO} jexec ${JPFX}r2 vtysh --config_dir ${FRRRUN}/${JPFX}r2 --vty_socket ${FRRRUN}/${JPFX}r2.sock"
	echo "  ${SUDO} jexec ${JPFX}r1 netstat -g"
	echo "  tail -f ${RCV_LOG}"
}

# --------------------------------------------------------------------------
# Assertions.  Each prints its evidence before its verdict: a FAIL whose
# output a human cannot read is a bug report nobody can act on.
# --------------------------------------------------------------------------
rc=0

pass() { echo "PASS ($1): $2"; }
fail() { echo "FAIL ($1): $2"; rc=1; }

# The known FreeBSD defects, named from the logs and from the kernel's vif
# table.  These print as NOTEs, not failures: the assertions above already
# counted what broke, and what a reader needs next is why.
frr_log_notes() {
	for _n in ${ROUTERS}; do
		_l=${FRRRUN}/${JPFX}${_n}/frr.log
		if ${SUDO} grep -q "Could not bind IGMP socket" ${_l} 2>/dev/null; then
			echo "NOTE (${_n}): pimd could not bind its IGMP socket --"
			${SUDO} grep -m1 "Could not bind IGMP socket" ${_l} | sed 's/^/    /'
			echo "    pim_igmp_sock_add() (pimd/pim_igmp.c) binds with a sockaddr_in it"
			echo "    never zeroes, and FreeBSD rip_bind() compares every sa_len byte, so"
			echo "    garbage in sin_zero makes the address lookup miss.  No IGMP at all."
		fi
		if ${SUDO} grep -q "PIM_SIOCGETSGCNT" ${_l} 2>/dev/null; then
			echo "NOTE (${_n}): pimd cannot read (S,G) counters --"
			${SUDO} grep -m1 "PIM_SIOCGETSGCNT" ${_l} | sed 's/^/    /'
			echo "    X_mrt_ioctl() needs PRIV_NETINET_MROUTE; pimd runs as frr by then."
		fi
		if ${SUDO} grep -q "WRVIFWHOLE" ${_l} 2>/dev/null; then
			echo "NOTE (${_n}): pimd says so itself at startup --"
			${SUDO} grep -m1 "WRVIFWHOLE" ${_l} | sed 's/^/    /'
		fi
	done
	# Defect 2: the daemon has an IGMP socket and is the querier, but the
	# IGMP packets the kernel counted never reached it.  Comparing the two
	# counters is what separates "nothing arrived" from "pimd dropped it",
	# and the latter is the missing IP_RECVIF on the mroute socket.
	_frr_rx=$(vt r3 "show ip igmp statistics" |
		awk '/total received messages/ {print $NF}')
	_kern_rx=$(${SUDO} jexec ${JPFX}r3 netstat -sp igmp 2>/dev/null |
		awk '/messages received/ {print $1; exit}')
	if [ "${_frr_rx:-0}" = 0 ] && [ "${_kern_rx:-0}" -gt 0 ] 2>/dev/null; then
		echo "NOTE (r3): the kernel counted ${_kern_rx} IGMP messages, pimd counted"
		echo "    ${_frr_rx}.  pim_mroute_set_options() (pimd/pim_mroute.c) sets only"
		echo "    IP_PKTINFO and has no BSD IP_RECVIF branch, so the mroute socket"
		echo "    yields no ifindex, process_igmp_packet() looks up interface -1 and"
		echo "    drops every report.  pim_socket_mcast() does set IP_RECVIF, which is"
		echo "    why PIM adjacency works and IGMP does not."
	fi

	# The register vif, from the kernel rather than from FRR's picture of it.
	# netstat -g lists vifs by index and local address, not by name, and the
	# register vif is the one at index 0.
	if ! kmroute r1 | awk '$1 == "0" && NF >= 5 { found = 1 } END { exit !found }'; then
		echo "NOTE (r1): no register vif at index 0 in the kernel vif table, yet the"
		echo "    MFC entry above forwards to vif 0 -- nothing encapsulates, so the RP"
		echo "    is never told about the source (assertion e2).  pim_mroute_add_vif()"
		echo "    refuses a vif with no local address on BSD; see"
		echo "    files/patch-pimd_pim__mroute.c in the port."
	fi

	# A last hop router that has the group but no (S,G): FreeBSD's mfc_find()
	# matches the source exactly (in_hosteq(), sys/netinet/ip_mroute.c), so a
	# (*,G) entry forwards nothing and the kernel parks a pending entry with
	# iif VIFI_INVALID (65535) while it waits for the daemon to install the
	# real one.  Linux resolves the same lookup against its wildcard entry in
	# ipmr_cache_find_any() and never asks.
	if kmroute r3 | awk '$2 == "'"${GROUP}"'" && $4 == "65535" { found = 1 }
			    END { exit !found }'; then
		echo "NOTE (r3): the kernel holds an unresolved (S,${GROUP}) entry with iif"
		echo "    65535 (VIFI_INVALID) -- a pending upcall nobody answered.  FRR's"
		echo "    pim_mroute_nocache_forward_existing() returns early when there is no"
		echo "    (S,G) upstream, which is the normal state on a last hop router whose"
		echo "    receivers joined (*,G): on Linux the kernel's wildcard lookup"
		echo "    forwards those packets and no NOCACHE is ever raised, so the case"
		echo "    does not arise there.  Until FRR installs an (S,G) mfc from the"
		echo "    (*,G) inherited olist, the data plane stops one hop short of the"
		echo "    receiver (assertion g)."
	fi
}

show() {
	echo "------ ${JPFX}$1: $2 ------"
	vt "$1" "$2"
	echo "-------------------------------------------------"
}

check() {
	for _n in src rcv ${ROUTERS}; do
		[ "$(jls -j ${JPFX}${_n} name 2>/dev/null)" = "${JPFX}${_n}" ] || \
			die "jail ${JPFX}${_n} is not running -- run start first"
	done

	# (a) Adjacency on every link, read from both ends of each.  A PIM
	#     neighbor is the cheapest proof that hellos are both sent and
	#     parsed, which on a new platform is not a given.
	_nbr_r1=$(vt r1 "show ip pim neighbor")
	_nbr_r2=$(vt r2 "show ip pim neighbor")
	_nbr_r3=$(vt r3 "show ip pim neighbor")
	show r2 "show ip pim neighbor"
	_adj=yes
	echo "${_nbr_r1}" | grep -q "${R2_CORE}" || _adj=no
	echo "${_nbr_r2}" | grep -q "${R1_CORE}" || _adj=no
	echo "${_nbr_r2}" | grep -q "${R3_CORE}" || _adj=no
	echo "${_nbr_r3}" | grep -q "${R2_EDGE}" || _adj=no
	if [ "${SCENARIO}" = rp-offpath ]; then
		echo "${_nbr_r1}" | grep -q "${R3_DIRECT}" || _adj=no
		echo "${_nbr_r3}" | grep -q "${R1_DIRECT}" || _adj=no
	fi
	if [ "${_adj}" = yes ]; then
		pass a "PIM adjacency up on every link, seen from both ends"
	else
		fail a "missing PIM neighbor"
		echo "${_nbr_r1}"; echo "${_nbr_r2}"; echo "${_nbr_r3}"
	fi

	# (b) The static RP, agreed on by all three, and claimed by exactly
	#     the one that owns the address.
	_rp_r2=$(vt r2 "show ip pim rp-info")
	show r2 "show ip pim rp-info"
	if echo "${_rp_r2}" | grep -q "${RP_ADDR}" &&
	   echo "${_rp_r2}" | grep -qi "yes"; then
		pass b1 "r2 is the RP for ${RP_ADDR}"
	else
		fail b1 "r2 does not claim to be the RP"
	fi
	_ok=yes
	for _n in r1 r3; do
		vt ${_n} "show ip pim rp-info" | grep -q "${RP_ADDR}" || _ok=no
	done
	[ "${_ok}" = yes ] && pass b2 "r1 and r3 know RP ${RP_ADDR}" || \
		fail b2 "r1 or r3 has no RP for the group range"

	# (c) The receiver's IGMPv3 report, turned into group state on the
	#     last hop router.  Without this nothing downstream can happen.
	_igmp=$(vt r3 "show ip igmp groups")
	show r3 "show ip igmp groups"
	if echo "${_igmp}" | grep -q "${GROUP}"; then
		pass c "r3 learned ${GROUP} from IGMP on the receiver LAN"
	else
		fail c "r3 has no IGMP group state for ${GROUP}"
	fi

	# (d) The shared tree: r3 joined (*,G) towards the RP, and its
	#     incoming interface is the one the unicast route to the RP
	#     names -- i.e. the Join went the right way, not just somewhere.
	_up_r3=$(vt r3 "show ip pim upstream")
	show r3 "show ip pim upstream"
	if echo "${_up_r3}" | grep -q "${GROUP}" &&
	   echo "${_up_r3}" | grep "${GROUP}" | grep -q "${LHR_RPT_IIF}"; then
		pass d "r3 has (*,${GROUP}) upstream on ${LHR_RPT_IIF} towards the RP"
	else
		fail d "r3 has no (*,${GROUP}) upstream, or it points the wrong way"
	fi

	# (e) The Register path, which is the piece with the most FreeBSD in
	#     it: the FHR encapsulates to the RP through the kernel's
	#     register vif (pimreg here), and the RP decapsulates.  r1 must
	#     hold (S,G) for the real source address, and the RP must have
	#     learned that same source without anyone configuring it.
	_up_r1=$(vt r1 "show ip pim upstream")
	show r1 "show ip pim upstream"
	if echo "${_up_r1}" | grep -q "${SRC_ADDR}.*${GROUP}"; then
		pass e1 "r1 (FHR) has (${SRC_ADDR},${GROUP}) upstream"
	else
		fail e1 "r1 has no (${SRC_ADDR},${GROUP}) state for the local source"
	fi
	_up_r2=$(vt r2 "show ip pim upstream")
	show r2 "show ip pim upstream"
	if echo "${_up_r2}" | grep -q "${SRC_ADDR}"; then
		pass e2 "RP learned source ${SRC_ADDR} (Register decapsulated)"
	else
		fail e2 "RP never learned ${SRC_ADDR}: Register path broken"
		show r1 "show ip pim interface"
	fi

	# (f) The kernel's forwarding cache, not FRR's picture of it.  An
	#     entry with an empty outgoing list is the classic shape of a
	#     daemon that talked to ip_mroute(4) and got the vifs wrong, so
	#     the packet count matters as much as the entry.
	for _n in ${ROUTERS}; do
		echo "------ ${JPFX}${_n}: netstat -g ------"
		_k=$(kmroute ${_n})
		echo "${_k}"
		echo "-------------------------------------------------"
		if echo "${_k}" | grep -q "${GROUP}"; then
			pass "f/${_n}" "kernel has an MFC entry for ${GROUP}"
		else
			fail "f/${_n}" "no kernel MFC entry for ${GROUP}"
		fi
	done

	# (g) The only assertion that cannot pass by accident: packets the
	#     sender put on 10.60.1.0/24 arriving on 10.60.3.0/24, three
	#     forwarders later, while check watches.
	_before=$(wc -l < ${RCV_LOG} 2>/dev/null || echo 0)
	echo "watching the receiver for ${DATA_WINDOW}s ..."
	sleep ${DATA_WINDOW}
	_after=$(wc -l < ${RCV_LOG} 2>/dev/null || echo 0)
	_delta=$((_after - _before))
	echo "------ ${RCV_LOG}: last lines ------"
	tail -3 ${RCV_LOG} 2>/dev/null || true
	echo "-------------------------------------------------"
	if [ ${_delta} -ge ${DATA_MIN} ]; then
		pass g "receiver got ${_delta} datagrams in ${DATA_WINDOW}s (>= ${DATA_MIN})"
	else
		fail g "receiver got ${_delta} datagrams in ${DATA_WINDOW}s (want >= ${DATA_MIN})"
		echo "  sender stderr: $(cat ${LABDIR}/sender.out 2>/dev/null)"
		echo "  receiver stderr: $(cat ${LABDIR}/receiver.out 2>/dev/null)"
	fi

	# (h) FRR's own view of what it forwarded, which it reads back from the
	#     kernel with SIOCGETSGCNT.  A daemon can forward correctly and
	#     still be blind to it: these are the counters the keepalive timer
	#     and the SPT switchover decision run on, so with them stuck at
	#     zero (S,G) state expires under live traffic and the stream breaks
	#     a few minutes in -- long after a short data-plane check passes.
	_cnt=$(vt r1 "show ip mroute count" |
		awk -v s="${SRC_ADDR}" -v g="${GROUP}" '$1 == s && $2 == g {print $4}')
	show r1 "show ip mroute count"
	if [ -n "${_cnt}" ] && [ "${_cnt}" -gt 0 ] 2>/dev/null; then
		pass h "r1 counts ${_cnt} forwarded packets for (${SRC_ADDR},${GROUP})"
	else
		fail h "r1 reports no packet count for (${SRC_ADDR},${GROUP}): SIOCGETSGCNT"
	fi

	# (i) rp-offpath only: the shared tree is the only path here, so the
	#     last hop router has to forward traffic that arrives on the
	#     RP-facing interface even though its RPF towards the source names
	#     another one.  Ordinary PIM-SM; the rpt scenario cannot ask the
	#     question, because there both trees arrive on the same interface.
	#
	#     Read from the kernel, not from pimd: pimd reports the (S,G) with
	#     the right input interface in "show ip mroute" even when the entry
	#     it installed has an empty outgoing list, so its own view cannot
	#     tell a forwarding router from a black hole.  The mfc can:
	#     packets arrive on the iif, and the Out-Vifs column says whether
	#     any of them leave.
	if [ "${SCENARIO}" = rp-offpath ]; then
		show r3 "show ip mroute"
		_k_r3=$(kmroute r3)
		echo "------ ${JPFX}r3: netstat -g ------"
		echo "${_k_r3}"
		echo "-------------------------------------------------"
		# The vif index of the RP-facing link, by its local address.
		_rpt_vif=$(echo "${_k_r3}" |
			awk -v a="${R3_CORE}" '$3 == a { print $1; exit }')
		_sg_row=$(echo "${_k_r3}" |
			awk -v s="${SRC_ADDR}" -v g="${GROUP}" '$1 == s && $2 == g { print; exit }')
		_sg_iif=$(echo "${_sg_row}" | awk '{print $4}')
		_sg_oif=$(echo "${_sg_row}" | awk '{ for (i = 5; i <= NF; i++) printf "%s ", $i }')
		if [ -z "${_sg_row}" ]; then
			fail i "r3 has no kernel (${SRC_ADDR},${GROUP}) entry: the RPT upcall was never resolved"
		elif [ -z "${_sg_oif}" ]; then
			fail i "r3 installed (${SRC_ADDR},${GROUP}) on vif ${_sg_iif} with an EMPTY outgoing list"
			echo "  packets arrive on the shared tree and are dropped: the (*,G) olist"
			echo "  was not inherited when the (S,G) was created for RPT traffic"
			echo "  (r3's RPF towards ${SRC_ADDR} is ${LHR_SRC_IIF}, not the ${LHR_RPT_IIF} they came in on)"
		elif [ "${_sg_iif}" != "${_rpt_vif}" ]; then
			fail i "r3 forwards (${SRC_ADDR},${GROUP}) from vif ${_sg_iif}, expected the RP-facing vif ${_rpt_vif}"
		else
			pass i "r3 forwards (${SRC_ADDR},${GROUP}) off the shared tree, vif ${_sg_iif} ->${_sg_oif}"
		fi
	fi

	echo
	if [ ${rc} -ne 0 ]; then
		echo "------ named causes ------"
		frr_log_notes
		echo "--------------------------"
		echo
	fi
	if [ ${rc} -eq 0 ]; then
		echo "OVERALL: PASS -- FRR pimd routes multicast on FreeBSD"
	else
		echo "OVERALL: FAIL -- see the assertions above"
	fi
	return ${rc}
}

# --------------------------------------------------------------------------
stop() {
	for _p in ${SND_PID} ${RCV_PID}; do
		[ -f ${_p} ] && ${SUDO} pkill -F ${_p} 2>/dev/null || true
	done
	for _n in src rcv ${ROUTERS}; do
		${SUDO} jail -R ${JPFX}${_n} 2>/dev/null || true
	done
	sleep 2
	for _e in ${ALL_EPAIRS}; do
		for _s in a b; do
			${SUDO} ifconfig epair${_e}${_s} destroy 2>/dev/null || true
		done
	done
	${SUDO} ifconfig lo960 destroy 2>/dev/null || true
	for _n in ${ROUTERS}; do
		${SUDO} rm -rf ${FRRRUN}/${JPFX}${_n} ${FRRRUN}/${JPFX}${_n}.sock
		${SUDO} rm -f ${FRRRUN}/${JPFX}${_n}_*.pid
	done
	# Give the host sysctl back, whatever it was.
	if [ -f ${SAVED_LOOP} ]; then
		${SUDO} sysctl -q net.inet.ip.mcast.loop="$(cat ${SAVED_LOOP})"
		rm -f ${SAVED_LOOP}
	fi
	rm -f ${SND_PID} ${RCV_PID} ${SCENARIO_FILE}
	echo "stopped [${SCENARIO}]"
}

run() {
	start
	_rc=0
	check || _rc=$?
	stop
	return ${_rc}
}

run_all() {
	_worst=0
	for _s in ${SCENARIOS}; do
		echo "=================== scenario: ${_s} ==================="
		scenario_vars ${_s}
		rc=0
		run || _worst=1
		echo
	done
	if [ ${_worst} -eq 0 ]; then
		echo "ALL SCENARIOS PASS"
	else
		echo "AT LEAST ONE SCENARIO FAILED"
	fi
	exit ${_worst}
}

if [ $# -eq 0 ]; then
	usage
	exit 2
fi
_action=$1
_want=${2:-}

case "${_action}" in
start|run)
	if [ "${_want}" = all ]; then
		[ "${_action}" = run ] || die "only 'run' takes all"
		run_all
	fi
	scenario_vars "${_want:-rpt}"
	;;
check|stop)
	# Whatever start left running, unless told otherwise.
	scenario_vars "${_want:-$(cat ${SCENARIO_FILE} 2>/dev/null || echo rpt)}"
	;;
esac

case "${_action}" in
start|stop)	"${_action}" ;;
run)		run; exit $? ;;
check)		check || exit $? ;;
*)		usage; exit 2 ;;
esac
