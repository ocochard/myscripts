#!/bin/sh
# cbmc smoke test: install the freshly built package, exercise the binary on
# a tiny C program with a deliberate bug, verify cbmc finds it, then uninstall.
#
# NOTE: this is only a *packaging* smoke test (does the .pkg install, does the
# cbmc binary run, does it produce the expected verdict on two trivial inputs).
# It does NOT exercise the upstream regression suite that the port ships.
#
# The real test suite — hundreds of cases under regression/cbmc/,
# regression/cbmc-library/, regression/goto-analyzer/, etc. — is wired into
# the port's `do-test` target as:
#
#     cd ${BUILD_WRKSRC} && ctest . -V -L CORE
#
# To run it, use poudriere's advanced-interactive mode (leaves the jail
# running with WRKDIR populated after the build):
#
#     sudo poudriere testport -I -j builder -p official devel/cbmc
#
# Then at the in-jail shell prompt:
#
#     cd /wrkdirs/usr/ports/devel/cbmc/work/.build
#     ctest -V -L CORE 2>&1 | tee /tmp/ctest.log
#     grep -E "Failed|FAILED" /tmp/ctest.log
#     exit
#     sudo poudriere jail -k -j builder -p official
#
# poudriere has no flag that runs do-test automatically — `testport` sets
# PORTTESTING=1 (enabling stage-qa/orphan checks) but does not invoke the
# port's test target. `-i`/`-I` both require a TTY, so this can't be driven
# from a non-interactive harness.
set -eu

PORT_NAME=cbmc
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

# 2. Version smoke check
/usr/local/bin/cbmc --version

# 3. Tiny C program with a provable assertion failure
cat > "${WORKDIR}/buggy.c" <<'EOF'
#include <assert.h>

int main(void)
{
	int x;
	__CPROVER_assume(x > 0 && x < 100);
	int y = x * 2;
	assert(y < 50);  /* fails when x >= 25 */
	return 0;
}
EOF

# 4. Run cbmc — expect non-zero exit and "VERIFICATION FAILED"
set +e
/usr/local/bin/cbmc "${WORKDIR}/buggy.c" > "${WORKDIR}/out.txt" 2>&1
rc=$?
set -e

grep -q "VERIFICATION FAILED" "${WORKDIR}/out.txt"
[ "${rc}" -ne 0 ]

# 5. Now a passing program — expect zero exit and "VERIFICATION SUCCESSFUL"
cat > "${WORKDIR}/ok.c" <<'EOF'
#include <assert.h>

int main(void)
{
	int x;
	__CPROVER_assume(x > 0 && x < 10);
	int y = x + 1;
	assert(y > 1);
	return 0;
}
EOF

/usr/local/bin/cbmc "${WORKDIR}/ok.c" > "${WORKDIR}/ok.txt" 2>&1
grep -q "VERIFICATION SUCCESSFUL" "${WORKDIR}/ok.txt"

echo "PASS  ${PORT_NAME}"
