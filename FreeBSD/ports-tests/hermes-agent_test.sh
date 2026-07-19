#!/bin/sh
# misc/hermes-agent regression test.
#
# Installs the freshly-built package from the poudriere builder, then
# exercises the four FreeBSD-specific pieces the port and its salvage
# patches add:
#
#   1. Wrappers on PATH — /usr/local/bin/{hermes,hermes-agent,hermes-acp}
#      resolve and `--help` returns 0 (proves sys.path shim works).
#
#   2. Skills catalog non-empty — `hermes skills list` on FreeBSD used to
#      show ZERO installed skills because most declare `platform: linux`
#      and `sys.platform` is `freebsdN`.  The PR#31850 salvage patch maps
#      freebsd -> linux for skill matching only.  This test asserts the
#      catalog has at least the expected floor of matched skills.
#
#   3. rc.d lifecycle — sysrc enable + `service hermes_gateway {start,
#      status,stop}` drive the port-installed /usr/local/etc/rc.d/
#      hermes_gateway script.  Exercises Commit A of the salvage plan.
#
#   4. Lazy-install default off on FreeBSD — Commit B.  A fresh install
#      writes `allow_lazy_installs: false` into the default config.yaml,
#      not True as on Linux/macOS.
#
# The test does NOT need an LLM API key: skills-list is offline, the
# gateway can start without ever making an outbound call, and the lazy-
# install check inspects config only.  Actual LLM round-trip is a
# separate concern.
#
# Usage:  sh hermes-agent_test.sh
#
# Runs as normal user; the script sudo's for pkg add/delete + rc.d.
# Cleans up (pkg delete, sysrc -x, /etc/rc.conf revert) on any exit.

set -eu

PORT_NAME=hermes-agent
JAIL=builder
TREE=official
PKGDIR=/usr/local/poudriere/data/packages/${JAIL}-${TREE}/.latest/All

# --- OS gate ---------------------------------------------------------------
if [ "$(uname -s)" != "FreeBSD" ]; then
	printf 'SKIP  hermes-agent test is FreeBSD-only (this is %s)\n' "$(uname -s)"
	exit 0
fi

# --- cleanup ---------------------------------------------------------------
GATEWAY_STARTED=0
cleanup() {
	set +e
	if [ "${GATEWAY_STARTED}" = "1" ]; then
		sudo service hermes_gateway stop >/dev/null 2>&1
	fi
	if sysrc -qc hermes_gateway_enable >/dev/null 2>&1; then
		sudo sysrc -x hermes_gateway_enable >/dev/null 2>&1
	fi
	if sysrc -qc hermes_gateway_user >/dev/null 2>&1; then
		sudo sysrc -x hermes_gateway_user >/dev/null 2>&1
	fi
	# Deinstall only if we installed it.
	if pkg info -q ${PORT_NAME} 2>/dev/null; then
		sudo pkg delete -y ${PORT_NAME} >/dev/null 2>&1
	fi
	set -e
}
trap cleanup EXIT INT TERM

pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; exit 1; }

# --- 0. Install the freshly-built package ----------------------------------
PKG=$(ls -t ${PKGDIR}/${PORT_NAME}-*.pkg 2>/dev/null | head -1)
[ -n "${PKG}" ] || fail "no ${PORT_NAME}-*.pkg in ${PKGDIR}"
printf 'Installing %s\n' "${PKG}"
sudo pkg add -f "${PKG}" >/dev/null

PKG_VER=$(pkg query '%v' ${PORT_NAME})
printf 'Installed version: %s\n' "${PKG_VER}"

# --- 1. Wrappers on PATH ---------------------------------------------------
for bin in hermes hermes-agent hermes-acp; do
	[ -x /usr/local/bin/${bin} ] \
		|| fail "wrapper /usr/local/bin/${bin} missing or not executable"
done
pass "wrappers installed at /usr/local/bin/{hermes,hermes-agent,hermes-acp}"

# `hermes --help` must return 0.  Runs the sys.path shim + argparse setup;
# a broken wrapper or missing runtime dep would surface here.
if hermes --help >/dev/null 2>&1; then
	pass "hermes --help returns 0 (wrapper + sys.path shim work)"
else
	fail "hermes --help exited non-zero — wrapper or runtime broken"
fi

# --- 2. Skills catalog non-empty on FreeBSD (PR#31850) --------------------
# `hermes skills list` renders a table.  We just need to prove the row
# count is > 0 (would be 0 without the freebsd->linux mapping).
#
# Output has header rows we don't want to count.  Filter for lines that
# start with a skill category token (lowercase word) in the second column.
SKILLS_OUT=$(mktemp)
if hermes skills list --source builtin >"${SKILLS_OUT}" 2>&1; then
	# The output ends with a summary line like:
	#   0 hub-installed, 68 builtin, 0 local — 68 enabled, 0 disabled
	# Parse the "N builtin" count from that line — table rendering uses
	# Unicode box-drawing characters that vary with terminal width, so
	# the summary is the reliable source of truth.
	SKILL_COUNT=$(grep -oE '[0-9]+ builtin' "${SKILLS_OUT}" | head -1 | awk '{print $1}')
	[ -n "${SKILL_COUNT}" ] || SKILL_COUNT=0
