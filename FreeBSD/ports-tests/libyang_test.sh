#!/bin/sh
# libyang smoke test — shared by net/libyang2 and net/libyang3.
#
# Usage: libyang_test.sh [libyang2|libyang3]   (default: libyang2)
#
# The two ports install the same layout (yanglint, headers, libyang.pc, IETF
# YANG modules) but differ in SONAME major (libyang.so.2 vs .so.3), package
# name, and one log-API symbol (2.x: ly_strerrcode, 3.x: ly_strerr). They also
# CONFLICT with each other (both ship include/libyang/*, libyang.pc). This
# script detects the major from the package, removes the *other* one if it's
# installed, then exercises:
#   - files landed, incl. the libyang.so.<major> SONAME (what consumers link)
#   - readelf SONAME matches the major (a bump crossing majors would break
#     every LIB_DEPENDS pinned to the old .so — e.g. net/frr9 -> libyang.so.2)
#   - yanglint --version matches the expected major
#   - the schema parser end-to-end via `yanglint -f tree` on a shipped module
#   - compile+link+run a C program against -lyang via the installed pkg-config
set -eu

PKG_NAME=${1:-libyang2}
case "${PKG_NAME}" in
	libyang2) MAJOR=2; OTHER=libyang3; STRERR_FN=ly_strerrcode ;;
	libyang3) MAJOR=3; OTHER=libyang2; STRERR_FN=ly_strerr ;;
	*) echo "usage: $0 [libyang2|libyang3]"; exit 2 ;;
esac

JAIL=builder
TREE=official
PKGDIR=/usr/local/poudriere/data/packages/${JAIL}-${TREE}/.latest/All
WORKDIR=$(mktemp -d /tmp/${PKG_NAME}-test.XXXXXX)

# Record whether we displaced the conflicting sibling so we can restore it,
# and whether the package under test was already installed before we started
# (if so, leave it — don't uninstall a package the host already had).
OTHER_WAS_INSTALLED=no
SELF_WAS_INSTALLED=no
pkg info -e "${PKG_NAME}" 2>/dev/null && SELF_WAS_INSTALLED=yes

cleanup() {
	rm -rf "${WORKDIR}"
	# Only uninstall the package under test if (a) we installed it ourselves
	# and (b) nothing depends on it — otherwise pkg delete cascades to real
	# consumers (e.g. libyang3 <- net/frr10).
	if [ "${SELF_WAS_INSTALLED}" = no ]; then
		if [ -z "$(pkg query '%rn' "${PKG_NAME}" 2>/dev/null || true)" ]; then
			sudo pkg delete -y "${PKG_NAME}" 2>/dev/null || true
		fi
	fi
	if [ "${OTHER_WAS_INSTALLED}" = yes ]; then
		OTHER_PKG=$(ls -t ${PKGDIR}/${OTHER}-*.pkg 2>/dev/null | head -1 || true)
		[ -n "${OTHER_PKG}" ] && sudo pkg add -f "${OTHER_PKG}" 2>/dev/null || true
	fi
}
trap cleanup EXIT INT TERM

# 0. libyang2 and libyang3 conflict — the sibling must be removed to install
# the package under test. But removing it would cascade to anything that
# depends on it (e.g. libyang3 <- net/frr10). Deleting a real installed daemon
# to run a smoke test is not acceptable, and reinstalling the whole cascade is
# fragile. So: if the sibling has reverse deps, refuse and tell the user to run
# this in a jail (or remove the consumer first). Only auto-remove a sibling
# that nothing else needs, and restore it on exit.
if pkg info -e "${OTHER}" 2>/dev/null; then
	RDEPS=$(pkg query '%rn' "${OTHER}" 2>/dev/null || true)
	if [ -n "${RDEPS}" ]; then
		echo "SKIP  ${PKG_NAME}: conflicting ${OTHER} is installed and required by:"
		echo "${RDEPS}" | sed 's/^/        /'
		echo "      Removing ${OTHER} would cascade to those packages."
		echo "      Test ${PKG_NAME} in a clean jail (poudriere testport), or"
		echo "      pkg delete the consumer(s) first, then rerun."
		exit 2
	fi
	OTHER_WAS_INSTALLED=yes
	sudo pkg delete -y "${OTHER}"
fi

