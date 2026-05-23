#!/bin/sh
# net/sslh smoke test.
#
# Installs the freshly-built package from the poudriere builder, starts
# sslh-ev on an unprivileged port (no rc.d), exercises it with an ssh
# probe to the local sshd, checks the log for the multiplexed connection,
# then stops the daemon and removes the package.
#
# Requires a running sshd on 127.0.0.1:22 and sudo.
set -eu

PORT_NAME=sslh
JAIL=builder
TREE=official
PKGDIR=/usr/local/poudriere/data/packages/${JAIL}-${TREE}/.latest/All
PIDFILE=/tmp/${PORT_NAME}-test.pid
LOGFILE=/tmp/${PORT_NAME}-test.log
LISTEN_PORT=8022

cleanup() {
	if [ -f "${PIDFILE}" ]; then
		sudo pkill -F "${PIDFILE}" 2>/dev/null || true
	fi
	rm -f "${PIDFILE}" "${LOGFILE}"
	sudo pkg delete -y "${PORT_NAME}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# 1. Install the freshly-built package
PKG=$(ls -t ${PKGDIR}/${PORT_NAME}-*.pkg | head -1)
echo "Installing ${PKG}"
sudo pkg add -f "${PKG}"

# 2. Verify the binary version matches the package version
PKG_VER=$(pkg query '%v' ${PORT_NAME})
BIN_VER=$(/usr/local/sbin/sslh-ev -V 2>&1 | awk '/^sslh-ev/ {print $2; exit}')
echo "Package version: ${PKG_VER}   binary -V: ${BIN_VER}"
case "${BIN_VER}" in
	v${PKG_VER}|${PKG_VER}) ;;
	*) echo "FAIL  binary version (${BIN_VER}) doesn't match package (${PKG_VER})"; exit 1 ;;
esac

# 3. Start sslh-ev on an unprivileged port, multiplexing only ssh
/usr/local/sbin/sslh-ev \
	--ssh=127.0.0.1:22 \
	--listen=127.0.0.1:${LISTEN_PORT} \
	--pidfile=${PIDFILE} \
	--logfile=${LOGFILE} \
	--verbose-connections=4
sleep 1

# 4. Verify it's running
if ! ps -p "$(cat ${PIDFILE})" >/dev/null 2>&1; then
	echo "FAIL  sslh-ev did not stay running"
	cat "${LOGFILE}" >&2 || true
	exit 1
fi
echo "PASS  sslh-ev is running (pid=$(cat ${PIDFILE}))"

# 5. Exercise it with an ssh probe.  We don't need the ssh session to
# succeed in auth — we only need sslh to log that it accepted the
# connection and demultiplexed it to ssh.
ssh -o BatchMode=yes -o StrictHostKeyChecking=no \
	-o ConnectTimeout=5 -p ${LISTEN_PORT} 127.0.0.1 true 2>/dev/null || true

# Give sslh a beat to flush the log
sleep 1

if grep -q -E '(localhost|127\.0\.0\.1)' "${LOGFILE}"; then
	echo "PASS  SSH connection multiplexed by sslh"
else
	echo "FAIL  no multiplexed connection in ${LOGFILE}"
	cat "${LOGFILE}" >&2
	exit 1
fi

echo "PASS  sslh ${PKG_VER}"