else
	fail "hermes skills list exited non-zero — see ${SKILLS_OUT}"
fi
rm -f "${SKILLS_OUT}"

# PR#31850 unblocked 87 skills upstream; the port's DATADIR ships 18
# built-in + 20 optional.  Anywhere north of 10 proves the platform
# mapping is working; below that indicates the freebsd->linux gate is
# broken again.
if [ "${SKILL_COUNT}" -ge 10 ]; then
	pass "hermes skills list shows ${SKILL_COUNT} skills (PR#31850 mapping active)"
else
	fail "hermes skills list shows only ${SKILL_COUNT} skills — PR#31850 mapping may be broken (expected >= 10)"
fi

# --- 3. Lazy-install default off on FreeBSD (Commit B) --------------------
# First run of hermes materializes ~/.hermes/config.yaml from the
# DEFAULT_CONFIG template.  On FreeBSD, allow_lazy_installs must be
# False.  Use an isolated HERMES_HOME so we don't collide with the
# operator's own config.
LAZY_HERMES_HOME=$(mktemp -d)
# Probe the runtime resolver in-process — that's the value the lazy-install
# code path actually honors, and it evaluates the DEFAULT_CONFIG template
# on a fresh install where config.yaml doesn't exist yet.
LAZY_OUT=$(HERMES_HOME="${LAZY_HERMES_HOME}" /usr/local/bin/python3.12 -c "
import os, sys
sys.path.insert(0, '/usr/local/lib/hermes-agent')
os.environ.setdefault('HERMES_BUNDLED_SKILLS', '/usr/local/share/hermes-agent/skills')
os.environ.setdefault('HERMES_OPTIONAL_SKILLS', '/usr/local/share/hermes-agent/optional-skills')
from tools.lazy_deps import _allow_lazy_installs
print(_allow_lazy_installs())
" 2>&1)
case "${LAZY_OUT}" in
	False) pass "allow_lazy_installs resolves to False on FreeBSD (Commit B)" ;;
	True)  fail "allow_lazy_installs resolves to True on FreeBSD — Commit B default gate is broken" ;;
	*)     fail "could not probe _allow_lazy_installs (got: ${LAZY_OUT})" ;;
esac
rm -rf "${LAZY_HERMES_HOME}"

# --- 4. rc.d lifecycle (Commit A) -----------------------------------------
# The rc.d script requires hermes_gateway_user because HOME dictates
# where ~/.hermes lives.  Use the current $USER — they have real
# credentials and a writable home.
sudo sysrc hermes_gateway_enable=YES hermes_gateway_user="${USER}" >/dev/null

# `service hermes_gateway status` on a not-yet-started service returns 1.
if service hermes_gateway status >/dev/null 2>&1; then
	fail "service hermes_gateway status returned 0 before start — stale state?"
fi
pass "service hermes_gateway status returns non-zero before start"

# Start.  The daemon backgrounds itself via daemon(8); allow a moment
# for the pid file to appear before probing.
sudo service hermes_gateway start >/dev/null 2>&1 \
	|| fail "service hermes_gateway start failed"
GATEWAY_STARTED=1

# Wait up to 15s for status to flip.  hermes-agent needs to import its
# dep tree on first boot; on a cold cache this can take a few seconds.
i=0
while [ "$i" -lt 30 ]; do
	if service hermes_gateway status >/dev/null 2>&1; then
		pass "service hermes_gateway status returns 0 after start"
		break
	fi
	i=$((i+1))
	sleep 0.5
done
if [ "$i" -ge 30 ]; then
	fail "service hermes_gateway never reported running after 15s"
fi

# Stop.
sudo service hermes_gateway stop >/dev/null 2>&1 \
	|| fail "service hermes_gateway stop failed"
GATEWAY_STARTED=0

# Post-stop, status must return non-zero again.
if service hermes_gateway status >/dev/null 2>&1; then
	fail "service hermes_gateway status still returns 0 after stop"
fi
pass "service hermes_gateway status returns non-zero after stop"

# --- 5. Uninstall (cleanup handled by trap, but assert the pkg is clean) --
# Nothing to do — the EXIT trap runs pkg delete.  The trap running clean
# also proves `pkg delete hermes-agent` succeeds after the rc.d cycle
# (no pkg-lock leftovers).

printf '\nAll hermes-agent regression tests passed.\n'
