#!/bin/sh
# Quick and Dirty script to create a light nullfs jail/vnet
# Purpose is to reproduce lagg/crazy-routing setup:
# https://lists.freebsd.org/archives/freebsd-net/2024-August/005406.html

set -eu
wrkdir=/tmp/lab

jail_populate() {
  local name=$1
  for d in etc dev tmp; do
    mkdir -p $wrkdir/$name/$d
  done
  mount -t unionfs -o below /etc $wrkdir/$name/etc
  for i in root bin sbin lib libexec usr; do
    mkdir -p $wrkdir/$name/$i
    mount -t nullfs /$i $wrkdir/$name/$i
  done
}

jail_create() {
  local name=$1
  local if1=$2
  local if2=$3
  jail -c name=$name path=$wrkdir/$name host.hostname=$name persist \
  vnet vnet.interface=$if1  \
  vnet vnet.interface=$if2 \
  exec.start="/bin/sh /etc/rc" \
  exec.stop="/bin/sh /etc/rc.shutdown" \
  mount.devfs
}

jail_destroy() {
  local name=$1
  jail -R $name
  sleep 2
  # mount | grep lab | cut -d ' ' -f 3 | xargs umount
  for i in root bin sbin lib libexec usr etc dev; do
    umount $wrkdir/$name/$i
  done
}

## main

if1a=$(ifconfig epair create)
if1b=$(echo $if1a | sed 's/a$/b/')

if2a=$(ifconfig epair create)
if2b=$(echo $if2a | sed 's/a$/b/')

jail_populate switch $wrkdir/switch
jail_populate host $wrkdir/host

kldstat -q -m if_lagg || kldload if_lagg
cat <<EOF > $wrkdir/switch/etc/rc.conf
hostname=switch
ifconfig_$if1a="up"
ifconfig_$if2a="up"
cloned_interfaces="lagg0"
ifconfig_lagg0="laggproto lacp laggport $if1a laggport $if2a 2.2.2.2/32"
EOF

cat <<EOF > $wrkdir/host/etc/rc.conf
hostname=host
ifconfig_$if1b="up"
ifconfig_$if2b="up"
cloned_interfaces="lagg0"
ifconfig_lagg0="laggproto lacp laggport $if1b laggport $if2b 1.1.1.1/32"
route_defaultgw="-host 2.2.2.2 -link -interface lagg0"
defaultrouter="2.2.2.2"
static_routes="defaultgw"
EOF

jail_create switch $if1a $if2a
jail_create host $if1b $if2b

echo "#### Status report ####"
sleep 2

echo "## Switch view ##"
echo "### Lagg interface status ###"
jexec switch ifconfig -v lagg0

echo "## Host view ##"
echo "### Lagg interface status ###"
jexec host ifconfig -v lagg0
echo "### Routing table (need to have default entry) ###"
jexec host netstat -rn4

# cleanup

jail_destroy host $wrkdir/host
jail_destroy switch $wrkdir/switch

ifconfig $if1a destroy
ifconfig $if2a destroy

echo "Done"
