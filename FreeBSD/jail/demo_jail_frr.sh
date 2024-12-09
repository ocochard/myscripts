#!/bin/sh
# Example of nullfs/unionfs jail to do regression test on FRR:
# The jails re-use host installed binary (read-only nullfs) and read-write (unionfs)
# directories to heritate the existing host configuration files.
# But because it uses already modified host's /etc files, need to overwrite them
# This allows to test FRR's RC scripts too.
# net/frr topologies connected by LAN (emulated by bridge and epair).
# Note on FreeBSD:

# Topoly: [ jail1 ]epair1_a -- epair1_b -bridge- epair2_b -- epair2_a[ jail2 ]

set -eu

# Create the bridge interface
bridge=$(ifconfig bridge create)

# Create epair interfaces, one pair for each jail
# we could use identifier at creation time to manage their id (ifconfig epair11 create)
epair1_a=$(ifconfig epair create)
epair1_b=$(echo ${epair1_a} | sed 's/a$/b/')
epair2_a=$(ifconfig epair create)
epair2_b=$(echo ${epair2_a} | sed 's/a$/b/')

# switch epair to UP and attach each b side to the bridge:
ifconfig ${epair1_a} up
ifconfig ${epair2_a} up
ifconfig ${epair1_b} up
ifconfig ${epair2_b} up
ifconfig ${bridge} addm ${epair1_b} addm ${epair2_b} up

# Now create the "light" filesystem for 2 jails (jail1 and jail2):
# shared directories (/bin, /sbin, etc.) are read only nullfs mounted
# write directory (/etc/, /var/run, etc.) are unionfs mounted, so they will
# heritate the contents of host system, then will be overwritted later.

to_be_umounted=""

for i in $(jot 2); do
  # Create empty directories
  for d in dev var/run/frr tmp usr/local/etc/frr; do
    mkdir -p /tmp/jails/jail${i}/${d}
  done
  # Use nullfs for read-only mount
  for d in root bin sbin lib libexec usr/bin usr/sbin usr/lib usr/libdata usr/local/bin usr/local/sbin usr/local/lib usr/local/etc/rc.d; do
    mkdir -p /tmp/jails/jail${i}/${d}
    mount -t nullfs -o ro /${d} /tmp/jails/jail${i}/${d}
    to_be_umounted="${to_be_umounted} /tmp/jails/jail${i}/$d"
  done
  # Use unionfs to heritate content (host config file) and allow write access
  # We don't have default etc configs file (called distrib-dirs and distribution sets)
  for d in etc; do
    mkdir -p /tmp/jails/jail${i}/${d}
    mount -t unionfs -o below /${d} /tmp/jails/jail${i}/${d}
    to_be_umounted="${to_be_umounted} /tmp/jails/jail${i}/$d"
  done
  # the hosts's sysctl.conf couldn't be applied inside a jail
  # (suppress some error messages)
  echo "#Empty" > /tmp/jails/jail${i}/etc/sysctl.conf
  # set correct owner
  # FRR is installed on the host, so frr user and groups exist.
  chown frr:frr /tmp/jails/jail${i}/var/run/frr
done

# Populate jail's configuration files

cat <<EOF > /tmp/jails/jail1/etc/rc.conf
hostname=jail1
cloned_interfaces="lo2"
ifconfig_${epair1_a}="up"
ifconfig_lo2="up"
gateway_enable="YES"
ipv6_gateway_enable="YES"
frr_enable="YES"
frr_daemons="mgmtd zebra staticd ripd"
EOF

cat <<EOF > /tmp/jails/jail2/etc/rc.conf
hostname=jail2
cloned_interfaces="lo2"
ifconfig_${epair2_a}="up"
ifconfig_lo2="up"
gateway_enable="YES"
ipv6_gateway_enable="YES"
frr_enable="YES"
frr_daemons="mgmtd zebra staticd ripd"
EOF

cat > /tmp/jails/jail1/usr/local/etc/frr/frr.conf <<EOF
log file /var/run/frr/frr.log
!
interface ${epair1_a}
 ip address 192.168.12.1/24
 ipv6 address 2001:db8:12::1/64
exit
!
interface lo2
 ip address 1.1.1.1/32
exit
!
router rip
 network 1.1.1.1/32
 network 192.168.12.0/24
exit
!
end
EOF

cat > /tmp/jails/jail2/usr/local/etc/frr/frr.conf <<EOF
log file /var/run/frr/frr.log
!
interface ${epair2_a}
 ip address 192.168.12.2/24
 ipv6 address 2001:db8:12::2/64
exit
!
interface lo2
 ip address 2.2.2.2/32
exit
!
router rip
 network 2.2.2.2/32
 network 192.168.12.0/24
exit
!
EOF

# Create and start the jails
jail -c name=jail1 path=/tmp/jails/jail1 host.hostname=jail1 persist vnet vnet.interface=${epair1_a} \
  exec.start="/bin/sh /etc/rc" \
  exec.stop="/bin/sh /etc/rc.shutdown" \
  mount.devfs

jail -c name=jail2 path=/tmp/jails/jail2 host.hostname=jail2 persist vnet vnet.interface=${epair2_a} \
  exec.start="/bin/sh /etc/rc" \
  exec.stop="/bin/sh /etc/rc.shutdown" \
  mount.devfs

echo "jail1 and jail2 started"
echo "While running, you can log into each jail using: jexec jail1 sh"
echo "Press Enter to delete all jails and interfaces (/tmp/jails directory will be not delete)"
read n

# reverse the list of mount points to be umounted
set -- ${to_be_umounted}
mounts=""
while [ "$#" -gt 0 ]; do
    mounts="$1 $mounts"
    shift
done

# Stop jails
for i in $(jot 2); do
  jail -R jail${i}
  sleep 2
  umount /tmp/jails/jail${i}/dev
done

# cleanup
for d in ${mounts}; do
  umount ${d} || echo "Failed to umount ${d}"
done

ifconfig ${bridge} destroy
ifconfig ${epair1_a} destroy
ifconfig ${epair2_a} destroy

# Manual cleanup:
# jail -R jail1
# jail -R jail2
# mount | grep '/tmp/jails' | cut -d ' ' -f 3 | xargs umount (twice)
# ifconfig -g epair | xargs -I {} ifconfig {} destroy
# ifconfig -g bridge | xargs -I {} ifconfig {} destroy
# rm -rf /tmp/jails
echo "Done"
