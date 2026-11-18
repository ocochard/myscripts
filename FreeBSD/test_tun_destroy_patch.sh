#!/bin/sh
#
# Validate the tun_destroy EBUSY patch on the running kernel.
#
# On a buggy (pre-patch) kernel: `ifconfig tunN destroy` wedges forever
# while another process holds /dev/tunN open.
#
# On a fixed (post-patch) kernel: `ifconfig tunN destroy` returns
# EBUSY ("Device busy") immediately.
#
# This script alocates a fresh tun, holds it open with `sleep < /dev/tunN`,
# tries to destroy it with a 5-second timeout, and prints PASS/FAIL.

set -u

REQUIRE_ROOT() {
	if [ "$(id -u)" -ne 0 ]; then
		exec sudo "$0" "$@"
	fi
}
REQUIRE_ROOT "$@"

TIMEOUT=5
TUN_IF=""
HOLDER_PID=""

cleanup() {
	if [ -n "${HOLDER_PID}" ] && kill -0 "${HOLDER_PID}" 2>/dev/null; then
		kill "${HOLDER_PID}" 2>/dev/null || true
		wait "${HOLDER_PID}" 2>/dev/null || true
	fi
	if [ -n "${TUN_IF}" ] && ifconfig "${TUN_IF}" >/dev/null 2>&1; then
		# Only safe if no wedged destroy is in flight
		if ! pgrep -f "ifconfig ${TUN_IF} destroy" >/dev/null; then
			ifconfig "${TUN_IF}" destroy 2>/dev/null || true
		fi
	fi
}
trap cleanup EXIT INT TERM

echo "Kernel: $(uname -v)"
echo ""

TUN_IF=$(ifconfig tun create) || {
	echo "FAIL: ifconfig tun create failed" >&2
	exit 1
}
echo "[+] created ${TUN_IF}"

# hold /dev/tunN open with a shell redirect (no Python dep)
sleep 99999 < /dev/${TUN_IF} &
HOLDER_PID=$!
sleep 1

if ! kill -0 "${HOLDER_PID}" 2>/dev/null; then
	echo "FAIL: holder sleep died immediately" >&2
	exit 1
fi

fstat /dev/${TUN_IF} >/dev/null 2>&1 && echo "[+] /dev/${TUN_IF} held open by PID ${HOLDER_PID}"

# Run destroy in background with timeout
echo "[+] running 'ifconfig ${TUN_IF} destroy' (timeout ${TIMEOUT}s)..."
ifconfig "${TUN_IF}" destroy 2>/tmp/test_tun_destroy.err &
DESTROY_PID=$!

i=0
while [ $i -lt ${TIMEOUT} ]; do
	if ! kill -0 "${DESTROY_PID}" 2>/dev/null; then
		wait "${DESTROY_PID}" 2>/dev/null
		rc=$?
		echo ""
		if [ $rc -eq 0 ]; then
			echo "UNEXPECTED: ifconfig destroy succeeded while ${TUN_IF}"
			echo "            had an open consumer. The patch is supposed"
			echo "            to refuse this case with EBUSY."
			exit 1
		fi
		err=$(cat /tmp/test_tun_destroy.err 2>/dev/null)
		echo "  exit code: ${rc}"
		echo "  stderr:    ${err}"
		case "${err}" in
		*Device\ busy*|*EBUSY*)
			echo ""
			echo "PASS: kernel correctly returned EBUSY. Patch is live."
			exit 0
			;;
		*)
			echo ""
			echo "PARTIAL: ifconfig destroy failed but not with the expected"
			echo "         'Device busy' message. Treat as inconclusive."
			exit 2
			;;
		esac
	fi
	sleep 1
	i=$((i+1))
done

# wedged
echo ""
echo "FAIL: ifconfig destroy did not return within ${TIMEOUT}s."
echo "      Kernel is still affected by the deadlock. The patched module"
echo "      was probably not actually built into this kernel (ccache?)."
echo ""
echo "Wedged thread:"
ipid=$(pgrep -f "^ifconfig ${TUN_IF} destroy" | head -1)
[ -n "${ipid}" ] && procstat -kk ${ipid} | sed 's/^/    /'
echo ""
echo "*** REBOOT REQUIRED. ***"
trap - EXIT
exit 1
