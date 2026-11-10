#!/bin/bash
# Compile pipe_<mode>.onnx to an int16 NBG for Quadra. Run in netint-ai:4.5.
# Usage: convert.sh identity|invert WIDTH HEIGHT
set -euo pipefail
MODE=$1 W=$2 H=$3
NAME=pipe_${MODE}
pegasus=${ACUITY_PATH}/pegasus.py
SIZES="${H},${W},1#$((H/2)),$((W/2)),1#$((H/2)),$((W/2)),1"

# pegasus quantize reuses an existing .quantize file: start clean.
rm -f ${NAME}_${W}x${H}_int16.nb ${NAME}.quantize
python3 make_pipe_onnx.py "$MODE" "$W" "$H" .
${pegasus} import onnx --model ${NAME}.onnx --inputs 'y u v' \
	--outputs 'y_out u_out v_out' --input-size-list "$SIZES" \
	--output-model ${NAME}.json \
	--output-data ${NAME}.data
${pegasus} generate inputmeta --model ${NAME}.json \
	--input-meta-output ${NAME}_inputmeta.yml
# Calibration tensors are .npy files, not images (TEXT database: one line per sample, one file per input).
sed -i -e 's/category: image/category: undefined/' \
	${NAME}_inputmeta.yml
${pegasus} quantize --model ${NAME}.json --model-data ${NAME}.data \
	--with-input-meta ${NAME}_inputmeta.yml --algorithm normal \
	--iterations 4 --device CPU \
	--quantizer dynamic_fixed_point --qtype int16 2>&1 | tee quantize.log
# The quantizer skips some tensors (an input feeding Sub with a constant),
# which then export as fp16. Add them as int16.
for t in $(sed -n 's/.*Tensor \(@[^ ]*\) type: float32.*/\1/p' quantize.log | sort -u); do
	grep -qF "'$t'" ${NAME}.quantize ||
	    sed -i "/^quantize_parameters:/a\\  '$t':\\n    qtype: i16\\n    quantizer: dynamic_fixed_point\\n    rounding: rtne\\n    fl: 0" ${NAME}.quantize
done
# Integer 10-bit samples: no fraction bits anywhere (fl: 0).
sed -i 's/^\(\s*fl:\).*/\1 0/' ${NAME}.quantize
${pegasus} export ovxlib --model ${NAME}.json --model-data ${NAME}.data \
	--with-input-meta ${NAME}_inputmeta.yml \
	--output-path ovx_network/${NAME} --pack-nbg-unify \
	--optimize VIP8000NANOQI_PLUS_PID0XB1 --viv-sdk ${VIVANTE_SDK_DIR} \
	--batch-size 1 --dtype quantized --model-quantize ${NAME}.quantize
cp ovx_network_nbg_unify/network_binary.nb ${NAME}_${W}x${H}_int16.nb
