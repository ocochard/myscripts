#!/usr/bin/env python3
"""
Synthetic HDR10 frames that cover the whole input color space, so the
per-pixel tonemap network does not have to extrapolate on very saturated
colors (films rarely reach them). Each frame is 960x544 of flat 32x32 blocks
(flat 2x2 luma blocks keep 4:2:0 chroma consistent). Block colors are drawn
uniformly in R'G'B' (BT.2020 primaries, PQ) between 0 and PQ_MAX, then
converted to limited-range 10-bit Y'CbCr (BT.2020 non-constant luminance).
Output: hdr_syn_<n>.yuv (yuv420p10le), same format as make_reference.sh.
Usage: make_synthetic.py OUTDIR COUNT
"""
import os
import sys

import numpy as np

W, H, B = 960, 544, 32
PQ_MAX = 0.80           # PQ code value of about 1500 nits (1000 nits = 0.752)

out, count = sys.argv[1], int(sys.argv[2])
os.makedirs(out, exist_ok=True)
rng = np.random.default_rng(1)
for n in range(count):
	rgb = rng.uniform(0, PQ_MAX, size=(H // B, W // B, 3))
	r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
	y = 0.2627 * r + 0.6780 * g + 0.0593 * b
	cb = (b - y) / 1.8814
	cr = (r - y) / 1.4746
	Y = np.round(64 + 876 * y).astype("<u2").repeat(B, 0).repeat(B, 1)
	U = np.round(512 + 896 * cb).astype("<u2").repeat(B // 2, 0).repeat(B // 2, 1)
	V = np.round(512 + 896 * cr).astype("<u2").repeat(B // 2, 0).repeat(B // 2, 1)
	with open(os.path.join(out, "hdr_syn_%03d.yuv" % n), "wb") as f:
		for p in (Y, U, V):
			f.write(p.tobytes())
