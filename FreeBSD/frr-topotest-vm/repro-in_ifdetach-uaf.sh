#!/bin/sh
#
# Reproduce the in_ifdetach() if_inet use-after-free (lltable_delete_addr
# GPF from rts_send) with the FRR zebra_nhg_check topotest.
#
# Needs a disposable FreeBSD 16-CURRENT machine or VM (it panics), running
# a GENERIC kernel (VIMAGE + INVARIANTS), with network access for pkg and
# git, about 4 GB of RAM and 3 GB of disk.  On an unpatched kernel it
# panics during the test teardown, about 3 minutes in.
#
#   usage: sh repro-in_ifdetach-uaf.sh /path/to/zebra-bsd-neigh.patch [workdir]
#
# The patch is the zebra change that implements kernel_neigh_update() on
# BSD with RTF_LLDATA routing messages.  Stock FRR never sends RTF_LLDATA,
# so without it the test does not reach the bug.
#
set -eu

PATCH=${1:?usage: $0 /path/to/zebra-bsd-neigh.patch [workdir]}
WORK=${2:-/root/frr-repro}
FRR_REPO=https://github.com/donaldsharp/frr.git
FRR_COMMIT=afe9d6bcb381c7d95bae14b9456deed0ca3561b7	# FRR PR 23475

[ "$(id -u)" -eq 0 ] || { echo "must be root" >&2; exit 1; }
PATCH=$(realpath "$PATCH")
[ "$(sysctl -n kern.features.vimage 2>/dev/null)" = 1 ] ||
	{ echo "kernel has no VIMAGE" >&2; exit 1; }
[ "$(sysctl -n kern.features.invariants 2>/dev/null)" = 1 ] ||
	echo "warning: no INVARIANTS, freed memory is not trashed and the bug may stay silent" >&2

echo "==> kernel: $(uname -v)"

echo "==> packages"
export ASSUME_ALWAYS_YES=yes
pkg bootstrap -f >/dev/null 2>&1 || true
pkg install -y autoconf automake bison c-ares git gmake json-c libtool \
    libunwind libyang2 pkgconf protobuf-c texinfo bash python3 >/dev/null
pyver=$(python3 -c 'import sys; print("%d%d" % sys.version_info[:2])')
pkg install -y "py${pyver}-pytest" "py${pyver}-pytest-asyncio" \
    "py${pyver}-pytest-xdist" >/dev/null

echo "==> frr user and groups"
pw groupshow frr >/dev/null 2>&1 || pw groupadd frr -g 168
pw groupshow frrvty >/dev/null 2>&1 || pw groupadd frrvty -g 152
pw usershow frr >/dev/null 2>&1 ||
	pw useradd frr -u 168 -g frr -G frrvty -d /var/run/frr -s /usr/sbin/nologin

echo "==> kernel modules and sysctls"
kldload -n if_epair if_bridge
# FRR asks for 16 MB socket buffers; at the 8 MB default vtysh prints
# SO_RCVBUF warnings and the test misreads its own output.
sysctl kern.ipc.maxsockbuf=33554432 >/dev/null

echo "==> FRR $FRR_COMMIT + $(basename "$PATCH")"
rm -rf "$WORK"
git init -q "$WORK"
cd "$WORK"
git fetch -q --depth 1 "$FRR_REPO" "$FRR_COMMIT"
git checkout -q FETCH_HEAD
git apply "$PATCH"

echo "==> build (several minutes)"
./bootstrap.sh >build.log 2>&1
MAKE=gmake LDFLAGS=-L/usr/local/lib CPPFLAGS=-I/usr/local/include \
    ./configure --prefix=/usr/local --sysconfdir=/usr/local/etc \
    --localstatedir=/var --enable-multipath=128 --enable-sharpd \
    --enable-user=frr --enable-group=frr --enable-vty-group=frrvty \
    >>build.log 2>&1
gmake -j"$(sysctl -n hw.ncpu)" >>build.log 2>&1
gmake install >>build.log 2>&1
mkdir -p /usr/local/etc/frr

echo "==> zebra_nhg_check: an unpatched kernel panics during teardown"
cd tests/topotests
sync
python3 -m pytest zebra_nhg_check -q || true
echo "==> no panic"
