#!/bin/sh
# Update FreeBSD and ports, then install new environment using ZFS BE
set -eu
# Absolute path script name
script=$(readlink -f $0)
# Absolute path this script is in
script_dir=$(dirname $script)
cd /usr/src
git pull --ff-only
make -j 32 buildworld buildkernel
poudriere ports -u
# Warning: Rebuilding the jail will force a rebuild of all ports
# But could be mandatory in case of video modules than need to be synced with kernel
#poudriere jail -j builder -u -m src=/usr/src
poudriere bulk -j builder -f ${script_dir}/packages.list
env NO_PKG_UPGRADE=YES tools/build/beinstall.sh
echo "shutdown -r now"
