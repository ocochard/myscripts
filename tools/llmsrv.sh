#!/bin/sh
# Launch llama-server tuned for Framework Desktop (Strix Halo + RADV).
# Works on both hosts:
#   - framework  (FreeBSD 16-CURRENT, Mesa 24.1.7)
#   - framework2 (Ubuntu 24.04,      Mesa 25.2.8)
#
# Defaults to the Qwen3.6-35B-A3B MoE in coder (thinking) mode:
# ~4x faster than the dense 27B on this hardware (TG ~50 vs ~12 t/s,
# PP ~810 vs ~290 t/s at d=0). See FreeBSD/Framework-desktop.md and
# tools/LLM.benches.FrameWork-Desktop.md for the bench data.
#
# Usage:
#   ./llmsrv.sh                  # default: MoE 35B-A3B, coder mode
#   MODE=fast ./llmsrv.sh        # non-thinking, faster on simple tasks
#   MODEL=dense ./llmsrv.sh      # fall back to dense 27B (older quality cap)
#   MODEL=big ./llmsrv.sh        # Qwen3.5-397B-A17B IQ2_XXS (Ubuntu only)
#   MODEL=med ./llmsrv.sh        # Qwen3.5-122B-A10B Q4_K_XL (Ubuntu only)
#   HOST=0.0.0.0 ./llmsrv.sh     # listen on all interfaces (default: 127.0.0.1)
set -eu

MODE=${MODE:-coder}
MODEL=${MODEL:-moe}
HOST=${HOST:-127.0.0.1}
PORT=${PORT:-8080}

OS=$(uname -s)

# OS-specific setup
case "${OS}" in
  FreeBSD)
    kldstat -q -m amdgpu || sudo kldload amdgpu
    # RADV_DEBUG=zerovram: workaround for RADV/GFX1151 uninitialized-VRAM bug
    # in Mesa 24.1.7 that causes vk::DeviceLostError on first request.
    # ~1.5% pp cost. Not needed on Ubuntu's Mesa 25.2.8.
    radv_env="RADV_DEBUG=zerovram"
    # FreeBSD/Mesa 24.1.7 cannot use --no-mmap / --direct-io / quantized KV
    # (they wedge the GPU and require reboot).
    extra_perf=""
    ;;
  Linux)
    # Ubuntu Mesa 25.2.8 is healthy: no zerovram workaround needed.
    radv_env=""
    # On Ubuntu we *could* use --no-mmap and quantized KV, but bench shows
    # they're within noise on Vulkan — keep the conservative defaults that
    # match FreeBSD so behavior is identical across hosts.
    extra_perf=""
    ;;
  *)
    echo "unsupported OS='${OS}'" >&2; exit 1 ;;
esac

cd ~/llama.cpp

HF_HUB="${HOME}/.cache/huggingface/hub"

