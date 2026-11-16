#!/bin/sh
#
# NPU (FastFlowLM) versus iGPU (llama.cpp Vulkan) power, same model
# (Qwen3-8B, 4-bit), with npu-power-bench.py.  Same steps on FreeBSD
# (FastFlowLM in the linuxlator chroot) and Linux.
#
# Usage: npu-power-run.sh [runs]   (as the user owning the models; uses sudo)

set -eu

runs=${1:-3}
dir=$(dirname "$(realpath "$0")")
bench="sudo python3 $dir/npu-power-bench.py"
gguf=$HOME/models/Qwen3-8B-Q4_1.gguf
llama=$HOME/llama.cpp/build/bin/llama-server

wait_port() {
	i=0
	until curl -fs "http://127.0.0.1:$1/v1/models" >/dev/null 2>&1; do
		i=$((i + 1))
		[ $i -lt 150 ] || { echo "server on port $1 did not start" >&2; exit 1; }
		sleep 2
	done
	sleep 10	# let power settle after the model load
}

if [ "$(uname)" = FreeBSD ]; then
	flm_start() {
		sudo chroot /compat/ubuntu /bin/bash -c \
		    "cd /tmp; (flm serve $1 --port 52625 > /tmp/flm-serve.log 2>&1 &)"
	}
else
	# FastFlowLM needs more locked memory than the 8 MB default.
	sudo prlimit --memlock=unlimited:unlimited --pid $$
	flm_start() {
		(cd /tmp; nohup flm serve "$1" --port 52625 > /tmp/flm-serve.log 2>&1 &)
	}
fi

uname -sr
sleep 20
$bench --idle 30

flm_start qwen3:8b
wait_port 52625
$bench qwen3:8b 52625 "$runs" | sed 's/^/NPU /'
sudo pkill -x flm || :
sleep 20

for fa in on off; do
	(nohup "$llama" -m "$gguf" -ngl 99 -fa $fa -c 8192 --port 52626 \
	    > /tmp/llama-power.log 2>&1 &)
	wait_port 52626
	$bench qwen3-8b 52626 "$runs" | sed "s/^/iGPU fa=$fa /"
	pkill -x llama-server || :
	sleep 20
done
$bench --idle 30
