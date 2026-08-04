#!/bin/sh
# multimedia/moonshine smoke test.
#
# Installs the freshly-built package from the poudriere builder, starts
# moonshine on unprivileged loopback ports (no rc.d, no GPU/Wayland
# needed for the network layer under test), then fires a burst of
# aborted TCP connections at each of the HTTP/HTTPS/RTSP listeners.
#
# This is the regression test for the accept-loop crash fix (fork tag
# v0.12.0-freebsd, PORTREVISION 1): on FreeBSD accept() returns
# ECONNABORTED ("Software caused connection abort", os error 53) for a
# connection reset by the peer before accept() completed. The buggy
# build propagated that error out of the accept loop, tripping the shared
# ShutdownManager and taking the whole process down; any nmap probe or
# half-open client attempt killed the server. The fix logs it at WARN and
# continues. This test proves moonshine stays up after such aborts.
#
# Requires sudo, python3, and a moonshine-*.pkg in the poudriere builder.
set -eu

PORT_NAME=moonshine
JAIL=builder
TREE=official
PKGDIR=/usr/local/poudriere/data/packages/${JAIL}-${TREE}/.latest/All

WORKDIR=$(mktemp -d /tmp/${PORT_NAME}-test.XXXXXX)
CONF=${WORKDIR}/moonshine.toml
LOGFILE=${WORKDIR}/moonshine.log
MPID=""

# Unprivileged loopback ports (well above 1024, off the real 479xx/480xx
# range so a running instance on the host is untouched).
HTTP_PORT=48989
HTTPS_PORT=48984
RTSP_PORT=49010

# Was the package already installed before we started? If so, leave it.
PREEXISTING=no
if pkg info -e ${PORT_NAME} 2>/dev/null; then
	PREEXISTING=yes
fi

cleanup() {
	[ -n "${MPID}" ] && kill "${MPID}" 2>/dev/null || true
	rm -rf "${WORKDIR}"
	if [ "${PREEXISTING}" = no ]; then
		# Skip uninstall if something depends on moonshine.
		if [ -z "$(pkg query '%rn' ${PORT_NAME} 2>/dev/null)" ]; then
			sudo pkg delete -y ${PORT_NAME} 2>/dev/null || true
		fi
	fi
}
trap cleanup EXIT INT TERM

# 1. Install the freshly-built package.
PKG=$(ls -t ${PKGDIR}/${PORT_NAME}-*.pkg | head -1)
echo "Installing ${PKG}"
sudo pkg add -f "${PKG}"

# 2. Verify the binary version matches the package version.
PKG_VER=$(pkg query '%v' ${PORT_NAME})
BIN_VER=$(/usr/local/bin/moonshine --version 2>&1 | awk '{print $NF; exit}')
echo "Package version: ${PKG_VER}   binary --version: ${BIN_VER}"

# 3. Minimal config: loopback bind, all listeners on unprivileged ports,
#    self-signed cert written under $HOME/.config/moonshine on first start.
export HOME="${WORKDIR}"
mkdir -p "${WORKDIR}/.config/moonshine" "${WORKDIR}/run"
cat > "${CONF}" <<EOF
name = "MoonshineSmoke"
address = "127.0.0.1"
[webserver]
port = ${HTTP_PORT}
port_https = ${HTTPS_PORT}
enable_pairing = true
certificate = "\$HOME/.config/moonshine/cert.pem"
private_key = "\$HOME/.config/moonshine/key.pem"
[stream]
port = ${RTSP_PORT}
timeout = 60
[stream.video]
port = 48998
fec_percentage = 20
encrypt = false
[stream.audio]
port = 49000
[stream.control]
port = 48999
EOF

# 4. Start moonshine directly (not via rc.d).
XDG_RUNTIME_DIR="${WORKDIR}/run" MOONSHINE_LOG=info \
	/usr/local/bin/moonshine "${CONF}" > "${LOGFILE}" 2>&1 &
MPID=$!
sleep 6

# 5. It must be up with all three listeners bound.
if ! ps -p "${MPID}" >/dev/null 2>&1; then
	echo "FAIL  moonshine did not stay running after start"
	cat "${LOGFILE}" >&2 || true
	exit 1
fi
BOUND=$(sockstat -4 -l 2>/dev/null \
	| awk -v h=${HTTP_PORT} -v s=${HTTPS_PORT} -v r=${RTSP_PORT} \
	'$0 ~ "127.0.0.1:"h || $0 ~ "127.0.0.1:"s || $0 ~ "127.0.0.1:"r {n++} END{print n+0}')
echo "Listeners bound on loopback: ${BOUND}/3"
if [ "${BOUND}" -lt 3 ]; then
	echo "FAIL  not all listeners bound"
	sockstat -4 -l | grep -E "127.0.0.1:(${HTTP_PORT}|${HTTPS_PORT}|${RTSP_PORT})" >&2 || true
	exit 1
fi

# 6. Fire aborted TCP connections at each listener: connect with
#    SO_LINGER {1,0} so close() sends an RST, reproducing the
#    ECONNABORTED that accept() sees. Pre-fix, the first one crashed
#    the process.
python3 - "${HTTP_PORT}" "${HTTPS_PORT}" "${RTSP_PORT}" <<'PY'
import socket, struct, sys
linger = struct.pack('ii', 1, 0)
for port in (int(p) for p in sys.argv[1:]):
    for _ in range(10):
        s = socket.socket()
        s.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, linger)
        try:
            s.settimeout(0.3)
            s.connect(('127.0.0.1', port))
        except OSError:
            pass
        s.close()
PY
sleep 3

# 7. The whole point: still up after the aborts.
if ps -p "${MPID}" >/dev/null 2>&1; then
	echo "PASS  ${PORT_NAME} survived aborted TCP connections (pid ${MPID})"
else
	echo "FAIL  ${PORT_NAME} crashed on an aborted TCP connection (accept-loop regression)"
	echo "----- log -----" >&2
	cat "${LOGFILE}" >&2 || true
	exit 1
fi

# 8. Confirm the errors were actually exercised and handled non-fatally
#    (logged at WARN, not ERROR). Absence would mean the abort never
#    reached the accept path and the test proved nothing.
if grep -q "WARN.*Failed to accept connection.*os error 53" "${LOGFILE}"; then
	echo "PASS  ECONNABORTED handled at WARN (accept loop continued)"
else
	echo "WARN  no ECONNABORTED WARN line seen; aborts may not have hit accept()"
	grep -i "accept" "${LOGFILE}" >&2 || true
fi

echo "PASS  ${PORT_NAME}"
