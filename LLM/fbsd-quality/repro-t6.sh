#!/bin/sh
# See regress-t6.sh for why this file carries no explanation.

set -e

kldload -n unionfs tmpfs

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
