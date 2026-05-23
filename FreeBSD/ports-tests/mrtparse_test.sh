#!/bin/sh
# net/mrtparse smoke test.
#
# Installs the freshly-built py-mrtparse package from the poudriere builder,
# imports the library, parses a sample MRT RIB dump shipped in this directory,
# checks the version and parsing output, then uninstalls the package.
set -eu

PORT_NAME=py311-mrtparse
JAIL=builder
TREE=official
PKGDIR=/usr/local/poudriere/data/packages/${JAIL}-${TREE}/.latest/All
SAMPLE=$(dirname "$0")/mrtparse-sample.mrt

cleanup() {
	sudo pkg delete -y "${PORT_NAME}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# 1. Install fresh package
PKG=$(ls -t ${PKGDIR}/${PORT_NAME}-*.pkg | head -1)
echo "Installing ${PKG}"
sudo pkg add -f "${PKG}"

# 2. Verify python import + version
PKG_VER=$(pkg query '%v' ${PORT_NAME})
PY_VER=$(python3 -c 'import mrtparse; print(mrtparse.__version__)')
echo "Package version: ${PKG_VER}   mrtparse.__version__: ${PY_VER}"
[ "${PKG_VER%_*}" = "${PY_VER}" ] || {
	echo "FAIL  version mismatch (pkg=${PKG_VER} module=${PY_VER})"
	exit 1
}

# 3. Exercise the parser on a sample MRT RIB dump and check we get records
echo "Parsing ${SAMPLE} with mrtparse.Reader"
N=$(python3 -c "
import mrtparse, sys
n = sum(1 for _ in mrtparse.Reader('${SAMPLE}'))
print(n)
")
echo "Parsed ${N} MRT records"
[ "${N}" -gt 0 ] || { echo "FAIL  no records parsed"; exit 1; }

# 4. Exercise the mrt2json CLI installed under /usr/local/bin
OUT=$(mrt2json.py "${SAMPLE}" 2>/dev/null | head -c 500)
case "${OUT}" in
	\[*|\{*)
		echo "PASS  mrt2json.py produced JSON output (first 60 chars: $(echo ${OUT} | head -c 60))" ;;
	*)
		echo "FAIL  mrt2json.py did not produce JSON"
		echo "      first 200 bytes: ${OUT}"
		exit 1 ;;
esac

echo "PASS  mrtparse ${PKG_VER}"
