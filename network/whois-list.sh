#!/bin/sh
# Retreive whois information from a list of IP addresses
set -eu
usage () {
	echo "$0 filename"
	exit 0
}
[ $# -lt 1 ] && usage
[ -r $1 ] || usage

vardir="/tmp/whois"

[ -d ${vardir} ] || mkdir -p ${vardir}

echo "ip; descr; country; AS"
while read ip; do
	echo -n "$ip;"
	[ -f ${vardir}/$ip ] || whois $ip > ${vardir}/$ip
	for desc in `grep -i 'descr:\|owner:\|orgname:' ${vardir}/$ip | tr -s ' ' | cut -d : -f 2 | tr -d ''`; do
		echo -n "$desc "
	done
	country=`grep -m 1 -i 'country:' ${vardir}/$ip | tr -s ' ' | cut -d : -f 2 | tr -d ''`
	echo -n "; ${country}"
	as=`grep -m 1 -i 'origin' ${vardir}/$ip | tr -s ' ' | cut -d : -f 2 | tr -d ''`
	echo -n "; ${as}"
	echo ""
done < $1
