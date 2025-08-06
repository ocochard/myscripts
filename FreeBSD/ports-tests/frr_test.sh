#!/bin/sh
# FRR regression lab using empty vnet jails
# https://bsdrp.net/documentation/examples/simple_bgp-rip-ospf_lab
#
set -eu

SUDO=${SUDO:-sudo}

cat > /tmp/topo.txt <<EOF
******************************************************************************
*                 net/frr regression lab using vnet jails                    *
******************************************************************************

 192.168.10.1/24
 2001:db8:10::1/64
  lo110
    |
  --------                          --------                         --------
  | frr1 |                          | frr2 |                          | frr3 |
  |      | .1 (192.168.12.0/24)  .2 |      |                          |      |
  | BGP  |--epair112a<-->epair112b--| BGP  | .2 (192.168.23.0/24)  .3 |      |
  --------                          | RIP  |--epair123a<-->epair123b--| RIP  |
                                    --------                          |      |
                                                                      |      |
  --------                          --------                          |      |
  | frr5 |                          | frr4 |                          |      |
  |      |                          |      | .4 (192.168.34.0/24)  .3 |      |
  |      | .5 (192.168.45.0/24) .4  | OSPF |--epair134b<-->epair134a--| OSPF |
  | ISIS |--epair145b<-->epair145a--| ISIS |                          --------
  |      |                          --------
  |      |
  |      |                          --------                          --------
  |      |                          | frr6 |                          | frr7 |
  |      | .5 (192.168.56.0/24) .6  |      |                          |      |
  |BABEL |--epair156a<-->epair156b--|BABEL | .6 (192.168.67.0/24)  .7 |      |
  --------                          |STATIC|--epair167a<-->epair167b--|STATIC|
                                    --------                          --------
                                                                         |
                                                                       lo170
                                                                192.168.70.7/24
                                                              2001:db8:70::7/64

                      ****** Expected results *******
# jexec frr1 netstat -rn | grep -v '^fe80'
Routing tables

Internet:
Destination        Gateway            Flags     Netif Expire
192.168.10.1       link#2             UH        lo110
192.168.12.0/24    link#3             U      epair112
192.168.12.1       link#3             UHS         lo0
192.168.34.0/24    192.168.12.2       UG1    epair112
192.168.45.0/24    192.168.12.2       UG1    epair112
192.168.56.0/24    192.168.12.2       UG1    epair112
192.168.67.0/24    192.168.12.2       UG1    epair112
192.168.70.0/24    192.168.12.2       UG1    epair112

Internet6:
Destination        Gateway                          Flags     Netif Expire
::1                link#2                           UHS         lo0
2001:db8:10::/64   link#2                           U         lo110
2001:db8:10::1     link#2                           UHS         lo0
2001:db8:12::/64   link#3                           U      epair112
2001:db8:12::1     link#3                           UHS         lo0
2001:db8:34::/64   fe80::4:c1ff:fe7a:ef0b%epair112a UG1    epair112

# jexec frr1 traceroute -ns 192.168.10.1 192.168.70.7
traceroute to 192.168.70.7 (192.168.70.7) from 192.168.10.1, 64 hops max, 40 byte packets
 1  192.168.12.2  0.044 ms  0.017 ms  0.013 ms
 2  192.168.23.3  0.020 ms  0.016 ms  0.015 ms
 3  192.168.34.4  0.022 ms  0.018 ms  0.017 ms
 4  192.168.45.5  0.026 ms  0.021 ms  0.020 ms
 5  192.168.56.6  0.028 ms  0.023 ms  0.023 ms
 6  192.168.70.7  0.032 ms  0.027 ms  0.025 ms

EOF

# Routers configuration
frr1_ifa=lo110
frr1_ifa_p=""
frr1_ifb=epair112
frr1_ifb_p=a
frr1_daemons="mgmtd zebra bgpd bfdd"
${SUDO} mkdir -p /var/run/frr/frr1
${SUDO} tee /var/run/frr/frr1/ipsec.conf <<EOF
flush ;
add 192.168.12.1 192.168.12.2 tcp 0x1000 -A tcp-md5 "abigpassword" ;
add 192.168.12.2 192.168.12.1 tcp 0x1001 -A tcp-md5 "abigpassword" ;
add -6 2001:db8:12::1 2001:db8:12::2 tcp 0x1002 -A tcp-md5 "abigpassword" ;
add -6 2001:db8:12::2 2001:db8:12::1 tcp 0x1003 -A tcp-md5 "abigpassword" ;
EOF
${SUDO} tee /var/run/frr/frr1/frr.conf <<EOF
log file /var/run/frr/frr1/frr.log
!
interface lo110
 ip address 192.168.10.1/24
 ipv6 address 2001:db8:10::1/64
