#!/bin/sh
# Bench time spend to buildworld & kernel
# /etc/src.conf (or make.conf):
# WITHOUT_LLVM_ASSERTIONS=yes
# WITH_MALLOC_PRODUCTION=yes
# MALLOC_PRODUCTION=yes
set -eu
for i in 8 16 32 48 64 96 128 160 192; do
	for j in $(seq 3); do
		echo Jobs: $i / run: $j
		make clean
		/usr/bin/time -h -o $i.$j.time make -j $i buildworld buildkernel > $i.$j.log
		cat $i.$j.time
	done
done
