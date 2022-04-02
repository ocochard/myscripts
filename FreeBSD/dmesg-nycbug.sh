#!/bin/sh
# Send dmesg to https://dmesgd.nycbug.org/
# Idea from https://lists.freebsd.org/pipermail/freebsd-current/2018-October/071533.html
maker=$(kenv smbios.system.maker)
product=$(kenv smbios.system.product)
case ${maker} in
	*NOT-FILLED*|""|'                                ')
		maker=$(kenv smbios.planar.maker) ;;
	*) ;;
esac

case ${product} in
	*NOT-FILLED*|""|'                                ')
		product=$(kenv smbios.planar.product) ;;
	*) ;;
esac

curl -v -d "nickname=$USER" -d "email=$USER@$(hostname)" -d \
"description=FreeBSD/$(uname -m) on ${maker} ${product}" -d \
"do=addd" --data-urlencode 'dmesg@/var/run/dmesg.boot' \
http://dmesgd.nycbug.org/index.cgi
