#!/bin/sh
#
# Reproduce and bisect the VA-API transcode hang on FreeBSD + AMD iGPU.
#
# Symptom: ffmpeg with BOTH hardware decode (-hwaccel vaapi) and hardware
# encode (h264_vaapi) initialises cleanly, then spins at 99% CPU in uwait
# forever without encoding a single frame. Either half alone works.
#
# See vaapi-transcode-hang.md for the full analysis.
#
# IMPORTANT: the wedged ffmpeg IGNORES SIGTERM, so timeout(1) cannot kill it.
# This script SIGKILLs the whole process tree after each test and verifies the
# die temperature has recovered before continuing. Never run these commands
# bare -- a missed cleanup leaves a core pinned at ~97C indefinitely.
#
# Usage:
#   sudo sh vaapi-hang-repro.sh [path-to-test-file.mkv]
#
# Must run as root: needs /dev/dri/renderD128 and kill -9 on jellyfin procs.

set -u

DEVICE="/dev/dri/renderD128"
DEFAULT_FILE="/NAS/films/Dessin.Anime/L'Age.de.glace.2002.720p.mkv"
FILE="${1:-$DEFAULT_FILE}"

# Seconds to let a test run before declaring it hung. Working configs finish
# in well under a second; anything still alive at this point is wedged.
HANG_AFTER=25

# Die temperature considered safe to start the next test.
COOL_C=60

export LIBVA_DRIVERS_PATH=/usr/local/lib/dri
export LIBVA_DRIVER_NAME=radeonsi

PASS=0
FAIL=0

die() { echo "FATAL: $*" >&2; exit 1; }

temp() {
	sysctl -n dev.amdtemp.0.core0.sensor0 2>/dev/null | tr -d 'C'
}

# Kill every ffmpeg this script started, hard. SIGTERM is useless here.
cleanup_ffmpeg() {
	_pids=$(pgrep -f 'ffmpeg -hide_banner -nostdin' 2>/dev/null)
	[ -z "$_pids" ] && return 0

	echo "    cleanup: SIGKILL $_pids"
	# shellcheck disable=SC2086
	kill -9 $_pids 2>/dev/null
	sleep 3

	_left=$(pgrep -f 'ffmpeg -hide_banner -nostdin' 2>/dev/null)
	[ -n "$_left" ] && die "ffmpeg survived SIGKILL: $_left (manual intervention needed)"
	return 0
}

# Block until the die has cooled, so one test's heat doesn't skew the next.
wait_cool() {
	_i=0
	while [ "$_i" -lt 30 ]; do
		_t=$(temp)
		case "$_t" in
			''|*[!0-9.]*) return 0 ;;   # sensor unreadable, don't block
		esac
		# integer compare on the whole-degree part
		[ "${_t%%.*}" -le "$COOL_C" ] && return 0
		sleep 2
		_i=$((_i + 1))
	done
	echo "    warning: still ${_t}C after 60s"
}

# run_test <label> <expectation: works|hangs> <ffmpeg args...>
#
# Runs ffmpeg in the background, polls for completion, and declares a hang if
# it is still alive after HANG_AFTER seconds. Compares against the documented
# expectation so a change in behaviour is visible immediately.
run_test() {
	_label="$1"; shift
	_expect="$1"; shift

	echo
	echo "=== $_label"
	echo "    expect: $_expect | temp before: $(temp)C"

	_out=$(mktemp /tmp/vaapi-repro.XXXXXX)

	ffmpeg -hide_banner -nostdin "$@" >"$_out" 2>&1 &
	_pid=$!

	_waited=0
	_result="hangs"
	while [ "$_waited" -lt "$HANG_AFTER" ]; do
		if ! kill -0 "$_pid" 2>/dev/null; then
			_result="works"
			break
		fi
		sleep 1
		_waited=$((_waited + 1))
	done

	if [ "$_result" = "works" ]; then
		wait "$_pid" 2>/dev/null
		_rc=$?
		_frames=$(grep -o 'frame= *[0-9]*' "$_out" | tail -1 | tr -dc '0-9')
		_speed=$(grep -o 'speed= *[0-9.]*x' "$_out" | tail -1)
		[ "$_rc" -ne 0 ] && _result="error(rc=$_rc)"
		echo "    actual: $_result  frames=${_frames:-0} ${_speed:-}"
	else
		# Confirm the classic signature before killing it.
		_stat=$(ps -o stat= -p "$_pid" 2>/dev/null | tr -d ' ')
		_cpu=$(ps -o %cpu= -p "$_pid" 2>/dev/null | tr -d ' ')
		_frames=$(grep -o 'frame= *[0-9]*' "$_out" | tail -1 | tr -dc '0-9')
		echo "    actual: hangs  state=${_stat:-?} cpu=${_cpu:-?}% frames=${_frames:-0}"
		cleanup_ffmpeg
	fi

	rm -f "$_out"

	if [ "$_result" = "$_expect" ]; then
		echo "    PASS (matches documented behaviour)"
		PASS=$((PASS + 1))
	else
		echo "    FAIL (expected $_expect, got $_result)"
		FAIL=$((FAIL + 1))
	fi

	wait_cool
}

# --- preflight -------------------------------------------------------------

[ "$(id -u)" -eq 0 ] || die "must run as root"
[ -e "$DEVICE" ] || die "$DEVICE not found (is amdgpu loaded?)"
[ -r "$FILE" ] || die "test file not readable: $FILE"
command -v ffmpeg >/dev/null || die "ffmpeg not in PATH"

cleanup_ffmpeg   # clear any strays from a previous aborted run

cat <<EOF
VA-API transcode hang bisection
  host:   $(hostname)
  device: $DEVICE
  file:   $FILE
  temp:   $(temp)C
