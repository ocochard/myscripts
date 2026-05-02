#!/bin/sh
# Launch llama-server tuned for Framework Desktop (Strix Halo + RADV).
# Works on all hosts:
#   - framework  (FreeBSD 16-CURRENT, Mesa 24.x or 25.x, Vulkan — auto-detected)
#   - framework2 (Ubuntu 24.04,       Mesa 25.2.8, Vulkan)
#   - mac        (macOS, Metal)
#
# Defaults to the Qwen3.6-35B-A3B MoE with thinking-coder sampling:
# ~4x faster than the dense 27B on this hardware (TG ~50 vs ~12 t/s,
# PP ~810 vs ~290 t/s at d=0). See FreeBSD/Framework-desktop.md and
# tools/LLM.benches.FrameWork-Desktop.md for the bench data.
#
# Usage:
#   ./llmsrv.sh                  # default: MoE 35B-A3B Q4 (coding)
#   USAGE=doc ./llmsrv.sh        # MoE 35B-A3B Q8 (better prose for docs)
#   MODEL=dense ./llmsrv.sh      # fall back to dense 27B (older quality cap)
#   MODEL=big ./llmsrv.sh        # Qwen3.5-397B-A17B IQ2_XXS (Ubuntu only)
#   MODEL=med ./llmsrv.sh        # Qwen3.5-122B-A10B Q4_K_XL (Ubuntu only)
#   HOST=0.0.0.0 ./llmsrv.sh     # listen on all interfaces (default: 127.0.0.1)
set -eu

usage() {
  cat <<EOF
Usage: [ENV=val ...] $(basename "$0") [-h]

Environment variables:
  MODEL=moe    Qwen3.6-35B-A3B MoE (default)
  MODEL=dense  Qwen3.6-27B dense
  MODEL=med    Qwen3.5-122B-A10B MoE (Ubuntu only)
  MODEL=big    Qwen3.5-397B-A17B MoE (Ubuntu only)
  USAGE=coding MoE: Q4_K_XL (default — fast, fine for code)
  USAGE=doc    MoE: Q8_K_XL (slower decode, better prose for documentation)
  HOST=addr    Listen address (default: 127.0.0.1)
  PORT=port    Listen port (default: 8080)
EOF
  exit 0
}

[ "${1:-}" = "-h" ] && usage

MODEL=${MODEL:-moe}
USAGE=${USAGE:-coding}
HOST=${HOST:-127.0.0.1}
PORT=${PORT:-8080}

case "${USAGE}" in
  coding|doc) ;;
  *) echo "unknown USAGE='${USAGE}' (use coding|doc)" >&2; exit 1 ;;
esac

OS=$(uname -s)

# OS-specific setup
case "${OS}" in
  FreeBSD)
    kldstat -q -m amdgpu || sudo kldload amdgpu
    # Mesa-version-dependent RADV behaviour on Strix Halo / gfx1151:
    #   Mesa 24.x: RADV_DEBUG=zerovram is REQUIRED — without it the first
    #              llama-server request crashes with vk::DeviceLostError
    #              in ggml_vk_buffer_write_2d. ~1.5% pp cost.
    #   Mesa 25.x: RADV_DEBUG=zerovram is HARMFUL — it crashes runs that
    #              succeed without it. First-run-after-boot is reliable
    #              with no env prefix.
    # See tools/LLM.benches.FrameWork-Desktop.md for the bench data.
    mesa_ver=$(pkg query %v mesa-libs 2>/dev/null | cut -d. -f1)
    if [ "${mesa_ver}" = "24" ]; then
      radv_env="RADV_DEBUG=zerovram"
    else
      # 25+ (current) or unknown — assume current behaviour, no env.
      radv_env=""
    fi
    extra_perf=""
    device="Vulkan0"
    ;;
  Linux)
    # Ubuntu Mesa 25.2.8 is healthy: no zerovram workaround needed.
    radv_env=""
    # On Ubuntu we *could* use --no-mmap and quantized KV, but bench shows
    # they're within noise on Vulkan — keep the conservative defaults that
    # match FreeBSD so behavior is identical across hosts.
    extra_perf=""
    device="Vulkan0"
    ;;
  Darwin)
    # macOS: Metal backend, no Vulkan/RADV env needed.
    radv_env=""
    extra_perf=""
    device="MTL0"
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

