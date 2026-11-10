#!/usr/bin/env python3
"""
Find out why the network misses the reference on some frames.
For each frame of a raw 1920x1080 yuv420p10le segment it prints the Y PSNR of
the float PyTorch model and of the NPU output against the reference, and
float against NPU (high = quantization is not the problem). For the worst
frame it then prints the mean Y error and compares the chroma saturation of
that frame with the training frames (are the colors outside the training
range?), and the Y error per saturation band.
Usage: diagnose_frames.py MODEL.pt WIDTH DEPTH HDR.yuv REF.yuv NPU.yuv PAIRDIR
"""
import glob
import math
import sys

import numpy as np
import torch

import train_tonemap as T

W, H = 1920, 1080
FS = W * H * 3 // 2


def frames(path):
	a = np.fromfile(path, dtype="<u2").reshape(-1, FS)
	return [(f[:W * H].reshape(H, W), f[W * H:W * H + FS // 6].reshape(H // 2, W // 2),
	    f[W * H + FS // 6:].reshape(H // 2, W // 2)) for f in a]


def psnr(a, b):
	mse = np.mean((a.astype(np.float64) - b) ** 2) / 1023 ** 2
	return 10 * math.log10(1 / mse) if mse else 99.0


def chroma_radius(u, v):
	return np.hypot(u.astype(float) - 512, v.astype(float) - 512)


def main():
	pt, width, depth = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
	hdr, ref, npu = (frames(p) for p in sys.argv[4:7])
	model = T.Tonemap(width, depth)
	model.load_state_dict(torch.load(pt))
	model.eval()
	worst, worst_y, worst_psnr = 0, None, 99.0
	for i in range(len(hdr)):
		with torch.no_grad():
			out = model(*T.to_tensors(hdr[i]))
		y = np.round(np.clip(out[0][0, 0].numpy(), 0, 1) * 1023)
		pf = psnr(y, ref[i][0])
		print("frame %d  float Y %.2f  npu Y %.2f  float-vs-npu Y %.2f" %
		    (i, pf, psnr(npu[i][0], ref[i][0]), psnr(y, npu[i][0])))
		if pf < worst_psnr:
			worst, worst_y, worst_psnr = i, y, pf
	e = worst_y - ref[worst][0]
	print("worst frame %d: ref Y mean %.1f, model Y mean %.1f, mean error %.1f" %
	    (worst, ref[worst][0].mean(), worst_y.mean(), e.mean()))
	sat = chroma_radius(hdr[worst][1], hdr[worst][2])
	p50 = np.percentile(sat, 50)
	print("worst frame chroma radius: p50 %.0f p99 %.0f max %.0f" %
	    tuple(np.percentile(sat, [50, 99, 100])))
	p99 = np.array([np.percentile(chroma_radius(*T.load_planes(p)[1:]), 99)
	    for p in glob.glob(sys.argv[7] + "/hdr_*.yuv")])
	print("training frames chroma radius p99: median %.0f, max %.0f, "
	    "%d of %d above the worst frame's p50" %
	    (np.median(p99), p99.max(), (p99 > p50).sum(), len(p99)))
	eb = np.abs(e).reshape(H // 2, 2, W // 2, 2).mean(axis=(1, 3))
	for lo, hi in ((0, 100), (100, 200), (200, 300), (300, 600)):
		sel = (sat >= lo) & (sat < hi)
		if sel.any():
			print("chroma radius %3d-%3d: %5.1f%% of blocks, mean |Y error| %.0f" %
			    (lo, hi, 100 * sel.mean(), eb[sel].mean()))


if __name__ == "__main__":
	main()
