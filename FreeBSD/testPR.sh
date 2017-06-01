#!/bin/sh
set -eu

PORTDIR="/usr/ports"
PATCH="patch.txt"
ID=""
TOPATCH=""
PORTNAME=""
SVNCMD="svnlite"

### Functions

# A usefull function (from: http://code.google.com/p/sh-die/)
die() { echo -n "EXIT: " >&2; echo "$@" >&2; exit 1; }

usage () {
	echo "$0 PR-attachement-id"
	exit 0
}

### main

if [ $# -lt 1 ]; then
        echo "Not enought argument"
        usage
fi

ID=$1
[ -f ${PORTDIR}/${PATCH} ] && rm  ${PORTDIR}/${PATCH}
echo "Downloading patch..."
fetch -q -o ${PORTDIR}/${PATCH} "https://bz-attachments.freebsd.org/attachment.cgi?id=${ID}"
grep -q 'DOCTYPE html' ${PORTDIR}/${PATCH} && die "Seems not a good patch (check ${PORTDIR}/${PATCH})"
TOPATCH=$(grep -m 1 '\-\-\-' ${PORTDIR}/${PATCH} | cut -d ' ' -f 2)
echo ${TOPATCH} | grep -q '/' || die "Patch didn't include full path"
PORTNAME=$(echo $TOPATCH | cut -d '/' -f 1,2)
[ -d ${PORTDIR}/${PORTNAME} ] || die "Can't found ${PORTDIR}/${PORTNAME}"
# benchmarks/stress-ng/Makefile
/usr/bin/which -s svn && SVNCMD="svn"
echo "Updating ${PORTDIR} and cleaning(reverting) ${PORTDIR}/${PORTNAME}..."
${SVNCMD} up -q ${PORTDIR}
${SVNCMD} revert -q -R ${PORTDIR}/${PORTNAME}
echo "Applying patch..."
patch -s -C -E -p 0 -d ${PORTDIR} < ${PORTDIR}/${PATCH} || die "Can't apply patch correctly"
patch -s -E -p 0 -d ${PORTDIR} < ${PORTDIR}/${PATCH}
#echo "Portlint"
#/usr/bin/which -s portlint && portlint -A ${PORTNAME}
echo "poudriere testport -j 110amd64 -o ${PORTNAME}"
poudriere testport -j 110amd64 -o ${PORTNAME}
echo "poudriere testport -j 103i386 -o ${PORTNAME}"
echo "done"

