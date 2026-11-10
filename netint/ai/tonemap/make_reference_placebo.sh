#!/bin/sh
# Make SDR training targets with libplacebo (BT.2390 curve, perceptual gamut
# mapping) on a Vulkan GPU, from the HDR halves of the pairs made by
# make_reference.sh (raw yuv420p10le, 960 wide, PQ BT.2020).
# libplacebo takes the source peak from the frame's HDR metadata, and raw
# frames carry none: each frame goes through lossless x265 tagged as mastered
# on a 1000-nit P3 D65 display (the mastering of every training film), so the
# curve is the same fixed 1000-nit curve for all pairs. Dithering is off so
# the targets are deterministic.
# WIDTH (default 960) is the frame width; a file may hold several frames if
# HEIGHT is given (for whole test clips).
# Usage: make_reference_placebo.sh outdir hdr_*.yuv
set -eu

WIDTH=${WIDTH:-960}

PL="libplacebo=tonemapping=bt.2390:gamut_mode=perceptual:peak_detect=0:dithering=none:colorspace=bt709:color_primaries=bt709:color_trc=bt709:range=tv:format=yuv420p10le"
MD="master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1)"

out=$1
shift
mkdir -p "$out"
for f in "$@"; do
	n=$(basename "$f" .yuv)
	n=${n#hdr_}
	h=${HEIGHT:-$(( $(wc -c < "$f") / (WIDTH * 3) ))}
	tmp=$(mktemp -t placebo).hevc
	ffmpeg -nostdin -hide_banner -loglevel error -y -f rawvideo \
	    -pix_fmt yuv420p10le -s ${WIDTH}x$h -color_range tv -color_primaries bt2020 \
	    -color_trc smpte2084 -colorspace bt2020nc -i "$f" -c:v libx265 \
	    -x265-params "lossless=1:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:range=limited:$MD:log-level=error" \
	    "$tmp"
	ffmpeg -nostdin -hide_banner -loglevel error -y -init_hw_device vulkan \
	    -i "$tmp" -vf "$PL" -f rawvideo "$out/sdr_$n.yuv"
	rm -f "$tmp"
	echo "$n"
done
