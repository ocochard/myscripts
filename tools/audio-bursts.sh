#!/bin/sh
# Download a YouTube URL (or use a local media file), extract its audio track
# without re-encoding, list the sound bursts separated by silences, and save
# the selected burst(s) as .wav
set -eu

NOISE=-40dB	# below this level is silence
MIN_SILENCE=0.3	# shortest pause (seconds) splitting two bursts
SELECT=""

usage() {
	echo "Usage: $0 [-n noise_dB] [-d min_silence_s] [-b burst_numbers] <url|file>"
	echo "Example: $0 -b 1 https://www.youtube.com/watch?v=XXXX"
	echo "         $0 -n -50dB -d 0.5 whistle.mkv"
	exit 1
}

while getopts n:d:b:h opt; do
	case $opt in
	n) NOISE=$OPTARG ;;
	d) MIN_SILENCE=$OPTARG ;;
	b) SELECT=$OPTARG ;;
	*) usage ;;
	esac
done
shift $((OPTIND - 1))
[ $# -eq 1 ] || usage

SRC="$1"
if [ ! -f "$SRC" ]; then
	echo "Downloading $SRC"
	# Best audio-only stream: avoids downloading the video just to drop it
	SRC=$(yt-dlp -f bestaudio -o '%(title)s [%(id)s].%(ext)s' \
		--print after_move:filepath "$SRC")
	[ -f "$SRC" ] || { echo "Error: download failed"; exit 1; }
	DOWNLOADED=1
fi

BASE="${SRC%.*}"
AUDIO="$BASE.mka"	# Matroska audio accepts any codec, so stream copy always works
if [ ! -f "$AUDIO" ]; then
	ffmpeg -v error -i "$SRC" -map 0:a:0 -vn -c:a copy "$AUDIO"
fi
# Only remove what we downloaded, never a user-provided file
[ -z "${DOWNLOADED:-}" ] || rm -f "$SRC"

DURATION=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$AUDIO")

# Bursts are the gaps between silences: "number start end duration"
BURSTS=$(ffmpeg -hide_banner -nostats -i "$AUDIO" \
	-af "silencedetect=noise=$NOISE:d=$MIN_SILENCE" -f null - 2>&1 |
	awk -v dur="$DURATION" '
	function emit(s, e) { if (e - s > 0.05) printf "%d %.3f %.3f %.3f\n", ++n, s, e, e - s }
	/silence_start:/ { split($0, a, "silence_start: "); emit(pos, a[2] + 0) }
	/silence_end:/   { split($0, a, "silence_end: "); pos = a[2] + 0 }
	END              { emit(pos, dur + 0) }')

[ -n "$BURSTS" ] || { echo "No sound above $NOISE found"; exit 1; }

echo "Audio: $AUDIO (${DURATION}s, silence < $NOISE for >= ${MIN_SILENCE}s)"
echo "$BURSTS" | awk '{ printf "  #%-3d %9.3fs -> %9.3fs  (%.3fs)\n", $1, $2, $3, $4 }'

if [ -z "$SELECT" ]; then
	printf "Burst number(s) to extract (e.g. 1 or 1 3, empty to quit): "
	read -r SELECT || true
fi

for i in $SELECT; do
	line=$(echo "$BURSTS" | awk -v i="$i" '$1 == i')
	[ -n "$line" ] || { echo "Error: no burst #$i"; continue; }
	set -- $line
	OUT="$BASE-burst$i.wav"
	ffmpeg -v error -y -i "$AUDIO" -ss "$2" -to "$3" "$OUT"
	echo "Wrote $OUT"
done
