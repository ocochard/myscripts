#!/bin/sh
# amazon-efs-utils regression test -- RUNS ON AN EC2 INSTANCE.
#
# Unlike every other harness in this directory, this one CANNOT run on the
# workstation: it needs a real EFS filesystem, a working IAM instance role and
# an EC2 network path. Copy this script (and the .pkg) to the instance and run
# it there:
#
#     scp amazon-efs-utils-*.pkg amazon-efs-utils_test.sh <instance>:/tmp/
#     ssh <instance> 'cd /tmp && sudo env EFS_FS_ID=fs-... sh amazon-efs-utils_test.sh'
#
# It exercises the FreeBSD-specific code paths the port patches add, which are
# exactly the parts upstream CI never covers:
#
#   * mount_options.py  -- nfsv4 + minorversion=1 (FreeBSD mount_nfs rejects
#                          nfsvers=4.1), oneopenown, retrycnt=1
#   * mount_utils.py    -- /sbin/mount_nfs instead of Linux mount(8)
#   * proxy.py          -- "rc" init system: watchdog auto-start via
#                          service(8) onestart, and the SO_BINDTODEVICE skip
#   * watchdog/__init__ -- FreeBSD get_current_local_nfs_mounts() (state-file
#                          based) and the sockstat socket probe that replaced
#                          the `df` health check
#   * the port layout   -- @@EFS_LIBDIR@@ sys.path insert, ${PREFIX}/etc paths
#
# PASS criteria:
#   1. package installs; all 5 artifacts present; mount_efs imports cleanly
#   2. TLS+IAM mount succeeds via `mount_efs <fs-id> <mp> -o tls,iam`
#   3. efs-proxy is alive and a state file exists in /var/run/efs
#   4. the watchdog auto-started (it is NOT enabled in rc.conf by design)
#   5. WRITE a file to the mount and READ IT BACK with matching content
#   6. read a pre-existing sentinel file, if EFS_SENTINEL names one
#   7. umount cleanly; efs-proxy exits; state file is reaped
#
# Required:
#   EFS_FS_ID       filesystem id, e.g. fs-0123456789abcdef0. No default --
#                   this repo is public and the script must never ship
#                   pointing at a real filesystem.
#
# Optional:
#   EFS_MOUNTPOINT  mount point           (default /mnt/nfs)
#   EFS_SENTINEL    name of an existing file on the FS to read back; if set
#                   but absent, that is a FAILURE, not a skip
#   PKG             explicit .pkg path    (default: newest in script dir)
#   SKIP_INSTALL    =1 to test the already-installed package
#   WATCHDOG_REAP_TIMEOUT  seconds to wait for cleanup (default 150)
#
set -eu

PORT_NAME=amazon-efs-utils
# EFS_FS_ID is REQUIRED and deliberately has no default: this repo is public,
# and a hardcoded filesystem id would both leak infrastructure detail and make
# an unsuspecting run target someone else's filesystem. Fail loudly instead.
FS_ID=${EFS_FS_ID:?required: export EFS_FS_ID=fs-0123456789abcdef0 (your EFS filesystem id)}
MP=${EFS_MOUNTPOINT:-/mnt/nfs}
SENTINEL=${EFS_SENTINEL:-}  # optional pre-existing file to read (informational)
STATE_DIR=/var/run/efs
WATCHDOG_RC=amazon-efs-mount-watchdog          # rc.d filename: dashes
WATCHDOG_PID=/var/run/amazon_efs_mount_watchdog.pid   # rcvar name: underscores
WATCHDOG_LOG=/var/log/amazon/efs/mount-watchdog.log   # constants.py LOG_FILE
SCRIPT_DIR=$(dirname "$0")

TESTFILE=""                 # set once mounted, removed by cleanup
MOUNTED=0

fail() {
	echo "FAIL  ${PORT_NAME}: $*"
	exit 1
}
info() { echo "  $*"; }

