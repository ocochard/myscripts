#!/bin/sh
# Compare the NPU tonemap with the software reference on an HDR10 clip.
# Decodes on the card, then writes three raw yuv420p10le streams:
#   ref.yuv   software zscale + tonemap (Hable, peak 1000 nits)
#   npu.yuv   ni_quadra_ai_pre with the network
#   naive.yuv no tonemap (the HDR samples as they are)
# and prints PSNR of npu and naive against ref, measured on the CROP area
# (to leave out letterbox bars). Also prints the NPU fps.
# Optional environment: START_FRAME and FRAMES select a segment (a trim
# filter: input -ss breaks the card decoder's hardware frames);
# GRADED=file.hevc (an SDR grade of the same clip, frame-aligned) adds a
# comparison of npu, ref and naive against that human-made grade.
# REF=file.yuv uses a precomputed reference (for example libplacebo output
# from make_reference_placebo.sh on naive.yuv) instead of zscale + Hable.
# Usage: eval_clip.sh clip.hevc model.nb [crop=w:h:x:y]
set -eu

FFMPEG=${FFMPEG:-$HOME/netint_ffmpeg/ffmpeg}
clip=$1 nb=$2 crop=${3:-}
TONEMAP="zscale=tin=smpte2084:min=bt2020nc:pin=bt2020:rin=tv:t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=tonemap=hable:peak=10:desat=0,zscale=t=bt709:m=bt709:r=tv,format=yuv420p10le"
DEC="-nostdin -hide_banner -y -c:v h265_ni_quadra_dec -dec 0 -xcoder-params out=hw -i $clip"
TRIM=
if [ -n "${FRAMES:-}" ]; then
	s=${START_FRAME:-0}
	TRIM="trim=start_frame=$s:end_frame=$((s + FRAMES)),setpts=PTS-STARTPTS,"
fi
quiet() { grep -v -E 'SID=|ni_dec_fme|draining|Decoder_complete' || true; }

# One value per line: the csv writer appends a separator when the stream has
# side data.
size=$(${FFMPEG%ffmpeg}ffprobe -v error -select_streams v:0 -show_entries \
    stream=width,height -of default=nw=1:nk=1 "$clip" | paste -s -d x -)
if [ -n "${REF:-}" ]; then
	ln -sf "$REF" ref.yuv
else
	sudo $FFMPEG $DEC -loglevel error -vf "${TRIM}hwdownload,format=yuv420p10le,$TONEMAP" -f rawvideo ref.yuv 2>&1 | quiet
fi
sudo $FFMPEG $DEC -loglevel error -vf "${TRIM}hwdownload,format=yuv420p10le" -f rawvideo naive.yuv 2>&1 | quiet
sudo $FFMPEG $DEC -loglevel info -vf "${TRIM}ni_quadra_ai_pre=nb=$nb,hwdownload,format=yuv420p10le" \
    -f rawvideo npu.yuv 2>&1 | grep -o 'fps=[ 0-9.]*' | tail -1
c=${crop:+crop=$crop,}
cmp_psnr() {
	printf '%s vs %s: ' $1 $2
	$FFMPEG -nostdin -hide_banner -f rawvideo -pix_fmt yuv420p10le -s "$size" -i $1.yuv \
	    -f rawvideo -pix_fmt yuv420p10le -s "$size" -i $2.yuv \
	    -lavfi "[0]${c}null[a];[1]${c}null[b];[a][b]psnr" -f null - 2>&1 |
	    grep -o 'PSNR y:.*' || echo FAILED
}
cmp_psnr npu ref
cmp_psnr naive ref
if [ -n "${GRADED:-}" ]; then
	$FFMPEG -nostdin -hide_banner -loglevel error -y -i "$GRADED" \
	    -vf "${TRIM}format=yuv420p10le" -f rawvideo graded.yuv
	for t in npu ref naive; do cmp_psnr $t graded; done
fi
