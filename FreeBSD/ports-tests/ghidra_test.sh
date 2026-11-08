#!/bin/sh
# ghidra smoke test: install the freshly built package, check the native
# helpers and launcher fixups the port adds, then run a real headless
# analysis of /bin/ls with a post-script that decompiles a function (this
# drives the FreeBSD-built `decompile` binary), then uninstall.
#
# The package pulls in openjdk, gcc and python RUN_DEPENDS: every package
# this test adds to the host is removed again on exit (installed-set diff,
# NOT `pkg autoremove`, which would also take unrelated orphans).
set -eu

PORT_NAME=ghidra
JAIL=builder
TREE=official
PKGDIR=/usr/local/poudriere/data/packages/${JAIL}-${TREE}/.latest/All
DATADIR=/usr/local/share/ghidra
NATIVE=build/os/freebsd_x86_64
TARGET=${TARGET:-/bin/ls}
ANALYZE_TIMEOUT=${ANALYZE_TIMEOUT:-900}
WORKDIR=$(mktemp -d /tmp/${PORT_NAME}-test.XXXXXX)

PREINSTALLED=0
pkg info -e "${PORT_NAME}" && PREINSTALLED=1
pkg query %n | sort > "${WORKDIR}/pkgs.before"

fail() {
	echo "FAIL  ${PORT_NAME}: $*" >&2
	exit 1
}

cleanup() {
	if [ "${PREINSTALLED}" = 0 ]; then
		pkg query %n | sort > "${WORKDIR}/pkgs.after"
		added=$(comm -13 "${WORKDIR}/pkgs.before" "${WORKDIR}/pkgs.after")
		[ -n "${added}" ] && sudo pkg delete -y ${added} || true
	fi
	rm -rf "${WORKDIR}"
}
trap cleanup EXIT INT TERM

# 1. Install fresh package
PKG=$(ls -t ${PKGDIR}/${PORT_NAME}-[0-9]*.pkg | head -1)
sudo env IGNORE_OSVERSION=yes ASSUME_ALWAYS_YES=yes pkg install -fy "${PKG}"
PKG_VER=$(pkg query %v "${PORT_NAME}")

# 2. Version: the shipped application.properties must match the package
APP_VER=$(sed -n 's/^application\.version=//p' ${DATADIR}/Ghidra/application.properties)
[ "${APP_VER}" = "${PKG_VER%%_*}" ] ||
	fail "application.version=${APP_VER}, pkg version ${PKG_VER}"

# 3. Native helpers the port builds must be FreeBSD executables
for f in Ghidra/Features/Decompiler/${NATIVE}/decompile \
    Ghidra/Features/Decompiler/${NATIVE}/sleigh \
    Ghidra/Features/FileFormats/${NATIVE}/lzfse \
    GPL/DemanglerGnu/${NATIVE}/demangler_gnu_v2_24 \
    GPL/DemanglerGnu/${NATIVE}/demangler_gnu_v2_41; do
	[ -x "${DATADIR}/${f}" ] || fail "missing or not executable: ${f}"
	file -L "${DATADIR}/${f}" | grep -q 'ELF.*FreeBSD' ||
		fail "not a FreeBSD ELF: ${f}"
done

# 4. Launcher fixups: bin/ghidra link, bash shebang, injected JAVA_HOME
[ "$(readlink -f /usr/local/bin/ghidra)" = "${DATADIR}/ghidraRun" ] ||
	fail "/usr/local/bin/ghidra does not point at ghidraRun"
for f in ghidraRun support/analyzeHeadless support/launch.sh; do
	[ "$(head -1 ${DATADIR}/${f})" = "#!/usr/local/bin/bash" ] ||
		fail "shebang not fixed in ${f}"
done
grep -q '^export JAVA_HOME=' ${DATADIR}/ghidraRun ||
	fail "JAVA_HOME not injected into ghidraRun"

# 5. Demangler: native GNU demangler must decode an Itanium C++ symbol
${DATADIR}/GPL/DemanglerGnu/${NATIVE}/demangler_gnu_v2_41 _ZN3foo3barEi \
	> "${WORKDIR}/demangle.txt" 2>&1 || true
grep -q 'foo::bar(int)' "${WORKDIR}/demangle.txt" ||
	fail "demangler output: $(cat ${WORKDIR}/demangle.txt)"

# 6. Headless analysis + decompilation of ${TARGET}
cat > "${WORKDIR}/PortSmoke.java" <<'EOF'
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.listing.Function;

public class PortSmoke extends GhidraScript {
	@Override
	public void run() throws Exception {
		println("PORTSMOKE functions=" +
		    currentProgram.getFunctionManager().getFunctionCount());
		DecompInterface d = new DecompInterface();
		d.openProgram(currentProgram);
		for (Function f : currentProgram.getFunctionManager().getFunctions(true)) {
			if (f.isThunk() || f.isExternal() || f.getBody().getNumAddresses() < 32)
				continue;
			DecompileResults r = d.decompileFunction(f, 60, monitor);
			if (r.decompileCompleted() && r.getDecompiledFunction() != null) {
				println("PORTSMOKE decompiled=" + f.getName() + " lines=" +
				    r.getDecompiledFunction().getC().split("\n").length);
			} else {
				println("PORTSMOKE decompile-error=" + f.getName() + ": " +
				    r.getErrorMessage());
			}
			break;
		}
		d.dispose();
	}
}
EOF

# Ghidra writes its user settings under ${HOME}; keep the real one untouched.
mkdir -p "${WORKDIR}/home" "${WORKDIR}/proj"
set +e
env HOME="${WORKDIR}/home" timeout "${ANALYZE_TIMEOUT}" \
	${DATADIR}/support/analyzeHeadless "${WORKDIR}/proj" PortSmoke \
	-import "${TARGET}" -scriptPath "${WORKDIR}" -postScript PortSmoke.java \
	-deleteProject > "${WORKDIR}/headless.log" 2>&1
rc=$?
set -e
grep 'PORTSMOKE' "${WORKDIR}/headless.log" || true
if [ "${rc}" -ne 0 ]; then
	tail -30 "${WORKDIR}/headless.log" >&2
	[ "${rc}" -eq 124 ] && fail "analyzeHeadless timed out after ${ANALYZE_TIMEOUT}s"
	fail "analyzeHeadless exited ${rc}"
fi

nfunc=$(sed -n 's/.*PORTSMOKE functions=\([0-9]*\).*/\1/p' "${WORKDIR}/headless.log")
[ -n "${nfunc}" ] && [ "${nfunc}" -gt 10 ] ||
	fail "analysis found ${nfunc:-no} functions in ${TARGET}"
grep -q 'PORTSMOKE decompiled=' "${WORKDIR}/headless.log" ||
	fail "decompiler did not produce C (see PORTSMOKE lines above)"

echo "PASS  ${PORT_NAME} ${PKG_VER}"
