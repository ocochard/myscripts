#!/bin/sh
set -eu
usage () {
	echo "$0 folder-to-works string-to-replace new-string"
	echo "new-string can be null"
	exit 0
}

loop () {
	for i in ${DIR}/*; do
		if echo $i | grep -q ${SRC_STRING}; then
			if ($1); then
				mv -v "$i" `echo $i | sed -e "s/${SRC_STRING}/${DST_STRING}/"`
			else
				echo "$i -> `echo $i | sed -e \"s/${SRC_STRING}/${DST_STRING}/\"`"
			fi
		fi
	done	
}

if [ $# -lt 2 ]; then
	echo "Not enought argument"
	usage
else
	DIR=$1
	SRC_STRING=$2
	[ $# -eq 3 ] && DST_STRING=$3 || DST_STRING=""
fi
echo "Will replace filename containing $SRC_STRING by $DST_STRING in $DIR"
loop false

echo "Do you want to continue ? (y/n)"
USER_CONFIRM=""
while [ "$USER_CONFIRM" != "y" -a "$USER_CONFIRM" != "n" ]; do
	read USER_CONFIRM <&1
done
[ "$USER_CONFIRM" = "n" ] && exit 0

loop true
