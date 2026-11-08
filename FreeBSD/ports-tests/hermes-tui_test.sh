#!/bin/sh
# misc/hermes-tui regression test.
#
# Installs the freshly-built hermes-agent and hermes-tui packages from the
# poudriere builder, then checks:
#
#   1. hermes-tui pins hermes-agent to its own version (the TUI speaks
#      hermes-agent's tui_gateway protocol, which moves every release).
#
#   2. `hermes --tui` starts the Ink TUI from the prebuilt bundle with the
#      system node (HERMES_NODE, set by the hermes-agent wrapper).  Without
#      the bundle hermes falls back to an npm build inside the read-only
#      install tree: "Preparing Node dependencies failed".  Without
#      HERMES_NODE upstream's pm refuses to provide node: "InstallError".
#
#   3. Removing hermes-tui brings back the no-bundle state, so the bundle
#      really comes from this package and not from hermes-agent.
#
# No LLM is needed: the TUI renders its status line before any request.
#
# Runs as normal user; the script sudo's for pkg install/delete.

set -eu

JAIL=builder
TREE=official
PKGDIR=/usr/local/poudriere/data/packages/${JAIL}-${TREE}/.latest/All

if [ "$(uname -s)" != "FreeBSD" ]; then
	printf 'SKIP  hermes-tui test is FreeBSD-only (this is %s)\n' "$(uname -s)"
	exit 0
fi

TUI_HOME=""
cleanup() {
	set +e
	[ -n "${TUI_HOME}" ] && rm -rf "${TUI_HOME}"
	for p in hermes-tui hermes-agent; do
		pkg info -q "$p" 2>/dev/null && sudo pkg delete -y "$p" >/dev/null 2>&1
	done
	set -e
}
trap cleanup EXIT INT TERM

# The TUI spawns an unmanaged gateway that outlives it (idle exit 600s).
# Kill the one whose HOME is $1.
stop_home_gateway() {
	_pids=""
	for p in $(pgrep -U "$(id -u)" python3 2>/dev/null); do
		procstat -e "$p" 2>/dev/null | grep -qE " HOME=$1( |$)" && _pids="${_pids} $p"
	done
	[ -n "${_pids}" ] || return 0
	kill ${_pids} 2>/dev/null
	# The gateway writes its shutdown state into HOME on SIGTERM; wait, or
	# the caller's rm -rf races it ("Directory not empty").
	pwait -t 15 ${_pids} 2>/dev/null
	return 0
}

pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; exit 1; }

# Drive the real TUI in a pty for 20s and print its ANSI-stripped output.
# stdin is held open (EOF quits the TUI), --safe-mode skips the first-run
# telemetry prompt, `script -t 0` flushes before timeout kills it.
run_tui() {
	TUI_HOME=$(mktemp -d /tmp/hermes-tui.XXXXXX)
	set +e
	(sleep 30) | env \
		HOME="${TUI_HOME}" TERM=xterm-256color \
		CUSTOM_BASE_URL="http://127.0.0.1:9/v1" CUSTOM_API_KEY="sk-unused" \
		timeout --foreground 20 script -q -t 0 "${TUI_HOME}/out.txt" sh -c \
			'stty cols 120 rows 40; exec hermes --provider custom -m dummy --safe-mode --tui' \
		>/dev/null 2>&1
	stop_home_gateway "${TUI_HOME}"
	set -e
	sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' "${TUI_HOME}/out.txt" | tr -s ' \r'
	rm -rf "${TUI_HOME}"
	TUI_HOME=""
}

# --- 0. Install both freshly-built packages --------------------------------
AGENT_PKG=$(ls -t ${PKGDIR}/hermes-agent-*.pkg 2>/dev/null | head -1)
TUI_PKG=$(ls -t ${PKGDIR}/hermes-tui-*.pkg 2>/dev/null | head -1)
[ -n "${AGENT_PKG}" ] || fail "no hermes-agent-*.pkg in ${PKGDIR}"
[ -n "${TUI_PKG}" ] || fail "no hermes-tui-*.pkg in ${PKGDIR}"
printf 'Installing %s %s\n' "${AGENT_PKG}" "${TUI_PKG}"
sudo pkg install -fy "${AGENT_PKG}" "${TUI_PKG}" >/dev/null

AGENT_VER=$(pkg query '%v' hermes-agent)
TUI_VER=$(pkg query '%v' hermes-tui)
printf 'Installed: hermes-agent %s, hermes-tui %s\n' "${AGENT_VER}" "${TUI_VER}"

# --- 1. Version pin --------------------------------------------------------
DEP=$(pkg query '%dn %dv' hermes-tui | awk '$1 == "hermes-agent"')
[ -n "${DEP}" ] || fail "hermes-tui does not depend on hermes-agent"
[ "${AGENT_VER%%[_,]*}" = "${TUI_VER%%[_,]*}" ] \
	|| fail "hermes-tui ${TUI_VER} installed against hermes-agent ${AGENT_VER}"
pass "hermes-tui ${TUI_VER} matches hermes-agent ${AGENT_VER%%[_,]*}"

# --- 2. TUI starts ---------------------------------------------------------
OUT=$(run_tui)
case "${OUT}" in
	*"Node dependencies failed"*|*Traceback*|*InstallError*)
		printf '%s\n' "${OUT}" | sed -n '1,30p'
		fail "hermes --tui failed to start" ;;
	*"tools · "*" skills"*)
		pass "hermes --tui renders the Ink interface" ;;
	*)
		printf '%s\n' "${OUT}" | sed -n '1,30p'
		fail "hermes --tui never rendered its status line in 20s" ;;
esac

# --- 3. Bundle belongs to hermes-tui --------------------------------------
sudo pkg delete -y hermes-tui >/dev/null
[ ! -e /usr/local/lib/hermes-agent/hermes_cli/tui_dist ] \
	|| fail "hermes_cli/tui_dist left behind after pkg delete hermes-tui"
OUT=$(run_tui)
case "${OUT}" in
	*"tools · "*" skills"*)
		fail "hermes --tui still renders without hermes-tui: bundle comes from elsewhere" ;;
	*)
		pass "hermes --tui needs hermes-tui (no TUI after pkg delete)" ;;
esac

printf 'All hermes-tui checks passed.\n'
