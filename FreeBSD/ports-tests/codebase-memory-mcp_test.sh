#!/bin/sh
# codebase-memory-mcp regression test.
#
# Installs the freshly built package and runs a full index over a large real
# repository (~/freebsd-official/src) via the one-shot CLI:
#
#     codebase-memory-mcp cli index_repository --repo_path <dir>
#
# This is the *crash regression* for the SIGSEGV that 0.8.1 hit on the FreeBSD
# source tree: the per-language LSP resolve-walkers (py/go/php/kotlin) recursed
# once per nesting level with no depth guard, so a deeply-nested or cyclic file
# drove a native stack overflow that took down the whole index run. 0.9.0 caps
# the walk depth (CBM_LSP_MAX_WALK_DEPTH, default 512) and skips-and-continues
# instead of crashing, reporting dropped files in the JSON `skipped` summary.
#
# PASS criteria:
#   1. .pkg installs, binary reports --version
#   2. index_repository over the full src tree exits 0 (NO signal / SIGSEGV)
#   3. the JSON result reports nodes > 0 (the graph was actually built)
# Skipped files are acceptable and reported (that IS the 0.9.0 fix), not a fail.
#
# Storage is redirected to a throwaway HOME so the run never touches the user's
# real ~/.cache/codebase-memory-mcp graph and is fully removed on exit.
set -eu

PORT_NAME=codebase-memory-mcp
JAIL=builder
TREE=official
PKGDIR=/usr/local/poudriere/data/packages/${JAIL}-${TREE}/.latest/All
BIN=/usr/local/bin/codebase-memory-mcp
REPO=${HOME}/freebsd-official/src
PROJECT=cbm-regress   # explicit index name (the derived default is path-encoded)

WORKDIR=$(mktemp -d /tmp/${PORT_NAME}-test.XXXXXX)
FAKE_HOME="${WORKDIR}/home"
mkdir -p "${FAKE_HOME}"

cleanup() {
	rm -rf "${WORKDIR}"
	sudo pkg delete -y "${PORT_NAME}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# 0. Sanity: the repo we regress against must exist
[ -d "${REPO}" ] || { echo "FAIL  ${PORT_NAME}: ${REPO} not found"; exit 1; }

# 1. Install fresh package
PKG=$(ls -t ${PKGDIR}/${PORT_NAME}-*.pkg | head -1)
sudo pkg add -f "${PKG}"

# 2. Version smoke check
"${BIN}" --version

# 3. Full index over the FreeBSD source tree (the 0.8.1 crasher).
#    --repo_path is the index_repository arg; stdout stays clean JSON.
#    Redirect HOME so the graph store is isolated + throwaway.
echo "indexing ${REPO} ... (this exercises 75K+ files, expect a few minutes)"
set +e
env HOME="${FAKE_HOME}" "${BIN}" cli index_repository \
	--repo_path "${REPO}" --name "${PROJECT}" \
	> "${WORKDIR}/index.json" 2> "${WORKDIR}/index.err"
rc=$?
set -e

# 4. Crash regression: any exit >= 128 means killed by a signal (139 = SIGSEGV).
if [ "${rc}" -ge 128 ]; then
	sig=$((rc - 128))
	echo "FAIL  ${PORT_NAME}: index killed by signal ${sig} (regression: 0.8.1 crash)"
	tail -20 "${WORKDIR}/index.err" || true
	exit 1
fi
if [ "${rc}" -ne 0 ]; then
	echo "FAIL  ${PORT_NAME}: index exited ${rc}"
	tail -20 "${WORKDIR}/index.err" || true
	exit 1
fi

# 5. Graph was actually built: nodes > 0.
#    Parse the "nodes":N field from the clean-JSON result without a JSON dep.
nodes=$(sed -n 's/.*"nodes"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' \
	"${WORKDIR}/index.json" | head -1)
: "${nodes:=0}"
if [ "${nodes}" -le 0 ]; then
	echo "FAIL  ${PORT_NAME}: index produced ${nodes} nodes"
	head -40 "${WORKDIR}/index.json" || true
	exit 1
fi

# 6. Report skipped files (graceful-degradation, informational not a failure).
skipped=$(sed -n 's/.*"skipped_count"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' \
	"${WORKDIR}/index.json" | head -1)
: "${skipped:=0}"

echo "indexed ${nodes} nodes, ${skipped} files skipped (no crash)"

# 7. FreeBSD sysctl OID-tree extractor regression.
#    The kernel assembles dotted sysctl paths (e.g. kern.ipc.maxsockbuf) at boot
#    from SYSCTL_* OID macros; the path is never a literal token in source, so a
#    plain identifier/string index cannot find it. The FreeBSD-only extractor
#    reconstructs it into a `Sysctl` graph node with the dotted path as its name.
#    This asserts the feature is wired in and actually resolved a known leaf
#    (kern.ipc.maxsockbuf, declared in sys/kern/uipc_sockbuf.c) whose parent
#    chain (_kern_ipc -> _kern) spans multiple translation units.
#
echo "querying resolved sysctl OID paths ..."
set +e
env HOME="${FAKE_HOME}" "${BIN}" cli --json query_graph --project "${PROJECT}" \
	--query 'MATCH (n:Sysctl) WHERE n.name = "kern.ipc.maxsockbuf" RETURN n.name, n.file_path' \
	> "${WORKDIR}/sysctl.json" 2> "${WORKDIR}/sysctl.err"
set -e

# The resolved Sysctl node's name is the full dotted path, returned on one line.
if ! grep -q 'kern\.ipc\.maxsockbuf' "${WORKDIR}/sysctl.json"; then
	echo "FAIL  ${PORT_NAME}: sysctl extractor did not resolve kern.ipc.maxsockbuf"
	echo "  (SYSCTL_* OID-tree extraction is broken or unwired)"
	head -40 "${WORKDIR}/sysctl.json" || true
	exit 1
fi
echo "sysctl extractor resolved kern.ipc.maxsockbuf -> Sysctl node"

echo "PASS  ${PORT_NAME}"
