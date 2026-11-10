#!/bin/sh
# Side-by-side comparison images of the tonemap filters for one frame.
# Input: DIR holding raw 1920x1080 yuv420p10le frames named <kind>_<N>.yuv:
#   hdr (the HDR10 samples), placebo (libplacebo reference), colorist (the
#   human SDR grade), and one file per filter (FILTERS: exactly three,
#   default w48 w32 w48u8).
# Output: OUT/compare_<N>.png, a 3x2 grid (top: no tonemap, libplacebo,
# colorist; bottom: the filters), and OUT/errors_<N>.png, the luma
# difference of each filter from libplacebo, amplified 8 times.
# Needs an FFmpeg with drawtext (libfreetype).
# Usage: make_compare.sh DIR OUT N...
set -eu

FONT=${FONT:-/usr/local/share/fonts/dejavu/DejaVuSans.ttf}
FILTERS=${FILTERS:-w48 w32 w48u8}
dir=$1 out=$2
shift 2
mkdir -p "$out"
label() {
	case $1 in
	hdr) echo "no tonemap (PQ shown as SDR)" ;;
	placebo) echo "libplacebo BT.2390 (target)" ;;
	colorist) echo "colorist SDR grade (Netflix)" ;;
	w48) echo "NPU width 48 int16 (27 fps)" ;;
	w32) echo "NPU width 32 int16 (37 fps)" ;;
	w48u8) echo "NPU width 48 uint8 inside (40 fps)" ;;
	*) echo "$1" ;;
	esac
}
in() { echo "-f rawvideo -pix_fmt yuv420p10le -s 1920x1080 -i $dir/$1_$2.yuv"; }
# One panel: 640x360 RGB with its label; HDR samples keep the BT.2020 matrix.
panel() {
	m=bt709
	[ "$2" = hdr ] && m=bt2020
	echo "[$1]scale=640:360:in_color_matrix=$m:out_range=pc,format=rgb24,drawtext=fontfile=$FONT:text='$(label $2)':x=8:y=8:fontsize=20:fontcolor=white:box=1:boxcolor=black@0.6:boxborderw=4[p$1]"
}
for n in "$@"; do
	set -- hdr placebo colorist $FILTERS
	ins= fc= k=0
	for kind in "$@"; do
		ins="$ins $(in $kind $n)"
		fc="$fc$(panel $k $kind);"
		k=$((k + 1))
	done
	ffmpeg -nostdin -hide_banner -loglevel error -y $ins -filter_complex \
	    "${fc}[p0][p1][p2][p3][p4][p5]xstack=inputs=6:layout=0_0|w0_0|w0+w1_0|0_h0|w0_h0|w0+w1_h0" \
	    -frames:v 1 "$out/compare_$n.png"
	ins="$(in placebo $n)" fc="[0]split=3[r1][r2][r3];" k=1
	for f in $FILTERS; do
		ins="$ins $(in $f $n)"
		fc="$fc[$k][r$k]blend=all_mode=difference,extractplanes=y,lut=val*8,scale=640:360,format=rgb24,drawtext=fontfile=$FONT:text='|$(label $f) - libplacebo| x8':x=8:y=8:fontsize=18:fontcolor=white:box=1:boxcolor=black@0.6:boxborderw=4[e$k];"
		k=$((k + 1))
	done
	ffmpeg -nostdin -hide_banner -loglevel error -y $ins -filter_complex \
	    "${fc}[e1][e2][e3]hstack=inputs=3" \
	    -frames:v 1 "$out/errors_$n.png"
done
