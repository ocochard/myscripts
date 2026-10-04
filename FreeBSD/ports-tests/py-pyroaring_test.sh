#!/bin/sh
# devel/py-pyroaring smoke test.
#
# Installs the freshly-built py-pyroaring package from the poudriere builder,
# then exercises the compiled CRoaring extension: BitMap/BitMap64/FrozenBitMap
# set algebra, rank/indexing, range ops and serialize/deserialize round-trip.
#
# No network needed; pure in-process Python.
set -eu

JAIL=builder
TREE=official
PKGDIR=/usr/local/poudriere/data/packages/${JAIL}-${TREE}/.latest/All

PKG=$(ls -t ${PKGDIR}/py3*-pyroaring-*.pkg | head -1)
PORT_NAME=$(basename "${PKG}" | sed 's/-[^-]*\.pkg$//')
PY=$(echo "${PORT_NAME}" | sed -E 's/^py([0-9])([0-9]+)-.*/python\1.\2/')

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
	echo "Note: ${PORT_NAME} has reverse dependencies, will not uninstall after test:"
	pkg query '  %rn-%rv' "${PORT_NAME}" 2>/dev/null
fi

# 1. Install fresh package
echo "Installing ${PKG}"
sudo pkg install -fy "${PKG}"

# 2. Verify version against package metadata
PKG_VER=$(pkg query '%v' ${PORT_NAME})
PY_VER=$(${PY} -c 'import pyroaring; print(pyroaring.__version__)')
echo "Package version: ${PKG_VER}   pyroaring.__version__: ${PY_VER}"
[ "${PKG_VER%_*}" = "${PY_VER}" ] || {
	echo "FAIL  version mismatch (pkg=${PKG_VER} module=${PY_VER})"
	exit 1
}

# 3. Exercise the C extension
${PY} - <<'PY'
import pickle
from pyroaring import BitMap, BitMap64, FrozenBitMap

a = BitMap(range(0, 1_000_000, 3))
b = BitMap(range(0, 1_000_000, 5))
assert len(a & b) == len(range(0, 1_000_000, 15))
assert len(a | b) == len(a) + len(b) - len(a & b)
assert len(a - b) == len(a) - len(a & b)
assert len(a ^ b) == len(a | b) - len(a & b)
print("PASS  BitMap set algebra")

assert a.rank(30) == 11 and a[10] == 30 and a[-1] == 999_999
assert a.min() == 0 and a.max() == 999_999
print("PASS  rank/index/min/max")

c = BitMap()
c.add_range(10, 20)
assert list(c) == list(range(10, 20))
c.remove_range(12, 18)
assert list(c) == [10, 11, 18, 19]
print("PASS  add_range/remove_range")

blob = a.serialize()
assert BitMap.deserialize(blob) == a
assert pickle.loads(pickle.dumps(a)) == a
print(f"PASS  serialize round-trip ({len(blob)} bytes)")

f = FrozenBitMap(a)
assert hash(f) == hash(FrozenBitMap(a))
try:
    f.add(1)
    raise AssertionError("FrozenBitMap accepted add()")
except AttributeError:
    pass
print("PASS  FrozenBitMap immutable + hashable")

big = BitMap64([1, 2**40, 2**63])
assert 2**40 in big and len(big) == 3
assert BitMap64.deserialize(big.serialize()) == big
print("PASS  BitMap64 64-bit values")
PY

echo "PASS  py-pyroaring ${PKG_VER}"