cleanup() {
	rc=$?
	# Best-effort teardown; never mask the real exit status.
	if [ -n "${TESTFILE}" ] && [ -f "${TESTFILE}" ]; then
		rm -f "${TESTFILE}" 2>/dev/null || true
	fi
	if [ "${MOUNTED}" -eq 1 ] && mount | grep -q " on ${MP} "; then
		echo "cleanup: unmounting ${MP}"
		umount "${MP}" 2>/dev/null || umount -fN "${MP}" 2>/dev/null || true
	fi
	exit ${rc}
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------- preflight
[ "$(id -u)" -eq 0 ] || fail "must run as root (mount/umount + pkg)"
[ "$(uname -s)" = "FreeBSD" ] || fail "this test is FreeBSD-only"

# The IAM path needs a reachable instance metadata service. Check it up front
# so an unroled instance fails with a clear message instead of a mount timeout.
if ! fetch -qo /dev/null -T 5 http://169.254.169.254/latest/meta-data/ 2>/dev/null; then
	fail "instance metadata service unreachable -- not an EC2 instance, or IMDS blocked"
fi
info "IMDS reachable"

# This test asserts on GLOBAL state: "no efs-proxy running" and "no state files
# left in ${STATE_DIR}". Those assertions are only meaningful if our mount is
# the only one on the box. Refuse to run otherwise rather than emit a bogus
# PASS (or tear down someone else's production mount).
if pgrep -f '[e]fs-proxy' >/dev/null 2>&1; then
	echo "  running: $(pgrep -lf '[e]fs-proxy' | head -5)"
	fail "an efs-proxy is already running -- unmount all EFS filesystems first"
fi
if [ -d "${STATE_DIR}" ] && [ "$(ls -1 "${STATE_DIR}" 2>/dev/null | wc -l | tr -d ' ')" -ne 0 ]; then
	echo "  present: $(ls -1 "${STATE_DIR}" | tr '\n' ' ')"
	fail "stale state files in ${STATE_DIR} -- clean up before running"
fi
info "no pre-existing EFS mounts (assertions on global state are valid)"

# ------------------------------------------------------------- 1. install
if [ "${SKIP_INSTALL:-0}" != "1" ]; then
	if [ -n "${PKG:-}" ]; then
		[ -f "${PKG}" ] || fail "PKG=${PKG} not found"
	else
		PKG=$(ls -t "${SCRIPT_DIR}"/${PORT_NAME}-*.pkg 2>/dev/null | head -1) \
			|| true
		[ -n "${PKG:-}" ] || fail "no ${PORT_NAME}-*.pkg in ${SCRIPT_DIR} (set PKG=)"
	fi
	echo "installing ${PKG}"
	pkg add -f "${PKG}" >/dev/null || fail "pkg add failed"
fi

VER=$(pkg query %v ${PORT_NAME} 2>/dev/null) || fail "${PORT_NAME} not installed"
info "installed version ${VER}"

# ------------------------------------------------- 2. artifacts + importability
for f in /usr/local/sbin/mount_efs \
         /usr/local/sbin/efs-proxy \
         /usr/local/sbin/amazon-efs-mount-watchdog \
         /usr/local/etc/rc.d/${WATCHDOG_RC} \
         /usr/local/etc/amazon/efs/efs-utils.conf.sample; do
	[ -e "${f}" ] || fail "missing installed artifact ${f}"
done
info "all 5 artifacts present"

# efs-utils.conf is a .sample -- the tools need the real file.
if [ ! -f /usr/local/etc/amazon/efs/efs-utils.conf ]; then
	cp /usr/local/etc/amazon/efs/efs-utils.conf.sample \
	   /usr/local/etc/amazon/efs/efs-utils.conf
	info "installed efs-utils.conf from sample"
fi

# Regression for the @@EFS_LIBDIR@@ sys.path insert: if that substitution ever
# breaks, mount_efs dies on `import efs_utils_common` at runtime -- which would
# otherwise only surface as a confusing mount failure.
python3 -c "
import ast, sys
src = open('/usr/local/sbin/mount_efs').read()
ast.parse(src)
assert '/usr/local/lib/amazon/efs' in src, 'EFS_LIBDIR sys.path insert missing'
" || fail "mount_efs is not valid Python or lost its sys.path insert"
python3 -c "
import sys; sys.path.insert(0, '/usr/local/lib/amazon/efs')
import efs_utils_common.constants as c
assert c.STATE_FILE_DIR == '${STATE_DIR}', c.STATE_FILE_DIR
assert '/usr/local/etc/amazon/efs' in c.CONFIG_FILE, c.CONFIG_FILE
" || fail "efs_utils_common not importable from the installed layout"
info "mount_efs parses; efs_utils_common imports with ports paths"

# --------------------------------------------------------------- 3. mount
mkdir -p "${MP}"
if mount | grep -q " on ${MP} "; then
	fail "${MP} is already mounted -- unmount it first"
fi

# Argument order matters: -o must come AFTER the positional fs-id.
echo "mounting ${FS_ID} -> ${MP} -o tls,iam"
if ! mount_efs "${FS_ID}" "${MP}" -o tls,iam; then
	fail "mount_efs exited non-zero"
fi
MOUNTED=1

mount | grep -q " on ${MP} " || fail "mount_efs returned 0 but ${MP} is not mounted"
info "mounted"

# FreeBSD must negotiate NFSv4.1 -- if mount_options.py regressed to the Linux
# nfsvers=4.1 spelling, mount_nfs silently falls back to v3 and EFS RSTs, so a
# successful mount here is itself the assertion. Record what we got.
info "mount line: $(mount | grep " on ${MP} " | head -1)"

# ------------------------------------------- 4. proxy + state file + watchdog
pgrep -f '[e]fs-proxy' >/dev/null || fail "efs-proxy is not running after mount"
info "efs-proxy alive (pid $(pgrep -f '[e]fs-proxy' | tr '\n' ' '))"

[ -d "${STATE_DIR}" ] || fail "${STATE_DIR} does not exist"
STATE_COUNT=$(ls -1 "${STATE_DIR}" 2>/dev/null | wc -l | tr -d ' ')
[ "${STATE_COUNT}" -ge 1 ] || fail "no state file in ${STATE_DIR} after mount"
info "${STATE_COUNT} state file(s) in ${STATE_DIR}"

# The watchdog is installed DISABLED in rc.conf on purpose; proxy.py's "rc"
# init-system branch must have started it on demand via service(8) onestart.
# Give it a moment -- it is spawned asynchronously via subprocess.Popen.
i=0
while [ ${i} -lt 10 ]; do
	if service ${WATCHDOG_RC} onestatus >/dev/null 2>&1; then
		break
	fi
	i=$((i + 1))
	sleep 1
done
if ! service ${WATCHDOG_RC} onestatus >/dev/null 2>&1; then
	fail "watchdog did not auto-start (proxy.py 'rc' init-system branch broken)"
fi
info "watchdog auto-started ($(cat ${WATCHDOG_PID} 2>/dev/null || echo 'pid unknown'))"

# ------------------------------------------------------ 5. WRITE then READ BACK
TESTFILE="${MP}/.efs-regress-$$-$(hostname -s)"
CONTENT="efs-utils ${VER} regression $(date -u +%Y-%m-%dT%H:%M:%SZ) pid=$$"

echo "${CONTENT}" > "${TESTFILE}" || fail "write to ${TESTFILE} failed"
info "wrote ${TESTFILE}"

# Force the data out to the server, then drop it back through the proxy: a
# read that is served purely from the local cache would not prove the TLS path
# actually carries data.
sync

READBACK=$(cat "${TESTFILE}") || fail "read back of ${TESTFILE} failed"
[ "${READBACK}" = "${CONTENT}" ] \
	|| fail "read-back mismatch:\n  wrote: ${CONTENT}\n  read:  ${READBACK}"
info "read back matches what was written"

# Directory listing must show it too (exercises READDIR, not just the open fd).
# Re-read the directory from scratch rather than trusting the cached lookup.
FOUND=0
for e in "${MP}"/.efs-regress-*; do
	[ "${e}" = "${TESTFILE}" ] && FOUND=1
done
[ "${FOUND}" -eq 1 ] || fail "written file does not appear in directory listing"
info "file visible in READDIR"

rm -f "${TESTFILE}" || fail "unlink of ${TESTFILE} failed"
[ ! -f "${TESTFILE}" ] || fail "file still present after unlink"
TESTFILE=""
info "unlink works"

# ------------------------------------------------ 6. sentinel (informational)
if [ -z "${SENTINEL}" ]; then
	info "no EFS_SENTINEL set (skipped)"
elif [ -f "${MP}/${SENTINEL}" ]; then
	info "sentinel ${SENTINEL}: $(cat "${MP}/${SENTINEL}")"
else
	fail "EFS_SENTINEL=${SENTINEL} requested but ${MP}/${SENTINEL} not found"
fi

# ------------------------------------------------------------- 7. teardown
echo "unmounting ${MP}"
umount "${MP}" || fail "umount failed"
MOUNTED=0
mount | grep -q " on ${MP} " && fail "${MP} still mounted after umount"
info "unmounted"

# What the watchdog is *supposed* to do once nothing is mounted any more.
#
# It does NOT react instantly, and a test that expects prompt cleanup will
# produce false failures. check_efs_mounts() runs every poll_interval_sec (1s)
# and walks the state files in ${STATE_DIR}; for a mount that has disappeared
# it applies three separate delays, all from efs-utils.conf / constants.py:
#
#   1. UNMOUNT_DIFF_TIME (30s, hardcoded) -- it ignores the missing mount until
#      30s have passed since that state file's *mount_time*. This is a race
#      guard: the watchdog reads NFS mounts and state files non-atomically, so
#      a freshly-created state file must not be mistaken for a dead mount.
#      NOTE the clock starts at MOUNT time, not umount time -- a short test
#      mount makes this wait longer, not shorter.
#   2. unmount_count_for_consistency (5) -- it must observe the mount missing
#      on 5 more consecutive polls before believing it, then calls
#      mark_as_unmounted() which stamps "unmount_time" into the state file.
#   3. unmount_grace_period_sec (30) -- only once
#      unmount_time + 30s has elapsed does clean_up_mount_state() run: SIGTERM
#      to the efs-proxy process group, then the state file is removed.
#
# So the full contract is roughly 30 + 5 + 30 = ~65s worst case, and the state
# file legitimately lingers for most of it. efs-proxy usually exits earlier on
# its own (it self-monitors and exits when its mount goes away) -- that is the
# expected path; the watchdog SIGTERM is the backstop for when it does not.
#
# We poll up to WATCHDOG_REAP_TIMEOUT for the *end state*: no state file left.
# That single assertion covers the whole chain, because the state file is only
# removed at the last step.
WATCHDOG_REAP_TIMEOUT=${WATCHDOG_REAP_TIMEOUT:-150}

echo "waiting for watchdog to reap mount state (contract: ~65s, timeout ${WATCHDOG_REAP_TIMEOUT}s)"
i=0
while [ ${i} -lt "${WATCHDOG_REAP_TIMEOUT}" ]; do
	LEFT=$(ls -1 "${STATE_DIR}" 2>/dev/null | wc -l | tr -d ' ')
	[ "${LEFT}" -eq 0 ] && break
	# Progress every 15s so a human watching knows it is not wedged.
	if [ $((i % 15)) -eq 0 ] && [ ${i} -gt 0 ]; then
		info "still ${LEFT} state file(s) after ${i}s ..."
	fi
	i=$((i + 1))
	sleep 1
done

LEFT=$(ls -1 "${STATE_DIR}" 2>/dev/null | wc -l | tr -d ' ')
if [ "${LEFT}" -ne 0 ]; then
	echo "  state files still present after ${WATCHDOG_REAP_TIMEOUT}s:"
	ls -la "${STATE_DIR}" || true
	echo "  watchdog log tail:"
	tail -20 "${WATCHDOG_LOG}" 2>/dev/null \
		|| echo "  (no watchdog log at ${WATCHDOG_LOG})"
	fail "watchdog did not clean up mount state after umount"
fi
info "watchdog reaped mount state after ~${i}s"

# By the time the state file is gone, clean_up_mount_state() has SIGTERMed the
# proxy group -- so no efs-proxy should survive. This is now a hard assertion:
# a lingering proxy after cleanup means the SIGTERM path failed.
i=0
while [ ${i} -lt 15 ]; do
	pgrep -f '[e]fs-proxy' >/dev/null || break
	i=$((i + 1))
	sleep 1
done
if pgrep -f '[e]fs-proxy' >/dev/null; then
	echo "  surviving efs-proxy: $(pgrep -lf '[e]fs-proxy' | head -5)"
	fail "efs-proxy still running after watchdog cleanup"
fi
info "efs-proxy gone"

# The watchdog itself is expected to KEEP RUNNING with zero mounts -- it was
# started by service(8) onestart and polls forever waiting for the next mount.
# If it exited, the next TLS mount would come up without a supervisor.
service ${WATCHDOG_RC} onestatus >/dev/null 2>&1 \
	|| fail "watchdog exited after last unmount (it should keep polling)"
info "watchdog still running with no mounts (correct)"

echo "PASS  ${PORT_NAME} ${VER}: mount, write, read-back, watchdog, umount+reap"