!
interface epair112a
 ip address 192.168.12.1/24
 ipv6 address 2001:db8:12::1/64
!
router bgp 12
 bgp router-id 192.168.10.1
 neighbor 192.168.12.2 remote-as 12
 neighbor 192.168.12.2 bfd
 neighbor 192.168.12.2 password abigpassword
 neighbor 2001:db8:12::2 remote-as 12
 neighbor 2001:db8:12::2 bfd
 neighbor 2001:db8:12::2 password abigpassword
 !
 address-family ipv4 unicast
  network 192.168.10.0/24
  neighbor 192.168.12.2 soft-reconfiguration inbound
  no neighbor 2001:db8:12::2 activate
 exit-address-family
 !
 address-family ipv6 unicast
  network 2001:db8:10::/64
  neighbor 2001:db8:12::2 activate
  neighbor 2001:db8:12::2 soft-reconfiguration inbound
 exit-address-family
!
bfd
 peer 2001:db8:12::2 local-address 2001:db8:12::1
  no shutdown
 !
 peer 192.168.12.2
  no shutdown
 !
!
EOF

frr2_ifa=epair112
frr2_ifa_p=b
frr2_ifb=epair123
frr2_ifb_p=a
frr2_daemons="mgmtd zebra bgpd bfdd ripd ripngd"
${SUDO} mkdir -p /var/run/frr/frr2
${SUDO} tee /var/run/frr/frr2/ipsec.conf <<EOF
flush ;
add 192.168.12.2 192.168.12.1 tcp 0x1000 -A tcp-md5 "abigpassword" ;
add 192.168.12.1 192.168.12.2 tcp 0x1001 -A tcp-md5 "abigpassword" ;
add -6 2001:db8:12::2 2001:db8:12::1 tcp 0x1002 -A tcp-md5 "abigpassword" ;
add -6 2001:db8:12::1 2001:db8:12::2 tcp 0x1003 -A tcp-md5 "abigpassword" ;
EOF
${SUDO} tee /var/run/frr/frr2/frr.conf <<EOF
log file /var/run/frr/frr2/frr.log
!
key chain rippass
 key 1
  key-string rippassword
!
interface epair112b
 ip address 192.168.12.2/24
 ipv6 address 2001:db8:12::2/64
!
interface epair123a
 ip address 192.168.23.2/24
 ip rip authentication key-chain rippass
 ip rip authentication mode md5
 ipv6 address 2001:db8:23::2/64
!
router rip
 network epair123a
 redistribute bgp
 redistribute connected
 version 2
!
router ripng
 network epair123a
 redistribute bgp
 redistribute connected
!
router bgp 12
 bgp router-id 192.168.10.2
 neighbor 192.168.12.1 remote-as 12
 neighbor 192.168.12.1 bfd
 neighbor 192.168.12.1 password abigpassword
 neighbor 2001:db8:12::1 remote-as 12
 neighbor 2001:db8:12::1 bfd
 neighbor 2001:db8:12::1 password abigpassword
 !
 address-family ipv4 unicast
  network 192.168.12.0/24
  redistribute rip
  neighbor 192.168.12.1 next-hop-self
  neighbor 192.168.12.1 soft-reconfiguration inbound
  no neighbor 2001:db8:12::1 activate
 exit-address-family
 !
 address-family ipv6 unicast
  network 2001:db8:12::/64
  redistribute ripng
  neighbor 2001:db8:12::1 activate
  neighbor 2001:db8:12::1 soft-reconfiguration inbound
 exit-address-family
!
bfd
 peer 192.168.12.1
  no shutdown
 !
 peer 2001:db8:12::1 local-address 2001:db8:12::2
  no shutdown
 !
!
EOF

frr3_ifa=epair123
frr3_ifa_p=b
frr3_ifb=epair134
frr3_ifb_p=a
frr3_daemons="mgmtd zebra ospfd ospf6d ripd ripngd bfdd"
${SUDO} mkdir -p /var/run/frr/frr3
${SUDO} tee /var/run/frr/frr3/frr.conf <<EOF
log file /var/run/frr/frr3/frr.log
!
key chain rippass
 key 1
  key-string rippassword
!
interface epair123b
 ip address 192.168.23.3/24
 ip rip authentication key-chain rippass
 ip rip authentication mode md5
 ipv6 address 2001:db8:23::3/64
!
interface epair134a
 ip address 192.168.34.3/24
 ip ospf bfd
 ip ospf message-digest-key 1 md5 superpass
 ipv6 address 2001:db8:34::3/64
 ipv6 ospf6 bfd
 ipv6 ospf6 area 0.0.0.0
