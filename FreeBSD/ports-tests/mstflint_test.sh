#!/bin/sh
# mstflint smoke test: install the freshly built package, exercise the tools
# that work without a Mellanox/NVIDIA adapter, then uninstall.
#
# No hardware needed: version checks, python tool entry points (catch missing
# plist entries / modules), and mstconfig's offline TLV + XML template
# generation, which reads the shipped mlxconfig host and switch databases.
# xml2raw/raw2xml need the FWMANAGER option (libxml2), off by default.
set -eu

PORT_NAME=mstflint
JAIL=builder
TREE=official
PKGDIR=/usr/local/poudriere/data/packages/${JAIL}-${TREE}/.latest/All
WORKDIR=$(mktemp -d /tmp/${PORT_NAME}-test.XXXXXX)

PREINSTALLED=0
pkg info -e "${PORT_NAME}" 2>/dev/null && PREINSTALLED=1

cleanup() {
	rm -rf "${WORKDIR}"
	if [ "${PREINSTALLED}" = 0 ]; then
		sudo pkg delete -y "${PORT_NAME}" 2>/dev/null || true
	fi
}
trap cleanup EXIT INT TERM

fail() { echo "FAIL  ${PORT_NAME}: $*" >&2; exit 1; }

# 1. Install fresh package
PKG=$(ls -t ${PKGDIR}/${PORT_NAME}-*.pkg | head -1)
sudo env IGNORE_OSVERSION=yes ASSUME_ALWAYS_YES=yes pkg install -fy "${PKG}"

# 2. Version reported by the tools matches the package (4.38.0.1 -> 4.38.0)
PKGVER=$(pkg query %v "${PORT_NAME}")
WANT=${PKGVER%.*}
WANT=${WANT%_*}
for t in mstflint mstconfig mstfwtrace mstresourcedump mstflintlogger; do
	/usr/local/bin/${t} --version 2>&1 | grep -q "mstflint ${WANT}," ||
	    fail "${t} --version does not report ${WANT}"
done

# 3. Python tools: wrapper + imports resolve (mstpcie/mstflintlogger new in 4.38)
for t in mstpcie mstresourceparse mstflintlogger; do
	/usr/local/bin/${t} --help > "${WORKDIR}/${t}.help" 2>&1 ||
	    fail "${t} --help exited non-zero"
	grep -qE 'Traceback|ModuleNotFoundError|ImportError' "${WORKDIR}/${t}.help" &&
	    fail "${t} has a python import error"
done
grep -q 'counters,events,link' "${WORKDIR}/mstpcie.help" ||
    fail "mstpcie usage missing subcommands"

# 4. mstconfig offline: TLV list + XML template from the shipped databases
cd "${WORKDIR}"
for type in HCA SWITCH; do
	mstconfig -t ${type} gen_tlvs_file tlvs-${type}.txt > /dev/null
	n=$(wc -l < tlvs-${type}.txt)
	[ "${n}" -gt 20 ] || fail "${type} TLV list has only ${n} entries"
done
grep -qE '^nv_global_pci_conf[[:space:]]+0$' tlvs-HCA.txt ||
    fail "nv_global_pci_conf missing from HCA TLV list"
sed -E 's/^(nv_global_pci_conf[[:space:]]+)0$/\11/' tlvs-HCA.txt > sel.txt
mstconfig -t HCA gen_xml_template sel.txt tmpl.xml > /dev/null
grep -q '<nv_global_pci_conf>' tmpl.xml || fail "template lacks selected TLV"
grep -q '<sriov_en></sriov_en>' tmpl.xml || fail "template lacks sriov_en"

echo "PASS  ${PORT_NAME} ${PKGVER}"
