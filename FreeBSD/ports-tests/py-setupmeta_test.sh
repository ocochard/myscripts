#!/bin/sh
# devel/py-setupmeta smoke test.
#
# Installs the freshly-built py-setupmeta package from the poudriere builder,
# checks version and that the port's setuptools>=67 strip held, then drives
# setupmeta as a setuptools plugin on a throwaway git project: tag-based
# versioning, `explain`, and egg_info metadata.  Uninstalls afterwards.
set -eu

JAIL=builder
TREE=official
PKGDIR=/usr/local/poudriere/data/packages/${JAIL}-${TREE}/.latest/All
PKG=$(ls -t ${PKGDIR}/py3*-setupmeta-*.pkg | head -1)
PORT_NAME=$(basename "${PKG}" | sed 's/-[0-9][^-]*\.pkg$//')
PY=python$(echo "${PORT_NAME}" | sed -E 's/^py3([0-9]+)-.*/3.\1/')
WORK=$(mktemp -d /tmp/setupmeta-test.XXXXXX)

PREEXISTED=0
HAS_REVDEPS=0

cleanup() {
	rm -rf "${WORK}"
	if [ "${HAS_REVDEPS}" = 1 ]; then
		echo "Leaving ${PORT_NAME} installed (other packages depend on it)"
	elif [ "${PREEXISTED}" = 0 ]; then
		sudo pkg delete -y "${PORT_NAME}" 2>/dev/null || true
	else
		echo "Leaving ${PORT_NAME} installed (was present before test)"
	fi
}
trap cleanup EXIT INT TERM

pkg info -E "${PORT_NAME}" >/dev/null 2>&1 && PREEXISTED=1
[ -n "$(pkg query '%rn-%rv' "${PORT_NAME}" 2>/dev/null)" ] && HAS_REVDEPS=1

# 1. Install fresh package
echo "Installing ${PKG}"
sudo pkg install -fy "${PKG}"

# 2. Version + no unsatisfiable setuptools floor in installed metadata
PKG_VER=$(pkg query '%v' "${PORT_NAME}")
PY_VER=$(${PY} -c 'import importlib.metadata as m; print(m.version("setupmeta"))')
[ "${PKG_VER%_*}" = "${PY_VER}" ] || {
	echo "FAIL  version mismatch (pkg=${PKG_VER} module=${PY_VER})"
	exit 1
}
echo "PASS  version ${PY_VER}"
${PY} - <<'PY'
import importlib.metadata as m
from packaging.requirements import Requirement
st = m.version("setuptools")
for r in m.requires("setupmeta") or []:
    req = Requirement(r)
    if req.name == "setuptools":
        assert req.specifier.contains(st), f"{r} unsatisfied by setuptools {st}"
print(f"PASS  requirements satisfied by setuptools {st}")
PY

# 3. setupmeta as setuptools plugin on a tagged git project
mkdir -p "${WORK}/demo/demo"
cd "${WORK}/demo"
cat > setup.py <<'EOF'
from setuptools import setup
setup(name="demo", versioning="post", setup_requires="setupmeta")
EOF
: > demo/__init__.py
cat > README.rst <<'EOF'
Demo package for setupmeta smoke test
=====================================

Body.
EOF
git init -q .
git -c user.name=t -c user.email=t@t add .
git -c user.name=t -c user.email=t@t commit -qm init
git tag -a v1.2.3 -m v1.2.3

OUT=$(${PY} setup.py -q version)
echo "${OUT}" | grep -q '^1\.2\.3$' || {
	echo "FAIL  setup.py version: ${OUT}"
	exit 1
}
echo "PASS  tag-based versioning (1.2.3)"

${PY} setup.py explain 2>&1 | grep -qE 'version:.*1\.2\.3' || {
	echo "FAIL  setup.py explain"
	exit 1
}
echo "PASS  explain"

${PY} setup.py -q egg_info >/dev/null 2>&1
grep -q '^Version: 1.2.3$' demo.egg-info/PKG-INFO
grep -q '^Summary: Demo package for setupmeta smoke test$' demo.egg-info/PKG-INFO
echo "PASS  egg_info metadata (version + README summary)"

echo "PASS  py-setupmeta ${PKG_VER}"