# 1. Install the freshly built package.
PKG=$(ls -t ${PKGDIR}/${PKG_NAME}-*.pkg | head -1)
sudo pkg add -f "${PKG}"

# 2. Files landed — including the .so.<major> SONAME symlink (what a consumer
# such as net/frr9 links against) and the concrete versioned object.
SOFILE=$(pkg query '%Fp' "${PKG_NAME}" | grep -E "/lib/libyang\.so\.${MAJOR}\.[0-9]" | head -1)
for f in \
	/usr/local/bin/yanglint \
	/usr/local/include/libyang/libyang.h \
	/usr/local/lib/libyang.so \
	/usr/local/lib/libyang.so.${MAJOR} \
	/usr/local/libdata/pkgconfig/libyang.pc \
	"${SOFILE}"
do
	test -e "${f}" || { echo "FAIL missing: ${f}"; exit 1; }
done

# The SONAME must be exactly libyang.so.<major>. If a bump ever crossed a major
# (e.g. libyang2 2.1.x -> 2.2.x actually ships .so.3), every LIB_DEPENDS pinned
# to the old .so would silently break.
# readelf prints:  (SONAME)  Library soname: [libyang.so.<major>]
readelf -d /usr/local/lib/libyang.so.${MAJOR} 2>/dev/null \
	| grep -qE "SONAME.*\[libyang\.so\.${MAJOR}\]" \
	|| { echo "FAIL SONAME is not libyang.so.${MAJOR}"; exit 1; }

# 3. yanglint runs and reports the expected major version.
VER=$(yanglint --version 2>&1 | awk '{print $NF}')
echo "yanglint version: ${VER}"
case "${VER}" in
	${MAJOR}.*) : ;;
	*) echo "FAIL unexpected yanglint version: ${VER} (expected ${MAJOR}.x)"; exit 1 ;;
esac

# 4. Behaviour: parse a shipped IETF YANG module and print its schema tree.
# Drives the schema parser inside libyang.so against real input. Both majors
# ship ietf-inet-types (a leaf-type module).
MOD=/usr/local/share/yang/modules/libyang/ietf-inet-types@2013-07-15.yang
test -e "${MOD}" || { echo "FAIL missing shipped module: ${MOD}"; exit 1; }
yanglint -f tree "${MOD}" > "${WORKDIR}/tree.out" 2>"${WORKDIR}/tree.err" \
	|| { echo "FAIL yanglint could not parse ${MOD}"; cat "${WORKDIR}/tree.err"; exit 1; }
# A types-only module has no data nodes, so the tree body is legitimately
# empty; assert the module header line, which proves the parser loaded it.
grep -q 'module: ietf-inet-types' "${WORKDIR}/tree.out" \
	|| { echo "FAIL unexpected yanglint tree output:"; cat "${WORKDIR}/tree.out"; exit 1; }
echo "yanglint parsed ietf-inet-types OK"

# 5. Link a tiny C program against -lyang via the installed pkg-config file and
# call into the library (create a context, resolve a second symbol, free it).
# Mirrors what a C consumer such as frr9 does; proves headers + .so + .pc are
# consistent. The log-strerr symbol is spelled ly_strerrcode in 2.x and
# ly_strerr in 3.x.
cat > "${WORKDIR}/ly_smoke.c" <<EOF
#include <libyang/libyang.h>
#include <stdio.h>

int main(void) {
	struct ly_ctx *ctx = NULL;
	if (ly_ctx_new(NULL, 0, &ctx) != LY_SUCCESS || ctx == NULL) {
		fprintf(stderr, "ly_ctx_new failed\n");
		return 1;
	}
	/* resolve a second libyang symbol at runtime to prove the .so linkage */
	printf("libyang ${STRERR_FN}(LY_SUCCESS)=%s\n", ${STRERR_FN}(LY_SUCCESS));
	ly_ctx_destroy(ctx);
	return 0;
}
EOF
CFLAGS=$(pkg-config --cflags libyang)
LIBS=$(pkg-config --libs libyang)
cc ${CFLAGS} "${WORKDIR}/ly_smoke.c" -o "${WORKDIR}/ly_smoke" ${LIBS} \
	|| { echo "FAIL could not compile/link against libyang via pkg-config"; exit 1; }
"${WORKDIR}/ly_smoke" || { echo "FAIL ly_smoke runtime error"; exit 1; }

echo "PASS  ${PKG_NAME} (${VER})"
