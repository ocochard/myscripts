#!/bin/sh
#
# Build an Ubuntu 26.04 userland for FastFlowLM under linuxlator.
#
# FastFlowLM's NPU engines are closed Linux libraries that need glibc
# 2.38 and libstdc++ 3.4.32, newer than the linux_base ports, so they
# run in a debootstrapped Ubuntu with AMD's Linux XRT from the
# lemonade-team PPA.  The NPU itself is driven by the FreeBSD amdxdna
# driver (graphics/amdxdna-kmod).
#
# Usage: fastflowlm-setup.sh [root]   (as root; default /compat/ubuntu)
# Then enable the mounts at boot with the fastflowlm rc.d script:
#	install -m 555 fastflowlm.rc /usr/local/etc/rc.d/fastflowlm
#	sysrc fastflowlm_enable=YES

set -eu

root=${1:-/compat/ubuntu}
suite=resolute
flm_version=1.0.13
flm_deb=fastflowlm_${flm_version}_ubuntu26.04_amd64.deb
flm_url=https://github.com/ROCm/FastFlowLM/releases/download/v${flm_version}/${flm_deb}
# Launchpad signing key of ppa:lemonade-team/stable.
ppa_key=881CF4B40B0BFA288D6776E83BF36CFA0BD50AEC

if [ "$(id -u)" -ne 0 ]; then
	echo "run as root" >&2
	exit 1
fi

kldload -n linux64
pkg info -e debootstrap || pkg install -y debootstrap

if [ ! -x "$root/bin/bash" ]; then
	debootstrap --arch=amd64 --variant=minbase \
	    --include=ca-certificates,gnupg,curl "$suite" "$root" \
	    http://archive.ubuntu.com/ubuntu
fi

# apt needs /proc and /dev inside the chroot.
mount | grep -q " $root/proc " || mount -t linprocfs linprocfs "$root/proc"
mount | grep -q " $root/dev " || mount -t devfs devfs "$root/dev"
cp /etc/resolv.conf "$root/etc/resolv.conf"

chroot "$root" /bin/bash -s "$suite" "$ppa_key" "$flm_url" "$flm_deb" <<'EOF'
set -eu
suite=$1 key=$2 url=$3 deb=$4
export DEBIAN_FRONTEND=noninteractive
mkdir -p /etc/apt/keyrings
if [ ! -s /etc/apt/keyrings/lemonade.gpg ]; then
	export GNUPGHOME=$(mktemp -d)
	gpg -q --keyserver hkps://keyserver.ubuntu.com --recv-keys "$key"
	gpg -q --export "$key" > /etc/apt/keyrings/lemonade.gpg
fi
echo "deb [signed-by=/etc/apt/keyrings/lemonade.gpg]" \
    "https://ppa.launchpadcontent.net/lemonade-team/stable/ubuntu $suite main" \
    > /etc/apt/sources.list.d/lemonade.list
# XRT needs packages from universe.
if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then
	sed -i 's/^Components: main$/Components: main universe/' \
	    /etc/apt/sources.list.d/ubuntu.sources
elif ! grep -q universe /etc/apt/sources.list; then
	sed -i 's/ main$/ main universe/' /etc/apt/sources.list
fi
apt-get -q update
apt-get -q -y install libxrt-npu2 libxrt-utils-npu
cd /tmp
curl -fsSLO "$url"
apt-get -q -y install "./$deb"
flm version
EOF
echo "FastFlowLM installed in $root.  Run: chroot $root flm run llama3.2:1b"
