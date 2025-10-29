#!/bin/sh
# Send dmesg to https://dmesgd.nycbug.org/
# Idea from https://lists.freebsd.org/pipermail/freebsd-current/2018-October/071533.html
maker=$(kenv smbios.system.maker)
product=$(kenv smbios.system.product)
family=$(kenv smbios.system.family)
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

if [ "$USER" = "olivier" ]; then
	email="$USER@FreeBSD.org"
else
	email="$USER@$(hostname)"
fi
description="FreeBSD $(uname -r)/$(uname -m) on ${maker} ${family} ${product}"

echo "USER = $USER"
echo "email = $email"
echo "description= ${description}"

# clean up /var/run/dmesg.boot from previous boot entries"
awk '/---<<BOOT>>---/ { content = $0; next } { content = content "\n" $0 } END { if (content) print content }' /var/run/dmesg.boot > /tmp/dmesg.boot
if [ "$(grep -c '<<BOOT>>' /tmp/dmesg.boot)" -gt 1 ]; then
  echo "Too many <<BOOT>> in /tmp/dmesg.boot"
  exit 1
fi

echo "Do you confirm those auto-set variables? (y/n)"
user_confirm=""
while [ "${user_confirm}" != "y" -a "${user_confirm}" != "n" ]; do
	read user_confirm <&1
done
[ "${user_confirm}" = "n" ] && exit 0

curl -v -d "nickname=$USER" -d "email=$email" -d \
"description=$description" -d \
"do=addd" --data-urlencode 'dmesg@/tmp/dmesg.boot' \
http://dmesgd.nycbug.org/index.cgi
