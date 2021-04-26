#!/bin/sh
# Update FreeBSD and ports, then install new environment using ZFS BE
set -eu
curdir=$(pwd)
cd /usr/src
git pull --ff-only
make -j 32 buildworld buildkernel
poudriere ports -u
# Warning: Rebuilding the jail will force a rebuild of all ports
# But could be mandatory in case of video modules than need to be synced with kernel
#poudriere jail -j builder -u -m src=/usr/src
poudriere bulk -j builder -f ${curdir}/packages.list
tools/build/beinstall.sh
echo "shutdown -r now"
