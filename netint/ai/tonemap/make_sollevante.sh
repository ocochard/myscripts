#!/bin/sh
# Make 1080p test clips from Netflix Open Content "Sol Levante" (ProRes
# masters): the HDR10 grade as a delivery-like HEVC Main 10 file for the card,
# and the SDR grade (BT.709, colorist) as the human-made reference.
# Scaling stays in each grade's own transfer domain (no conversion).
# The masters carry no mastering-display or MaxCLL metadata: none is invented.
# Usage: make_sollevante.sh HDR.mov SDR.mov OUTDIR
set -eu

hdr=$1 sdr=$2 out=$3
mkdir -p "$out"
ffmpeg -nostdin -hide_banner -loglevel error -y -i "$hdr" -map 0:v:0 \
    -vf "scale=1920:1080:flags=spline,format=yuv420p10le" \
    -c:v libx265 -preset medium -crf 10 \
    -x265-params "colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:range=limited" \
    "$out/sollevante_1080p_hdr10.hevc"
ffmpeg -nostdin -hide_banner -loglevel error -y -i "$sdr" -map 0:v:0 \
    -vf "scale=1920:1080:flags=spline,format=yuv420p10le" \
    -c:v libx265 -preset medium -crf 10 \
    -x265-params "colorprim=bt709:transfer=bt709:colormatrix=bt709:range=limited" \
    "$out/sollevante_1080p_sdr_graded.hevc"
