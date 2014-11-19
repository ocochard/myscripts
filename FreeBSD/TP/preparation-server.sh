#!/bin/sh
#Preparation TP version 7
set -eu

BIN_MAX=10
USER_FILE="/tmp/user.table"
EASYRSA_DIR="/usr/local/share/easy-rsa"

# A usefull function (from: http://code.google.com/p/sh-die/)
die() { echo -n "EXIT: " >&2; echo "$@" >&2; exit 1; }

### Setting hostname
sysrc hostname="concentrateur.univ-rennes1.fr"
hostname concentrateur.univ-rennes1.fr

### Regenerate a new host ssh keys
echo "## Regenerate new host SSH keys ##"
if service sshd onestatus; then
        service sshd onestop || die "Can't stop SSHd"
fi
if [ -f /ssh_host_dsa_key.pub ]; then
        rm /etc/ssh/ssh_host_* || \
          die "Can't delete existing ssh key"
fi

service sshd onestart || \
  die "Can't start SSHd for generating host key"

service sshd onestop || die "Can't stop SSHd"

### Creating Users ###
echo "## Creating users ##"
[ -f $USER_FILE ] && rm -rf $USER_FILE

for i in `jot $BIN_MAX`; do
        #Generate user table for adduser
        #name:uid:gid:class:change:expire:gecos:home_dir:shell:password
        [ ! -d /home/succursale_$i ] && \
                echo "succursale_$i::::::::/bin/csh:$i" >> $USER_FILE
done
[ -f $USER_FILE ] && adduser -f $USER_FILE

### Generating server SSL certificate and client script
#Converting bash script for tcsh:
#sed 's/export/setenv/;s/=/ /' ${EASYRSA_DIR}/vars > /usr/local/etc/easy-rsa.vars
#Converting bash script for sh:
#sed 's/\(export \)\(.*\)\(=.*\)/\2\3; \1\2/g;' vars.bash.old
if [ -d ${EASYRSA_DIR} ];then
	(cd ${EASYRSA_DIR};
        	#Convert the variable bash script to sh script
		sed 's/\(export \)\(.*\)\(=.*\)/\2\3; \1\2/g;' vars.bash.old >vars.sh
		chmod +x vars.sh
		. vars.sh
                ./clean-all
		KEY_CN="CA"; export KEY_CN
                ./pkitool --batch --initca
		KEY_CN="concentrateur"; export KEY_CN
                ./pkitool --server
                ./build-dh
                mkdir -p /usr/local/etc/openvpn
                for FILE in ca.crt dh1024.pem concentrateur.crt concentrateur.key; do
                	cp keys/${FILE} /usr/local/etc/openvpn
                done
        )
fi

### Create /root/.ssh directory
# All users SSH keys will be put in /root/.ssh/authorized_keys
mkdir -p /root/.ssh
chmod -R 600 /root/.ssh

### OpenVPN base configuration generation
mkdir -p /usr/local/etc/openvpn/ccd
cat <<EOF > /usr/local/etc/openvpn/openvpn.conf
dev tun98
ca ca.crt
cert concentrateur.crt
key concentrateur.key
dh dh1024.pem
server 192.168.254.0 255.255.255.0
server-ipv6 fc00:254::/64
ifconfig-pool-persist ipp.txt
client-config-dir ccd
push "route 172.16.254.0 255.255.255.0"
push "route-ipv6 fc00:dead:beef::/64"
verb 4
keepalive 10 120
EOF

