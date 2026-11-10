#!/usr/bin/env python3
"""
Write calibration tensors for the int16 quantizer: HDR frames from the
training pairs (960 wide), repeated 2x2 and cropped/padded to the network
input size, as .npy files in the [1,H,W,1] plane layout, plus dataset.txt.
Usage: make_calib.py PAIRDIR OUTDIR WIDTH HEIGHT [COUNT]
"""
import glob
import os
import random
import sys

import numpy as np

pairdir, out, w, h = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
count = int(sys.argv[5]) if len(sys.argv) > 5 else 16
os.makedirs(out, exist_ok=True)
random.seed(1)
files = random.sample(sorted(glob.glob(os.path.join(pairdir, "hdr_*.yuv"))), count)


def fit(p, ph, pw):
	"""Repeat 2x2, then crop or edge-pad to ph x pw."""
	p = p.repeat(2, axis=0).repeat(2, axis=1)[:ph, :pw]
	return np.pad(p, ((0, ph - p.shape[0]), (0, pw - p.shape[1])), mode="edge")


with open(os.path.join(out, "dataset.txt"), "w") as f:
	for i, path in enumerate(files):
		raw = np.fromfile(path, dtype="<u2")
		fh = raw.size * 2 // 3 // 960
		ys, cs = 960 * fh, 960 * fh // 4
		planes = (fit(raw[:ys].reshape(fh, 960), h, w),
		    fit(raw[ys:ys + cs].reshape(fh // 2, 480), h // 2, w // 2),
		    fit(raw[ys + cs:].reshape(fh // 2, 480), h // 2, w // 2))
		names = []
		for p, plane in zip("yuv", planes):
			n = "calib_%02d_%s.npy" % (i, p)
			np.save(os.path.join(out, n),
			    plane.astype(np.float32)[None, :, :, None])
			names.append(n)
		f.write(" ".join(names) + "\n")
