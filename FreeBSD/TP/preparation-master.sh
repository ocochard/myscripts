#!/bin/sh
set -eu
EASYRSA_DIR="/usr/local/share/easy-rsa"

grep -q autoboot /boot/loader.conf || echo 'autoboot_delay="2"' >> /boot/loader.conf
grep -q CLICOLOR /etc/csh.cshrc ||  echo "setenv CLICOLOR" >> /etc/csh.cshrc
grep -q nobeep /etc/csh.cshrc || echo "set nobeep" >> /etc/csh.cshrc

echo "Installing packages"
PKG_LIST='
tmux
openvpn
mohawk
w3m
'

for PACKAGE in ${PKG_LIST}; do
  pkg info ${PACKAGE} || pkg install -y ${PACKAGE}
done

if [ -d ${EASYRSA_DIR} ]; then
  echo "Converting easy-rsa bash script to tcsh script"
  sed 's/export/setenv/;s/=/ /' ${EASYRSA_DIR}/vars > ${EASYRSA_DIR}/vars.tcsh 
  mv ${EASYRSA_DIR}/vars ${EASYRSA_DIR}/vars.bash.old
  mv ${EASYRSA_DIR}/vars.tcsh ${EASYRSA_DIR}/vars
else
  echo "ERROR: No easy-RSA installed?"
fi

[ -f preparation-server.sh ] || fetch http://dev.bsdrp.net/scripts/TP/preparation-server.sh
[ -f tunnels.sh ] || fetch http://dev.bsdrp.net/scripts/TP/tunnels.sh
echo "Check your fstab in the form:"
echo "/dev/gpt/FREEBSD        /               ufs     rw,noatime      1       1"

