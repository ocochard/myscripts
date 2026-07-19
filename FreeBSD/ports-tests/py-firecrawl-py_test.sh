#!/bin/sh
# www/py-firecrawl-py smoke test.
#
# Installs the freshly-built py-firecrawl-py package from the poudriere
# builder, imports the library, checks version + main surface (Firecrawl
# / AsyncFirecrawl clients, legacy FirecrawlApp aliases, v1/v2 proxies),
# instantiates a client without making a network call, then uninstalls
# the package.
#
# Does NOT call the live Firecrawl API (no key required); the goal is
# to catch packaging breakage, not test the upstream SDK.
#
# The FreeBSD package name carries the active python flavor prefix
# (py311-, py312-, ...).  This script derives the prefix from the pkg
# file itself so it keeps working when the tree's default python flips.
set -eu

PORT_BASE=firecrawl-py       # module + suffix of the pkg name
JAIL=builder
TREE=official
PKGDIR=/usr/local/poudriere/data/packages/${JAIL}-${TREE}/.latest/All

# Discover the freshly-built package: py3XX-firecrawl-py-<ver>.pkg
PKG=$(ls -t ${PKGDIR}/py3*-${PORT_BASE}-*.pkg 2>/dev/null | head -1)
[ -n "${PKG}" ] || {
	echo "FAIL  no py3*-${PORT_BASE}-*.pkg in ${PKGDIR}"
	exit 1
}
PKG_NAME=$(basename "${PKG}" | sed -E 's/-[0-9].*$//')  # py3XX-firecrawl-py

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

# 2. Verify python import + version
PKG_VER=$(pkg query '%v' ${PKG_NAME})
PY_VER=$(python3 -c 'import firecrawl; print(firecrawl.__version__)')
echo "Package version: ${PKG_VER}   firecrawl.__version__: ${PY_VER}"
[ "${PKG_VER%_*}" = "${PY_VER}" ] || {
	echo "FAIL  version mismatch (pkg=${PKG_VER} module=${PY_VER})"
	exit 1
}

# 3. Probe the SDK's public surface: unified + async client, legacy
#    FirecrawlApp aliases, v1/v2 proxies, ScrapeOptions type.
python3 - <<'PY'
import firecrawl
from firecrawl import (
    Firecrawl,
    AsyncFirecrawl,
    FirecrawlApp,
    AsyncFirecrawlApp,
    Watcher,
    AsyncWatcher,
)
from firecrawl import V1ScrapeOptions, V1JsonConfig

# Instantiate without a key + without making any network call.
c = Firecrawl(api_key="fc-test-not-real")
assert c.v2 is not None, "client.v2 proxy missing"
assert c.v1 is not None, "client.v1 proxy missing"
assert callable(c.scrape), "client.scrape not callable"
assert callable(c.search), "client.search not callable"
assert callable(c.map),    "client.map not callable"
print(f"PASS  Firecrawl client constructed (api_url={c.api_url})")

a = AsyncFirecrawl(api_key="fc-test-not-real")
assert a.v2 is not None
print("PASS  AsyncFirecrawl client constructed")

# Legacy v1 aliases still resolve
assert FirecrawlApp is not None and AsyncFirecrawlApp is not None
print("PASS  legacy FirecrawlApp / AsyncFirecrawlApp importable")

# Type objects are importable
_ = V1ScrapeOptions
_ = V1JsonConfig
print("PASS  types: V1ScrapeOptions, V1JsonConfig importable")
PY

echo "PASS  ${PKG_NAME} ${PKG_VER}"
