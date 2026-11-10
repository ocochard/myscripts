#!/bin/bash
# Build untrained tonemap NBGs of several sizes, for speed tests on the card
# (the speed does not depend on the weights). Run in netint-ai:4.5 from the
# work directory holding train_tonemap.py, convert_tonemap.sh and a CALIB
# directory with calibration files from make_calib.py.
# Usage: speed_variants.sh split|fused WIDTHxDEPTH...   (HYBRID=1|2 passes on)
set -eu
arch=$1
shift
CALIB=${CALIB:-smoke}
for v in "$@"; do
	w=${v%x*} d=${v#*x} dir=speed_${arch}_w${w}d${d}${HYBRID:+_h$HYBRID}
	mkdir -p $dir
	cp $CALIB/calib_* $CALIB/dataset.txt convert_tonemap.sh $dir/
	python3 train_tonemap.py tm_pairs $dir --iters 0 --arch $arch --width $w --depth $d \
	    > $dir/export.log 2>&1
	(cd $dir && ./convert_tonemap.sh 1920 1080 > convert.log 2>&1 && echo "$dir ok" || echo "$dir FAIL")
done
