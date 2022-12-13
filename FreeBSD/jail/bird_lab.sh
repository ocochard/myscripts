#!/bin/sh
# bird regression lab using empty vnet jails
# https://bsdrp.net/documentation/examples/simple_bgp-rip-ospf_lab_with_bird
set -eu
cat > /tmp/topo.txt <<EOF
******************************************************************************
*                 net/bird regression lab using vnet jails                   *
******************************************************************************

 192.168.10.1/24
 2001:db8:10::1/64
  lo110
    |
  ---------                          --------                           ---------
  | bird1 |                          | bird2 |                          | bird3 |
  |       | .1 (192.168.12.0/24)  .2 |       |                          |       |
  |  BGP  |--epair112a<-->epair112b--| BGP   | .2 (192.168.23.0/24)  .3 |       |
  --------                           | RIP   |--epair123a<-->epair123b--| RIP   |
                                      --------                          |       |
                                                                        |       |
  ---------                         ---------                           |       |
  | bird5 |                         | bird4 |                           |       |
  |       |                         |       | .4 (192.168.34.0/24)   .3 |       |
  |       | .5 (192.168.45.0/24) .4 | OSPF  |--epair134b<-->epair134a---| OSPF  |
  | BABEL |--epair145b<->epair145a--| BABEL |                           ---------
  |       |                         --------
  |       |
  |       |                          --------
  |       |                          | bird6|
  |       | .5 (192.168.56.0/24) .6  |      |
  |STATIC |--epair156a<-->epair156b--|STATIC|
  --------                           --------
                                        |
                                      lo160
                                 192.168.60.6/24
                                2001:db8:60::6/64

                      ****** Expected results *******
root@host:~ # jexec bird1 netstat -rn
Routing tables

Internet:
Destination        Gateway            Flags     Netif Expire
127.0.0.1          link#16            UH          lo0
192.168.10.0/24    link#26            U1          lo1
192.168.10.1       link#26            UH          lo1
192.168.12.0/24    link#4             U     epair112a
192.168.12.1       link#4             UHS         lo0
192.168.23.0/24    192.168.12.2       UG1   epair112a
192.168.34.0/24    192.168.12.2       UG1   epair112a
192.168.45.0/24    192.168.12.2       UG1   epair112a
192.168.56.0/24    192.168.12.2       UG1   epair112a
192.168.60.0/24    192.168.12.2       UG1   epair112a

Internet6:
Destination                       Gateway                       Flags     Netif Expire
::/96                             ::1                           UGRS        lo0
::1                               link#16                       UHS         lo0
::ffff:0.0.0.0/96                 ::1                           UGRS        lo0
2001:db8:10::/64                  link#26                       U           lo1
2001:db8:10::1                    link#26                       UHS         lo0
2001:db8:12::/64                  link#4                        U     epair112a
2001:db8:12::1                    link#4                        UHS         lo0
2001:db8:23::/64                  2001:db8:12::2                UG1   epair112a
2001:db8:34::/64                  2001:db8:12::2                UG1   epair112a
2001:db8:45::/64                  2001:db8:12::2                UG1   epair112a
2001:db8:56::/64                  2001:db8:12::2                UG1   epair112a
2001:db8:60::/64                  2001:db8:12::2                UG1   epair112a
fe80::/10                         ::1                           UGRS        lo0
fe80::%epair112a/64               link#4                        U     epair112a
fe80::99:d6ff:fe95:710a%epair112a link#4                        UHS         lo0
fe80::%lo0/64                     link#16                       U           lo0
fe80::1%lo0                       link#16                       UHS         lo0
fe80::%lo1/64                     link#26                       U           lo1
fe80::1%lo1                       link#26                       UHS         lo0
ff02::/16                         ::1                           UGRS        lo0

# jexec bird1 traceroute 192.168.60.6
traceroute to 192.168.60.6 (192.168.60.6), 64 hops max, 40 byte packets
 1  192.168.12.2 (192.168.12.2)  0.038 ms  0.030 ms  0.014 ms
 2  192.168.23.3 (192.168.23.3)  0.020 ms  0.025 ms  0.014 ms
 3  192.168.34.4 (192.168.34.4)  0.020 ms  0.026 ms  0.016 ms
 4  192.168.45.5 (192.168.45.5)  0.033 ms  0.027 ms  0.020 ms
 5  192.168.60.6 (192.168.60.6)  0.031 ms  0.030 ms  0.020 ms

EOF

mkdir -p /var/run/bird/

