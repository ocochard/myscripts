#!/bin/bash
# Compile tonemap_<W>x<H>.onnx (train_tonemap.py --arch fused) to an int16
# NBG for Quadra. Run in
# netint-ai:4.5, in a directory holding the .onnx and the calibration files
# from make_calib.py (dataset.txt).
# Usage: convert_tonemap.sh WIDTH HEIGHT
set -euo pipefail
W=$1 H=$2
NAME=tonemap_${W}x${H}
# QUANT="--quantizer asymmetric_affine --qtype uint8" for a uint8 build (speed tests).
QUANT=${QUANT:---quantizer dynamic_fixed_point --qtype int16}
# HYBRID=1: uint8 for the hidden layers (convolutions fed by a ReLU that feed
# a ReLU, and the ReLUs), int16 for everything else. HYBRID=2: the first
# convolution too (its 10-bit input is then quantized to 8 bits).
HYBRID=${HYBRID:-}
[ -n "$HYBRID" ] && QUANT="--quantizer asymmetric_affine --qtype uint8"
pegasus=${ACUITY_PATH}/pegasus.py
SIZES="${H},${W},1#$((H/2)),$((W/2)),1#$((H/2)),$((W/2)),1"

# pegasus quantize reuses an existing .quantize file: start clean.
rm -f ${NAME}_int16.nb ${NAME}.quantize
${pegasus} import onnx --model ${NAME}.onnx --inputs 'y u v' \
	--outputs 'y_out u_out v_out' --input-size-list "$SIZES" \
	--output-model ${NAME}.json --output-data ${NAME}.data
${pegasus} generate inputmeta --model ${NAME}.json \
	--input-meta-output ${NAME}_inputmeta.yml
# Calibration tensors are .npy files, not images (TEXT database: one line
# per sample, one file per input).
sed -i -e 's/category: image/category: undefined/' ${NAME}_inputmeta.yml
${pegasus} quantize --model ${NAME}.json --model-data ${NAME}.data \
	--with-input-meta ${NAME}_inputmeta.yml --algorithm normal \
	--iterations "$(wc -l < dataset.txt)" --device CPU \
	$QUANT 2>&1 | tee quantize.log
if [ -n "$HYBRID" ]; then
	python3 - ${NAME}.json ${NAME}.quantize $HYBRID <<'PY'
import json, sys
layers = json.load(open(sys.argv[1]))["Layers"]
src = {n: [i.split(":")[0][1:] for i in l.get("inputs", [])]
    for n, l in layers.items()}
feeds_relu = {i for n, l in layers.items() if l["op"] == "relu" for i in src[n]}
u8 = {n for n, l in layers.items() if l["op"] == "relu" or (
    l["op"] == "convolution" and n in feeds_relu and
    (sys.argv[3] == "2" or any(layers[i]["op"] == "relu" for i in src[n])))}
i16 = sorted(n for n, l in layers.items() if n not in u8)
p = sys.argv[2]
s = open(p).read()
s = s.replace("customized_quantize_layers: {}", "customized_quantize_layers:\n" +
    "".join("  %s: dynamic_fixed_point-i16\n" % n for n in i16))
open(p, "w").write(s)
print("uint8 layers:", " ".join(sorted(u8)))
PY
	${pegasus} quantize --model ${NAME}.json --model-data ${NAME}.data \
		--with-input-meta ${NAME}_inputmeta.yml --algorithm normal \
		--iterations "$(wc -l < dataset.txt)" --device CPU \
		--model-quantize ${NAME}.quantize --hybrid 2>&1 | tee -a quantize.log
	# The hybrid graph, with the inserted dtype converters, is a new file.
	MODEL=${NAME}.quantize.json
fi
MODEL=${MODEL:-${NAME}.json}
# Tensors the quantizer skipped would export as fp16: add them as int16.
for t in $(sed -n 's/.*Tensor \(@[^ ]*\) type: float32.*/\1/p' quantize.log | sort -u); do
	grep -qF "'$t'" ${NAME}.quantize ||
	    sed -i "/^quantize_parameters:/a\\  '$t':\\n    qtype: i16\\n    quantizer: dynamic_fixed_point\\n    rounding: rtne\\n    fl: 0" ${NAME}.quantize
done
# Frame planes in and out are integer 10-bit samples: fl 0 on the inputs
# and the outputs, and on every layer between them and the first or last
# real convolution: reshape, permute, concat and slice do not convert, so
# their fl must match; the fixed space-to-depth (stride 2) and depth-to-space
# (deconvolution) layers move integer samples. Internal tensors keep the
# fraction bits the quantizer chose.
python3 - $MODEL ${NAME}.quantize <<'PY'
import json, re, sys
layers = json.load(open(sys.argv[1]))["Layers"]
src = {n: [i.split(":")[0][1:] for i in l.get("inputs", [])]
    for n, l in layers.items()}
dst = {}
for n, ins in src.items():
	for i in ins:
		dst.setdefault(i, []).append(n)
def forward(n):
	l = layers[n]
	return l["op"] in ("reshape", "permute", "concat") or (
	    l["op"] == "convolution" and l["parameters"].get("stride_h") == 2
	    and l["parameters"].get("weights") == 4)
zero = set()
todo = [n for n, l in layers.items() if l["op"] == "input"]
while todo:
	n = todo.pop()
	zero.add(n)
	todo += [d for d in dst.get(n, []) if forward(d)]
backward = ("output", "reshape", "permute", "slice", "deconvolution")
todo = [n for n, l in layers.items() if l["op"] == "output"]
while todo:
	n = todo.pop()
	zero.add(n)
	if layers[n]["op"] in backward:
		todo += src[n]
p = sys.argv[2]
lines = open(p).read().split("\n")
key = None
for i, l in enumerate(lines):
	m = re.match(r"  '@([^':]+):out0':", l)
	if m or re.match(r"  '", l):
		key = m.group(1) if m else None
	elif key in zero and l.strip().startswith("fl:"):
		lines[i] = "    fl: 0"
		print("fl 0:", key)
open(p, "w").write("\n".join(lines))
PY
${pegasus} export ovxlib --model $MODEL --model-data ${NAME}.data \
	--with-input-meta ${NAME}_inputmeta.yml \
	--output-path ovx_network/${NAME} --pack-nbg-unify \
	--optimize VIP8000NANOQI_PLUS_PID0XB1 --viv-sdk ${VIVANTE_SDK_DIR} \
	--batch-size 1 --dtype quantized --model-quantize ${NAME}.quantize
cp ovx_network_nbg_unify/network_binary.nb ${NAME}_int16.nb
