#!/bin/sh
# Update FreeBSD and ports, then install new environment using ZFS BE
# To cleanup old BE:
# bectl list | grep -v 'NR\|default\|BE' | cut -d ' ' -f 1 | xargs -L1 bectl destroy
set -eu

ARCH=$(uname -m)
if which -s nproc; then
	JOBS=$(nproc)
else
	JOBS=$(sysctl -n kern.smp.cpus)
fi
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
# Disable asserstion about pthread
# https://cgit.freebsd.org/src/commit/?id=642cd511028b8839db2c89a44cf7807d80664f38
WITHOUT_PTHREADS_ASSERTIONS=yes
EOF

if [ -f /etc/src-env.conf ]; then
	if ! grep -q WITH_META_MODE /etc/src-env.conf; then
		mv  /etc/src-env.conf  /etc/src-env.conf.bak
		echo "WITH_META_MODE=yes" > /etc/src-env.conf
	fi
fi

if [ -f /etc/make.conf ]; then
	if ! grep -q BBR /etc/make.conf; then
		mv /etc/make.conf /etc/make.conf.bak
		cat > /etc/make.conf <<EOF
# Use a custom kernel configuration file
KERNCONF=BBR
# run stage-qa automatically when building ports
DEVELOPER=yes
EOF
	fi
fi

# Using META_MODE requiere filemon
if ! kldstat -qm filemon; then
	kldload filemon
	sysrc kld_list+=" filemon"
fi

if [ -e /usr/src/.git ]; then
	cd /usr/src
	echo "Updating source tree..."
	git pull --ff-only
else
	echo "Cloning main source tree..."
	git clone -b main --single-branch https://git.freebsd.org/src.git /usr/src
	cd /usr/src
fi

cat > /usr/src/sys/$ARCH/conf/BBR <<EOF
include GENERIC-NODEBUG
ident			BBR
options			KDB_UNATTENDED
makeoptions		WITH_EXTRA_TCP_STACKS=1 # Enable RACK & BBR
options			TCPHPTS		# Need high precision timer for rackh & bbr
options			RATELIMIT	# RACK depends on some constants
options			CC_NEWRENO	# RACK depends on some constants
EOF

echo "Building world and kernel..."
make buildworld-jobs buildkernel-jobs
if poudriere ports -ln | grep -q 'default'; then
	ports_src=$(poudriere ports -lq | awk '/^default/ { print $5; exit; }')
	# Backing up local patches
	cd ${ports_src}
	git stash
	# Updating port tree
	poudriere ports -u
	# Restoring local patches
	git stash pop || true
else
	# Creating the port tree
	poudriere ports -c
fi

if poudriere jail -ln | grep -q builder; then
	# Warning: Upgrading the jail will force a rebuild of all ports each time!
	# But could be mandatory in case of video modules than need to be synced with kernel
	poudriere jail -j builder -u -m src=/usr/src
else
	# Create the builder jail
	poudriere jail -j builder -c -m src=/usr/src
fi

# Fixing licenses that need user confirmation
if [ ! -f /usr/local/etc/poudriere.d/builder-make.conf ]; then
	(
	echo "DISABLE_LICENSES=yes"
	) > /usr/local/etc/poudriere.d/builder-make.conf
fi

# Improving build speed for some ports (warning, could consume a lot of RAM/CPU)
if ! grep -q llvm /usr/local/etc/poudriere.conf; then
	cp /usr/local/etc/poudriere.conf /usr/local/etc/poudriere.conf.bak
	echo 'ALLOW_MAKE_JOBS_PACKAGES="pkg ccache cmake-core rust gcc* llvm* libreoffice chromium node* ghc qt5-webkit qt5-base qt5-declarative qt6-base qt6-declarative py-qt5-pyqt* ruby rpcs* webkit2-gtk3 qemu wireshark wine-devel wine-proton"' >> /usr/local/etc/poudriere.conf
fi

echo "Building ports..."
if ! poudriere bulk -j builder -f ${script_dir}/packages.list; then
	echo "[WARNING] Some packages fails to build"
fi
cd /usr/src
# Don't want to fail upgrade if some packages refuse to install, so don't upgrade package at the same step
env NO_PKG_UPGRADE=YES /usr/src/tools/build/beinstall.sh -j ${JOBS}
echo "Base and kernel upgraded, time to reboot:"
echo "shutdown -r now"
