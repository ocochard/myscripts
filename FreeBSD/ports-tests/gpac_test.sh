#!/bin/sh
# multimedia/gpac smoke test: install the freshly built package, run
# `gpac -i <sample.mp4> inspect` and `MP4Box -info` against the bundled
# gpac.mp4 sample, then deinstall. The sample is shipped in the port at
# ${DATADIR}/res/gpac.mp4.
set -eu

PORT_NAME=gpac
JAIL=builder
TREE=official
PKGDIR=/usr/local/poudriere/data/packages/${JAIL}-${TREE}/.latest/All
DATADIR=/usr/local/share/gpac
SAMPLE=${DATADIR}/res/gpac.mp4
LOGFILE=/tmp/${PORT_NAME}-test.log

cleanup() {
	rm -f "${LOGFILE}"
	sudo pkg delete -y "${PORT_NAME}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

PKG=$(ls -t ${PKGDIR}/${PORT_NAME}-*.pkg | head -1)
sudo pkg add -f "${PKG}"

test -f "${SAMPLE}"

/usr/local/bin/gpac -i "${SAMPLE}" inspect > "${LOGFILE}" 2>&1
grep -q "PID 1 ID " "${LOGFILE}"
grep -q "codec " "${LOGFILE}"

/usr/local/bin/MP4Box -info "${SAMPLE}" >> "${LOGFILE}" 2>&1
grep -q "Movie Info" "${LOGFILE}"

echo "PASS  ${PORT_NAME}"
