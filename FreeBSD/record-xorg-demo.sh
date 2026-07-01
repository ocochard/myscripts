#!/bin/sh
# Record Xorg screen + game audio (via a virtual_oss loopback on /dev/dsp.rec)
# for a fixed duration, then mux video and audio into a single demo.mkv.
#
# Audio and video are captured with two separate ffmpeg processes: a single
# ffmpeg process reading x11grab and oss together starves the audio thread,
# producing periodic silent gaps in the output.
#
# Requires: ffmpeg, and virtual_oss already running with a /dev/dsp.rec
# loopback tap (see virtual_oss(8)).

set -e

# Detect the running Xorg server's display and auth file, so this also
# works over a non-interactive ssh session where $DISPLAY/$XAUTHORITY
# aren't inherited from the graphical login.
detect_x11 () {
	XORG_CMD=$(ps -axo command | grep '[X]org' | head -1)
	if [ -z "$XORG_CMD" ]; then
		echo "No running Xorg server found" >&2
		exit 1
	fi

	DETECTED_DISPLAY=$(echo "$XORG_CMD" | awk '{for (i=1;i<=NF;i++) if ($i ~ /^:[0-9]/) {print $i; exit}}')
	DETECTED_XAUTHORITY=$(echo "$XORG_CMD" | awk '{for (i=1;i<=NF;i++) if ($i == "-auth") {print $(i+1); exit}}')

	if [ -z "$DETECTED_DISPLAY" ]; then
		echo "Could not detect display number from: $XORG_CMD" >&2
		exit 1
	fi
}

detect_resolution () {
	DETECTED_VIDEO_SIZE=$(xdpyinfo | awk '/dimensions:/{print $2}')
	if [ -z "$DETECTED_VIDEO_SIZE" ]; then
		echo "Could not detect screen resolution via xdpyinfo" >&2
		exit 1
	fi
}

detect_x11

DISPLAY_NUM=${DISPLAY:-$DETECTED_DISPLAY}
XAUTHORITY=${XAUTHORITY:-$DETECTED_XAUTHORITY}
export DISPLAY="$DISPLAY_NUM"
[ -n "$XAUTHORITY" ] && export XAUTHORITY

detect_resolution

VIDEO_SIZE=${VIDEO_SIZE:-$DETECTED_VIDEO_SIZE}
FRAMERATE=${FRAMERATE:-15}
AUDIO_DEV=${AUDIO_DEV:-/dev/dsp.rec}
OUTPUT=${OUTPUT:-demo.mkv}

VOSS_EXAMPLE='virtual_oss -C 2 -c 2 -r 48000 -b 16 -s 200ms -f /dev/dsp3 -d dsp -l dsp.rec -M o,0,0,0,0,0 -M o,1,1,0,0,0 -t vdsp.ctl -B'

check_oss () {
	if ! pgrep -qx virtual_oss; then
		echo "virtual_oss is not running -- start it first, e.g.:" >&2
		echo "  sudo kldload cuse   # if not already loaded" >&2
		echo "  sudo $VOSS_EXAMPLE" >&2
		exit 1
	fi

	if [ ! -c "$AUDIO_DEV" ]; then
		echo "AUDIO_DEV ($AUDIO_DEV) does not exist or is not a character device" >&2
		echo "Check the -l name given to virtual_oss matches AUDIO_DEV" >&2
		exit 1
	fi
}

check_oss

usage () {
	echo "Usage: $(basename $0) <duration_seconds> [output_file]"
	echo
	echo "Environment overrides:"
	echo "  DISPLAY       X display to grab (auto-detected: ${DISPLAY_NUM})"
	echo "  XAUTHORITY    X auth file (auto-detected: ${XAUTHORITY:-none})"
	echo "  VIDEO_SIZE    video capture size (auto-detected: ${VIDEO_SIZE})"
	echo "  FRAMERATE     video framerate (default: ${FRAMERATE})"
	echo "  AUDIO_DEV     OSS device to capture (default: ${AUDIO_DEV})"
	exit 1
}

if [ $# -lt 1 ]; then
	usage
fi

DURATION=$1
[ -n "$2" ] && OUTPUT=$2

case $DURATION in
	''|*[!0-9]*) usage ;;
esac

VIDEO_TMP=$(mktemp /tmp/record-video.XXXXXX.mkv)
AUDIO_TMP=$(mktemp /tmp/record-audio.XXXXXX.m4a)

cleanup () {
	rm -f "$VIDEO_TMP" "$AUDIO_TMP"
}
trap cleanup EXIT

echo "Using display ${DISPLAY_NUM} (XAUTHORITY=${XAUTHORITY:-none})"
echo "Recording ${DURATION}s of video (${VIDEO_SIZE}@${FRAMERATE}fps) and audio (${AUDIO_DEV})..."

ffmpeg -y -f x11grab -video_size "$VIDEO_SIZE" -r "$FRAMERATE" -i "$DISPLAY_NUM" \
	-c:v libx264 -preset ultrafast -crf 23 \
	-t "$DURATION" "$VIDEO_TMP" >/tmp/record-video.log 2>&1 &
VIDEO_PID=$!

ffmpeg -y -f oss -thread_queue_size 8192 -i "$AUDIO_DEV" \
	-c:a aac \
	-t "$DURATION" "$AUDIO_TMP" >/tmp/record-audio.log 2>&1 &
AUDIO_PID=$!

remaining=$DURATION
while [ "$remaining" -gt 0 ] && kill -0 $VIDEO_PID 2>/dev/null && kill -0 $AUDIO_PID 2>/dev/null; do
	printf '\r%ds remaining...  ' "$remaining"
	sleep 1
	remaining=$((remaining - 1))
done
printf '\rRecording done, finalizing...   \n'

wait $VIDEO_PID
wait $AUDIO_PID

echo "Muxing into ${OUTPUT}..."
ffmpeg -y -i "$VIDEO_TMP" -i "$AUDIO_TMP" -c copy -shortest "$OUTPUT"

echo "Done: ${OUTPUT}"
