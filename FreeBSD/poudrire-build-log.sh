#!/bin/sh
#
# poudrire-build-log.sh - list poudriere build times per package, sorted
#
# Scans /usr/local/poudriere/data/logs/bulk/latest-per-pkg/ and extracts
# the "build time" line from each package log, then sorts the output by
# build duration.

set -eu

LOGDIR="/usr/local/poudriere/data/logs/bulk/latest-per-pkg"

if [ ! -d "$LOGDIR" ]; then
	echo "Error: $LOGDIR does not exist" >&2
	exit 1
fi

for pkgdir in "$LOGDIR"/*/; do
	pkg=$(basename "$pkgdir")
	for verdir in "$pkgdir"*/; do
		[ -d "$verdir" ] || continue
		ver=$(basename "$verdir")
		log="${verdir}builder-default.log"
		[ -f "$log" ] || continue
		btime=$(grep "^build time:" "$log" | tail -1 | awk '{print $3}')
		[ -n "$btime" ] || continue
		printf "%s\t%s-%s\n" "$btime" "$pkg" "$ver"
	done
done | sort -r
