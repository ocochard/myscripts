#!/bin/sh
# Check that two grades of the same clip are frame-aligned: luma SSIM of 48
# frames from frame START of A against B shifted by -2..+2 frames. The peak
# should be at offset 0.
# Usage: frame_offset.sh A.hevc B.hevc [START]
set -eu
FFMPEG=${FFMPEG:-$HOME/netint_ffmpeg/ffmpeg}
a=$1 b=$2 s0=${3:-3000}
for off in -2 -1 0 1 2; do
	s=$((s0 + off))
	printf 'offset %s: ' $off
	$FFMPEG -nostdin -hide_banner -i "$a" -i "$b" -lavfi \
	    "[0]trim=start_frame=$s0:end_frame=$((s0 + 48)),setpts=PTS-STARTPTS,extractplanes=y[x];[1]trim=start_frame=$s:end_frame=$((s + 48)),setpts=PTS-STARTPTS,extractplanes=y[y];[x][y]ssim" \
	    -f null - 2>&1 | grep -o 'All:[0-9.]*'
done
