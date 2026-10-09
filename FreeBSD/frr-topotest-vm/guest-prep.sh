#!/bin/sh
# Install what the guest needs to build FRR and run the topotests.
#
# A freshly built image has an EMPTY /usr/local and no package database (both
# are excluded by mkvm.sh on purpose: a cloned pkg database without
# /usr/local makes pkg believe every host package is installed and then skip
# their files). So this starts from pkg bootstrap every time.
#
# Run it in the guest: sh /mnt/host/guest-prep.sh
set -eu

[ "$(id -u)" -eq 0 ] || { echo "$0: must be root" >&2; exit 1; }

echo "==> pkg bootstrap"
ASSUME_ALWAYS_YES=yes pkg bootstrap -f >/dev/null
pkg update -q >/dev/null

# FRR build deps per doc/developer/building-frr-for-freebsd14.rst, plus bash
# (topotest helpers) and gdb (kgdb in the guest, if you ever want it there).
echo "==> FRR build dependencies"
pkg install -y autoconf automake bison c-ares git gmake json-c libtool \
    libunwind libyang2 pkgconf protobuf-c texinfo bash gdb python3

# The pytest stack MUST match the interpreter python3 resolves to, or pytest
# imports from a different version's site-packages.
pyver=$(python3 -c 'import sys; print("%d%d" % sys.version_info[:2])')
echo "==> py$pyver pytest stack"
pkg install -y "py${pyver}-pytest" "py${pyver}-pytest-asyncio" "py${pyver}-pytest-xdist"

python3 -c 'import pytest, xdist; print("pytest", pytest.__version__)'
echo "==> dump device: $(dumpon -l)"
kldstat -q -m ip_mroute && echo "==> ip_mroute loaded" || echo "!!! ip_mroute NOT loaded: PIM tests will learn no groups" >&2
