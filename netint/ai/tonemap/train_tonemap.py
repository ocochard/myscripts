#!/usr/bin/env python3
"""
Train the HDR10 -> SDR tonemap network on the pairs from make_reference.sh,
then export it to ONNX for the NETINT AI Toolkit.

The network works on one 2x2 luma block and its chroma sample at a time
(all layers are convolutions at chroma resolution):
  h  = relu(conv2x2/2(Y) + conv1x1(U) + conv1x1(V))
  h  = relu(conv1x1(h))            (DEPTH times)
  Y' = convtranspose2x2/2(h),  U' = conv1x1(h),  V' = conv1x1(h)
Inputs and outputs are 10-bit code values (0..1023); the /1023 and *1023
scaling is folded into the first and last layers before export.
--export-fused converts the trained weights exactly into TonemapFused, the
same function with fewer full-size tensors (3.7x faster on the NPU), which
trains more slowly if trained directly (--arch fused).

Usage: train_tonemap.py PAIRDIR OUTDIR [--iters N] [--width C] [--depth D]
           [--export-fused] [--load STATE.pt] [--arch split|fused]
--iters 0 exports without training (with --load: a trained model).
Pairs are hdr_<name>_<n>.yuv / sdr_<name>_<n>.yuv, yuv420p10le, 960 wide.
"""
import argparse
import glob
import math
import os
import random

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F

WIDTH = 960
HOLDOUT = ("revenant", "toystory3")     # films kept for validation


