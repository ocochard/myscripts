#!/bin/sh
# net/mlvpn regression smoke test (host-only, no jails).
#
# Runs two mlvpn instances on the host, one in server mode and one in
# client mode, each bound to a different loopback alias.  Verifies the
# binary parses its config, opens a tun device, negotiates with the peer,
# brings the tunnel interface up, and forwards ICMP through it.
#
# Topology:
#
#                127.0.0.1:5081 (mlvpn server)
#                127.0.0.1:5082 (mlvpn client)
#                          |
#                  UDP between the two ports
#                          |
#                tun(N)           tun(N+1)
#             10.0.16.2/30 <----> 10.0.16.1/30
#
# Why no jails: mlvpn's tun device wants /dev/tunN which a default vnet
# jail hides via devfs ruleset; setting up a custom ruleset works but is
# brittle.  Running both instances on the host keeps the test small and
# fast — the goal is to catch packaging breakage, not to model topology.
#
# Usage: mlvpn_test.sh start | stop | run
#   start: bring up both daemons (leaves them running)
#   stop:  tear down
#   run:   full regression — install pkg, start, smoke-test, stop, pkg delete
set -eu

SUDO=${SUDO:-sudo}
PORT_NAME=mlvpn
JAIL=builder
TREE=official
PKGDIR=/usr/local/poudriere/data/packages/${JAIL}-${TREE}/.latest/All

${SUDO} mkdir -p /var/run/mlvpn /var/log

# --- server (mlvpn-srv) ---
cat > /tmp/mlvpn_srv.conf <<'EOF'
[general]
statuscommand = "/var/run/mlvpn/mlvpn_updown.sh"
interface_name = "tun"
tuntap = "tun"
mode = "server"
ip4 = "10.0.16.2/30"
ip4_gateway = "10.0.16.1"
timeout = 30
password = "labpassword"
loglevel = 3

[tunnel1]
bindhost = "127.0.0.1"
bindport = 5081
EOF

# --- client (mlvpn-cli) ---
cat > /tmp/mlvpn_cli.conf <<'EOF'
[general]
statuscommand = "/var/run/mlvpn/mlvpn_updown.sh"
interface_name = "tun"
mode = "client"
mtu = 1452
tuntap = "tun"
ip4 = "10.0.16.1/30"
ip4_gateway = "10.0.16.2"
timeout = 30
password = "labpassword"
loglevel = 3

[tunnel1]
bindhost = "127.0.0.1"
bindport = 5082
remotehost = "127.0.0.1"
remoteport = 5081
EOF

cat > /tmp/mlvpn_updown.sh <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x /tmp/mlvpn_updown.sh

die() { echo "EXIT: $*" >&2; exit 1; }

check_req () {
	command -v mlvpn >/dev/null 2>&1 || die "net/mlvpn not installed"
}

install_pkg () {
	if pkg info -E "${PORT_NAME}" >/dev/null 2>&1; then
		echo "${PORT_NAME} already installed"
		return
	fi
	PKG=$(ls -t ${PKGDIR}/${PORT_NAME}-*.pkg 2>/dev/null | head -1)
	[ -n "${PKG}" ] || die "no mlvpn .pkg in ${PKGDIR}"
	echo "Installing ${PKG}"
	${SUDO} pkg add -f "${PKG}"
}

uninstall_pkg () {
	${SUDO} pkg delete -y "${PORT_NAME}" 2>/dev/null || true
}

start_mlvpn () {
	# $1 = role (srv|cli)
	role=$1
	${SUDO} cp /tmp/mlvpn_${role}.conf /var/run/mlvpn/mlvpn_${role}.conf
	${SUDO} chmod 600 /var/run/mlvpn/mlvpn_${role}.conf
	${SUDO} cp /tmp/mlvpn_updown.sh /var/run/mlvpn/
	${SUDO} chmod 700 /var/run/mlvpn/mlvpn_updown.sh
	# --debug = log to stdout instead of syslog (so daemon -o captures it).
	${SUDO} daemon -P /var/run/mlvpn/mlvpn_${role}.pid \
		-o /var/log/mlvpn_${role}.log \
		mlvpn --debug --yes-run-as-root \
		      -c /var/run/mlvpn/mlvpn_${role}.conf
}

