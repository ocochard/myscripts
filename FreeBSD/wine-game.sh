#!/bin/sh
# Prepare a Wine prefix for Windows games (Electron/Chromium, Unreal Engine) and launch one.
#
# Fixes applied (all idempotent):
#  - Tahoma registered in the prefix: without it Wine's DirectWrite cannot
#    resolve Chromium's UI font and the browser process recurses until a stack
#    overflow (hang, no window).
#  - MS core fonts (winetricks corefonts): Chromium maps CSS serif/sans-serif to
#    Times New Roman/Arial; when absent, text renders as zero-width glyphs.
#  - --no-sandbox: the sandboxed renderer gets killed under Wine (white screen).
#  - US keyboard layout while the game runs: Wine cannot map exotic layouts
#    (e.g. bepo) to scancodes, so games reading KeyboardEvent.code (WASD) get
#    wrong keys. The previous layout is restored on exit.
#  - Unreal Engine games: DXVK + vkd3d-proton (winetricks dxvk vkd3d). Wine's
#    builtin wined3d/vkd3d fail to build UE5 pipelines => "LowLevelFatalError
#    PipelineStateCache.cpp: Shader compilation failures are Fatal". Installed
#    in a separate prefix (~/.wine-ue) to leave the Electron prefix untouched.

set -eu

usage() {
	echo "Usage: $(basename "$0") [-d] [-k] [-s] /path/to/game.exe [game args...]"
	echo "  -d  install DXVK + vkd3d-proton (automatic for Unreal Engine games)"
	echo "  -k  keep the current keyboard layout (no switch to us)"
	echo "  -s  setup the prefix only, do not launch"
	echo "Env: WINEPREFIX (default ~/.wine, ~/.wine-ue for -d), WINEDIR (default /usr/local/wine-proton)"
	exit 1
}

dxvk=false
keep_layout=false
setup_only=false
while getopts "dksh" opt; do
	case ${opt} in
	d) dxvk=true ;;
	k) keep_layout=true ;;
	s) setup_only=true ;;
	*) usage ;;
	esac
done
shift $((OPTIND - 1))

# Unreal Engine packaged game: Engine/ directory next to the launcher
[ $# -ge 1 ] && [ -d "$(dirname "$1")/Engine" ] && dxvk=true

WINEDIR=${WINEDIR:-/usr/local/wine-proton}
if ${dxvk}; then
	export WINEPREFIX=${WINEPREFIX:-${HOME}/.wine-ue}
else
	export WINEPREFIX=${WINEPREFIX:-${HOME}/.wine}
fi
export PATH=${WINEDIR}/bin:${PATH}
export WINEDEBUG=${WINEDEBUG:--all}
fonts=${WINEPREFIX}/drive_c/windows/Fonts

setup_prefix() {
	[ -d "${fonts}" ] || wineboot -i
	if [ ! -f "${fonts}/tahoma.ttf" ]; then
		echo "Installing Tahoma into ${WINEPREFIX}"
		cp "${WINEDIR}"/share/wine/fonts/tahoma*.ttf "${fonts}/"
		key='HKLM\Software\Microsoft\Windows NT\CurrentVersion\Fonts'
		wine64 reg add "${key}" /v 'Tahoma (TrueType)' /d tahoma.ttf /f >/dev/null
		wine64 reg add "${key}" /v 'Tahoma Bold (TrueType)' /d tahomabd.ttf /f >/dev/null
	fi
	if [ ! -f "${fonts}/arial.ttf" ] || [ ! -f "${fonts}/times.ttf" ]; then
		echo "Installing MS core fonts into ${WINEPREFIX}"
		winetricks --optout -q corefonts
	fi
	if ${dxvk} && ! grep -q '^"\*d3d12"="native"' "${WINEPREFIX}/user.reg"; then
		echo "Installing DXVK + vkd3d-proton into ${WINEPREFIX}"
		winetricks --optout -q dxvk vkd3d
	fi
}

setup_prefix
${setup_only} && exit 0

[ $# -ge 1 ] || usage
exe=$1
shift
[ -f "${exe}" ] || { echo "ERROR: ${exe} not found"; exit 1; }

# A stale instance would hold Electron's single-instance lock, and Wine only
# detects the keyboard layout when its X11 driver starts.
wineserver -k 2>/dev/null || true
wineserver -w

if ! ${keep_layout}; then
	q=$(setxkbmap -query)
	layout=$(echo "${q}" | awk '/^layout:/ {print $2}')
	variant=$(echo "${q}" | awk '/^variant:/ {print $2}')
	options=$(echo "${q}" | awk '/^options:/ {print $2}')
	restore_layout() {
		setxkbmap -layout "${layout}" -variant "${variant}" \
		    ${options:+-option "" -option "${options}"}
	}
	trap restore_layout EXIT
	trap 'exit 1' INT TERM
	setxkbmap -layout us -variant "" -option ""
fi

cd "$(dirname "${exe}")"
# WebView2 apps (e.g. Construct 3 exports) ignore command-line flags and
# WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS; they read "chromium-args" from
# package.json. Without --no-sandbox the GPU process is killed in a loop.
if grep -q '"chromium-args"' package.json 2>/dev/null &&
    ! grep -q '"chromium-args": "--no-sandbox' package.json; then
	echo "Adding --no-sandbox to package.json (backup: package.json.orig)"
	cp -n package.json package.json.orig
	sed 's/"chromium-args": "/"chromium-args": "--no-sandbox /' \
	    package.json.orig > package.json
fi
wine64 "$(basename "${exe}")" --no-sandbox "$@"