def load_planes(path):
	"""Read one yuv420p10le frame; height follows from the file size."""
	raw = np.fromfile(path, dtype="<u2")
	h = raw.size * 2 // 3 // WIDTH
	ys = WIDTH * h
	cs = ys // 4
	return (raw[:ys].reshape(h, WIDTH), raw[ys:ys + cs].reshape(h // 2, WIDTH // 2),
	    raw[ys + cs:].reshape(h // 2, WIDTH // 2))


def load_pairs(pairdir):
	train, val = [], []
	for hdr in sorted(glob.glob(os.path.join(pairdir, "hdr_*.yuv"))):
		name = os.path.basename(hdr)[4:-4]
		pair = (name, load_planes(hdr),
		    load_planes(os.path.join(pairdir, "sdr_" + name + ".yuv")))
		(val if name.rsplit("_", 1)[0] in HOLDOUT else train).append(pair)
	return train, val


def to_tensors(planes):
	"""Planes to [1,1,H,W] float tensors scaled to 0..1."""
	return [torch.from_numpy(p.astype(np.float32) / 1023.0)[None, None]
	    for p in planes]


class Tonemap(nn.Module):
	def __init__(self, width, depth):
		super().__init__()
		self.in_y = nn.Conv2d(1, width, 2, stride=2)
		self.in_u = nn.Conv2d(1, width, 1, bias=False)
		self.in_v = nn.Conv2d(1, width, 1, bias=False)
		self.hidden = nn.ModuleList(
		    [nn.Conv2d(width, width, 1) for _ in range(depth)])
		self.out_y = nn.ConvTranspose2d(width, 1, 2, stride=2)
		self.out_u = nn.Conv2d(width, 1, 1)
		self.out_v = nn.Conv2d(width, 1, 1)

	def forward(self, y, u, v):
		h = F.relu(self.in_y(y) + self.in_u(u) + self.in_v(v))
		for layer in self.hidden:
			h = F.relu(layer(h))
		return self.out_y(h), self.out_u(h), self.out_v(h)


class TonemapFused(nn.Module):
	"""Same function, fewer full-size tensors on the NPU: one 6-channel
	input (Y as 4 channels by a fixed space-to-depth convolution, U, V),
	one convolution into the wide layer, one convolution out to 6 channels
	(Y back to 2x2 blocks by a fixed transposed convolution)."""
	def __init__(self, width, depth):
		super().__init__()
		s2d = torch.zeros(4, 1, 2, 2)
		for k in range(4):
			s2d[k, 0, k // 2, k % 2] = 1.0
		self.register_buffer("s2d", s2d)
		self.register_buffer("d2s", s2d.clone())
		self.inp = nn.Conv2d(6, width, 1)
		self.hidden = nn.ModuleList(
		    [nn.Conv2d(width, width, 1) for _ in range(depth)])
		self.out = nn.Conv2d(width, 6, 1)

	def forward(self, y, u, v):
		x = torch.cat([F.conv2d(y, self.s2d, stride=2), u, v], 1)
		h = F.relu(self.inp(x))
		for layer in self.hidden:
			h = F.relu(layer(h))
		o = self.out(h)
		yo = F.conv_transpose2d(o[:, 0:4], self.d2s, stride=2)
		return yo, o[:, 4:5], o[:, 5:6]


def to_fused(split):
	"""Exact conversion of a trained Tonemap into a TonemapFused (same
	function, the fast graph). Space-to-depth channel k is luma (k//2, k%2)."""
	width, depth = split.in_y.out_channels, len(split.hidden)
	fused = TonemapFused(width, depth)
	with torch.no_grad():
		for k in range(4):
			fused.inp.weight[:, k, 0, 0] = split.in_y.weight[:, 0, k // 2, k % 2]
			fused.out.weight[k, :, 0, 0] = split.out_y.weight[:, 0, k // 2, k % 2]
			fused.out.bias[k] = split.out_y.bias[0]
		fused.inp.weight[:, 4, 0, 0] = split.in_u.weight[:, 0, 0, 0]
		fused.inp.weight[:, 5, 0, 0] = split.in_v.weight[:, 0, 0, 0]
		fused.inp.bias.copy_(split.in_y.bias)
		for a, b in zip(fused.hidden, split.hidden):
			a.weight.copy_(b.weight)
			a.bias.copy_(b.bias)
		fused.out.weight[4:6] = torch.cat([split.out_u.weight, split.out_v.weight])
		fused.out.bias[4] = split.out_u.bias[0]
		fused.out.bias[5] = split.out_v.bias[0]
	return fused


def random_crops(pairs, n, size):
	"""n random crops, size x size at chroma resolution (2x for luma)."""
	ins, outs = [[], [], []], [[], [], []]
	for _ in range(n):
		_, hdr, sdr = random.choice(pairs)
		ch, cw = hdr[1].shape
		r = random.randrange(ch - size + 1)
		c = random.randrange(cw - size + 1)
		for k, (src, dst) in enumerate(zip(hdr, sdr)):
			s = 2 if k == 0 else 1
			ins[k].append(src[r * s:(r + size) * s, c * s:(c + size) * s])
			outs[k].append(dst[r * s:(r + size) * s, c * s:(c + size) * s])
	f = lambda planes: [torch.from_numpy(
	    np.stack(p).astype(np.float32) / 1023.0)[:, None] for p in planes]
	return f(ins), f(outs)


def load_planes_check():
	"""A random 64x64 (chroma) frame to check the fused conversion."""
	g = np.random.default_rng(1)
	return (g.integers(0, 1024, (128, 128)), g.integers(0, 1024, (64, 64)),
	    g.integers(0, 1024, (64, 64)))


def psnr(mse):
	return 10 * math.log10(1.0 / mse) if mse > 0 else float("inf")


def evaluate(model, pairs):
	"""Mean PSNR per plane (10-bit, peak 1023) over full frames."""
	tot = np.zeros(3)
	with torch.no_grad():
		for _, hdr, sdr in pairs:
			pred = model(*to_tensors(hdr))
			for k, (p, t) in enumerate(zip(pred, to_tensors(sdr))):
				q = torch.round(p.clamp(0, 1) * 1023) / 1023
				tot[k] += psnr(F.mse_loss(q, t).item())
	return tot / len(pairs)


def fold_scaling(model):
	"""Make the model take and return 10-bit code values directly."""
	with torch.no_grad():
		if isinstance(model, TonemapFused):
			ins, outs = (model.inp,), (model.out,)
		else:
			ins = (model.in_y, model.in_u, model.in_v)
			outs = (model.out_y, model.out_u, model.out_v)
		for conv in ins:
			conv.weight /= 1023.0
		for conv in outs:
			conv.weight *= 1023.0
			conv.bias *= 1023.0


class Deploy(nn.Module):
	"""Frame planes in the [1,H,W,1] layout that ni_quadra_ai_pre feeds."""
	def __init__(self, model, h, w):
		super().__init__()
		self.model, self.h, self.w = model, h, w

	def forward(self, y, u, v):
		h, w = self.h, self.w
		yo, uo, vo = self.model(y.reshape(1, 1, h, w),
		    u.reshape(1, 1, h // 2, w // 2), v.reshape(1, 1, h // 2, w // 2))
		return (yo.reshape(1, h, w, 1), uo.reshape(1, h // 2, w // 2, 1),
		    vo.reshape(1, h // 2, w // 2, 1))


def main():
	ap = argparse.ArgumentParser()
	ap.add_argument("pairdir")
	ap.add_argument("outdir")
	ap.add_argument("--iters", type=int, default=20000)
	ap.add_argument("--width", type=int, default=32)
	ap.add_argument("--depth", type=int, default=2)
	ap.add_argument("--arch", choices=("split", "fused"), default="split")
	ap.add_argument("--export-fused", action="store_true",
	    help="train the split graph, export the equivalent fused graph")
	ap.add_argument("--load", help="skip training: load a split state dict")
	ap.add_argument("--batch", type=int, default=32)
	ap.add_argument("--crop", type=int, default=64)
	ap.add_argument("--onnx-size", default="1920x1080")
	args = ap.parse_args()

	torch.manual_seed(1)
	random.seed(1)
	os.makedirs(args.outdir, exist_ok=True)
	model = (TonemapFused if args.arch == "fused" else Tonemap)(
	    args.width, args.depth)
	if args.load:
		model.load_state_dict(torch.load(args.load))
	if args.iters == 0:
		# Export without training (--load), or untrained: the speed on the
		# card does not depend on the weights.
		export(model, args)
		return
	train, val = load_pairs(args.pairdir)
	print("pairs: train %d, validation %d (%s)" %
	    (len(train), len(val), ",".join(HOLDOUT)), flush=True)

	# Baseline: SDR output = HDR input unchanged (what force8Bit gives).
	ident = lambda y, u, v: (y, u, v)
	print("validation PSNR Y/U/V, no tonemap: %.2f %.2f %.2f" %
	    tuple(evaluate(ident, val)), flush=True)

	opt = torch.optim.Adam(model.parameters(), lr=2e-3)
	sched = torch.optim.lr_scheduler.CosineAnnealingLR(opt, args.iters)
	for it in range(1, args.iters + 1):
		ins, outs = random_crops(train, args.batch, args.crop)
		pred = model(*ins)
		# Luma counts 4x per chroma sample, as in the frame.
		loss = sum(F.mse_loss(p, t) for p, t in zip(pred, outs))
		opt.zero_grad()
		loss.backward()
		opt.step()
		sched.step()
		if it % 1000 == 0 or it == args.iters:
			print("iter %d loss %.3e val PSNR Y/U/V %.2f %.2f %.2f" %
			    ((it, loss.item()) + tuple(evaluate(model, val))),
			    flush=True)

	torch.save(model.state_dict(), os.path.join(args.outdir, "tonemap.pt"))
	export(model, args)


def export(model, args):
	if args.export_fused and isinstance(model, Tonemap):
		fused = to_fused(model)
		x = to_tensors(load_planes_check())
		with torch.no_grad():
			err = max((a - b).abs().max().item()
			    for a, b in zip(model(*x), fused(*x)))
		print("fused conversion max difference: %.2e" % err)
		model = fused
	fold_scaling(model)
	w, h = (int(x) for x in args.onnx_size.split("x"))
	dep = Deploy(model, h, w).eval()
	dummy = (torch.zeros(1, h, w, 1), torch.zeros(1, h // 2, w // 2, 1),
	    torch.zeros(1, h // 2, w // 2, 1))
	onnx_path = os.path.join(args.outdir, "tonemap_%dx%d.onnx" % (w, h))
	torch.onnx.export(dep, dummy, onnx_path, opset_version=11,
	    input_names=["y", "u", "v"], output_names=["y_out", "u_out", "v_out"])
	print("wrote", onnx_path)


if __name__ == "__main__":
	main()
