#!/bin/sh
# Cut COUNT single keyframes, spread over a film, as tiny raw HEVC files
# (stream copy, no decode). Run where the films are; copy the output to the
# FFmpeg+zimg host for make_reference.sh.
# Usage: cut_keyframes.sh film tag count outdir
set -eu

film=$1 tag=$2 count=$3 out=$4
mkdir -p "$out"
dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$film")
# Skip the first 5 minutes and the last 10 (logos, credits).
start=300
span=$(echo "$dur - 900" | bc)
i=0
while [ $i -lt "$count" ]; do
	t=$(echo "$start + $span * $i / $count" | bc)
	ffmpeg -nostdin -hide_banner -loglevel error -y -ss "$t" -i "$film" \
	    -map 0:v:0 -c copy -bsf:v hevc_mp4toannexb -frames:v 1 \
	    "$out/$(printf '%s_%03d' "$tag" $i).hevc" </dev/null
	i=$((i + 1))
done
