#!/bin/sh
# www/py-exa-py smoke test.
#
# Installs the freshly-built py-exa-py package from the poudriere builder,
# imports the SDK, checks version + main surface (Exa client class, AsyncExa,
# submodules), instantiates a client without making a network call, then
# uninstalls the package.
#
# Does NOT call the live Exa API (no key required); the goal is to catch
# packaging breakage, not test the upstream SDK.
set -eu

PORT_BASE=exa-py            # module + suffix of the pkg name
JAIL=builder
TREE=official
PKGDIR=/usr/local/poudriere/data/packages/${JAIL}-${TREE}/.latest/All

# Discover the freshly-built package: py3XX-exa-py-<ver>.pkg
PKG=$(ls -t ${PKGDIR}/py3*-${PORT_BASE}-*.pkg 2>/dev/null | head -1)
[ -n "${PKG}" ] || {
	echo "FAIL  no py3*-${PORT_BASE}-*.pkg in ${PKGDIR}"
	exit 1
}
PORT_NAME=$(basename "${PKG}" | sed -E 's/-[0-9].*$//')  # py3XX-exa-py

PREEXISTED=0
HAS_REVDEPS=0

cleanup() {
	if [ "${HAS_REVDEPS}" = 1 ]; then
		echo "Leaving ${PORT_NAME} installed (other packages depend on it)"
	elif [ "${PREEXISTED}" = 0 ]; then
		sudo pkg delete -y "${PORT_NAME}" 2>/dev/null || true
	else
		echo "Leaving ${PORT_NAME} installed (was present before test)"
	fi
}
trap cleanup EXIT INT TERM

# 0. Record pre-test state
if pkg info -E "${PORT_NAME}" >/dev/null 2>&1; then
	PREEXISTED=1
fi
if [ -n "$(pkg query '%rn-%rv' ${PORT_NAME} 2>/dev/null)" ]; then
	HAS_REVDEPS=1
	echo "Note: ${PORT_NAME} has reverse dependencies — will not uninstall after test:"
	pkg query '  %rn-%rv' "${PORT_NAME}" 2>/dev/null
fi

# 1. Install fresh package
echo "Installing ${PKG}"
sudo pkg add -f "${PKG}"

# 2. Verify python import + version.  exa_py doesn't expose __version__,
#    so read it from package metadata via importlib.
PKG_VER=$(pkg query '%v' ${PORT_NAME})
PY_VER=$(python3 -c 'from importlib.metadata import version; print(version("exa-py"))')
echo "Package version: ${PKG_VER}   exa-py metadata version: ${PY_VER}"
[ "${PKG_VER%_*}" = "${PY_VER}" ] || {
	echo "FAIL  version mismatch (pkg=${PKG_VER} module=${PY_VER})"
	exit 1
}

# 3. Probe the SDK's public surface: main client + async variant + a few
#    submodules.  Catches missing submodules, broken imports, vendored
#    deps that didn't get installed, etc.
python3 - <<'PY'
import exa_py
from exa_py import Exa, AsyncExa
# Submodules shipped under exa_py/.
import exa_py.api
import exa_py.utils
import exa_py.research
import exa_py.websets

# Instantiate without making any network call.  Exa() needs an api_key
# (or EXA_API_KEY env var); a fake value is enough to construct.
c = Exa(api_key="fake-test-key")
assert c.base_url, "client.base_url missing"
assert "x-api-key" in c.headers, "client.headers missing x-api-key"
print(f"PASS  Exa client constructed (base_url={c.base_url})")

# AsyncExa should be a subclass of Exa.
assert issubclass(AsyncExa, Exa), "AsyncExa is not a subclass of Exa"
print(f"PASS  AsyncExa subclasses Exa")
print(f"PASS  submodules: api, utils, research, websets importable")
PY

echo "PASS  py-exa-py ${PKG_VER}"
