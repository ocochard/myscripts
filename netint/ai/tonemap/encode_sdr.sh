#!/bin/sh
# HDR10 to SDR on the Quadra, end to end: hardware decode (scaled to fit
# 1920x1080 by the decoder), letterbox/pillarbox pad to 1920x1080, tonemap
# network on the NPU (ni_quadra_ai_pre, int16 1920x1080 model), 10-bit to
# 8-bit on the 2D engine, hardware H.264 encode tagged BT.709.
# The HDR side data (mastering display, content light level, Dolby Vision)
# is deleted right after decoding: otherwise the encoder writes it as SEI
# 137/144 and the MP4 muxer as mdcv/clli, and players treat the SDR as HDR.
# Usage: encode_sdr.sh in.mkv out.mp4 model.nb [bitrate]
set -eu

FFMPEG=${FFMPEG:-$HOME/netint_ffmpeg/ffmpeg}
in=$1 out=$2 nb=$3 rate=${4:-8000000}
# One value per line: the csv writer appends a separator when the stream
# has side data (3840x1632x).
set -- $(${FFMPEG%ffmpeg}ffprobe -v error -select_streams v:0 \
    -show_entries stream=width,height -of default=nw=1:nk=1 "$in")
w=$1 h=$2
# Fit inside 1920x1080, even sizes, centred.
if [ $((w * 1080)) -ge $((h * 1920)) ]; then
	sw=1920 sh=$(( (1920 * h / w + 1) / 2 * 2 ))
else
	sh=1080 sw=$(( (1080 * w / h + 1) / 2 * 2 ))
fi
px=$(( (1920 - sw) / 4 * 2 )) py=$(( (1080 - sh) / 4 * 2 ))
STRIP="sidedata=mode=delete:type=MASTERING_DISPLAY_METADATA,sidedata=mode=delete:type=CONTENT_LIGHT_LEVEL,sidedata=mode=delete:type=DOVI_RPU_BUFFER,sidedata=mode=delete:type=DOVI_METADATA"
sudo $FFMPEG -nostdin -hide_banner -y \
    -c:v h265_ni_quadra_dec -dec 0 -xcoder-params "out=hw:scale0=${sw}x${sh}" -i "$in" \
    -map 0:v:0 -map_chapters -1 \
    -vf "$STRIP,ni_quadra_pad=1920:1080:$px:$py,ni_quadra_ai_pre=nb=$nb,ni_quadra_scale=format=yuv420p,setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709" \
    -c:v h264_ni_quadra_enc -enc 0 \
    -xcoder-params "RcEnable=1:bitrate=$rate:colorPri=1:colorTrc=1:colorSpc=1" "$out"
