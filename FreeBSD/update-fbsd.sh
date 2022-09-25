#!/bin/sh
# Update FreeBSD and ports, then install new environment using ZFS BE
set -eu

ARCH=$(uname -m)
# Absolute path script name
script=$(readlink -f $0)
# Absolute path this script is in
script_dir=$(dirname $script)
echo "Setting up /etc/make.conf and kernel"
if [ -f /etc/src.conf ]; then
	mv /etc/src.conf /etc/src.conf.bak
fi
cat > /etc/src.conf <<EOF
# Disable debugging assertions in LLVM
WITHOUT_LLVM_ASSERTIONS=yes
# Only build the required LLVM target support
WITHOUT_LLVM_TARGET_ALL=yes
# Disable assertions and statistics gathering in malloc(3)
WITH_MALLOC_PRODUCTION=yes
EOF

if [ -f /etc/src-env.conf ]; then
	mv  /etc/src-env.conf  /etc/src-env.conf.bak
fi
cat > /etc/src-env.conf <<EOF
WITH_META_MODE=yes
EOF

cat > /usr/src/sys/$ARCH/conf/BBR <<EOF
include GENERIC-NODEBUG
ident			BBR
options			KDB_UNATTENDED
makeoptions		WITH_EXTRA_TCP_STACKS=1 # Enable RACK & BBR
options			TCPHPTS		# Need high precision timer for rackh & bbr
options			RATELIMIT	# RACK depends on some constants
options			CC_NEWRENO	# RACK depends on some constants
EOF

if [ -f /etc/make.conf ]; then
	mv /etc/make.conf /etc/make.conf.bak
fi
cat > /etc/make.conf <<EOF
# Use our custom kernel configuration file
KERNCONF=BBR
DEVELOPER=yes
EOF

# Using META_MODE requiere filemon
kldstat -qm filemon || kldload filemon

echo "Updating source tree"
cd /usr/src
git pull --ff-only
echo "Building world and kernel"
make -j 32 buildworld buildkernel
ports_src=$(poudriere ports -lq | grep '^default' | awk {'print $5'})
cd ${ports_src}
git stash
poudriere ports -u
git stash pop
# Warning: Rebuilding the jail will force a rebuild of all ports
# But could be mandatory in case of video modules than need to be synced with kernel
#poudriere jail -j builder -u -m src=/usr/src
if [ ! -f /usr/local/etc/poudriere.d/make.conf ]; then
	(
	echo "LICENSES_ACCEPTED+= DCC"
	echo "LICENSES_ACCEPTED+= Proprietary"
	) > /usr/local/etc/poudriere.d/make.conf
fi
echo "Building ports..."
if ! poudriere bulk -j builder -f ${script_dir}/packages.list; then
	echo "[WARNING] Some packages fails to build"
fi
cd /usr/src
env NO_PKG_UPGRADE=YES /usr/src/tools/build/beinstall.sh
echo "shutdown -r now"
