#!/bin/sh
# FreeBSD desktop configuration script
set -eu

OLDIFS=$IFS
IFS="
"
# A usefull function (from: http://code.google.com/p/sh-die/) 
die() { echo -n "EXIT: " >&2; echo "$@" >&2; exit 1; } 

check_and_add() {
	# $1: Table of values
	# $2: Filename to patch
	for VALUE in $1; do
		grep -q ${VALUE} $2 || echo ${VALUE} >> $2
	done
}

install_pkg () {
	# $1: package name
	if ! pkg info -q ${PACKAGE}; then
		pkg install -y ${PACKAGE} || echo "Can't install ${PACKAGE}"
	fi
}


[ `id -u` -ne 0 ] && die "you need to execute this script as root"

# Boot loader
LOADER_CONF='
autoboot_delay="2"
'

check_and_add "${LOADER_CONF}" /boot/loader.conf

# system service enable/disable
sysrc sendmail_enable=NONE
sysrc kld_list="ichsmb coretemp ichwd"

service sendmail onestop

cat >>/etc/periodic.conf <<EOF
#disable some sendmail specific daily maintenance routines
daily_clean_hoststat_enable="NO"
daily_status_mail_rejects_enable="NO"
daily_status_include_submit_mailq="NO"
daily_submit_queuerun="NO"
EOF
    
CSH_CSHRC='
setenv CLICOLOR
set nobeep
'

check_and_add "${CSH_CSHRC}" /etc/csh.cshrc

SYSCTL_CONF='
vfs.usermount=1
kern.ipc.shm_allow_removed=1
'

env ASSUME_ALWAYS_YES=true pkg info

pkg update || die "Can't bootstrap pkg"

echo "Installing packages"
PKG_LIST='
ca_root_nss
vim-lite
smartmontools
panicmail
tmux
keychain
'
for PACKAGE in ${PKG_LIST}; do
	install_pkg ${PACKAGE}
done

if [ -f /usr/local/share/certs/ca-root-nss.crt ]; then
    [ ! -h /etc/ssl/cert.pem ] && ln -s /usr/local/share/certs/ca-root-nss.crt /etc/ssl/cert.pem
fi

# ports services enable
sysrc smartd_enable=YES
sysrc panicmail_enable=YES
sysrc panicmail_autosubmit=YES

check_and_add "DEVICESCAN" /usr/local/etc/smartd.conf
service smartd start || echo "Can't start smartd"

if grep -q "/usr/libexec/dma" /etc/mail/mailer.conf; then
	cp /etc/mail/mailer.conf /etc/mail/mailer.conf.bak
	cat >/etc/mail/mailer.conf <<EOF
sendmail        /usr/libexec/dma
send-mail       /usr/libexec/dma
mailq           /usr/libexec/dma
newaliases      /usr/bin/true
hoststat        /usr/bin/true
purgestat       /usr/bin/true
EOF
fi

echo "template for dma"
cat >/etc/dma/dma.conf <<EOF
SMARTHOST smtp.gmail.com
PORT 587
AUTHPATH /usr/local/etc/dma/auth.conf
SECURETRANSFER
STARTTLS
MASQUERADE your-login@gmail.com
EOF
if [ ! -f /etc/dma/auth.conf ]; then
	cat >/etc/dma/auth.conf <<EOF
your-loging|smtp.gmail.com:your-password
EOF
fi

#Need to put this in a trap:
IFS=$OLDIFS
exit 0
