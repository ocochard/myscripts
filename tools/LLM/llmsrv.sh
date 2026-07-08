#!/bin/sh
# Launch llama-server tuned for Framework Desktop (Strix Halo + RADV).
# Works on all hosts:
#   - framework  (FreeBSD 16-CURRENT, Mesa 24.x or 25.x, Vulkan — auto-detected)
#   - framework2 (Ubuntu 24.04,       Mesa 25.2.8, Vulkan)
#   - mac        (macOS, Metal)
#
# Default: agents-a1-mtp (Agents-A1 Q8_0 + MTP speculative decoding). ~77 t/s TG
# at 4k on Strix Halo — Q8 weights + MTP beats plain Q4 (~66 t/s), and the
# Agents-A1 fine-tune is tuned for agentic reasoning + tool calling. See Stage 7
# in tools/LLM/benches.FrameWork-Desktop.md.
#
# Usage:
#   ./llmsrv.sh                  # default: Agents-A1-MTP Q8 (fast + high quality)
#   USAGE=coding ./llmsrv.sh     # alias for MODEL=agents-a1-mtp
#   USAGE=doc    ./llmsrv.sh     # alias for MODEL=moe-q8 (plain Q8, no MTP cliff risk)
#   MODEL=moe ./llmsrv.sh        # Qwen3.6-35B-A3B Q4 (older baseline; use only if 38 GB Q8 model too big)
#   MODEL=moe-q8 ./llmsrv.sh     # Qwen3.6-35B-A3B Q8 (plain, no MTP)
#   MODEL=dense ./llmsrv.sh      # dense 27B (higher quality but ~4x slower)
#   MODEL=mtp ./llmsrv.sh        # Qwen3.6-27B-MTP Q8 (havenoammo, dense MTP 2.4x)
#   MODEL=agents-a1 ./llmsrv.sh      # Agents-A1 Q4_K_M plain (no MTP)
#   MODEL=big ./llmsrv.sh        # Qwen3.5-397B-A17B IQ2_XXS
#   MODEL=med ./llmsrv.sh        # Qwen3.5-122B-A10B Q4_K_XL
#   HOST=0.0.0.0 ./llmsrv.sh     # listen on all interfaces (default: 127.0.0.1)
#   CTX=131072 ./llmsrv.sh       # extend ctx past 65536 (TTFT collapses past ~30k
#                                # on Strix Halo — see LLM.benches.FrameWork-Desktop.md)
#   JINJA=0 ./llmsrv.sh          # disable embedded jinja template (default is on)
#   LLAMA_DIR=~/llama-am17an ./llmsrv.sh   # override llama.cpp build dir
#                                          # (MTP needs llama.cpp >= b9878 — PR #22673
#                                          #  is in upstream master since 2026-06)
set -eu

usage() {
  cat <<EOF
Usage: [ENV=val ...] $(basename "$0") [-h]

Environment variables:
  USAGE=coding  Alias for MODEL=agents-a1-mtp (default coding recipe)
  USAGE=doc     Alias for MODEL=moe-q8 (plain Q8, safer for long-form prose)
  MODEL=agents-a1-mtp
                protoLabsAI Agents-A1-MTP Q8_0 (default — 77 t/s TG at 4k,
                Q8 MoE + speculative decoding, agentic fine-tune)
  MODEL=agents-a1
                InternScience Agents-A1 Q4_K_M (same fine-tune, plain Q4;
                slightly slower + noisier than MTP but half the disk)
  MODEL=moe     Qwen3.6-35B-A3B MoE Q4_K_XL (older Q4 baseline)
  MODEL=moe-q8  Qwen3.6-35B-A3B MoE Q8_K_XL (older Q8 baseline, no MTP)
  MODEL=dense   Qwen3.6-27B dense (higher quality but ~4x slower)
  MODEL=mtp     Qwen3.6-27B-MTP Q8_K_XL (havenoammo, dense multi-token-pred)
  MODEL=med     Qwen3.5-122B-A10B MoE
  MODEL=big     Qwen3.5-397B-A17B MoE
  HOST=addr     Listen address (default: 127.0.0.1)
  PORT=port     Listen port (default: 8080)
  CTX=N         --ctx-size (default: 65536 — Strix Halo working ceiling.
                TTFT collapses past d ~30k regardless of OS. Bump to 131072
                if you need the headroom and can accept the prefill cost.)
  LLAMA_DIR=dir llama.cpp build dir (default: ~/llama.cpp for all models;
                MTP requires llama.cpp >= b9878, in upstream master since 2026-06)
  JINJA=0       Disable --jinja (default is on — uses the GGUF's embedded
                chat template, routes <think> blocks into reasoning_content,
                and gives agent clients correct tool-call boundaries).
  DRY=1         Enable the DRY sampler. Targets structural repetition without
                punishing legitimate code-syntax repeats the way rep-penalty
                does. Try when the model loops on prose/code blocks.
  DRY_MULT=f    DRY multiplier      (default: 0.8; llama.cpp author-recommended)
  DRY_BASE=f    DRY base            (default: 1.75)
  DRY_ALLOWED=N DRY allowed length  (default: 4; llama.cpp default is 2)
EOF
  exit 0
}

