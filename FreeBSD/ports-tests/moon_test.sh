#!/bin/sh
# moon smoke test: install the freshly built package, exercise the moon and
# moonx binaries, generate a shell completion, initialize a tiny workspace,
# then uninstall.
#
# moon is a Rust-based monorepo task runner. The full upstream test suite
# lives in the source tree and requires a network-connected toolchain
# (Node.js, Bun, etc.) to exercise — out of scope for a packaging smoke test.
set -eu

PORT_NAME=moon
JAIL=builder
TREE=official
PKGDIR=/usr/local/poudriere/data/packages/${JAIL}-${TREE}/.latest/All
WORKDIR=$(mktemp -d /tmp/${PORT_NAME}-test.XXXXXX)

cleanup() {
	rm -rf "${WORKDIR}"
	sudo pkg delete -y "${PORT_NAME}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# 1. Install fresh package
PKG=$(ls -t ${PKGDIR}/${PORT_NAME}-*.pkg | head -1)
sudo pkg add -f "${PKG}"

# 2. Version smoke checks — both binaries
/usr/local/bin/moon --version | grep -q "^moon "
/usr/local/bin/moonx --version | grep -q "^moon-exec "

# 3. Shell completion generation — offline, no workspace needed.
#    Proves the CLI dispatcher and clap wiring are intact.
/usr/local/bin/moon completions --shell bash > "${WORKDIR}/moon.bash"
grep -q "_moon()" "${WORKDIR}/moon.bash"

# 4. Initialize a minimal workspace and assert the expected files appear.
cd "${WORKDIR}"
/usr/local/bin/moon init --yes --minimal . > "${WORKDIR}/init.log" 2>&1
[ -f "${WORKDIR}/.moon/workspace.yml" ]

echo "PASS  ${PORT_NAME}"