!
router rip
 network epair123b
 redistribute connected
 redistribute ospf
 version 2
!
router ripng
 network epair123b
 redistribute connected
 redistribute ospf6
!
router ospf
 ospf router-id 3.3.3.3
 redistribute connected
 redistribute rip
 network 192.168.34.0/24 area 0.0.0.0
 area 0.0.0.0 authentication message-digest
!
router ospf6
 redistribute connected
 redistribute ripng
 interface epair134a area 0.0.0.0
!
bfd
 peer 2001:db8:34::4 local-address 2001:db8:34::3
  no shutdown
 !
 peer 192.168.34.4
  no shutdown
 !
!
EOF

frr4_ifa=epair134
frr4_ifa_p=b
frr4_ifb=epair145
frr4_ifb_p=a
frr4_daemons="mgmtd zebra ospfd ospf6d isisd bfdd"
${SUDO} mkdir -p /var/run/frr/frr4
${SUDO} tee /var/run/frr/frr4/frr.conf <<EOF
log file /var/run/frr/frr4/frr.log
!
interface epair134b
 ip address 192.168.34.4/24
 ip ospf bfd
 ip ospf message-digest-key 1 md5 superpass
 ipv6 address 2001:db8:34::4/64
 ipv6 ospf6 bfd
 ipv6 ospf6 area 0.0.0.0
!
interface epair145a
 ip address 192.168.45.4/24
 ip router isis BSDRP
 ipv6 address 2001:db8:45::4/64
 ipv6 router isis BSDRP
 isis circuit-type level-2-only
!
router ospf
 ospf router-id 4.4.4.4
 redistribute connected
 redistribute isis
 network 192.168.34.0/24 area 0.0.0.0
 area 0.0.0.0 authentication message-digest
!
router ospf6
 redistribute connected
 redistribute isis
 interface epair134b area 0.0.0.0
!
router isis BSDRP
 is-type level-1-2
 net 49.0000.0000.0004.00
 redistribute ipv4 ospf level-2
 redistribute ipv4 connected level-2
 redistribute ipv6 ospf6 level-2
 redistribute ipv6 connected level-2
!
bfd
 peer 2001:db8:34::3 local-address 2001:db8:34::4
  no shutdown
 !
 peer 192.168.34.3
  no shutdown
 !
!
EOF

frr5_ifa=epair145
frr5_ifa_p=b
frr5_ifb=epair156
frr5_ifb_p=a
frr5_daemons="mgmtd zebra babeld isisd"
${SUDO} mkdir -p /var/run/frr/frr5
${SUDO} tee /var/run/frr/frr5/frr.conf <<EOF
log file /var/run/frr/frr5/frr.log
!
interface epair145b
 ip address 192.168.45.5/24
 ip router isis BSDRP
 ipv6 address 2001:db8:45::5/64
 ipv6 router isis BSDRP
 isis circuit-type level-2-only
!
interface epair156a
 ip address 192.168.56.5/24
 ip router isis BSDRP
 ipv6 address 2001:db8:56::5/64
 ipv6 router isis BSDRP
 isis circuit-type level-2-only
 isis passive
!
router babel
 network epair145b
 network epair156a
 redistribute ipv4 isis
 redistribute ipv6 isis
!
router isis BSDRP
 is-type level-1-2
 net 49.0000.0000.0005.00
 redistribute ipv4 babel level-2
 redistribute ipv6 babel level-2
!
EOF

frr6_ifa=epair156
frr6_ifa_p=b
frr6_ifb=epair167
frr6_ifb_p=a
frr6_daemons="mgmtd zebra staticd babeld"
${SUDO} mkdir -p /var/run/frr/frr6
${SUDO} tee /var/run/frr/frr6/frr.conf <<EOF
log file /var/run/frr/frr6/frr.log
!
ip route 192.168.70.0/24 192.168.67.7
ipv6 route 2001:db8:70::/64 2001:db8:67::7
!
interface epair156b
 ip address 192.168.56.6/24
 ipv6 address 2001:db8:56::6/64
!
interface epair167a
 ip address 192.168.67.6/24
 ipv6 address 2001:db8:67::6/64
!
router babel
 network epair156b
 redistribute ipv4 connected
 redistribute ipv4 static
 redistribute ipv6 connected
 redistribute ipv6 static
!
EOF

