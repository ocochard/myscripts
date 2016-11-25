#!/bin/sh
# stupid non-multithreaded ping
set -eu
count=2
usage () {
	echo "$0 filename"
	exit 0
}
[ $# -lt 1 ] && usage
[ -r $1 ] || usage
while read ip; do
	echo -n "$ip : "
	ping -c $count $ip > /dev/null 2>&1 && echo "reply" || echo "timeout"
done < $1
