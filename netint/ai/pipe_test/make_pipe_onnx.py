#!/usr/bin/env python3
"""
Build the pipe-test networks for ni_quadra_ai_pre with 10-bit frames:
3 inputs (Y, U, V planes of a yuv420p10le frame), 3 outputs.
  identity: every plane goes through Relu (values are >= 0, so unchanged)
  invert:   Y' = 1023 - Y, U and V unchanged
Also writes random 10-bit calibration tensors and dataset.txt.
Usage: make_pipe_onnx.py identity|invert WIDTH HEIGHT OUTDIR
"""
import os
import sys

import numpy as np
import onnx
from onnx import TensorProto, helper

mode, w, h, out = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
os.makedirs(out, exist_ok=True)
# Tensor shape [1, H, W, 1]: memory order equals one frame plane.
shapes = {"y": [1, h, w, 1], "u": [1, h // 2, w // 2, 1],
    "v": [1, h // 2, w // 2, 1]}

inputs = [helper.make_tensor_value_info(p, TensorProto.FLOAT, s)
    for p, s in shapes.items()]
outputs = [helper.make_tensor_value_info(p + "_out", TensorProto.FLOAT, s)
    for p, s in shapes.items()]
nodes, inits = [], []
for p in shapes:
	if p == "y" and mode == "invert":
		inits.append(helper.make_tensor("max10", TensorProto.FLOAT, [1],
		    [1023.0]))
		nodes.append(helper.make_node("Sub", ["max10", "y"], ["y_out"]))
	else:
		nodes.append(helper.make_node("Relu", [p], [p + "_out"]))
graph = helper.make_graph(nodes, "pipe_" + mode, inputs, outputs, inits)
model = helper.make_model(graph,
    opset_imports=[helper.make_opsetid("", 11)])
onnx.checker.check_model(model)
onnx.save(model, os.path.join(out, "pipe_%s.onnx" % mode))

rng = np.random.default_rng(1)
with open(os.path.join(out, "dataset.txt"), "w") as f:
	for i in range(4):
		names = []
		for p, s in shapes.items():
			n = "calib_%d_%s.npy" % (i, p)
			np.save(os.path.join(out, n),
			    rng.integers(0, 1024, size=s).astype(np.float32))
			names.append(n)
		f.write(" ".join(names) + "\n")