frr7_ifa=epair167
frr7_ifa_p=b
frr7_ifb=lo170
frr7_ifb_p=""
frr7_daemons="mgmtd zebra staticd"
${SUDO} mkdir -p /var/run/frr/frr7
${SUDO} tee /var/run/frr/frr7/frr.conf <<EOF
log file /var/run/frr/frr7/frr.log
!
ip route 0.0.0.0/0 192.168.67.6
ipv6 route ::/0 2001:db8:67::6
!
interface lo170
 ip address 192.168.70.7/24
 ipv6 address 2001:db8:70::7/64
!
interface epair167b
 ip address 192.168.67.7/24
 ipv6 address 2001:db8:67::7/64
!
EOF

# A usefull function (from: http://code.google.com/p/sh-die/)
die() { echo -n "EXIT: " >&2; echo "$@" >&2; exit 1; }

usage () {
	echo "$0 start|stop"
}

check_req () {
	which vtysh > /dev/null 2>&1 || die "net/frr not installed: vtysh not found"
}

create_jail () {
	id=$1
	if [ "$(jls -d -j frr${id} dying)" = "true" ]; then
		echo "BUG: Previous jail stuck in dying state"
		echo "https://bugs.freebsd.org/bugzilla/show_bug.cgi?id=264981"
		exit 1
	fi
	eval "
		if [ -z "\$frr${id}_ifa_p" ] || [ "\$frr${id}_ifa_p" != b ]; then
			${SUDO} ifconfig \$frr${id}_ifa create group frr
		fi
		if [ -z "\$frr${id}_ifb_p" ] || [ "\$frr${id}_ifb_p" != b ]; then
			${SUDO} ifconfig \$frr${id}_ifb create group frr
		fi
	    ${SUDO} jail -c name=frr${id} host.hostname=frr${id} persist \
			vnet vnet.interface=\$frr${id}_ifa\$frr${id}_ifa_p \
			vnet vnet.interface=\$frr${id}_ifb\$frr${id}_ifb_p
		${SUDO} jexec frr${id} sysctl net.inet.ip.forwarding=1
		${SUDO} jexec frr${id} sysctl net.inet6.ip6.forwarding=1
		${SUDO} mkdir -p /var/run/frr/frr${id}.sock
		${SUDO} chown frr /var/run/frr/frr${id}.sock
		${SUDO} touch /var/run/frr/frr${id}/vtysh.conf
		if [ -f /var/run/frr/frr${id}/ipsec.conf ]; then
			echo "Loading ipsec.conf for jail frr${id}"
			${SUDO} kldstat -qm ipsec || ${SUDO} kldload ipsec
			${SUDO} kldstat -qm tcpmd5 || ${SUDO} kldload tcpmd5
			${SUDO} jexec frr${id} setkey -vf /var/run/frr/frr${id}/ipsec.conf
		fi
		for daemon in \$frr${id}_daemons; do
			${SUDO} jexec frr${id} \$daemon -d -i /var/run/frr/frr${id}_\$daemon.pid --vty_socket /var/run/frr/frr${id}.sock
		done
		${SUDO} jexec frr${id} vtysh -b --config_dir /var/run/frr/frr${id}/ --vty_socket /var/run/frr/frr${id}.sock || true
		"
}

destroy_jail () {
	# FreeBSD bug https://bugs.freebsd.org/bugzilla/show_bug.cgi?id=264981
	# $1: jail id
	iflist=$(${SUDO} jexec frr$1 ifconfig -l | sed 's/lo0//')
	${SUDO} jail -R frr$1 || true
	sleep 2
	for i in $iflist; do
		${SUDO} ifconfig $i destroy || true
	done
}

start () {
	echo start
	check_req
	${SUDO} chown -R frr /var/run/frr/
	for i in $(seq 7); do
		create_jail $i
	done
	echo "All jails configured with FRR running on them"
	echo "Network topology:"
	cat /tmp/topo.txt
	echo "To run command from jail, some examples:"
	echo "${SUDO} jexec frr1 ping -c 4 -S 192.168.10.1 192.168.70.7"
	echo "${SUDO} jexec frr3 vtysh --vty_socket /var/run/frr/frr3.sock"
	echo "${SUDO} jexec frr4"
	exit 0
}

stop () {
	echo stop
	for i in $(seq 7); do
		destroy_jail $i
		${SUDO} rm -rf /var/run/frr/frr${i}
		${SUDO} rm -f /var/run/frr/frr${i}_*
	done
	# There are some long-dying jail that could prevent deleteing all epairs
	for i in epair112 epair123 epair134 epair145 epair156 epair167; do
		for j in a b; do
			${SUDO} ifconfig $i$j destroy || true
		done
	done
	for i in lo110 lo170; do
		${SUDO} ifconfig $i destroy || true
	done
}

if [ $# -eq 0 ] ; then
	usage
	exit 2
else
	$1
fi
