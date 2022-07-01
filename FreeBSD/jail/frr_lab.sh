#!/bin/sh
# FRR regression lab using empty vnet jails
# https://bsdrp.net/documentation/examples/simple_bgp-rip-ospf_lab
#
set -eu
cat > /tmp/topo.txt <<EOF
 192.168.10.1/24
 2001:db8:10::1/64
  lo110
    |
  --------                       --------                       --------
  | frr1 | .1                 .2 | frr2 |                       | frr3 |
  | BGP  |-epair112a<->epair112b-| BGP  | .2                 .3 |      |
  --------                       | RIP  |-epair123a<->epair123b-| RIP  |
                                 --------                       |      |
                                                                |      |
  --------                       --------                       |      |
  | frr5 |                       | frr4 | .4                .3  |      |
  |      | .5                 .4 | OSPF |-epair134b<->epair134a-| OSPF |
  | ISIS |-epair145b<->epair145a-| ISIS |                       --------
  |      |                       --------
  |      |
  |      |                       --------                       --------
  |      | .5                .6  | frr6 |                       | frr7 |
  |BABEL |-epair156a<->epair156b-|BABEL | .6                 .7 |      |
  --------                       |STATIC|-epair167a<->epair167b-|STATIC|
                                 --------                       --------
                                                                   |
                                                                 lo170
                                                            192.168.70.7/24
                                                           2001:db8:70::7/64
EOF

# Routers configuration
frr1_ifa=lo110
frr1_ifa_p=""
frr1_ifb=epair112
frr1_ifb_p=a
frr1_daemons="zebra bgpd bfdd"
#frr1_ifa_inet=192.168.10.1/24
#frr1_ifa_inet6=2001:db8:10::1/64
#frr1_ifb_inet=192.168.12.1/24
#frr1_ifb_inet6=2001:db8:12::1/64
mkdir -p /var/run/frr/frr1
cat > /var/run/frr/frr1/frr.conf <<EOF
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
 neighbor 2001:db8:12::2 remote-as 12
 neighbor 2001:db8:12::2 bfd
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
frr2_daemons="zebra bgpd bfdd ripd ripngd"
#frr2_ifa_inet=192.168.12.2/24
#frr2_ifa_inet6=2001:db8:12::2/64
#frr2_ifb_inet=192.168.13.2/24
#frr2_ifb_inet6=2001:db8:13::3/64
mkdir -p /var/run/frr/frr2
cat > /var/run/frr/frr2/frr.conf <<EOF
log file /var/run/frr/frr2/frr.log
!
key chain rippass
 key 1
  key-string rippassword
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
 network epair1a
 redistribute bgp
 redistribute connected
 version 2
!
router ripng
 network epair1a
 redistribute bgp
 redistribute connected
!
router bgp 12
 bgp router-id 192.168.10.2
 neighbor 192.168.12.1 remote-as 12
 neighbor 192.168.12.1 bfd
 neighbor 2001:db8:12::1 remote-as 12
 neighbor 2001:db8:12::1 bfd
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
frr3_daemons="zebra ospfd ospf6d ripd ripngd bfdd"
mkdir -p /var/run/frr/frr3
cat > /var/run/frr/frr3/frr.conf <<EOF
log file /var/run/frr/frr3/frr.log
!
key chain rippass
 key 1
  key-string rippassword
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
frr4_daemons="zebra ospfd ospf6d isisd bfdd"
mkdir -p /var/run/frr/frr4
cat > /var/run/frr/frr4/frr.conf <<EOF
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
frr5_daemons="zebra babeld isisd"
mkdir -p /var/run/frr/frr5
cat > /var/run/frr/frr5/frr.conf <<EOF
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
frr6_daemons="zebra babeld staticd"
mkdir -p /var/run/frr/frr6
cat > /var/run/frr/frr6/frr.conf <<EOF
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
frr7_daemons="zebra staticd"
mkdir -p /var/run/frr/frr7
cat > /var/run/frr/frr7/frr.conf <<EOF
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
	whereis -b vtysh > /dev/null 2>&1 || die "net/frr not installed: vtysh not found"
	[ "$(id -u)" != "0" ] && die "Need to be root" || true
}

