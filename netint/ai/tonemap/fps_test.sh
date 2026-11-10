#!/bin/sh
# Speed of networks on the card: decode an HDR10 HEVC clip on the Quadra and
# run ni_quadra_ai_pre, no download (-f null). Prints the final fps.
# Usage: fps_test.sh clip.hevc model.nb...
set -eu
FFMPEG=${FFMPEG:-$HOME/netint_ffmpeg/ffmpeg}
clip=$1
shift
for nb in "$@"; do
	printf '%s: ' "$nb"
	sudo $FFMPEG -nostdin -hide_banner -y -c:v h265_ni_quadra_dec -dec 0 \
	    -xcoder-params out=hw -i "$clip" -vf "ni_quadra_ai_pre=nb=$nb" -f null - 2>&1 |
	    grep -o -E 'fps=[ 0-9.]*' | tail -1
done