# Resolve a model file inside a HF cache repo by globbing its snapshots dir.
# HF stores blobs under hashed names; the human-readable filename only exists
# as a symlink in snapshots/<rev>/[subdir/]filename. The snapshot rev differs
# per host (framework vs framework2 fetched at different times), so glob it
# instead of hardcoding. Args: $1=repo dir, $2=relative path under snapshots/<rev>/.
# Echos resolved path or empty.
hf_resolve() {
  for f in "$1"/snapshots/*/$2; do
    [ -e "$f" ] && { echo "$f"; return; }
  done
  # Fallback: framework was hand-populated with named files under blobs/.
  [ -e "$1/blobs/$2" ] && echo "$1/blobs/$2"
}

case "${MODEL}" in
  moe)
    # Qwen3.6-35B-A3B: 35B total, 3B active per token. ~22 GB on disk.
    # Quality slightly below the dense 27B per Unsloth, but ~4x faster
    # per-token on this hardware. Available on both hosts.
    model=$(hf_resolve "${HF_HUB}/models--unsloth--Qwen3.6-35B-A3B-GGUF" "Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf")
    alias="Qwen3.6-35B-A3B-UD-Q4_K_XL"
    # --no-warmup: the default warmup decode (empty batch) hits
    # vk::DeviceLostError in ggml_vk_buffer_write_2d on this MoE.
    # Real prompts work fine; first real request serves as warmup.
    warmup_flag="--no-warmup"
    ;;
  dense)
    # Original 27B dense. Higher quality on hard reasoning, but ~4x slower.
    # Available on both hosts.
    model=$(hf_resolve "${HF_HUB}/models--unsloth--Qwen3.6-27B-GGUF" "Qwen3.6-27B-UD-Q4_K_XL.gguf")
    alias="Qwen3.6-27B-UD-Q4_K_XL"
    warmup_flag=""
    ;;
  med)
    # Qwen3.5-122B-A10B (MoE, 122B total / 10B active). Ubuntu only — not
    # downloaded on FreeBSD host.
    [ "${OS}" = "Linux" ] || { echo "MODEL=med only available on Ubuntu host" >&2; exit 1; }
    model=$(hf_resolve "${HF_HUB}/models--unsloth--Qwen3.5-122B-A10B-GGUF" "UD-Q4_K_XL/Qwen3.5-122B-A10B-UD-Q4_K_XL-00001-of-00003.gguf")
    alias="Qwen3.5-122B-A10B-UD-Q4_K_XL"
    warmup_flag="--no-warmup"
    ;;
  big)
    # Qwen3.5-397B-A17B IQ2_XXS (MoE, 397B total / 17B active). Ubuntu only.
    # Needs unified memory to fit the 128 GB UMA pool.
    [ "${OS}" = "Linux" ] || { echo "MODEL=big only available on Ubuntu host" >&2; exit 1; }
    model=$(hf_resolve "${HF_HUB}/models--unsloth--Qwen3.5-397B-A17B-GGUF" "UD-IQ2_XXS/Qwen3.5-397B-A17B-UD-IQ2_XXS-00001-of-00004.gguf")
    alias="Qwen3.5-397B-A17B-UD-IQ2_XXS"
    warmup_flag="--no-warmup"
    # Required to spill across the unified memory pool on Ubuntu.
    export GGML_CUDA_ENABLE_UNIFIED_MEMORY=ON
    ;;
  *)
    echo "unknown MODEL='${MODEL}' (use moe|dense|med|big)" >&2; exit 1 ;;
esac

[ -n "${model}" ] && [ -e "${model}" ] || {
  echo "model file for MODEL=${MODEL} not found under ${HF_HUB}" >&2
  echo "(checked snapshots/*/ and blobs/)" >&2
  exit 1
}

# Sampling presets (Qwen3 docs):
#   Thinking, general:  temp=1.0 top_p=0.95 top_k=20 min_p=0.0
#   Thinking, coding:   temp=0.6 top_p=0.95 top_k=20 min_p=0.0    <- mode=coder
#   Non-thinking:       temp=0.7 top_p=0.80 top_k=20 min_p=0.0    <- mode=fast
#                       presence=1.5
case "${MODE}" in
  coder)
    extra='--temperature 0.6 --top-p 0.95 --top-k 20 --min-p 0.0'
    ;;
  fast)
    # Non-thinking: skips reasoning entirely. On dense 27B this was 8.6x
    # faster on simple tasks. On MoE the gap is smaller (gen is already fast)
    # but still useful for routine edits / agent loops.
    extra='--temperature 0.7 --top-p 0.80 --top-k 20 --min-p 0.0 --presence-penalty 1.5 --reasoning-budget 0'
    ;;
  *)
    echo "unknown MODE='${MODE}' (use coder|fast)" >&2; exit 1 ;;
esac

# Notes on flags intentionally NOT set (see Framework-desktop.md):
# --no-mmap / --direct-io        : wedge the FreeBSD GPU; ~no benefit on Ubuntu
# --ctk q8_0 / --ctv q8_0        : crash Vulkan on FreeBSD; ~no benefit on Ubuntu
# --kv-unified                   : no effect for single-client (parallel slots only)
# --cache-reuse N                : Qwen3 uses M-RoPE; KV-shifting unsupported
# --batch-size 4096 / --ub 1024  : ~3% slower than 2048/512 on this build
# --ctx-size > 131072            : 131072 is the model native max RoPE length
# --parallel > 1                 : slots divide ctx; single-client gets full ctx with -p 1

exec env ${radv_env} build/bin/llama-server \
  --model "${model}" \
  --no-mmproj \
  ${warmup_flag} \
  --alias "${alias}" \
  --device Vulkan0 \
  --flash-attn on \
  --no-host \
  ${extra} \
  ${extra_perf} \
  --batch-size 2048 --ubatch-size 512 \
  --ctx-size 131072 --parallel 1 \
  --log-file /tmp/llama-server.log \
  --host "${HOST}" --port "${PORT}"
