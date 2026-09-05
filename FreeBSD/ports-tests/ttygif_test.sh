#!/bin/sh
# ttygif smoke test: install the freshly built package, exercise the ttyrec
# parser and GIF-command builder end-to-end, then uninstall.
#
# ttygif screenshots a terminal window (xwd) once per ttyrec frame and pipes
# the result through ImageMagick's convert.  Neither an X11 display nor a real
# terminal window exists in a headless test run, so the test drives the binary
# with TTYGIF_DEBUG=1: in that mode system_exec() prints each command instead
# of running it.  That still exercises the whole interesting path -- ttyrec
# header parsing, frame iteration, inter-frame delay computation and convert(1)
# argument assembly -- while needing no display.
#
# Two upstream quirks the test pins down:
#   * ttygif checks $WINDOWID before it parses argv, so even `ttygif -v` fails
#     without it.  Every invocation below sets WINDOWID=1.
#   * Upstream ships a stale `VERSION = '"1.4.0"'` in its Makefile on the 1.6.0
#     tag; the port rewrites it from PORTVERSION in post-patch.  The version
#     assertion below is what catches that regressing on a future bump.
set -eu

PORT_NAME=ttygif
JAIL=builder
TREE=official
PKGDIR=/usr/local/poudriere/data/packages/${JAIL}-${TREE}/.latest/All
WORKDIR=$(mktemp -d /tmp/${PORT_NAME}-test.XXXXXX)

# Expected version comes from the port Makefile, so the test follows bumps.
PORTSDIR=${PORTSDIR:-/home/olivier/freebsd-official/ports}
EXPECTED_VERSION=$(make -C "${PORTSDIR}/graphics/${PORT_NAME}" -V PORTVERSION)

cleanup() {
	rm -rf "${WORKDIR}"
	# Only uninstall if nothing else depends on it (see README).
	if [ -z "$(pkg query '%rn-%rv' ${PORT_NAME} 2>/dev/null)" ]; then
		sudo pkg delete -y "${PORT_NAME}" 2>/dev/null || true
	fi
}
trap cleanup EXIT INT TERM

# 1. Install fresh package.  The port uses a bare USES=magick:run, so the
#    ImageMagick dependency follows the tree/user DEFAULT_VERSIONS rather than
#    being pinned to a version+flavour -- that is what lets this install
#    against whichever ImageMagick the host already runs (x11 or nox11).
#    IGNORE_OSVERSION: the jail can be a newer __FreeBSD_version than the host
#    userland, which otherwise makes pkg add stop and prompt interactively.
PKG=$(ls -t ${PKGDIR}/${PORT_NAME}-*.pkg | head -1)
sudo env IGNORE_OSVERSION=yes ASSUME_ALWAYS_YES=yes pkg add -f "${PKG}"

# 2. Version smoke check -- must report the port's version, not upstream's
#    stale hardcoded one.
VERSION_OUT=$(WINDOWID=1 /usr/local/bin/ttygif -v)
if [ "${VERSION_OUT}" != "${EXPECTED_VERSION}" ]; then
	echo "FAIL  ${PORT_NAME}: -v printed '${VERSION_OUT}', expected '${EXPECTED_VERSION}'" >&2
	echo "      (upstream hardcodes VERSION in its Makefile and forgets to bump" >&2
	echo "       it; the port's post-patch REINPLACE_CMD should be fixing that)" >&2
	exit 1
fi

# 3. Usage output reachable
WINDOWID=1 /usr/local/bin/ttygif -h | grep -q '^Usage: ttygif'

# 4. Build a 3-frame ttyrec fixture.  Format is a repeating
#    {int32 tv_sec, int32 tv_usec, int32 len} little-endian header followed by
#    len payload bytes.  Frame timestamps 0.00 / 0.30 / 0.65 give predictable
#    inter-frame delays in centiseconds: 30 and 35.
TTYREC="${WORKDIR}/sample.ttyrec"
python3 - "${TTYREC}" <<'EOF'
import struct, sys
frames = [(0.0, "hello from ttygif\r\n"),
          (0.30, "second frame\r\n"),
          (0.65, "third frame\r\n")]
out = b""
for t, text in frames:
    sec, usec = int(t), int(round((t - int(t)) * 1_000_000))
    b = text.encode()
    out += struct.pack("<iii", sec, usec, len(b)) + b
open(sys.argv[1], "wb").write(out)
EOF
test -s "${TTYREC}"

# 5. Drive the full conversion path in debug mode.
cd "${WORKDIR}"
WINDOWID=1 TTYGIF_DEBUG=1 /usr/local/bin/ttygif "${TTYREC}" \
	> "${WORKDIR}/run.log" 2>&1

# 5a. One screenshot per frame -- proves every ttyrec record was parsed.
SNAPS=$(grep -c 'DEBUG: xwd -id 1 -out' "${WORKDIR}/run.log")
[ "${SNAPS}" = "3" ] || {
	echo "FAIL  ${PORT_NAME}: expected 3 frame snapshots, got ${SNAPS}" >&2
	cat "${WORKDIR}/run.log" >&2
	exit 1
}

# 5b. Inter-frame delays computed from the fixture timestamps, and the trailing
#     frame gets the 1000ms last_frame_delay default.  This is the real
#     correctness check: it would catch a regression in the timing maths that a
#     bare --version test sails straight past.
grep -q 'DEBUG: convert -loop 0 .*-delay 30\..*-delay 35\..*-delay 100\..*-layers Optimize GIF:tty.gif' \
	"${WORKDIR}/run.log" || {
	echo "FAIL  ${PORT_NAME}: convert command / frame delays not as expected" >&2
	grep 'DEBUG: convert' "${WORKDIR}/run.log" >&2
	exit 1
}

# 5c. Reached the end of the pipeline.
grep -q 'Created: tty.gif' "${WORKDIR}/run.log"

# 6. ImageMagick's convert must actually be present at runtime (USES=magick:6,run)
[ -x /usr/local/bin/convert ] || [ -x /usr/local/bin/magick ] || {
	echo "FAIL  ${PORT_NAME}: no convert/magick binary -- USES=magick:6,run missing?" >&2
	exit 1
}

echo "PASS  ${PORT_NAME} ${EXPECTED_VERSION}"
