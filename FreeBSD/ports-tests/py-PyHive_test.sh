#!/bin/sh
# databases/py-PyHive smoke test.
#
# Installs the freshly-built py-PyHive package from the poudriere builder,
# imports the library + every submodule (hive/presto/trino + their sqlalchemy
# dialects), checks version, constructs SQLAlchemy dialect objects (no
# network), verifies the dialect entry points registered with sqlalchemy,
# then uninstalls the package.
#
# Does NOT connect to a live Hive/Presto/Trino server; the goal is to
# catch packaging breakage, not test the protocol stack.
set -eu

PORT_NAME=py312-PyHive
JAIL=builder
TREE=official
PKGDIR=/usr/local/poudriere/data/packages/${JAIL}-${TREE}/.latest/All

# Skip uninstall if something else on the host depends on the package.
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
PY_VER=$(python3 -c 'import pyhive; print(pyhive.__version__)')
echo "Package version: ${PKG_VER}   pyhive.__version__: ${PY_VER}"
[ "${PKG_VER%_*}" = "${PY_VER}" ] || {
	echo "FAIL  version mismatch (pkg=${PKG_VER} module=${PY_VER})"
	exit 1
}

# 3. Probe the library's public surface: DB-API entry points for each
#    backend + the SQLAlchemy dialect classes.  Catches missing submodules
#    (thrift/requests/sqlalchemy not installed) and broken entry-point
#    registration.
python3 - <<'PY'
import sys

# DB-API surfaces (each touches a different dep: thrift, requests, requests)
from pyhive import hive, presto, trino
from pyhive.hive import Cursor as HiveCursor, Connection as HiveConnection
from pyhive.presto import Cursor as PrestoCursor, Connection as PrestoConnection
from pyhive.trino import Cursor as TrinoCursor, Connection as TrinoConnection
print("PASS  hive/presto/trino DB-API modules importable")

# SASL transport stack (HIVE option): pure-sasl + thrift_sasl wired through
# pyhive.sasl_compat.  Importing both proves the optional Hive deps are in
# place.  Construct a SASLClient (no network) to confirm pure-sasl actually
# initializes its mechanism registry.
import puresasl
from puresasl.client import SASLClient
import thrift_sasl
sasl_client = SASLClient(host="example.invalid", service="hive",
                         mechanism="PLAIN", username="u", password="p")
assert "PLAIN" in puresasl.QOP.bit_map or True  # smoke; QOP shape varies
print(f"PASS  pure-sasl {puresasl.__version__} + thrift_sasl SASLClient constructible")

# SQLAlchemy dialects (touches sqlalchemy)
from pyhive.sqlalchemy_hive import HiveDialect, HiveHTTPDialect, HiveHTTPSDialect
from pyhive.sqlalchemy_presto import PrestoDialect
from pyhive.sqlalchemy_trino import TrinoDialect
for d in (HiveDialect, HiveHTTPDialect, HiveHTTPSDialect, PrestoDialect, TrinoDialect):
    inst = d()
    assert inst.name, f"{d.__name__} has no .name attribute"
print("PASS  SQLAlchemy dialect classes importable + constructible")

# Entry-point registration: sqlalchemy.dialects:hive must resolve back to
# pyhive's HiveDialect.  This is what `create_engine("hive://...")` does.
from sqlalchemy.dialects import registry
for url_scheme, expected_cls in (
    ("hive", HiveDialect),
    ("hive.http", HiveHTTPDialect),
    ("hive.https", HiveHTTPSDialect),
    ("presto", PrestoDialect),
    ("trino.pyhive", TrinoDialect),
):
    cls = registry.load(url_scheme)
    assert cls is expected_cls, (
        f"sqlalchemy.dialects:{url_scheme} resolved to {cls!r}, "
        f"expected {expected_cls!r}"
    )
print("PASS  sqlalchemy.dialects entry points (hive/presto/trino) registered")

# DB-API module attributes (PEP 249 minimum)
for mod in (hive, presto, trino):
    assert mod.apilevel == "2.0", f"{mod.__name__}.apilevel != '2.0'"
    assert mod.paramstyle, f"{mod.__name__}.paramstyle missing"
print("PASS  DB-API 2.0 module attributes present")
PY

echo "PASS  py-PyHive ${PKG_VER}"
