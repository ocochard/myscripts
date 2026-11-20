#!/bin/sh
# Run moonlight (moonlight-embedded) with the X screen saver and DPMS disabled.
#
# moonlight grabs the keyboard and mouse (EVIOCGRAB) and reads the gamepad
# itself, so the X server sees no input while streaming and blanks the
# monitor after its idle timeout.  With the monitor in DPMS standby,
# vaPutSurface() waits forever for the X server, the video freezes (black
# screen) and the stream is dropped on the floor.  The previous screen saver
# and DPMS settings are restored on exit.
#
# Usage: moonlight-stream.sh <moonlight arguments>
#   e.g. moonlight-stream.sh stream -1080 -fps 60 -app "Wild Life" 192.168.100.7

set -eu

: "${DISPLAY:=:0}"
export DISPLAY

if [ $# -eq 0 ]; then
	echo "usage: ${0##*/} <moonlight arguments>" >&2
	exit 1
fi

# Save the current settings
q=$(xset q)
ss_timeout=$(echo "$q" | awk '/timeout:/ {print $2}')
ss_cycle=$(echo "$q" | awk '/cycle:/ {print $4}')
dpms_times=$(echo "$q" | awk '/Standby:/ {print $2, $4, $6}')
dpms_on=$(echo "$q" | grep -q "DPMS is Enabled" && echo yes || echo no)

restore() {
	xset s "$ss_timeout" "$ss_cycle"
	# shellcheck disable=SC2086
	xset dpms $dpms_times
	[ "$dpms_on" = yes ] && xset +dpms || xset -dpms
}
trap restore EXIT
trap 'exit 130' INT TERM

xset s off -dpms
moonlight "$@"
