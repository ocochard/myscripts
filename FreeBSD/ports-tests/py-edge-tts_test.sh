#!/bin/sh
# audio/py-edge-tts smoke test.
#
# Installs the freshly-built py-edge-tts package from the poudriere builder,
# checks the CLI version against the pkg, then does a real round-trip against
# Microsoft's online TTS service: voice list, then synthesize a short phrase
# to MP3 + SRT subtitles. The network steps SKIP (not FAIL) if the service is
# unreachable within NET_TIMEOUT seconds.
set -eu

JAIL=builder
TREE=official
PKGDIR=/usr/local/poudriere/data/packages/${JAIL}-${TREE}/.latest/All
NET_TIMEOUT=${NET_TIMEOUT:-60}

PKG=$(ls -t ${PKGDIR}/py3*-edge-tts-*.pkg | head -1)
PORT_NAME=$(basename "${PKG}" | sed 's/-[^-]*\.pkg$//')
PY=$(echo "${PORT_NAME}" | sed -E 's/^py([0-9])([0-9]+)-.*/python\1.\2/')
TMP=$(mktemp -d /tmp/edge-tts-test.XXXXXX)

PREEXISTED=0
HAS_REVDEPS=0

cleanup() {
	rm -rf "${TMP}"
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

# 2. Version: CLI, module and pkg must agree
PKG_VER=$(pkg query '%v' ${PORT_NAME})
CLI_VER=$(edge-tts --version | awk '{print $2}')
PY_VER=$(${PY} -c 'import edge_tts; print(edge_tts.__version__)')
echo "Package: ${PKG_VER}   edge-tts --version: ${CLI_VER}   module: ${PY_VER}"
[ "${PKG_VER%_*}" = "${CLI_VER}" ] && [ "${CLI_VER}" = "${PY_VER}" ] || {
	echo "FAIL  version mismatch"
	exit 1
}
command -v edge-playback >/dev/null || { echo "FAIL  edge-playback missing"; exit 1; }
echo "PASS  version + entry points"

# 3. Voice list (network)
rc=0
timeout "${NET_TIMEOUT}" edge-tts --list-voices > "${TMP}/voices.txt" 2>&1 || rc=$?
if [ "${rc}" = 124 ] || grep -qE 'ClientConnectorError|Cannot connect|Name does not resolve' "${TMP}/voices.txt"; then
	echo "SKIP  TTS service unreachable"
	exit 0
fi
[ "${rc}" = 0 ] || { cat "${TMP}/voices.txt"; echo "FAIL  --list-voices rc=${rc}"; exit 1; }
grep -q 'en-US-EmmaMultilingualNeural' "${TMP}/voices.txt" || {
	echo "FAIL  default voice not in voice list"
	exit 1
}
echo "PASS  voice list ($(grep -c Neural "${TMP}/voices.txt") voices)"

# 4. Synthesize to MP3 + SRT (network)
timeout "${NET_TIMEOUT}" edge-tts --no-progress \
	--text "Hello from FreeBSD. This is a regression test." \
	--write-media "${TMP}/out.mp3" --write-subtitles "${TMP}/out.srt"
SIZE=$(stat -f %z "${TMP}/out.mp3")
[ "${SIZE}" -gt 4000 ] || { echo "FAIL  MP3 too small (${SIZE} bytes)"; exit 1; }
file -b "${TMP}/out.mp3" | grep -qiE 'MPEG ADTS|Audio file with ID3' || {
	echo "FAIL  output is not MP3: $(file -b "${TMP}/out.mp3")"
	exit 1
}
grep -q -- '-->' "${TMP}/out.srt" && grep -qi 'FreeBSD' "${TMP}/out.srt" || {
	cat "${TMP}/out.srt"
	echo "FAIL  SRT missing cues or text"
	exit 1
}
echo "PASS  synthesis (${SIZE} bytes MP3, $(grep -c -- '-->' "${TMP}/out.srt") SRT cues)"

echo "PASS  py-edge-tts ${PKG_VER}"
