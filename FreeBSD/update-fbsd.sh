#!/bin/sh
# Update FreeBSD and ports, then install new environment using ZFS BE
# To cleanup old BE:
# bectl list | grep -v 'NR\|default\|BE' | cut -d ' ' -f 1 | xargs -L1 sudo bectl destroy

set -eu

# Check if we need sudo and set up SUDO variable
if [ "$(id -u)" -ne 0 ]; then
    if ! command -v sudo >/dev/null 2>&1; then
        echo "Error: This script requires root privileges. Please install sudo or run as root."
        exit 1
    fi
    SUDO="sudo"
    echo "Running with sudo (not root user)"
else
    SUDO=""
    echo "Running as root"
fi

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
	$SUDO mv /etc/src.conf /etc/src.conf.bak
fi
$SUDO tee /etc/src.conf >/dev/null <<EOF
# Disable debugging assertions in LLVM
WITHOUT_LLVM_ASSERTIONS=yes
# Only build the required LLVM target support
# (prevent to cross-build, needed for my build-benches perf)
#WITHOUT_LLVM_TARGET_ALL=yes
# Disable assertions and statistics gathering in malloc(3)
WITH_MALLOC_PRODUCTION=yes
# Compile programs and libraries without the assert(3) checks
WITHOUT_ASSERT_DEBUG=yes
# Disable debugging assertions in pthreads library
WITHOUT_PTHREADS_ASSERTIONS=yes
# Disable regression tests (and ATF)
#WITHOUT_TESTS=yes
EOF

if [ -f /etc/src-env.conf ]; then
	if ! grep -q WITH_META_MODE /etc/src-env.conf; then
		$SUDO mv  /etc/src-env.conf  /etc/src-env.conf.bak
		echo "WITH_META_MODE=yes" | $SUDO tee /etc/src-env.conf >/dev/null
	fi
fi

if [ -w /etc/make.conf ]; then
	if ! grep -q GENERIC-NODEBUG /etc/make.conf; then
		$SUDO mv /etc/make.conf /etc/make.conf.bak
		$SUDO tee /etc/make.conf >/dev/null <<EOF
KERNCONF="GENERIC-NODEBUG GENERIC"
# run stage-qa automatically when building ports
DEVELOPER=yes
EOF
	fi
fi

# Using META_MODE requiere filemon
if ! $SUDO kldstat -qm filemon; then
	$SUDO kldload filemon
	$SUDO sysrc kld_list+=" filemon"
fi

# Enable ccache if installed
if command -v ccache; then
  echo "ccache installed, enabling it"
  $SUDO mkdir -p /var/cache/ccache
  if [ ! -f /var/cache/ccache/ccache.conf ]; then
    echo 'max_size = 30.0Gi' | $SUDO tee /var/cache/ccache/ccache.conf
  fi
  if ! grep -q CCACHE /etc/make.conf; then
$SUDO tee -a /etc/make.conf >/dev/null <<EOF
# Improve next builds
WITH_CCACHE_BUILD=yes
CCACHE_DIR=/var/cache/ccache/
EOF
  fi
else
  echo "Do not enable ccache (not installed)"
fi # no ccache

if [ -e /usr/src/.git ]; then
	cd /usr/src
	echo "Updating source tree..."
  ${SUDO} git checkout main
	${SUDO} git pull --ff-only
else
	echo "Cloning main source tree..."
	${SUDO} git clone -b main --single-branch https://git.freebsd.org/src.git /usr/src
	cd /usr/src
fi

echo "Building world and kernel..."
$SUDO make buildworld-jobs buildkernel-jobs
# make buildworld buildkernel update-packages to create pkg repo compliant
# with upgrade mode
if $SUDO poudriere ports -ln | grep -q 'default'; then
	ports_src=$($SUDO poudriere ports -lq | awk '/^default/ { print $5; exit; }')
	# Backing up local patches
	cd ${ports_src}
	$SUDO git stash
	# Updating port tree
	$SUDO poudriere ports -u
	# Restoring local patches
	$SUDO git stash pop || true
else
	# Creating the port tree
	$SUDO poudriere ports -c
fi

$SUDO cp /etc/src.conf /usr/local/etc/poudriere.d/builder-src.conf

if $SUDO poudriere jail -ln | grep -q builder; then
	# Warning: Upgrading the jail will force a rebuild of all ports each time!
	# But could be mandatory in case of video modules than need to be synced with kernel
	$SUDO poudriere jail -j builder -u -m src=/usr/src
else
	# Create the builder jail
	$SUDO poudriere jail -j builder -c -m src=/usr/src
fi

# Fixing licenses that need user confirmation
# Force rebuild Kernel modules if kernel was upgraded
if [ ! -f /usr/local/etc/poudriere.d/builder-make.conf ]; then
	(
	echo "DISABLE_LICENSES=yes"
  echo 'PORTS_MODULES=net/realtek-re-kmod graphics/drm-kmod graphics/drm-61-kmod graphics/gpu-firmware-kmod'
	) | $SUDO tee /usr/local/etc/poudriere.d/builder-make.conf >/dev/null
fi

# Improving build speed for some ports (warning, could consume a lot of RAM/CPU)
if ! grep -q llvm /usr/local/etc/poudriere.conf; then
	$SUDO cp /usr/local/etc/poudriere.conf /usr/local/etc/poudriere.conf.bak
  (
  echo 'ALLOW_MAKE_JOBS_PACKAGES="pkg firefox electron* perl5 ccache cmake-core cbmc cvc5 rust gcc* gdb gimp-app llvm* libreoffice mesa-devel mariadb* qemu chromium node* ghc py* rpcs* ruby qt5-declarative qt5-webkit* qt6-multimedia webkit2-gtk* pytorch onednn qt5-base qt6-base qt6-declarative opencv osg samba* wine-devel wine-proton nginx protobuf wireshark hs-pandoc z3'
  ) | $SUDO tee -a /usr/local/etc/poudriere.conf >/dev/null
fi

echo "Building ports..."
# -b latest: downlad latest package from repo to avoid building them
if ! $SUDO poudriere bulk -j builder -f ${script_dir}/packages.list; then
	echo "[WARNING] Some packages fails to build"
fi

# Adding this new repo to the system
if ! [ -r /usr/local/etc/pkg/repos/local.conf ]; then
	$SUDO tee /usr/local/etc/pkg/repos/local.conf >/dev/null <<EOF
local: {
  url: "file:////usr/local/poudriere/data/packages/builder-default/.latest",
  signature_type: "none",
  assume_always_yes: true,
  priority: 1,
  enabled: yes
}
EOF
fi

cd /usr/src
# Don't want to fail upgrade if some packages refuse to install, so don't upgrade package at the same step
$SUDO env NO_PKG_UPGRADE=YES /usr/src/tools/build/beinstall.sh -j ${JOBS}
echo "Base and kernel upgraded, time to reboot:"
echo "shutdown -r now"
