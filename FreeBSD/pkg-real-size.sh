#!/bin/sh
#Return size in bytes and megabytes of the package and all its deps
set -eu
total_size=0
tempfoo=$(basename $0)
tmpfile=$(mktemp /tmp/${tempfoo}.XXXXXX)

get_deps () {
	local package=$1
	if grep -q $package $tmpfile; then
		return
	fi
	echo $package >> $tmpfile
	# If multiples repo configured will get duplicates, so add a sort|uniq
	deps=$(pkg rquery %do $1 | sort | uniq)
	if [ -n "$deps" ]; then
		for i in $deps; do
			get_deps $i
		done
	fi
}

usage() {
    echo "$0 [-h] [-v] package-name" >&2;
    echo -e "\t-h: emit this message, then exit" >&2
    echo -e "\t-v: enable execution tracing" >&2
    exit $1
}

if [ $# -lt 1 ]; then
	usage
fi

while getopts "hv" arg; do
    case "$arg" in
    h)  usage 0 ;;
    v)  set -x ;;
    *)  usage 1 ;;
    esac
done
shift $(( OPTIND - 1 ))

get_deps $1
echo "List of dependencies and their size:"
for i in $(sort $tmpfile | uniq); do
	size=$(pkg rquery -r FreeBSD %sb $i | head -1)
	echo "$i : $size bytes"
	total_size=$(( total_size + size ))
done
echo "----------------------------------"
echo "TOTAL size: ${total_size} bytes (" $(units -o %0.f -t "${total_size} bytes" megabytes) " megabytes )"
rm $tmpfile
