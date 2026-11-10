#!/bin/sh
# Make the 1080p HDR10 test clip from a 2160p HDR10 film on quadra-host:
# 10 s from minute 30, scaled in the PQ domain to 1920x816 (2.39:1),
# letterboxed to 1920x1080, encoded on the Quadra as HEVC Main 10 with
# BT.2020/PQ color tags. PSNR is then measured on crop=1920:816:0:132.
# Usage: make_eh_clip.sh film.mkv out.hevc
set -eu
FFMPEG=${FFMPEG:-$HOME/netint_ffmpeg/ffmpeg}
sudo $FFMPEG -nostdin -hide_banner -loglevel error -y -ss 1800 -t 10 -i "$1" \
    -map 0:v:0 -vf "zscale=w=1920:h=816:f=spline36:tin=smpte2084:min=bt2020nc:pin=bt2020:rin=tv,format=yuv420p10le,pad=1920:1080:0:132:black" \
    -c:v h265_ni_quadra_enc \
    -xcoder-params "profile=2:RcEnable=1:bitrate=20000000:colorPri=9:colorTrc=16:colorSpc=9" "$2"
