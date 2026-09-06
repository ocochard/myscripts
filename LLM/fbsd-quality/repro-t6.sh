#!/bin/sh
# See regress-t6.sh for why this file carries no explanation.

set -e

# NOT under set -e: `kldload -n unionfs tmpfs` exits 1 here because tmpfs is
# compiled into GENERIC, so "loading" it fails even though the filesystem is
# perfectly available. With set -e that aborted the whole script at this line
# and it produced no output at all — which read as "the kernel no longer
# panics", i.e. a false PASS.
kldload -n unionfs tmpfs || true

D=/var/tmp/fbsdq-repro
rm -rf $D
mkdir -p $D/lower $D/mp
mount -t tmpfs tmpfs $D/mp
mkdir $D/mp/upper

mount -t unionfs -o below $D/lower $D/mp/upper
echo FBSDQ:repro:STEP1-OK

ls $D/mp/upper
echo FBSDQ:repro:STEP2-OK

umount $D/mp/upper
umount $D/mp
echo FBSDQ:repro:STEP3-OK
