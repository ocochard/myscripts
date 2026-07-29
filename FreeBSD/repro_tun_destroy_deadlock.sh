#!/bin/sh
#
# Reproduce the tun_destroy(9) deadlock that wedges ifnet_detach_sxlock
# on FreeBSD 16-CURRENT.
#
# What it does:
#   1. Allocates a fresh tun(4) cloner (never touches an existing one).
#   2. Opens that /dev/tunN from a background sleep process via a shell
#      redirect, which holds the fd open the same way openvpn would.
#   3. Runs `ifconfig tunN destroy`.
#
# Expected outcome (buggy kernel):
#   `ifconfig tunN destroy` never returns. The thread is parked in
#   `tun_destroy -> cv_wait_sig` on WCHAN `tun_cond`, holding
#   `ifnet_detach_sxlock` exclusively. Every subsequent cloner-destroy
#   on the host wedges in `_sx_xlock_hard`. ONLY A REBOOT RECOVERS.
#
# Expected outcome (fixed kernel, hypothetical):
#   `ifconfig tunN destroy` returns immediately with `Device busy` (or
#   similar) and exits non-zero. The script reports the kernel as fixed.
#
# Refs:
#   - FreeBSD/docs/tun_destroy_deadlock_case_study.md in this repo
#   - sys/net/if_tuntap.c:646-670 (tun_destroy CV-wait loop)
#   - sys/net/if_clone.c:480 (sx_xlock(&ifnet_detach_sxlock))

set -u

REQUIRE_ROOT() {
	if [ "$(id -u)" -ne 0 ]; then
		echo "Re-running under sudo..."
		exec sudo "$0" "$@"
	fi
}
REQUIRE_ROOT "$@"

DESTROY_TIMEOUT=10	# seconds to wait before declaring the wedge
HOLDER_PID=""
TUN_IF=""

cleanup() {
	# Only useful if the bug is fixed and ifconfig destroy returned.
	# If it wedged, the kernel still holds the sx lock and nothing here
	# can help — the user has to reboot anyway.
	if [ -n "${HOLDER_PID}" ] && kill -0 "${HOLDER_PID}" 2>/dev/null; then
		kill "${HOLDER_PID}" 2>/dev/null || true
	fi
	if [ -n "${TUN_IF}" ] && ifconfig "${TUN_IF}" >/dev/null 2>&1; then
		# Only attempt cleanup destroy if we have no wedged ifconfig left
		if ! pgrep -f "ifconfig ${TUN_IF} destroy" >/dev/null; then
			ifconfig "${TUN_IF}" destroy 2>/dev/null || true
		fi
	fi
}
trap cleanup EXIT INT TERM

cat <<'WARN'
##############################################################################
# WARNING: this script will wedge the kernel's ifnet-clone subsystem on a
# buggy kernel. After running it on an affected system, EVERY subsequent
# `ifconfig <foo> destroy`, `jail -R`, `jls` (via poudriere) and similar
# call will block in uninterruptible sleep until you reboot.
#
# The reproducer itself is local and contained, but the side effect is
# system-wide. Do not run on a production host.
#
# Continuing in 5 seconds. Ctrl-C to abort.
##############################################################################
WARN
sleep 5

# 1. allocate a fresh tun cloner
TUN_IF=$(ifconfig tun create) || {
	echo "ifconfig tun create failed (kernel may already be wedged)" >&2
	exit 1
}
echo "[+] allocated ${TUN_IF}"

# 2. hold /dev/${TUN_IF} open from a background process.
#
# The shell `sleep 99999 < /dev/${TUN_IF}` form keeps the fd open via
# fd 0 of the long-running sleep, with no Python or compiled helper
# needed. open(2) on /dev/tunN goes through tun_open() which bumps
# tp->tun_busy from 0 -> 1; the bug requires tun_busy != 0 when the
# destroy is requested.
sleep 99999 < /dev/${TUN_IF} &
HOLDER_PID=$!
sleep 1

if ! kill -0 "${HOLDER_PID}" 2>/dev/null; then
	echo "[!] holder sleep died immediately, /dev/${TUN_IF} open failed?" >&2
	exit 1
fi

# sanity: confirm the kernel saw the open (tun_busy bumped)
echo "[+] /dev/${TUN_IF} held open by PID ${HOLDER_PID}:"
fstat /dev/${TUN_IF} 2>/dev/null | sed 's/^/    /'

# 3. trigger the destroy.
echo "[+] running 'ifconfig ${TUN_IF} destroy' in background; ${DESTROY_TIMEOUT}s timeout..."
ifconfig "${TUN_IF}" destroy &
DESTROY_PID=$!

# poll for completion vs wedge
i=0
while [ $i -lt ${DESTROY_TIMEOUT} ]; do
	if ! kill -0 "${DESTROY_PID}" 2>/dev/null; then
		# returned — fixed kernel, or unexpectedly fast
		wait "${DESTROY_PID}" 2>/dev/null
		rc=$?
		echo "[=] ifconfig ${TUN_IF} destroy exited with code ${rc}"
		if [ $rc -eq 0 ]; then
			echo "[!] UNEXPECTED: destroy succeeded while ${TUN_IF} was open."
			echo "    Either the kernel is fixed or the holder closed early."
		else
			echo "[OK] kernel correctly refused destroy of in-use tun."
			echo "    This kernel appears to NOT be affected by the bug."
		fi
		exit 0
	fi
	sleep 1
	i=$((i+1))
done

# wedged
echo ""
echo "##############################################################################"
echo "# WEDGED. ifconfig destroy did not return after ${DESTROY_TIMEOUT}s."
echo "##############################################################################"
echo ""
echo "Wedged thread stack:"
# the actual ifconfig is the child of the backgrounded sh job
IFCONFIG_PID=$(pgrep -f "^ifconfig ${TUN_IF} destroy" | head -1)
if [ -n "${IFCONFIG_PID}" ]; then
	ps -o pid,state,wchan,command -p ${IFCONFIG_PID} 2>/dev/null | sed 's/^/    /'
	procstat -kk ${IFCONFIG_PID} 2>/dev/null | sed 's/^/    /'
fi
echo ""
echo "Lock state (try another destroy from a second shell):"
echo "    sudo ifconfig epair create        # works"
echo "    sudo ifconfig <whatever> destroy  # will wedge in _sx_xlock_hard"
echo ""
echo "Recovery: REBOOT. Nothing else clears it."
echo ""
echo "If DEADLKRES is compiled in (GENERIC, not GENERIC-NODEBUG) and the"
echo "thresholds are at the defaults, the kernel will panic itself after"
echo "~15 minutes (debug.deadlkres.slptime_threshold ticks). Lower with:"
echo "    sudo sysctl debug.deadlkres.slptime_threshold=120 debug.deadlkres.blktime_threshold=60"
echo ""
# leave HOLDER_PID and the wedged ifconfig in place — the trap can't help
# us here, the kernel won't let us clean up.
trap - EXIT
exit 2
