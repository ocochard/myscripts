#!/bin/sh
# List objdir libraries needed to run the bootstrap tools on this host.
obj=${1:-/usr/obj/usr/src/$(uname -m).$(uname -p)}
if [ ! -d "$obj/tmp/legacy" ]; then
	echo "$obj/tmp/legacy not found: run buildworld first" >&2
	exit 1
fi
need=$(mktemp) have=$(mktemp)
find "$obj/tmp/legacy" "$obj/tmp/usr/bin" "$obj/tmp/usr/sbin" -type f -perm +111 2>/dev/null |
    xargs readelf -V 2>/dev/null |
    awk '/vn_file:/ {for (i = 1; i < NF; i++) if ($i == "vn_file:") lib = $(i+1)} /vna_name:/ {print lib, $3}' | sort -u > "$need"
for l in $(awk '{print $1}' "$need" | sort -u); do
	p=$(ls /lib/$l /usr/lib/$l 2>/dev/null | head -1)
	[ -n "$p" ] && readelf -V "$p" | awk -v l="$l" '/vda_name:/ {print l, $NF}'
done | sort -u > "$have"
comm -23 "$need" "$have" | awk '{print $1}' | sort -u | while read l; do
	f=$(find "$obj/lib" "$obj/usr.bin" "$obj/secure/lib" "$obj/cddl/lib" "$obj/gnu/lib" \
	    -name "$l" -type f 2>/dev/null | head -1)
	echo "${f:-$l: NOT FOUND IN OBJDIR}"
	comm -23 "$need" "$have" | awk -v l="$l" '$1 == l {print "    needs", $2}'
done
rm -f "$need" "$have"
