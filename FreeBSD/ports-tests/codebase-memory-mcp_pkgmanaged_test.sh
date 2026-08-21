#!/bin/sh
# codebase-memory-mcp package-managed-install regression test.
#
# Proves the RUNTIME package-managed detection: when the binary runs from its
# package prefix (/usr/local/bin, i.e. NOT under ~/.local/bin), `install` must
#   1. NOT copy the binary into ~/.local/bin (the pkg owns it under its prefix),
#   2. NOT append `export PATH=...` to the user's shell rc, and
#   3. write agent configs that reference the REAL binary (/usr/local/bin/...),
#      never the ~/.local/bin path.
#
# This is the behaviour the port relies on so a `pkg install` never clobbers the
# package-manager-owned binary or edits the user's dotfiles. It replaces the old
# compile-time CBM_PACKAGE_MANAGED install-path gate with a runtime decision
# (self-path under bin_dir?), so no build flag is needed for this behaviour.
#
# Everything runs against a throwaway HOME so the user's real dotfiles and graph
# store are never touched, and is fully removed on exit.
set -eu

PORT_NAME=codebase-memory-mcp
JAIL=builder
TREE=official
PKGDIR=/usr/local/poudriere/data/packages/${JAIL}-${TREE}/.latest/All
BIN=/usr/local/bin/codebase-memory-mcp

WORKDIR=$(mktemp -d /tmp/${PORT_NAME}-pkgmanaged.XXXXXX)
FAKE_HOME="${WORKDIR}/home"
mkdir -p "${FAKE_HOME}"

cleanup() {
	rm -rf "${WORKDIR}"
	sudo pkg delete -y "${PORT_NAME}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# 1. Install fresh package (binary lands at ${PREFIX}/bin = /usr/local/bin).
PKG=$(ls -t ${PKGDIR}/${PORT_NAME}-*.pkg | head -1)
sudo pkg add -f "${PKG}"
"${BIN}" --version >/dev/null

# 2. Seed the throwaway HOME so `install` has agent configs to write into.
#    Agent detection keys off a config DIRECTORY (dir_exists) or file:
#    ~/.codex present  -> Codex detected       -> ~/.codex/config.toml
#    ~/.claude.json    -> Claude Code detected -> ~/.claude.json (the MCP server
#                         entry, i.e. the "mcp.json" a user edits). This is the
#                         exact file #the-report hit: it pointed at ~/.local/bin
#                         instead of the package binary. Assert BOTH agents so a
#                         Codex-only regression never masks a broken Claude path.
mkdir -p "${FAKE_HOME}/.codex" "${FAKE_HOME}/.claude"
: > "${FAKE_HOME}/.claude.json"
CFG="${FAKE_HOME}/.codex/config.toml"
CLAUDE_CFG="${FAKE_HOME}/.claude.json"
#    cbm_detect_shell_rc() keys off $SHELL: /bin/sh -> ~/.profile. Seed that
#    file so we can prove the package-managed path leaves it untouched (the rc
#    step is skipped entirely under package-managed, so it must stay empty).
RC="${FAKE_HOME}/.profile"
: > "${RC}"

# 3. Run install from the PACKAGE prefix against the throwaway HOME.
#    Pin SHELL so rc detection is deterministic (~/.profile).
env HOME="${FAKE_HOME}" SHELL=/bin/sh "${BIN}" install -y \
	> "${WORKDIR}/install.out" 2>&1 || {
	echo "FAIL  ${PORT_NAME}: install exited non-zero"; cat "${WORKDIR}/install.out"; exit 1; }

fail() { echo "FAIL  ${PORT_NAME}: $1"; echo "--- install output ---"; cat "${WORKDIR}/install.out"; exit 1; }

# 4a. No copy: ~/.local/bin/codebase-memory-mcp must NOT exist.
if [ -e "${FAKE_HOME}/.local/bin/${PORT_NAME}" ]; then
	fail "binary was copied into ~/.local/bin (should be left in the package prefix)"
fi

# 4b. No rc edit: the shell rc must not have gained an export PATH line.
if [ -s "${RC}" ] && grep -q "PATH" "${RC}"; then
	fail "shell rc was modified (package-managed install must not touch PATH)"
fi

# 4c. Codex config points at the real binary, not ~/.local/bin.
[ -f "${CFG}" ] || fail "install did not write ${CFG} (Codex agent not detected)"
grep -q "${BIN}" "${CFG}" || fail "config.toml does not reference ${BIN}"

# 4d. Claude Code MCP config (the "mcp.json") points at the real binary. This
#     is the file the bug report was about: it must carry ${BIN}, never
#     ~/.local/bin.
[ -f "${CLAUDE_CFG}" ] || fail "install did not write ${CLAUDE_CFG} (Claude Code not detected)"
grep -q "${BIN}" "${CLAUDE_CFG}" ||
	fail "${CLAUDE_CFG##*/} does not reference the package binary ${BIN}"

# 4e. No written config anywhere under HOME may reference ~/.local/bin. Scanning
#     every config (not just one agent's) is what turns this into a real guard:
#     the original test only checked Codex, so a broken Claude/QWen path slipped
#     through. A stray ~/.local/bin/<bin> in ANY config is a fail.
stray=$(grep -rl "/.local/bin/${PORT_NAME}" "${FAKE_HOME}" 2>/dev/null || true)
if [ -n "${stray}" ]; then
	fail "config(s) reference the ~/.local/bin path (stale hardcoded target):
${stray}"
fi

echo "no copy into ~/.local/bin, rc untouched, all configs -> ${BIN}"
echo "PASS  ${PORT_NAME} (package-managed install)"
