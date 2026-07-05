#!/bin/sh
# misc/py-anthropic smoke test.
#
# Installs the freshly-built py-anthropic package from the poudriere builder,
# imports the library, checks version + main surface (Anthropic client class,
# message stream types), instantiates a client without making a network call,
# then uninstalls the package.
#
# Does NOT call the live Anthropic API (no key required); the goal is to
# catch packaging breakage, not test the upstream SDK.
#
# The FreeBSD package name carries the active python flavor prefix
# (py311-, py312-, ...).  This script derives the prefix from the pkg
# file itself so it keeps working when the tree's default python flips.
set -eu

PORT_BASE=anthropic         # module + suffix of the pkg name
JAIL=builder
TREE=official
PKGDIR=/usr/local/poudriere/data/packages/${JAIL}-${TREE}/.latest/All

# Discover the freshly-built package: py3XX-anthropic-<ver>.pkg
PKG=$(ls -t ${PKGDIR}/py3*-${PORT_BASE}-*.pkg 2>/dev/null | head -1)
[ -n "${PKG}" ] || {
	echo "FAIL  no py3*-${PORT_BASE}-*.pkg in ${PKGDIR}"
	exit 1
}
PKG_NAME=$(basename "${PKG}" | sed -E 's/-[0-9].*$//')  # py3XX-anthropic

# Skip uninstall if something else on the host depends on the package
# (e.g. hermes-agent depends on py-anthropic).  `pkg delete -y` would
# cascade and remove the consumer too.
PREEXISTED=0
HAS_REVDEPS=0

cleanup() {
	if [ "${HAS_REVDEPS}" = 1 ]; then
		echo "Leaving ${PKG_NAME} installed (other packages depend on it)"
	elif [ "${PREEXISTED}" = 0 ]; then
		sudo pkg delete -y "${PKG_NAME}" 2>/dev/null || true
	else
		echo "Leaving ${PKG_NAME} installed (was present before test)"
	fi
}
trap cleanup EXIT INT TERM

# 0. Record pre-test state
if pkg info -E "${PKG_NAME}" >/dev/null 2>&1; then
	PREEXISTED=1
fi
if [ -n "$(pkg query '%rn-%rv' ${PKG_NAME} 2>/dev/null)" ]; then
	HAS_REVDEPS=1
	echo "Note: ${PKG_NAME} has reverse dependencies — will not uninstall after test:"
	pkg query '  %rn-%rv' "${PKG_NAME}" 2>/dev/null
fi

# 1. Install fresh package
echo "Installing ${PKG}"
sudo pkg add -f "${PKG}"

# 2. Verify python import + version
PKG_VER=$(pkg query '%v' ${PKG_NAME})
PY_VER=$(python3 -c 'import anthropic; print(anthropic.__version__)')
echo "Package version: ${PKG_VER}   anthropic.__version__: ${PY_VER}"
[ "${PKG_VER%_*}" = "${PY_VER}" ] || {
	echo "FAIL  version mismatch (pkg=${PKG_VER} module=${PY_VER})"
	exit 1
}

# 3. Probe the SDK's public surface: main client + a representative
#    message type.  Catches missing submodules, broken imports, vendored
#    deps that didn't get installed, etc.
python3 - <<'PY'
import sys
import anthropic
from anthropic import Anthropic, AsyncAnthropic
from anthropic.types import Message, MessageParam, TextBlock

# Instantiate without a key + without making any network call.
# Anthropic() reads ANTHROPIC_API_KEY from env; passing api_key="" is
# enough to construct the object — the request would fail later.
c = Anthropic(api_key="sk-test-not-real")
assert c.messages is not None, "client.messages missing"
assert c.completions is not None, "client.completions missing"
print(f"PASS  Anthropic client constructed (base_url={c.base_url})")
print(f"PASS  types: Message, MessageParam, TextBlock importable")
PY

echo "PASS  ${PKG_NAME} ${PKG_VER}"
