#!/bin/sh
# misc/py-headroom smoke test.
#
# Installs the freshly-built py-headroom package from the poudriere builder,
# imports the library, checks version + main surface (HeadroomClient class,
# providers, compress() one-function API, exception hierarchy, Rust _core
# extension module), instantiates a compress call on a tiny payload without
# hitting any network, then uninstalls the package.
#
# Does NOT call any LLM API (no key required); the goal is to catch packaging
# breakage (missing modules, broken maturin wheel, ort dynamic-load lookup
# broken on FreeBSD), not test the upstream SDK.
#
# The FreeBSD package name carries the active python flavor prefix
# (py311-, py312-, ...).  This script derives the prefix from the pkg
# file itself so it keeps working when the tree's default python flips.
#
# The port maturin-builds a native Rust extension (headroom._core) that
# dlopen's libonnxruntime.so — patched to look up the right filename on
# FreeBSD.  Import + attribute access catches breakage in that path
# without needing a real onnxruntime install.
set -eu

PORT_BASE=headroom-ai        # module + suffix of the pkg name
JAIL=builder
TREE=official
PKGDIR=/usr/local/poudriere/data/packages/${JAIL}-${TREE}/.latest/All

# Discover the freshly-built package: py3XX-headroom-ai-<ver>.pkg
PKG=$(ls -t ${PKGDIR}/py3*-${PORT_BASE}-*.pkg 2>/dev/null | head -1)
[ -n "${PKG}" ] || {
	echo "FAIL  no py3*-${PORT_BASE}-*.pkg in ${PKGDIR}"
	exit 1
}
PKG_NAME=$(basename "${PKG}" | sed -E 's/-[0-9].*$//')  # py3XX-headroom-ai

# Skip uninstall if something else on the host depends on the package.
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

# 2. Verify python import + version.
PKG_VER=$(pkg query '%v' ${PKG_NAME})
PY_VER=$(python3 -c 'from importlib.metadata import version; print(version("headroom-ai"))')
echo "Package version: ${PKG_VER}   headroom-ai metadata version: ${PY_VER}"
[ "${PKG_VER%_*}" = "${PY_VER}" ] || {
	echo "FAIL  version mismatch (pkg=${PKG_VER} module=${PY_VER})"
	exit 1
}

# 3. Probe the SDK's public surface: main client, providers, exception
#    hierarchy, one-function API, and the Rust _core extension module.
python3 - <<'PY'
import headroom
from headroom import (
    HeadroomClient,
    OpenAIProvider,
    AnthropicProvider,
    HeadroomError,
    ConfigurationError,
    ProviderError,
    compress,
)

# The Rust _core extension (maturin-built pyd) is what the FreeBSD patches
# target — its dynamic-loader lookup for libonnxruntime.so lives here.
# Importing it exercises the maturin wheel + FreeBSD ort patch path.
import headroom._core
assert hasattr(headroom._core, "__file__"), "headroom._core has no __file__"
print(f"PASS  headroom._core loaded from {headroom._core.__file__}")

# Exception hierarchy: ConfigurationError and ProviderError should both
# inherit from HeadroomError so callers can catch them generically.
assert issubclass(ConfigurationError, HeadroomError), "ConfigurationError not a HeadroomError"
assert issubclass(ProviderError, HeadroomError), "ProviderError not a HeadroomError"
print("PASS  exception hierarchy: ConfigurationError, ProviderError <: HeadroomError")

# Providers are constructible without any credentials — headroom uses them
# to describe payload shape, not to make network calls.
op = OpenAIProvider()
ap = AnthropicProvider()
assert op is not None and ap is not None
print("PASS  OpenAIProvider, AnthropicProvider constructible")

# compress() is the one-function API — takes messages + provider, returns
# compressed messages.  Empty input should not crash.
result = compress(messages=[], provider=op)
assert result is not None, "compress() returned None"
print(f"PASS  compress() one-function API works (empty input -> {type(result).__name__})")

# HeadroomClient class should be constructible (checks that the wrapper
# import chain — providers, transforms, hooks — resolves cleanly).
assert HeadroomClient is not None and callable(HeadroomClient)
print("PASS  HeadroomClient class importable + callable")
PY

# 4. Console script is installed and shows help without importing optional deps.
if ! command -v headroom >/dev/null 2>&1; then
	echo "FAIL  headroom CLI not on PATH"
	exit 1
fi
headroom --help >/dev/null 2>&1 || {
	echo "FAIL  headroom --help failed"
	exit 1
}
echo "PASS  headroom CLI --help works"

# 5. Exercise the CLI subcommands that need the [proxy] extra deps.
#    `headroom proxy --help` imports fastapi/uvicorn during click's help
#    rendering — if the [proxy] extras aren't in RUN_DEPENDS, this fails
#    with "No module named fastapi".  This is what an earlier version of
#    the port missed:  the library imported cleanly, but every user who
#    ran `headroom wrap claude` or `headroom proxy` hit ImportError at
#    startup.
headroom proxy --help >/dev/null 2>&1 || {
	echo "FAIL  headroom proxy --help failed — [proxy] extras missing from RUN_DEPENDS?"
	headroom proxy --help 2>&1 | tail -5
	exit 1
}
echo "PASS  headroom proxy --help works ([proxy] extras present)"

# `headroom wrap claude --help` catches the same class of miss for the
# wrap-a-tool flow (which starts a proxy internally).
headroom wrap claude --help >/dev/null 2>&1 || {
	echo "FAIL  headroom wrap claude --help failed"
	exit 1
}
echo "PASS  headroom wrap claude --help works"

echo "PASS  ${PKG_NAME} ${PKG_VER}"
