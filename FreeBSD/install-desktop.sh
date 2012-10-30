#!/bin/sh
#This script install desktop environnement to a FreeBSD 9.1
set -eu

skip () {
# Boot loader
echo "Configuring /boot/loader.conf"
echo "#Reduce the boot menu timeout" >> /boot/loader.conf
echo 'autoboot_delay="2"' >> /boot/loader.conf
echo "#gamin process recommand to increase kern.maxfiles" >> /boot/loader.conf
echo 'kern.maxfiles="25000"' >> /boot/loader.conf
echo "#splash screen" >> /boot/loader.conf
echo 'splash_bmp_load="YES"' >> /boot/loader.conf
echo 'bitmap_load="YES"' >> /boot/loader.conf
echo 'bitmap_name="/boot/splash.bmp"' >> /boot/loader.conf
fetch -o /boot/splash.bmp http://gugus69.free.fr/images/splash.bmp

#locale

echo "Enabling UTF-8"
# Generat the login.conf.patch
cat > login.conf.patch << "EOF"
--- login.conf.orig     2012-09-24 23:39:35.000000000 +0200
+++ login.conf  2012-09-24 23:45:58.000000000 +0200
@@ -44,7 +44,9 @@
        :pseudoterminals=unlimited:\
        :priority=0:\
        :ignoretime@:\
-       :umask=022:
+       :umask=022:\
+       :charset=UTF-8:\
+       :lang=en_US.UTF-8:
 
 
 #
EOF

patch /etc/login.conf login.conf.patch
echo "Adding french language to login.conf"
echo 'french|French Users Accounts:\' >> /etc/login.conf
echo '        :charset=UTF-8:\' >> /etc/login.conf
echo '        :lang=fr_FR.UTF-8:\' >> /etc/login.conf
echo '        :tc=default:' >> /etc/login.conf
echo "Rebuilding cap database"
cap_mkdb /etc/login.conf
echo "defaultclass = french" >> /etc/adduser.conf

#/etc/rc.conf

echo "Configuring /etc/rc.conf"
echo "#Increase console resolution"
echo 'allscreens_flags="MODE_261"' >> /etc/rc.conf
echo "#Put all kernel module to load here"
echo "kld_list='ichsmb'" >> /etc/rc.conf
echo "Configuring /etc/sysctl.conf"
echo "# Disable sendmail" >> /etc/rc.conf
echo 'sendmail_enable="NONE"' >> /etc/rc.conf
echo 'sendmail_submit_enable="NO"' >> /etc/rc.conf
echo 'sendmail_outbound_enable="NO"' >> /etc/rc.conf
echo 'sendmail_msp_queue_enable="NO"' >> /etc/rc.conf

#/etc/sysctl.conf

echo "#Permit user to mount"
echo "vfs.usermount=1" >> /etc/sysctl.conf

#/etc/fstab

echo "HAL need procfs mounted"
echo "proc	/proc	procfs	rw	0	0" >> /etc/fstab
mount /proc

#.cshrc

echo "Session profile setup"
# Generate the cshrc.patch
cat > cshrc.patch << "EOF"
--- .cshrc.orig 2012-09-24 23:23:13.000000000 +0200
+++ .cshrc      2012-09-24 23:24:05.000000000 +0200
@@ -19,6 +19,7 @@
 
 setenv EDITOR  vi
 setenv PAGER   less
+setenv LESS    -x4
 setenv BLOCKSIZE       K
 
 if ($?prompt) then
@@ -28,7 +29,9 @@
        endif
        set prompt = "%n@%m:%/ %# "
        set promptchars = "%#"
-
+       set color
+       set colorcat
+       set nobeep
        set filec
        set history = 1000
        set savehist = (1000 merge)
EOF
patch /root/.cshrc cshrc.patch

echo "Bootstraping pkg"
env ASSUME_ALWAYS_YES=true pkg info
echo "Configuring my own repo"
echo "packagesite: http://dev.bsdrp.net/pkg/9.1/`uname -m`/desktop/" >  /usr/local/etc/pkg.conf
echo "Installing my packages"
pkg update
pkg install -y vim-lite
pkg install -y bsdstats
pkg install -y smartmontools
pkg install -y tmux
pkg install -y xorg
pkg install -y slim
pkg install -y slim-themes
pkg install -y xfce
pkg install -y webfonts
pkg install -y freefonts
pkg install -y cups
pkg install -y chromium
pkg install -y vlc
pkg install -y fr-libreoffice
echo 'dbus_enable="YES"' >> /etc/rc.conf
service dbus start
echo 'hald_enable="YES"' >> /etc/rc.conf
service hald start
echo 'smartd_enable="YES"' >> /etc/rc.conf
echo "DEVICESCAN" >> /usr/local/etc/smartd.conf
service smartd start
echo 'slim_enable="YES"' >> /etc/rc.conf
echo "Gamin tuning"
mkdir /usr/local/etc/gamin
echo "fsset ufs poll 10" > /usr/local/etc/gamin/gaminrc
echo "Change slim default theme to fbsd"
sed -i "" -e "/current_theme/s/default/fbsd/" /usr/local/etc/slim.conf
}

echo "Configure fr keyboard mapping for HAL:"
echo "/usr/local/etc/hal/fdi/policy/x11-input.fdi"
cat > /usr/local/etc/hal/fdi/policy/x11-input.fdi << "EOF"
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

echo "Enable shutdown/reboot/suspend for xfce"
echo "/usr/local/etc/polkit-1/localauthority/50-local.d/40-power.pkla"
cat > /usr/local/etc/polkit-1/localauthority/50-local.d/40-power.pkla << "EOF"
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

cat >> /etc/rc.conf << "EOF"
#configure a failover between Ethernet and wireless"
ifconfig_em0="up"
ifconfig_ath0="ether 00:0d:60:2f:19:4f"
wlans_ath0="wlan0"
ifconfig_wlan0="WPA"
cloned_interfaces="lagg0"
ifconfig_lagg0="laggproto failover laggport em0 laggport wlan0 DHCP"
ifconfig_lagg0_ipv6="inet6 accept_rtadv"
EOF

echo "TO DO:"
echo "Start vipw and add class french for your user"
echo "Add your user to operator and dialer group:"
echo "pw group mod operator -m <username>"
echo "pw group mod dialer -m <username>"
echo 'echo export LANG="fr_FR.UTF-8"' >> .xinitrc
echo 'echo export MM_CHARSET="UTF-8"' >> .xinitrc
echo 'echo "exec ck-launch-session startxfce4" >> .xinitrc'