[ "${1:-}" = "-h" ] && usage

# USAGE= is the naming used in LLM.benches.FrameWork-Desktop.md; translate to
# the MODEL= slots the rest of the script switches on. Explicit MODEL= wins.
if [ -n "${USAGE:-}" ] && [ -z "${MODEL:-}" ]; then
  case "${USAGE}" in
    coding) MODEL=agents-a1-mtp ;;   # Q8 MoE + MTP: 77 t/s TG at 4k, beats plain Q4
    doc)    MODEL=moe-q8         ;;  # plain Q8 (no MTP): better prose than Q4, no draft-cliff risk
    *) echo "unknown USAGE='${USAGE}' (use coding|doc)" >&2; exit 1 ;;
  esac
fi

MODEL=${MODEL:-agents-a1-mtp}
HOST=${HOST:-127.0.0.1}
PORT=${PORT:-8080}
CTX=${CTX:-65536}
JINJA=${JINJA:-1}
DRY=${DRY:-0}
DRY_MULT=${DRY_MULT:-0.8}
DRY_BASE=${DRY_BASE:-1.75}
DRY_ALLOWED=${DRY_ALLOWED:-4}

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
    # See tools/LLM/benches.FrameWork-Desktop.md for the bench data.
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

LLAMA_DIR=${LLAMA_DIR:-${HOME}/llama.cpp}

HF_HUB="${HOME}/.cache/huggingface/hub"

