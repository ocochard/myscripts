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
kern.maxfiles="2500"
splash_bmp_load="YES"
bitmap_load="YES"
bitmap_name="/boot/splash.bmp"
'

check_and_add "${LOADER_CONF}" /boot/loader.conf

if [ ! -f /boot/splash.bmp ]; then
    fetch -o /boot/splash.bmp http://gugus69.free.fr/images/splash.bmp || echo "Can't download a splash screen"
fi

#Add french UTF-8locale

if ! grep -q french /etc/login.conf; then
	LOGIN_CONF='
french|French Users Accounts:\
	:charset=UTF-8:\
	:lang=fr_FR.UTF-8:\
	:tc=default:
'
	for line in $LOGIN_CONF; do
		echo $line >>/etc/login.conf
	done

	echo "Rebuilding cap database"
	cap_mkdb /etc/login.conf || die "ERROR during rebuild cap database"
fi

check_and_add "LANG=fr_FR.UTF-8; export LANG" /etc/profile
check_and_add "CHARSET=UTF-8; export CHARSET" /etc/profile
check_and_add "GDM_LANG=fr_FR.UTF-8; export GDM_LANG" /etc/profile
check_and_add "defaultclass = french" /etc/adduser.conf

#/etc/rc.conf
sysrc sendmail_enable=NONE
sysrc sendmail_submit_enable=NO
sysrc sendmail_outbound_enable=NO
sysrc sendmail_msp_queue_enable=NO
sysrc kld_list="ichsmb fuse sem coretemp ichwd acpi_video"

CSH_CSHRC='
setenv CLICOLOR
set nobeep
'

check_and_add "${CSH_CSHRC}" /etc/csh.cshrc

SYSCTL_CONF='
vfs.usermount=1
kern.ipc.shm_allow_removed=1
'

check_and_add "${SYSCTL_CONF}" /etc/sysctl.conf

FSTAB='
fdesc		/dev/fd		fdescfs	rw	0	0
proc		/proc		procfs	rw	0	0
'
check_and_add "${FSTAB}" /etc/fstab

env ASSUME_ALWAYS_YES=true pkg info

pkg update || die "Can't bootstrap pkg"

echo "Installing packages"
#fusefs-exfat
#fusefs-ntfs
#automount
#corkscrew 
PKG_LIST='
ca_root_nss
vim-lite
smartmontools
panicmail
tmux
openvpn
keychain
xorg
slim
slim-themes
xfce
ristretto
galculator
webfonts
freefonts
inconsolata-ttf
dejavu
liberation-fonts-ttf
proggy_fonts
proggy_fonts-ttf
ubuntu-font
urwfonts
urwfonts-ttf
terminus-font
cups
firefox-i18n
vlc
fr-libreoffice
'
for PACKAGE in ${PKG_LIST}; do
	install_pkg ${PACKAGE}
done

if [ -f /usr/local/share/certs/ca-root-nss.crt ];
    [ ! -h /etc/ssl/cert.pem ] && ln -s /usr/local/share/certs/ca-root-nss.crt /etc/ssl/cert.pem
fi

sysctl -n dev.agp.0.%desc | grep -q Intel && install_pkg xf86-video-intel

sysrc dbus_enable=YES
sysrc smartd_enable=YES
sysrc slim_enable=YES
sysrc panicmail_enable=YES
sysrc panicmail_autosubmit=YES

service dbus start || echo "Can't start dbus"

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

echo "Gamin tuning"
[ -d /usr/local/etc/gamin ] || mkdir /usr/local/etc/gamin
check_and_add "fsset ufs poll 10" /usr/local/etc/gamin/gaminrc

echo "template for dma"
if [ ! -f /etc/dma/dma.conf ]; then
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

echo "Change slim default theme to fbsd"
if [ -f /usr/local/etc/slim.conf ]; then
	sed -i "" -e "/current_theme/s/default/fbsd/" /usr/local/etc/slim.conf || echo "slim allready configured?"
fi

if [ ! -f /usr/share/syscons/keymaps/fr-dvorak-bepo.kbd ]; then
	fetch http://download.tuxfamily.org/dvorak/devel/fr-dvorak-bepo-kbdmap-1.0rc2.tgz || echo "Can't fetch bepo layout"
	tar zxvf fr-dvorak-bepo-kbdmap-1.0rc2.tgz || echo "Can't extract bepo layout"
	cp fr-dvorak-bepo-kbdmap-1.0rc2/fr-dvorak-bepo.kbd /usr/share/syscons/keymaps/ || echo "Can't install bepo layout"
	echo 'keymap="fr-dvorak-bepo"' >> /etc/rc.conf
fi

if ! grep -q 'Option "XkbLayout" "fr"' /etc/X11/xorg.conf; then
	cat >>/etc/X11/xorg.conf <<EOF
Section "InputDevice"
	Identifier "Generic Keyboard"
	Driver "kbd"
	Option "XkbLayout" "fr"
	Option "XkbVariant" "bepo"
EndSection
EOF

fi

if [ -d /usr/local/etc/hal ]; then
	if [ ! -f /usr/local/etc/hal/fdi/policy/x11-input.fdi ]; then
		echo "Configure fr keyboard mapping for HAL"
		cat > /usr/local/etc/hal/fdi/policy/x11-input.fdi << EOF
<?xml version="1.0" encoding="ISO-8859-1"?>
<deviceinfo version="0.2">
  <device>
    <match key="info.capabilities" contains="input.keyboard">
      <merge key="input.xkb.Layout" type="string">fr</merge>
      <merge key="input.xkb.Variant" type="string">latin9</merge>
      <merge key="input.xkb.Option" type="string">compose:rwin</merge>
    </match>
  </device>
</deviceinfo>
EOF
	fi
fi
if [ ! -f /usr/local/etc/polkit-1/localauthority/50-local.d/40-power.pkla ]; then
	echo "Enable shutdown/reboot/suspend for xfce"
	echo "/usr/local/etc/polkit-1/localauthority/50-local.d/40-power.pkla"
	cat > /usr/local/etc/polkit-1/localauthority/50-local.d/40-power.pkla << EOF
[Restart]
Identity=unix-group:operator
Action=org.freedesktop.consolekit.system.restart
ResultAny=yes
ResultInactive=yes
ResultActive=yes

[Shutdown]
Identity=unix-group:operator
Action=org.freedesktop.consolekit.system.stop
ResultAny=yes
ResultInactive=yes
ResultActive=yes

[Suspend]
Identity=unix-group:operator
Action=org.freedesktop.upower.suspend
ResultAny=yes
ResultInactive=yes
ResultActive=yes
EOF

fi

#Cool background picture: http://gugus69.free.fr/freebsd/FreeBSD_paefchen_1920x1200.jpg

echo "TO DO:"
echo "Configuring ssmtp: /usr/local/etc/ssmtp/ssmtp.conf"
echo "Start vipw and add class french for your user"
echo "Add your user to operator and dialer group:"
echo "pw group mod operator -m <username>"
echo "pw group mod dialer -m <username>"
echo 'echo export LANG="fr_FR.UTF-8" >> ~/.xinitrc'
echo 'echo export MM_CHARSET="UTF-8" >> ~/.xinitrc'
echo 'echo xset m 5 1 >> ~/.xinitrc'
echo 'echo "exec ck-launch-session startxfce4" >> ~/.xinitrc'
echo 'fetch http://gugus69.free.fr/freebsd/FreeBSD_paefchen_1920x1200.jpg'

echo "FreeBSD configured as a desktop: Done!"
#Need to put this in a trap:
IFS=$OLDIFS
exit 0
