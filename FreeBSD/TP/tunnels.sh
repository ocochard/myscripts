#!/bin/sh
set -eu
WAN_NET4="192.168"
WAN_NET6="fc00:bad:cafe"
LAN_NET4="172.16"
LAN_NET6="fc00"
OPENVPN_IP="192.168.254.2"
BIN_MAX=10
if [ ! $(whoami) = "root" ]; then
    echo "This script need to be started as root"
    return 1
fi
echo "Do not exit this script!"
while true; do
    for bin in `jot ${BIN_MAX}`;do
        if ifconfig gif${bin} > /dev/null 2>&1; then
            if ping -t 1 -c 2 ${WAN_NET4}.${bin}.2 > /dev/null 2>&1;then
		#Need to test if route allready installed
		if route get ${LAN_NET4}.${bin}.0/24 | grep -q 'interface: tun98'; then
		    echo "Adding GIF routes for binome ${bin}"
		    route del ${LAN_NET4}.${bin}.0/24 > /dev/null 2>&1 || echo "Warning: Can't delete ${LAN_NET4}.${bin}.0/24"
		    route del -inet6 ${LAN_NET6}:${bin}::0 -prefixlen 64 > /dev/null 2>&1 || echo "Warning: Can't delete ${LAN_NET6}:${bin}::0"
                    route add ${LAN_NET4}.${bin}.0/24 ${WAN_NET4}.${bin}.2 > /dev/null 2>&1 || echo "Warning: Can't add ${LAN_NET4}.${bin}.0/24 ${WAN_NET4}.${bin}.2"
                    route add -inet6 ${LAN_NET6}:${bin}::0 -prefixlen 64 ${WAN_NET6}:${bin}::2 > /dev/null 2>&1 || echo "Warning: Can't add ${LAN_NET6}:${bin}::0 ${WAN_NET6}:${bin}::2"
		fi
            else
                if route get ${LAN_NET4}.${bin}.0/24 | grep -q "interface: gif${bin}"; then
                    echo "Restoring openvpn route for binome ${bin}"
		    route del ${LAN_NET4}.${bin}.0/24 > /dev/null 2>&1 || echo "Warning: Can't delete ${LAN_NET4}.${bin}.0/24"
                    route del -inet6 ${LAN_NET6}:${bin}::0 -prefixlen 64 > /dev/null 2>&1 || echo  "Warning: Can't delete ${LAN_NET6}:${bin}::0"
                    route add ${LAN_NET4}.${bin}.0/24 ${OPENVPN_IP} > /dev/null 2>&1 || echo  "Warning: Can't add ${LAN_NET4}.${bin}.0/24 ${OPENVPN_IP}"
		    route add -inet6 ${LAN_NET6}:${bin}::0 -prefixlen 64 -interface tun98  > /dev/null 2>&1 || echo  "Warning: Can't add  ${LAN_NET6}:${bin}::0 -interface tun98"
                fi
            fi # if ping remote gif
        fi # if ifconfig gif
    done #for
done #While true
