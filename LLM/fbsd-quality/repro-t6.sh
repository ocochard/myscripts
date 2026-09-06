#!/bin/sh
# See regress-t6.sh for why this file carries no explanation.

set -e

# Only unionfs needs loading, and it is loaded by MODULE name so this works
# whether it arrives as a .ko or is compiled in.
#
# tmpfs is deliberately NOT listed. It is compiled into GENERIC, so there is no
# tmpfs.ko in the image, and `kldload -n tmpfs` fails with
#   kldload: can't load tmpfs: No such file or directory
# returning 1 — correctly, since the FILE really is absent (-n skips only what
# is already LOADED, and a compiled-in filesystem is neither). Under set -e
# that aborted this script at its first command: it produced no output at all,
# the guest booted and shut down cleanly, and the harness reported "test
# machine completed" — i.e. a buggy kernel looking FIXED. Asking for a module
# that cannot and need not be loaded was the actual mistake; `|| true` would
# only have hidden it.
kldload -n unionfs

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
