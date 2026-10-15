#!/bin/sh
# Reproduce rpcbind GETADDR returning the wrong interface address.
# Runs an rpcbind inside a throwaway vnet jail with two interfaces,
# the "wrong" one first, and asks for rpcbind's own address over udp6 and udp.
# Usage: rpcbind_getaddr_wildcard_repro.sh [rpcbind binary]
set -eu

RPCBIND=${1:-/usr/sbin/rpcbind}
J=rbj
ROOT=/tmp/$J
GOOD=2001:db8:1::1
PEER=2001:db8:1::2
BAD=2001:db8:bad::1
GOOD4=192.0.2.1
PEER4=192.0.2.2
BAD4=198.51.100.1

cleanup() {
	jail -r $J 2>/dev/null || true
	[ -n "${DUMMY:-}" ] && ifconfig ${DUMMY%a}b destroy 2>/dev/null || true
	[ -n "${LINK:-}" ] && ifconfig ${LINK%a}b destroy 2>/dev/null || true
	umount $ROOT/var/run 2>/dev/null || true
	umount $ROOT 2>/dev/null || true
	rmdir $ROOT 2>/dev/null || true
}
trap cleanup EXIT

[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }

mkdir -p $ROOT
mount -t nullfs -o ro / $ROOT
mount -t tmpfs tmpfs $ROOT/var/run
cp "$RPCBIND" $ROOT/var/run/rpcbind

jail -c name=$J path=$ROOT vnet persist
DUMMY=$(ifconfig epair create)
LINK=$(ifconfig epair create)
# Attach the dummy first so getifaddrs() in the jail lists it before LINK.
ifconfig $DUMMY vnet $J
ifconfig $LINK vnet $J
ifconfig ${DUMMY%a}b up
ifconfig ${LINK%a}b inet6 $PEER/64 no_dad up
ifconfig ${LINK%a}b inet $PEER4/24

jexec $J sysctl -q net.inet6.ip6.dad_count=0 >/dev/null
jexec $J ifconfig lo0 up
jexec $J ifconfig $DUMMY inet6 $BAD/64 no_dad up
jexec $J ifconfig $DUMMY inet $BAD4/24
jexec $J ifconfig $LINK inet6 $GOOD/64 no_dad up
jexec $J ifconfig $LINK inet $GOOD4/24
jexec $J /var/run/rpcbind
sleep 1

echo "jail interfaces: $(jexec $J ifconfig -l)"
getaddr() {
	echo "GETADDR(rpcbind) over $1 from $2 to $3:"
	tcpdump -ni ${LINK%a}b -c 1 -A "udp and src host $3" 2>/dev/null |
	    grep -aoE '2001:db8:[0-9a-f:]*\.[0-9]+\.[0-9]+|([0-9]+\.){5}[0-9]+' &
	TD=$!
	sleep 1
	timeout 5 rpcinfo -T $1 $3 100000 4 || true
	wait $TD || true
}

getaddr udp6 $PEER $GOOD
getaddr udp $PEER4 $GOOD4
