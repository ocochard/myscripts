#!/bin/sh
# Make training pairs for the tonemap network from single-frame HDR10 files
# (from cut_keyframes.sh): the frame downscaled in the PQ domain (the HDR
# input) and the same frame tonemapped to SDR BT.709 by zscale + tonemap
# (the target). Both raw yuv420p10le, limited range.
# Usage: make_reference.sh outdir frame.hevc...
# Needs an FFmpeg with libzimg (FFMPEG=... to override). WIDTH defaults to
# 960: the network works per pixel, so the size does not matter.
set -eu

FFMPEG=${FFMPEG:-$HOME/netint_ffmpeg/ffmpeg}
WIDTH=${WIDTH:-960}
# Fixed curve for every film: Hable, peak 1000 nits (10 x npl 100).
# Only films mastered at 1000 nits are used. Input tags are pinned (HDR10).
TONEMAP="zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=tonemap=hable:peak=10:desat=0,zscale=t=bt709:m=bt709:r=tv,format=yuv420p10le"

out=$1
shift
mkdir -p "$out"
for f in "$@"; do
	n=$(basename "$f" .hevc)
	$FFMPEG -nostdin -hide_banner -loglevel error -y -i "$f" \
	    -filter_complex "[0:v:0]zscale=w=${WIDTH}:h=-2:f=spline36:tin=smpte2084:min=bt2020nc:pin=bt2020:rin=tv,format=yuv420p10le,split[h][s];[s]${TONEMAP}[d]" \
	    -map '[h]' -frames:v 1 -f rawvideo "$out/hdr_$n.yuv" \
	    -map '[d]' -frames:v 1 -f rawvideo "$out/sdr_$n.yuv"
	echo "$n"
done