EOF

# --- the bisection ---------------------------------------------------------
#
# The matrix isolates -hwaccel vaapi as the trigger. Tests 1 and 2 prove each
# hardware block works alone; 3 and 4 show the hang with both; 5 shows that
# dropping hardware DECODE (keeping hardware encode) fixes it.

# 1. Hardware decode only. VCN decode is healthy.
run_test "1. HW decode only" works \
	-hwaccel vaapi -vaapi_device "$DEVICE" \
	-i "$FILE" -t 5 -an -f null -

# 2. Hardware encode only, synthetic source. VCN encode is healthy.
run_test "2. HW encode only (synthetic source)" works \
	-init_hw_device vaapi=va:"$DEVICE" -filter_hw_device va \
	-f lavfi -i testsrc=size=1280x720:rate=25 -t 5 \
	-vf format=nv12,hwupload -c:v h264_vaapi -f null -

# 3. Jellyfin's exact chain. Both hardware paths -> deadlock.
run_test "3. Jellyfin exact chain (HW decode + HW encode)" hangs \
	-analyzeduration 200M -probesize 1G -f matroska \
	-init_hw_device vaapi=va:"$DEVICE" -filter_hw_device va -hwaccel vaapi \
	-i "$FILE" -t 10 -threads 0 -map 0:0 \
	-codec:v:0 h264_vaapi -rc_mode VBR -b:v 1116000 \
	-vf "setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709,scale=trunc(min(max(iw\,ih*a)\,1280)/2)*2:trunc(ow/a/2)*2,format=nv12,hwupload=derive_device=vaapi" \
	-an -f null -

# 4. Same, without derive_device. Rules it out as the cause.
run_test "4. Same chain minus derive_device" hangs \
	-analyzeduration 200M -probesize 1G -f matroska \
	-init_hw_device vaapi=va:"$DEVICE" -filter_hw_device va -hwaccel vaapi \
	-i "$FILE" -t 10 -threads 0 -map 0:0 \
	-codec:v:0 h264_vaapi -rc_mode VBR -b:v 1116000 \
	-vf "setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709,scale=trunc(min(max(iw\,ih*a)\,1280)/2)*2:trunc(ow/a/2)*2,format=nv12,hwupload" \
	-an -f null -

# 5. THE WORKAROUND: software decode, hardware encode. Fast and stable.
run_test "5. SW decode + HW encode (workaround)" works \
	-f matroska \
	-init_hw_device vaapi=va:"$DEVICE" -filter_hw_device va \
	-i "$FILE" -t 10 -map 0:0 \
	-codec:v:0 h264_vaapi -b:v 1116000 \
	-vf "format=nv12,hwupload" \
	-an -f null -

# 6. Same HW decode + HW encode as test 3, but split across two processes
#    joined by a pipe. Both run concurrently on the same VCN and complete.
#    This proves the hardware is fine and the deadlock is process-local
#    userspace locking (radeonsi shares a pipe_context/screen lock per device
#    within a process). Run inline rather than via run_test() because it needs
#    a shell pipeline rather than a single ffmpeg invocation.
echo
echo "=== 6. HW decode | HW encode, two processes"
echo "    expect: works | temp before: $(temp)C"

_res=$(mktemp /tmp/vaapi-repro.XXXXXX)
(
	ffmpeg -hide_banner -nostdin \
		-hwaccel vaapi -vaapi_device "$DEVICE" \
		-i "$FILE" -t 10 -an -f rawvideo -pix_fmt nv12 - 2>/dev/null \
	| ffmpeg -hide_banner -nostdin \
		-f rawvideo -pix_fmt nv12 -s 1280x688 -r 23.976 -i - -t 10 \
		-init_hw_device vaapi=va:"$DEVICE" -filter_hw_device va \
		-vf hwupload -c:v h264_vaapi -b:v 1116000 -f null -
) >"$_res" 2>&1 &
_pipe_pid=$!

_waited=0
_pipe_result="hangs"
while [ "$_waited" -lt "$HANG_AFTER" ]; do
	if ! kill -0 "$_pipe_pid" 2>/dev/null; then
		_pipe_result="works"
		break
	fi
	sleep 1
	_waited=$((_waited + 1))
done

if [ "$_pipe_result" = "works" ]; then
	_f=$(grep -o 'frame= *[0-9]*' "$_res" | tail -1 | tr -dc '0-9')
	_s=$(grep -o 'speed= *[0-9.]*x' "$_res" | tail -1)
	echo "    actual: works  frames=${_f:-0} ${_s:-}"
	echo "    PASS (matches documented behaviour)"
	PASS=$((PASS + 1))
else
	echo "    actual: hangs"
	echo "    FAIL (expected works, got hangs)"
	FAIL=$((FAIL + 1))
	kill -9 "$_pipe_pid" 2>/dev/null
	cleanup_ffmpeg
fi
rm -f "$_res"
wait_cool

# --- summary ---------------------------------------------------------------

cleanup_ffmpeg

echo
echo "=========================================="
echo "  matched expectations: $PASS"
echo "  deviated:             $FAIL"
echo "  final temp:           $(temp)C"
echo "=========================================="

if [ "$FAIL" -eq 0 ]; then
	echo
	echo "Bisection matches vaapi-transcode-hang.md:"
	echo "  -hwaccel vaapi + h264_vaapi in one process = deadlock."
	echo "  Workaround: disable hardware DECODE in Jellyfin, keep hardware encode."
	exit 0
fi

echo
echo "Behaviour differs from the documented findings -- the bug may have"
echo "changed or been fixed. Re-check package versions against the doc."
exit 1