# Routers configuration
bird1_ifa=lo110
bird1_ifa_p=""
bird1_ifb=epair112
bird1_ifb_p=a
cat > /var/run/bird/bird1.conf <<EOF
# Configure logging
log syslog all;
log "/var/log/bird.log" all;
log stderr all;

# Override router ID
router id 192.168.10.1;

# Sync bird routing table with kernel
protocol kernel kernel4 {
    ipv4 {
        export all;
    };
}
protocol kernel kernel6 {
    ipv6 {
        export all;
    };
}

protocol device {
        scan time 10;
}

# Include directly connected networks
protocol direct {
        ipv4;
        ipv6;
}

protocol bgp bgp4 {
        local as 12;
        # Bird creates IPSEC SAD entry automatically but it need to know the source IP address
        # Otherwise it will use the wrong 0.0.0.0 IP as source
        source address 192.168.12.1;
        neighbor 192.168.12.2 as 12;
        password "abigpassword";
        ipv4 {
            import all;
            export all;
        };
}

protocol bgp bgp6 {
        local as 12;
        # Bird creates IPSEC SAD entry automatically but it need to know the source IP address
        # Otherwise it will use the wrong :: IP as source
        source address 2001:db8:12::1;
        neighbor 2001:db8:12::2 as 12;
        password "abigpassword";
        ipv6 {
            import all;
            export all;
        };
}

protocol bfd {}
EOF

bird2_ifa=epair112
bird2_ifa_p=b
bird2_ifb=epair123
bird2_ifb_p=a
cat > /var/run/bird/bird2.conf <<EOF
# Configure logging
log syslog all;
log "/var/log/bird.log" all;
log stderr all;

# Override router ID
router id 192.168.10.2;

# Sync bird routing table with kernel
protocol kernel kernel4 {
    ipv4 {
        export all;
    };
}
protocol kernel kernel6 {
    ipv6 {
        export all;
    };
}

protocol device {
        scan time 10;
}

# Include directly connected networks
protocol direct {
        ipv4;
        ipv6;
}

protocol bgp bgp4 {
        local as 12;
        # Bird creates IPSEC SAD entry automatically but it need to know the source IP address
        # Otherwise it will use the wrong 0.0.0.0 IP as source
        source address 192.168.12.2;
        neighbor 192.168.12.1 as 12;
        password "abigpassword";
        ipv4 {
            import all;
            export all;
            next hop self;
        };
}

protocol bgp bgp6 {
        local as 12;
        # Bird creates IPSEC SAD entry automatically but it need to know the source IP address
        # Otherwise it will use the wrong :: IP as source
        source address 2001:db8:12::2;
        neighbor 2001:db8:12::1 as 12;
        password "abigpassword";
        ipv6 {
            import all;
            export all;
            next hop self;
        };
}

protocol bfd {}

protocol rip rip4 {
  ipv4 { import all; export all;};
  interface "epair1a" {};
}

protocol rip ng rip6 {
  ipv6 { import all; export all;};
  interface "epair1a" {};
}

EOF

bird3_ifa=epair123
bird3_ifa_p=b
bird3_ifb=epair134
bird3_ifb_p=a
cat > /var/run/bird/bird3.conf <<EOF
# Configure logging
log syslog all;
log "/var/log/bird.log" all;
log stderr all;

# Override router ID
router id 192.168.10.3;

# Sync bird routing table with kernel
protocol kernel kernel4 {
    ipv4 {
        export all;
    };
}
protocol kernel kernel6 {
    ipv6 {
        export all;
    };
}

protocol device {
        scan time 10;
}

# Include directly connected networks
protocol direct {
        ipv4;
        ipv6;
}

protocol bfd {}

protocol rip rip4 {
  ipv4 { import all; export all;};
  interface "epair1b" {};
}

protocol rip ng rip6 {
  ipv6 { import all; export all;};
  interface "epair1b" {};
}

protocol ospf v2 ospf4 {
  ipv4 { import all; export all;};
  area 0 {
    interface "epair2a" {};
    };
}

protocol ospf v3 ospf6 {
  ipv6 { import all; export all;};
  area 0 {
    interface "epair2a" {};
    };
}

EOF

bird4_ifa=epair134
bird4_ifa_p=b
bird4_ifb=epair145
bird4_ifb_p=a
cat > /var/run/bird/bird4.conf <<EOF
# Configure logging
log syslog all;
log "/var/log/bird.log" all;
log stderr all;

# Override router ID
router id 192.168.10.4;

# Sync bird routing table with kernel
protocol kernel kernel4 {
    ipv4 {
        export all;
    };
}
protocol kernel kernel6 {
    ipv6 {
        export all;
    };
}

protocol device {
        scan time 10;
}