# Resolve a model file inside a HF cache repo by globbing its snapshots dir.
# HF stores blobs under hashed names; the human-readable filename only exists
# as a symlink in snapshots/<rev>/[subdir/]filename. The snapshot rev differs
# per host (framework vs framework2 fetched at different times), so glob it
# instead of hardcoding. Args: $1=repo dir, $2=relative path under snapshots/<rev>/.
# Echos resolved path or empty.
hf_resolve() {
  for f in "$1"/snapshots/*/$2; do
    [ -e "$f" ] && { echo "$f"; return 0; }
  done
  # Fallback: framework was hand-populated with named files under blobs/.
  [ -e "$1/blobs/$2" ] && echo "$1/blobs/$2"
  return 0
}

# --no-host: enables UMA-aware host-pointer path on Vulkan. On Strix Halo:
#   - MoE (35B-A3B Q4/Q8): safe and slightly faster on both OSes / Mesa versions.
#   - Dense (27B Q4):       crashes on FreeBSD (Mesa 24 and 25); OK on Ubuntu.
#   - Dense (27B Q8):       crashes on FreeBSD/Mesa 25 (regression vs Mesa 24);
#                           OK on Ubuntu.
# Default to no-host; cleared below for FreeBSD dense.
nohost_flag="--no-host"

# Per-model extras (chat-template flags etc.). Set inside cases as needed.
model_extra=""

case "${MODEL}" in
  moe)
    # Qwen3.6-35B-A3B Q4_K_XL: 35B total, 3B active per token. Available on
    # all hosts. Fast (~54 t/s TG at 4k), fine for code.
    # Prefer Q4_K_XL; fall back to Q4_K_M (only quant on macOS).
    hf_repo="unsloth/Qwen3.6-35B-A3B-GGUF"
    hf_dir="${HF_HUB}/models--unsloth--Qwen3.6-35B-A3B-GGUF"
    model=$(hf_resolve "${hf_dir}" "Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf")
    if [ -n "${model}" ]; then
      hf_file="Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf"
      alias="Qwen3.6-35B-A3B-UD-Q4_K_XL"
    else
      model=$(hf_resolve "${hf_dir}" "Qwen3.6-35B-A3B-UD-Q4_K_M.gguf")
      hf_file="Qwen3.6-35B-A3B-UD-Q4_K_M.gguf"
      alias="Qwen3.6-35B-A3B-UD-Q4_K_M"
    fi
    # --no-warmup: the default warmup decode (empty batch) hits
    # vk::DeviceLostError in ggml_vk_buffer_write_2d on this MoE (Vulkan).
    # Harmless on Metal. Real prompts work fine either way.
    warmup_flag="--no-warmup"
    ;;
  moe-q8)
    # Qwen3.6-35B-A3B Q8_K_XL: ~22% slower TG than Q4, better prose quality
    # (small 3B active path is more sensitive to quant noise; doc work has
    # no syntax-level error feedback). Available on all hosts.
    hf_repo="unsloth/Qwen3.6-35B-A3B-GGUF"
    hf_file="Qwen3.6-35B-A3B-UD-Q8_K_XL.gguf"
    model=$(hf_resolve "${HF_HUB}/models--unsloth--Qwen3.6-35B-A3B-GGUF" "${hf_file}")
    alias="Qwen3.6-35B-A3B-UD-Q8_K_XL"
    warmup_flag="--no-warmup"
    ;;
  dense)
    # Original 27B dense. Higher quality on hard reasoning, but ~4x slower.
    hf_repo="unsloth/Qwen3.6-27B-GGUF"
    hf_file="Qwen3.6-27B-UD-Q4_K_XL.gguf"
    model=$(hf_resolve "${HF_HUB}/models--unsloth--Qwen3.6-27B-GGUF" "${hf_file}")
    alias="Qwen3.6-27B-UD-Q4_K_XL"
    warmup_flag=""
    # Drop --no-host on FreeBSD: crashes 27B dense (Q4 always, Q8 on Mesa 25).
    [ "${OS}" = "FreeBSD" ] && nohost_flag=""
    ;;
  mtp)
    # Qwen3.6-27B-MTP (havenoammo): dense 27B fine-tuned with Multi-Token
    # Prediction heads + thinking traces. PR #22673 ("llama + spec: MTP Support")
    # is in upstream master since 2026-06; requires llama.cpp >= b9878. The
    # am17an fork's own MTP implementation has an incompatible tensor layout
    # and fails to load this GGUF with "missing tensor 'blk.64.ssm_conv1d.weight'".
    LLAMA_DIR=${LLAMA_DIR:-${HOME}/llama.cpp}
    hf_repo="havenoammo/Qwen3.6-27B-MTP-UD-GGUF"
    hf_file="Qwen3.6-27B-MTP-UD-Q8_K_XL.gguf"
    model=$(hf_resolve "${HF_HUB}/models--havenoammo--Qwen3.6-27B-MTP-UD-GGUF" "${hf_file}")
    alias="Qwen3.6-27B-MTP-UD-Q8_K_XL"
    warmup_flag=""
    # Same constraint as plain dense 27B on FreeBSD: --no-host crashes.
    [ "${OS}" = "FreeBSD" ] && nohost_flag=""
    # --jinja + preserve_thinking: keep the model's <think> traces in the
    # OpenAI-compatible chat completions (per the model card / friend's
    # working config). The embedded chat_template is used; no template
    # file needed.
    # --spec-type draft-mtp: enable MTP-based speculative decoding using the
    #   draft head embedded in the GGUF (no separate draft model needed).
    #   Added by PR #22673 ("spec: support MTP"). Renamed from `mtp` to
    #   `draft-mtp` in b9878 as part of the spec-type namespace cleanup.
    #   Whole point of this model.
    # --spec-draft-n-max 5: cap draft chain length. Default (16) regressed
    #   between b9124 and b9878 (~60 % slower decode on Strix Halo). N=5 is
    #   the measured peak on b9878 (16.2 t/s vs 10.0 at default). See
    #   LLM.benches.FrameWork-Desktop.md Stage 5 sweep.
    # NOT carrying over from friend's config on this hardware:
    #   -ctk q4_0 -ctv q4_0  : quantized KV crashes Vulkan on FreeBSD,
    #                          ~no benefit on Ubuntu (see Framework-desktop.md)
    #   --no-mmap            : wedges the FreeBSD GPU
    #   -t 6                 : threads irrelevant when fully GPU-offloaded
    #   --chat-template-file : friend's local file; this GGUF has it embedded
    model_extra='--jinja --chat-template-kwargs {"preserve_thinking":true} --spec-type draft-mtp --spec-draft-n-max 5'
    ;;
  agents-a1)
    # InternScience Agents-A1 Q4_K_M: agentic fine-tune of Qwen3.6-35B-A3B
    # (same qwen3_5_moe arch, 35B total / ~3B active). Same runtime shape as
    # MODEL=moe — expect ~50 t/s TG, ~900 PP at d~4k. 262k native RoPE ctx
    # but TTFT collapses past d~30k on Strix Halo (bandwidth-bound); keep
    # CTX at 65536 for daily use.
    hf_repo="InternScience/Agents-A1-Q4_K_M-GGUF"
    hf_file="Agents-A1-Q4_K_M.gguf"
    model=$(hf_resolve "${HF_HUB}/models--InternScience--Agents-A1-Q4_K_M-GGUF" "${hf_file}")
    alias="Agents-A1-Q4_K_M"
    warmup_flag="--no-warmup"
    ;;
  agents-a1-mtp)
    # protoLabsAI Agents-A1-MTP Q8_0: same weights as agents-a1 but with an
    # MTP head grafted in for speculative decoding. Q8_0 (~37.8 GB). Requires
    # llama.cpp >= b9878 (PR #22673). NVFP4 sibling in the repo is NVIDIA-only
    # (skip). MoE MTP acceptance is often lower than dense (~3B active path,
    # less predictable), so measure vs plain agents-a1 before adopting.
    hf_repo="protoLabsAI/Agents-A1-MTP-GGUF"
    hf_file="Agents-A1-MTP-Q8_0.gguf"
    model=$(hf_resolve "${HF_HUB}/models--protoLabsAI--Agents-A1-MTP-GGUF" "${hf_file}")
    alias="Agents-A1-MTP-Q8_0"
    warmup_flag="--no-warmup"
    # MoE + --no-host is safe on both OSes (unlike dense 27B on FreeBSD).
    model_extra='--jinja --spec-type draft-mtp --spec-draft-n-max 5'
    ;;
  med)
    # Qwen3.5-122B-A10B (MoE, 122B total / 10B active).
    [ "${OS}" = "Linux" ] || { echo "MODEL=med only available on Ubuntu host" >&2; exit 1; }
    hf_repo="unsloth/Qwen3.5-122B-A10B-GGUF"
    hf_file="UD-Q4_K_XL/Qwen3.5-122B-A10B-UD-Q4_K_XL-00001-of-00003.gguf"
    model=$(hf_resolve "${HF_HUB}/models--unsloth--Qwen3.5-122B-A10B-GGUF" "${hf_file}")
    alias="Qwen3.5-122B-A10B-UD-Q4_K_XL"
    warmup_flag="--no-warmup"
    ;;
  big)
    # Qwen3.5-397B-A17B IQ2_XXS (MoE, 397B total / 17B active).
    # Needs unified memory to fit the 128 GB UMA pool.
    [ "${OS}" = "Linux" ] || { echo "MODEL=big only available on Ubuntu host" >&2; exit 1; }
    hf_repo="unsloth/Qwen3.5-397B-A17B-GGUF"
    hf_file="UD-IQ2_XXS/Qwen3.5-397B-A17B-UD-IQ2_XXS-00001-of-00004.gguf"
    model=$(hf_resolve "${HF_HUB}/models--unsloth--Qwen3.5-397B-A17B-GGUF" "${hf_file}")
    alias="Qwen3.5-397B-A17B-UD-IQ2_XXS"
    warmup_flag="--no-warmup"
    # Required to spill across the unified memory pool on Ubuntu.
    export GGML_CUDA_ENABLE_UNIFIED_MEMORY=ON
    ;;
  *)
    echo "unknown MODEL='${MODEL}' (use moe|moe-q8|dense|mtp|agents-a1|agents-a1-mtp|med|big)" >&2; exit 1 ;;
esac

# If the file isn't in the HF cache, hand off to llama-server's -hf/-hff so it
# downloads on first run. Skip --model in that case (-hf is mutually exclusive).
if [ -n "${model}" ] && [ -e "${model}" ]; then
  model_src="--model ${model}"
else
  echo "model file not cached under ${HF_HUB}; downloading via -hf ${hf_repo} -hff ${hf_file}" >&2
  model_src="-hf ${hf_repo} -hff ${hf_file}"
fi

# Sampling preset: Qwen3 thinking-coder (per Qwen3 docs).
# Non-thinking mode was removed — on MoE the gen-time savings are small
# and quality drops. For mechanical agent loops, just use a smaller
# n_predict / inline `/no_think` in the prompt instead.
extra='--temperature 0.6 --top-p 0.95 --top-k 20 --min-p 0.0'

# Opt-in loop-mitigation flags. Both default off so bench numbers stay
# comparable to prior runs; enable per-session when a client is looping.
extra_sampler=""
[ "${DRY}" = "1" ] && \
  extra_sampler="--dry-multiplier ${DRY_MULT} --dry-base ${DRY_BASE} --dry-allowed-length ${DRY_ALLOWED}"

# --jinja uses the GGUF's embedded chat template instead of llama.cpp's
# built-in guesser. Required for correct tool-call parsing with agent
# clients (qwen-code, aider). mtp already sets it via model_extra; skip
# to avoid duplicate flag.
jinja_flag=""
case "${MODEL}" in
  mtp|agents-a1-mtp) ;;  # already set in model_extra
  *) [ "${JINJA}" = "1" ] && jinja_flag="--jinja" ;;
esac

# Notes on flags intentionally NOT set (see Framework-desktop.md):
# --no-mmap / --direct-io        : wedge the FreeBSD GPU; ~no benefit on Ubuntu
# --ctk q8_0 / --ctv q8_0        : crash Vulkan on FreeBSD; ~no benefit on Ubuntu
# --kv-unified                   : no effect for single-client (parallel slots only)
# --cache-reuse N                : Qwen3 uses M-RoPE; KV-shifting unsupported
# --batch-size 4096 / --ub 1024  : ~3% slower than 2048/512 on this build
# --ctx-size > 131072            : 131072 is the model native max RoPE length
# --parallel > 1                 : slots divide ctx; single-client gets full ctx with -p 1

cd "${LLAMA_DIR}"

exec env ${radv_env} build/bin/llama-server \
  ${model_src} \
  --no-mmproj \
  ${warmup_flag} \
  --alias "${alias}" \
  --device "${device}" \
  --flash-attn on \
  ${nohost_flag} \
  ${extra} \
  ${extra_sampler} \
  ${jinja_flag} \
  ${extra_perf} \
  ${model_extra} \
  --batch-size 2048 --ubatch-size 512 \
  --ctx-size "${CTX}" --parallel 1 \
  --log-file /tmp/llama-server.log \
  --host "${HOST}" --port "${PORT}"