### Users main loop
for i in `jot $BIN_MAX`; do
        [ -f /home/succursale_$i/.ssh/authorized_keys ] && \
          rm /home/succursale_$i/.ssh/*
        su -l succursale_${i} -c 'ssh-keygen -b 4096 -f /home/$USER/.ssh/id_rsa -N ""'
        cp /etc/ssh/ssh_host_rsa_key.pub /home/succursale_${i}/.ssh/cle_ssh_publique_concentrateur
        tar -cf /tmp/succursale_${i}_cles_ssh.tgz -C /home/succursale_${i}/.ssh .
        # Permit users to login as root with its SSH key
        # (used for SSH routed tunnel)
        (cd /home/succursale_${i}/.ssh;
        cat id_rsa.pub >> /root/.ssh/authorized_keys
        mv id_rsa.pub authorized_keys
        rm id_rsa
        rm cle_ssh_publique_concentrateur
        )
        if [ -d ${EASYRSA_DIR} ];then
            (cd ${EASYRSA_DIR};
		. vars.sh
		KEY_CN="succursale_$i"; export KEY_CN
		./pkitool --batch
		#Testing correct file size
		FILE_LIST="ca.crt succursale_${i}.crt succursale_${i}.key"
		for file in ${FILE_LIST}; do
		  [ -s ${EASYRSA_DIR}/keys/${file} ] || \
		    die "Error with file ${EASYRSA_DIR}/keys/${file}: Missing or empty"
		done
                tar -cf /tmp/succursale_${i}_cles_openvpn.tgz -C ${EASYRSA_DIR}/keys ca.crt succursale_${i}.crt succursale_${i}.key
            )
        echo "route 172.16.${i}.0 255.255.255.0" >> /usr/local/etc/openvpn/openvpn.conf
	echo "route-ipv6 fc00:${i}::/64" >> /usr/local/etc/openvpn/openvpn.conf
        echo "iroute 172.16.${i}.0 255.255.255.0" > /usr/local/etc/openvpn/ccd/succursale_${i}
	echo "iroute-ipv6 fc00:${i}::/64" >> /usr/local/etc/openvpn/ccd/succursale_${i}
        # Generate user OpenVPN configuration file (used by the teacher only!)
        cat <<EOF > /tmp/binome_${i}.openvpn.conf
client
proto udp
dev tun
remote 10.0.0.254
ca ca.crt
cert succursale_${i}.crt
key succursale_${i}.key
verb 4
keepalive 10 120
EOF

        fi
done

### Serveur virtuel derriere le concentrateur VPN et Tunnels GIFs
CLONED_IF_LIST="tap99"
for i in `jot $BIN_MAX`; do
	CLONED_IF_LIST="${CLONED_IF_LIST} gif${i}"
	sysrc ifconfig_gif${i}="inet 192.168.${i}.1/31 192.168.${i}.2 tunnel 10.0.0.254 10.0.0.${i} up"
	sysrc ifconfig_gif${i}_ipv6="inet6 fc00:bad:cafe:${i}::1 prefixlen 64"
done
echo "debug cloned_if_list: ${CLONED_IF_LIST}"
sysrc cloned_interfaces="${CLONED_IF_LIST}"
sysrc ifconfig_tap99="inet 172.16.254.1/24"
sysrc ifconfig_tap99_ipv6="inet6 fc00:dead:beef::1 prefixlen 64"
sysrc ifconfig_em1="inet 10.0.0.254/24"

service netif restart && \
  echo "Meet a problem for restarting/generating new interface"

### Activation du Routage
sysrc ipv6_activate_all_interfaces="YES"
sysrc gateway_enable="YES"
sysrc ipv6_gateway_enable="YES"
service routing restart && echo "Meet a problem for starting routing"

### Serveur SSH configuration
if ! grep -q "UseDNS no" /etc/ssh/sshd_config; then
        cat <<EOF >>/etc/ssh/sshd_config
#Permit to create SSH routed tunnels
PermitTunnel yes
PermitRootLogin yes
UseDNS no
LogLevel DEBUG
#Prevent user to play with the root account :-)
Match User root
        ChrootDirectory /var/empty
EOF
fi
### Serveur WWW
if [ -d /usr/local/www ]; then
        cat <<EOF > /usr/local/www/index.html
<html>
<head>
<title>Serveur Web TP/OpenVPN</title>
</head>
<body>
<br>
<p align="center"><b>Acces au serveur Web fonctionnel<b></p>
</body>
</html>
EOF
fi

if [ ! -f /usr/local/etc/mohawk.conf ]; then
	cat <<EOF > /usr/local/etc/mohawk.conf
chroot /usr/local/www
user www
mime_type { html text/html txt text/plain }
vhost default {
        rootdir /
        dirlist off
        index_names { index.html index.htm default.html }
        status_url /status
}
EOF
fi

sysrc mohawk_enable="YES"
service mohawk restart && \
  echo "Warning: Can t restart WWW server!"

sysrc sshd_enable="YES"
service sshd restart && \
  echo "Warning: Can t reload sshd"

sysrc openvpn_enable="YES"
service openvpn restart && \
  echo "Warning: Can t reload openvpn"