# Include directly connected networks
protocol direct {
        ipv4;
        ipv6;
}

protocol bfd {}

protocol ospf v2 ospf4 {
  ipv4 { import all; export all;};
  area 0 {
    interface "epair2b" {};
    };
}

protocol ospf v3 ospf6 {
  ipv6 { import all; export all;};
  area 0 {
    interface "epair2b" {};
    };
}

protocol babel {
  interface "epair3a" { type wired; };
  ipv4 { import all; export all;};
  ipv6 { import all; export all;};
}

EOF

bird5_ifa=epair145
bird5_ifa_p=b
bird5_ifb=epair156
bird5_ifb_p=a
cat > /var/run/bird/bird5.conf <<EOF
# Configure logging
log syslog all;
log "/var/log/bird.log" all;
log stderr all;

# Override router ID
router id 192.168.10.5;

# Sync bird routing table with kernel
protocol kernel kernel4 {
    ipv4 {
        export all;
    };
}
protocol kernel kernel6 {
    ipv6 {
        export all;
    };
}

protocol device {
        scan time 10;
}

# Include directly connected networks
protocol direct {
        ipv4;
        ipv6;
}

protocol babel {
  interface "epair3b" { type wired; };
  ipv4 { import all; export all;};
  ipv6 { import all; export all;};
}

protocol static static4 {
    ipv4;
    route 192.168.60.0/24 via 192.168.56.6;
}

protocol static static6 {
    ipv6;
    route 2001:db8:60::/64 via 2001:db8:56::6;
}
EOF

bird6_ifa=epair156
bird6_ifa_p=b
bird6_ifb=lo170
bird6_ifb_p=""
cat > /var/run/bird/bird6.conf <<EOF
# Configure logging
log syslog all;
log "/var/log/bird.log" all;
log stderr all;

# Override router ID
router id 192.168.10.6;

# Sync bird routing table with kernel
protocol kernel kernel4 {
    ipv4 {
        export all;
    };
}
protocol kernel kernel6 {
    ipv6 {
        export all;
    };
}

protocol device {
        scan time 10;
}

# Include directly connected networks
protocol direct {
        ipv4;
        ipv6;
}
EOF

# A usefull function (from: http://code.google.com/p/sh-die/)
die() { echo -n "EXIT: " >&2; echo "$@" >&2; exit 1; }

usage () {
	echo "$0 start|stop"
}

check_req () {
	which bird > /dev/null 2>&1 || die "net/bird2 not installed: bird not found"
	[ "$(id -u)" != "0" ] && die "Need to be root" || true
}

create_jail () {
	id=$1
	eval "
		if [ -z "\$bird${id}_ifa_p" ] || [ "\$bird${id}_ifa_p" != b ]; then
			ifconfig \$bird${id}_ifa create group bird
		fi
		if [ -z "\$bird${id}_ifb_p" ] || [ "\$bird${id}_ifb_p" != b ]; then
			ifconfig \$bird${id}_ifb create group bird
		fi
	    jail -c name=bird${id} host.hostname=bird${id} persist \
			vnet vnet.interface=\$bird${id}_ifa\$bird${id}_ifa_p \
			vnet vnet.interface=\$bird${id}_ifb\$bird${id}_ifb_p
		jexec bird${id} sysctl net.inet.ip.forwarding=1
		jexec bird${id} sysctl net.inet6.ip6.forwarding=1
		jexec bird${id} bird -c /var/run/bird/bird${id}.conf -s /var/run/bird/bird${id}.ctl || true
		"
}

destroy_jail () {
	# FreeBSD bug https://bugs.freebsd.org/bugzilla/show_bug.cgi?id=264981
	# $1: jail id
	iflist=$(jexec bird$1 ifconfig -l | sed 's/lo0//')
	jail -R bird$1 || true
	for iftodestroy in $iflist; do
		ifconfig $iftodestroy destroy || true
	done
}

start () {
	echo start
	check_req
	for i in $(seq 6); do
		create_jail $i
	done
	echo "All jails configured with bird running on them"
	echo "Network topology:"
	cat /tmp/topo.txt
	echo "To run command from jail, some examples:"
	echo "jexec bird1 ping -c 4 -S 192.168.10.1 192.168.60.6"
	echo "jexec bird3 birdc -s /var/run/bird/bird3.sock"
	echo "jexec bird4"
	exit 0
}

stop () {
	echo stop
	for i in $(seq 7); do
		destroy_jail $i
		rm -f /var/run/bird/bird${i}.conf
		#rm -f /var/run/bird/bird${i}_*
	done
}

if [ $# -eq 0 ] ; then
	usage
	exit 2
else
	$1
fi
