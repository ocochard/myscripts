#!/bin/sh
#Return size in bytes and megabytes of the package and all its deps
set -eu
total_size=0
tempfoo=$(basename $0)
TMPFILE=$(mktemp /tmp/${tempfoo}.XXXXXX)
r=""

get_deps () {
	empty=$(pkg ${r}query %do $1)
	echo $1 >> $TMPFILE
	if [ -n "$empty" ]; then
		for i in $(pkg ${r}query %do $1); do
			get_deps $i
		done
	fi
}

usage() {
    echo "$0 [-r] [-h] [-v] package-name" >&2;
    echo -e "\t-r: use remote pkg repository" >&2
    echo -e "\t-h: emit this message, then exit" >&2
    echo -e "\t-v: enable execution tracing" >&2
    exit $1
}

while getopts "hrv" arg; do
    case "$arg" in
    h)  usage 0 ;;
    r)  r="r" ;;
    v)  set -x ;;
    *)  usage 1 ;;
    esac
done
shift $(( OPTIND - 1 ))

get_deps $1
echo "List of dependencies and their size:"
for i in $(sort $TMPFILE | uniq); do
	size=$(pkg ${r}query %sb $i | head -1)
	echo "$i : $size bytes"
	total_size=$(( total_size + size ))
done
echo "----------------------------------"
echo "TOTAL size: ${total_size} bytes (" $(units -o %0.f -t "${total_size} bytes" megabytes) " megabytes )"
rm $TMPFILE
