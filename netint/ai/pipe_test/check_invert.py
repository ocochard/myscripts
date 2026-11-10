#!/usr/bin/env python3
"""Check a pipe-test invert output: Y' == 1023 - Y, U and V unchanged.
Usage: check_invert.py ref.yuv inv.yuv WIDTH HEIGHT (yuv420p10le)"""
import array
import sys

ref, inv = sys.argv[1], sys.argv[2]
w, h = int(sys.argv[3]), int(sys.argv[4])
ysz, csz = w * h, w * h // 4
fsz = ysz + 2 * csz
a, b = array.array("H"), array.array("H")
a.frombytes(open(ref, "rb").read())
b.frombytes(open(inv, "rb").read())
assert len(a) == len(b) and len(a) % fsz == 0
for f in range(len(a) // fsz):
	o = f * fsz
	ybad = sum(1 for i in range(o, o + ysz) if b[i] != 1023 - a[i])
	cbad = sum(1 for i in range(o + ysz, o + fsz) if b[i] != a[i])
	print("frame %d: Y mismatches %d/%d, UV mismatches %d/%d, "
	    "Y[0] %d->%d" % (f, ybad, ysz, cbad, 2 * csz, a[o], b[o]))
