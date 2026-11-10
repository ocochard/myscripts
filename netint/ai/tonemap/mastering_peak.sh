#!/bin/sh
# Print the mastering-display peak (and MaxCLL) of each film listed on stdin,
# one path per line: from the stream side data, else from the first frame.
# Used to keep only films mastered at 1000 nits (10000000/10000 or 1000/1).
# Usage: mastering_peak.sh < paths.txt
while IFS= read -r f; do
	ml=$(ffprobe -v error -select_streams v:0 -show_entries \
	    stream_side_data=max_luminance,max_content -of default=nw=1:nk=1 "$f" </dev/null |
	    tr '\n' ' ')
	[ -z "$ml" ] && ml=$(ffprobe -v error -select_streams v:0 -read_intervals "%+#1" \
	    -show_entries frame_side_data=max_luminance,max_content \
	    -of default=nw=1:nk=1 "$f" </dev/null | head -2 | tr '\n' ' ')
	echo "$ml|$f"
done