# --no-host: enables UMA-aware host-pointer path on Vulkan. On Strix Halo:
#   - MoE (35B-A3B Q4/Q8): safe and slightly faster on both OSes / Mesa versions.
#   - Dense (27B Q4):       crashes on FreeBSD (Mesa 24 and 25); OK on Ubuntu.
#   - Dense (27B Q8):       crashes on FreeBSD/Mesa 25 (regression vs Mesa 24);
#                           OK on Ubuntu.
# Default to no-host; cleared below for FreeBSD dense.
nohost_flag="--no-host"

case "${MODEL}" in
  moe)
    # Qwen3.6-35B-A3B: 35B total, 3B active per token. Available on all hosts.
    # Quant choice driven by USAGE:
    #   coding (default): Q4_K_XL — fast (~54 t/s TG at 4k), fine for code.
    #   doc:              Q8_K_XL — ~22% slower TG, better prose quality
    #                     (small 3B active path is more sensitive to quant
    #                     noise; doc work has no syntax-level error feedback).
    if [ "${USAGE}" = "doc" ]; then
      model=$(hf_resolve "${HF_HUB}/models--unsloth--Qwen3.6-35B-A3B-GGUF" "Qwen3.6-35B-A3B-UD-Q8_K_XL.gguf")
      alias="Qwen3.6-35B-A3B-UD-Q8_K_XL"
    else
      # coding: prefer Q4_K_XL; fall back to Q4_K_M (only quant on macOS).
      model=$(hf_resolve "${HF_HUB}/models--unsloth--Qwen3.6-35B-A3B-GGUF" "Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf")
      if [ -n "${model}" ]; then
        alias="Qwen3.6-35B-A3B-UD-Q4_K_XL"
      else
        model=$(hf_resolve "${HF_HUB}/models--unsloth--Qwen3.6-35B-A3B-GGUF" "Qwen3.6-35B-A3B-UD-Q4_K_M.gguf")
        alias="Qwen3.6-35B-A3B-UD-Q4_K_M"
      fi
    fi
    # --no-warmup: the default warmup decode (empty batch) hits
    # vk::DeviceLostError in ggml_vk_buffer_write_2d on this MoE (Vulkan).
    # Harmless on Metal. Real prompts work fine either way.
    warmup_flag="--no-warmup"
    ;;
  dense)
    # Original 27B dense. Higher quality on hard reasoning, but ~4x slower.
    # Available on both hosts.
    model=$(hf_resolve "${HF_HUB}/models--unsloth--Qwen3.6-27B-GGUF" "Qwen3.6-27B-UD-Q4_K_XL.gguf")
    alias="Qwen3.6-27B-UD-Q4_K_XL"
    warmup_flag=""
    # Drop --no-host on FreeBSD: crashes 27B dense (Q4 always, Q8 on Mesa 25).
    [ "${OS}" = "FreeBSD" ] && nohost_flag=""
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

# Sampling preset: Qwen3 thinking-coder (per Qwen3 docs).
# Non-thinking mode was removed — on MoE the gen-time savings are small
# and quality drops. For mechanical agent loops, just use a smaller
# n_predict / inline `/no_think` in the prompt instead.
extra='--temperature 0.6 --top-p 0.95 --top-k 20 --min-p 0.0'

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
  --device "${device}" \
  --flash-attn on \
  ${nohost_flag} \
  ${extra} \
  ${extra_perf} \
  --batch-size 2048 --ubatch-size 512 \
  --ctx-size 131072 --parallel 1 \
  --log-file /tmp/llama-server.log \
  --host "${HOST}" --port "${PORT}"
