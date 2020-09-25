#!/bin/sh
#Return size in bytes and megabytes of the package and all its deps
set -eu
total_size=0
tempfoo=$(basename $0)
TMPFILE=$(mktemp /tmp/${tempfoo}.XXXXXX)

# replace r="" by r="r" for a remote query
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

get_deps $1
for i in $(sort $TMPFILE | uniq); do
	size=$(pkg ${r}query %sb $i)
	total_size=$(( total_size + size ))
done
echo "size in bytes: ${total_size} bytes (" $(units -o %0.f -t "${total_size} bytes" megabytes) " megabytes )"
rm $TMPFILE