create_jail () {
	id=$1
	eval "
		if [ -z "\$frr${id}_ifa_p" ] || [ "\$frr${id}_ifa_p" != b ]; then
			ifconfig \$frr${id}_ifa create group frr
		fi
		if [ -z "\$frr${id}_ifb_p" ] || [ "\$frr${id}_ifb_p" != b ]; then
			ifconfig \$frr${id}_ifb create group frr
		fi
	    jail -c name=frr${id} host.hostname=frr${id} persist \
			vnet vnet.interface=\$frr${id}_ifa\$frr${id}_ifa_p \
			vnet vnet.interface=\$frr${id}_ifb\$frr${id}_ifb_p
		jexec frr${id} sysctl net.inet.ip.forwarding=1
		jexec frr${id} sysctl net.inet6.ip6.forwarding=1
		mkdir -p /var/run/frr/frr${id}.sock
		chown frr /var/run/frr/frr${id}.sock
		touch /var/run/frr/frr${id}/vtysh.conf
		for daemon in \$frr${id}_daemons; do
			jexec frr${id} \$daemon -d -i /var/run/frr/frr${id}_\$daemon.pid --vty_socket /var/run/frr/frr${id}.sock
		done
		jexec frr${id} vtysh -b --config_dir /var/run/frr/frr${id}/ --vty_socket /var/run/frr/frr${id}.sock || true
		"
		#jexec frr${id} ifconfig \$frr${id}_ifa\$frr${id}_ifa_p inet \
		#	\$frr${id}_ifa_inet up
		#jexec frr${id} ifconfig \$frr${id}_ifa\$frr${id}_ifa_p inet6 \
		#	\$frr${id}_ifa_inet6
		#jexec frr${id} ifconfig \$frr${id}_ifb\$frr${id}_ifb_p inet \
		#	\$frr${id}_ifb_inet up
		#jexec frr${id} ifconfig \$frr${id}_ifb\$frr${id}_ifb_p inet6 \
		#	\$frr${id}_ifb_inet6
}

destroy_jail () {
	# FreeBSD bug https://bugs.freebsd.org/bugzilla/show_bug.cgi?id=264981
	# We MUST destroy interfaces before destroying the jail
	jexec frr1 ifconfig -l | tr -s ' ' '\0' | xargs -0 -L1 -I % jexec frr1 ifconfig % destroy || true
	jail -R frr$1 || true
}

start () {
	echo start
	check_req
	chown -R frr /var/run/frr/
	for i in $(seq 7); do
		create_jail $i
	done
	echo "All jails configured with FRR running on them"
	echo "Network topology:"
	cat /tmp/topo.txt
	echo "To run command from jail, some examples:"
	echo "jexec frr1 ping -c 4 -S 192.168.10.1 192.168.70.7"
	echo "jexec frr2 netstat -rn"
	echo "jexec frr3 vtysh --vty_socket /var/run/frr/frr3.sock"
	echo "jexec frr4"
	exit 0
}

stop () {
	echo stop
	for i in $(seq 7); do
		destroy_jail $i
		rm -rf /var/run/frr/frr${i}
		eval "
			if [ -z "\$frr${i}_ifa_p" ] || [ "\$frr${i}_ifa_p" != b ]; then
				ifconfig \$frr${i}_ifa\$frr${i}_ifa_p destroy || true
			fi
			if [ -z "\$frr${i}_ifb_p" ] || [ "\$frr${i}_ifb_p" != b ]; then
				eval ifconfig \$frr${i}_ifb\$frr${i}_ifb_p destroy || true
			fi
		"
	done
}

if [ $# -eq 0 ] ; then
	usage
	exit 2
else
	$1
fi
