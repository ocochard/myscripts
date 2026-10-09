#!/bin/sh
# Build and install FRR inside the topotest guest.
set -eux
cd /root
rm -rf frr
tar xzf /mnt/host/frr.tar.gz
cd /root/frr
./bootstrap.sh
export MAKE=gmake LDFLAGS=-L/usr/local/lib CPPFLAGS=-I/usr/local/include
./configure \
    --prefix=/usr/local \
    --sysconfdir=/usr/local/etc \
    --localstatedir=/var \
    --enable-multipath=64 \
    --enable-user=frr \
    --enable-group=frr \
    --enable-vty-group=frrvty
gmake -j8
gmake install
mkdir -p /usr/local/etc/frr
ls -l /usr/local/sbin/zebra /usr/local/sbin/pimd /usr/local/bin/vtysh
