#!/bin/sh
# One line per film under $FILMS: transfer|codec|WxH|mastering max nits|MaxCLL|path
find "${FILMS:?set FILMS to the film library root}" -type f \( -iname "*2160p*" -o -iname "*hdr*" -o -iname "*uhd*" -o -iname "*4k*" \) \( -iname "*.mkv" -o -iname "*.mp4" -o -iname "*.ts" \) |
while IFS= read -r f; do
	r=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,width,height,color_transfer:stream_side_data=max_luminance,max_content -of default=nw=1 "$f" </dev/null |
	    awk -F= "{v[\$1]=\$2} END{print v[\"color_transfer\"]\"|\"v[\"codec_name\"]\"|\"v[\"width\"]\"x\"v[\"height\"]\"|\"v[\"max_luminance\"]\"|\"v[\"max_content\"]}")
	echo "$r|$f"
done > ~/hdr_probe.txt
echo DONE >> ~/hdr_probe.txt
