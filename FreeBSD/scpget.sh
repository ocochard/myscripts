#!/bin/sh
set -eu

usage () {
	echo "Usage:"
	echo "$0 FILE DEST-DIR"
	echo "With FILE, a text file containning list of remote file path to scp get"
}

# A usefull function (from: http://code.google.com/p/sh-die/)
die() { echo -n "EXIT: " >&2; echo "$@" >&2; exit 1; }

if [ $# -ne 2 ]; then
	usage
	exit 1
fi

FILENAME=$1
DESTDIR=$2

[ -f $FILENAME ] || die "ERROR: There is no $FILENAME"
[ -d $DESTDIR ] || die "ERROR: There is no dir $DESTDIR"

backup=$IFS
IFS="
"
for file in `cat ${FILENAME}`; do
        scp dev:${file} ${DESTDIR} ||
        echo "ERROR: Can't copy ${file}"
done
IFS=$backup
