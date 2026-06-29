#!/bin/sh
# devel/py-deepdiff smoke test.
#
# Installs the freshly-built py-deepdiff package from the poudriere builder,
# imports the library, then exercises the cachebox-backed DistanceCache
# (deepdiff/lfucache.py) both directly and via the high-level DeepDiff API
# with get_deep_distance=True / cache_size=N.  Catches cachebox API breakage
# across major bumps (e.g. cachebox 5.x -> 6.x), which is exactly the kind
# of regression the previous "<6" upper bound was hiding.
#
# No network needed; pure in-process Python.
set -eu

PORT_NAME=py311-deepdiff
JAIL=builder
TREE=official
PKGDIR=/usr/local/poudriere/data/packages/${JAIL}-${TREE}/.latest/All

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
PKG=$(ls -t ${PKGDIR}/${PORT_NAME}-*.pkg | head -1)
echo "Installing ${PKG}"
sudo pkg add -f "${PKG}"

# 2. Verify python import + version
PKG_VER=$(pkg query '%v' ${PORT_NAME})
PY_VER=$(python3 -c 'import deepdiff; print(deepdiff.__version__)')
CACHEBOX_VER=$(python3 -c 'import cachebox; print(cachebox.__version__)')
echo "Package version: ${PKG_VER}   deepdiff.__version__: ${PY_VER}   cachebox: ${CACHEBOX_VER}"
[ "${PKG_VER%_*}" = "${PY_VER}" ] || {
	echo "FAIL  version mismatch (pkg=${PKG_VER} module=${PY_VER})"
	exit 1
}

# 3. Exercise the cachebox-backed code path.  deepdiff/lfucache.py wraps
#    cachebox.LRUCache as DistanceCache and is reached via DeepDiff()
#    when get_deep_distance=True is passed.
python3 - <<'PY'
# (a) module wiring — cachebox import + DistanceCache class are reachable
from deepdiff.lfucache import DistanceCache, LFUCache
from cachebox import LRUCache
assert LFUCache is DistanceCache, "LFUCache alias broken"

# (b) DistanceCache directly: set / get / __contains__
dc = DistanceCache(8)
dc.set("k1", value=1.5)
dc.set("k2", value=2.5)
assert dc.get("k1") == 1.5
assert dc.get("k2") == 2.5
assert "k1" in dc and "missing" not in dc
print("PASS  DistanceCache (cachebox.LRUCache) set/get/contains")

# (c) High-level API exercising the cache: deep_distance + values_changed
from deepdiff import DeepDiff
t1 = {"a": [1, 2, 3, 4, 5], "b": {"x": 10, "y": 20}}
t2 = {"a": [1, 2, 3, 4, 6], "b": {"x": 10, "y": 21}}
d = DeepDiff(t1, t2, get_deep_distance=True,
             cache_size=500, cache_tuning_sample_size=500)
assert "deep_distance" in d, "deep_distance missing from DeepDiff output"
assert "values_changed" in d, "values_changed missing"
print(f"PASS  DeepDiff get_deep_distance => {d['deep_distance']:.6f}")

# (d) Larger payload with ignore_order=True — repeated cache hits on the
#     Hungarian-distance pairings.
t1 = [{"id": i, "v": i * 2} for i in range(50)]
t2 = [{"id": i, "v": i * 2 + (1 if i % 10 == 0 else 0)} for i in range(50)]
d2 = DeepDiff(t1, t2, get_deep_distance=True,
              cache_size=1000, cache_tuning_sample_size=1000,
              ignore_order=True)
assert "deep_distance" in d2
print(f"PASS  DeepDiff ignore_order+cache (50 items) => {d2['deep_distance']:.6f}")
PY

echo "PASS  py-deepdiff ${PKG_VER}"