stop_mlvpn () {
	role=$1
	# pkill the [priv] parent and the worker child explicitly — they share
	# the @tunnel1 name suffix.  Pid file points at the daemon(8) wrapper,
	# not at mlvpn itself.
	${SUDO} pkill -f "mlvpn.*mlvpn_${role}.conf" 2>/dev/null || true
	if [ -f /var/run/mlvpn/mlvpn_${role}.pid ]; then
		${SUDO} pkill -F /var/run/mlvpn/mlvpn_${role}.pid 2>/dev/null || true
		${SUDO} rm -f /var/run/mlvpn/mlvpn_${role}.pid
	fi
}

start () {
	echo "==> starting mlvpn (server + client on host)"
	check_req
	start_mlvpn srv
	sleep 1
	start_mlvpn cli
	echo "==> mlvpn running"
	echo "    server log: /var/log/mlvpn_srv.log"
	echo "    client log: /var/log/mlvpn_cli.log"
}

stop () {
	echo "==> stopping mlvpn"
	# Remember which tun interfaces carry our test IPs before we kill
	# anything — those are the only ones we may destroy.  This avoids
	# nuking unrelated tun(4) consumers on the host (e.g. an OpenVPN
	# tun0 owned by another process).
	OUR_TUNS=$(ifconfig 2>/dev/null | awk '
		/^tun[0-9]+:/        { ifn=$1; sub(":","",ifn) }
		/inet 10\.0\.16\.[12] / { print ifn }
	')
	stop_mlvpn srv
	stop_mlvpn cli
	sleep 1
	for ifx in $OUR_TUNS; do
		${SUDO} ifconfig $ifx destroy 2>/dev/null || true
	done
	${SUDO} rm -f /var/run/mlvpn/mlvpn_*.conf /var/run/mlvpn/mlvpn_updown.sh
	${SUDO} rm -f /var/log/mlvpn_*.log
}

smoke_test () {
	echo "==> waiting up to 30 s for tunnel to come up"
	tries=0
	CLI_IF=""
	SRV_IF=""
	while [ $tries -lt 30 ]; do
		# Find which tun interface has each tunnel IP.
		CLI_IF=$(ifconfig 2>/dev/null | awk '
			/^tun[0-9]+:/    { ifn=$1; sub(":","",ifn) }
			/inet 10.0.16.1 / { print ifn; exit }
		')
		SRV_IF=$(ifconfig 2>/dev/null | awk '
			/^tun[0-9]+:/    { ifn=$1; sub(":","",ifn) }
			/inet 10.0.16.2 / { print ifn; exit }
		')
		[ -n "${CLI_IF}" ] && [ -n "${SRV_IF}" ] && break
		sleep 1
		tries=$((tries + 1))
	done
	[ -n "${CLI_IF}" ] && [ -n "${SRV_IF}" ] || {
		echo "FAIL  tun interfaces never came up (server=${SRV_IF:-none} client=${CLI_IF:-none})"
		echo "--- server log ---"
		${SUDO} tail -20 /var/log/mlvpn_srv.log 2>/dev/null || true
		echo "--- client log ---"
		${SUDO} tail -20 /var/log/mlvpn_cli.log 2>/dev/null || true
		return 1
	}
	echo "==> tunnel up: server=${SRV_IF} (10.0.16.2)  client=${CLI_IF} (10.0.16.1)"
	echo "==> pinging through tunnel"
	# Source from the client end, target the server end.  Need -S to make
	# sure the reply path goes back via the tun interface and not via lo0.
	if ${SUDO} ping -c 3 -t 5 -S 10.0.16.1 10.0.16.2 >/dev/null 2>&1; then
		echo "PASS  ICMP through mlvpn tunnel (10.0.16.1 -> 10.0.16.2)"
	else
		echo "FAIL  no ICMP through tunnel"
		ifconfig ${SRV_IF}
		ifconfig ${CLI_IF}
		return 1
	fi
}

run () {
	PRE=0
	pkg info -E "${PORT_NAME}" >/dev/null 2>&1 && PRE=1
	[ $PRE -eq 1 ] || install_pkg
	trap 'stop; [ $PRE -eq 1 ] || uninstall_pkg' EXIT INT TERM
	start
	smoke_test || die "smoke test failed"
	PKG_VER=$(pkg query '%v' ${PORT_NAME})
	echo "PASS  mlvpn ${PKG_VER}"
}

usage () { echo "usage: $0 start|stop|run|install|uninstall"; exit 2; }

case "${1:-}" in
	start)     start ;;
	stop)      stop ;;
	run)       run ;;
	install)   install_pkg ;;
	uninstall) uninstall_pkg ;;
	*)         usage ;;
esac
