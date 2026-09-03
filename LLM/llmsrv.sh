#!/bin/sh
# Launch llama-server tuned for Framework Desktop (Strix Halo + RADV).
# Works on all hosts:
#   - framework  (FreeBSD 16-CURRENT, Mesa 24.x or 25.x, Vulkan — auto-detected)
#   - framework2 (Ubuntu 24.04,       Mesa 25.2.8, Vulkan)
#   - mac        (macOS, Metal)
#
# Default: qwen38-mtp (Qwen3.8-27B dense Q8_0 + Q8_0 sidecar MTP draft head,
# both from ggml-org/Qwen3.8-27B-GGUF). Best FreeBSD-source doc accuracy in the
# DaemonDocs quality bench, with speculative decoding on top. The MTP draft
# path is UNVERIFIED on FreeBSD/Mesa 26 — see the WARNING on the slot below and
# fall back to MODEL=qwen38-q8 if cold starts report 0.00 draft acceptance.
#
# Usage:
#   ./llmsrv.sh                  # default: qwen38-mtp (Q8 dense + Q8 MTP head)
#   USAGE=coding ./llmsrv.sh     # alias for MODEL=qwen38-mtp
#   USAGE=doc    ./llmsrv.sh     # alias for MODEL=qwen38-q8 (spec-off fallback)
#   MODEL=qwen38-q8 ./llmsrv.sh  # Qwen3.8-27B dense Q8, no MTP (DaemonDocs
#                                #   production recipe; see
#                                #   benches.DaemonDocs-model-quality.md)
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
Usage: [ENV=val ...] $(basename "$0") [-h|--help]

Environment variables:
  USAGE=coding  Alias for MODEL=qwen38-mtp (default)
  USAGE=doc     Alias for MODEL=qwen38-q8 (spec-off fallback)
  MODEL=qwen38-mtp
                DEFAULT. Qwen3.8-27B dense Q8_0 + Q8_0 sidecar MTP draft head
                (ggml-org). Speculative decoding; acceptance UNMEASURED for
                this Q8/Q8 pairing and the draft path is unverified on
                FreeBSD/Mesa 26. See the slot comment before relying on it.
  MODEL=qwen38-q8
                Qwen3.8-27B dense Q8_K_XL (unsloth), no MTP. Best
                FreeBSD-source doc accuracy in the DaemonDocs quality bench,
                and the fallback when the MTP draft path misbehaves.
  HOST=addr     Listen address (default: 127.0.0.1)
  PORT=port     Listen port (default: 8080)
  CTX=N         --ctx-size (default: 131072 — practical sweet spot on Strix
                Halo, and the Qwen3.8-27B base maximum; raising past it needs
                RoPE scaling — TG/PP are functions of filled depth, not the
                ceiling. Cost is entirely cold-prefill: ~4 s at 4k, ~40 s at
                32k, ~5 min at 128k, ~20 min at 256k. Drop to 65536 for a
                smaller KV footprint if you never work past ~30 k prompts.
                See benches.FrameWork-Desktop.md.)
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

case "${1:-}" in -h|--help|help) usage ;; esac

# USAGE= is the naming used in LLM.benches.FrameWork-Desktop.md; translate to
# the MODEL= slots the rest of the script switches on. Explicit MODEL= wins.
if [ -n "${USAGE:-}" ] && [ -z "${MODEL:-}" ]; then
  case "${USAGE}" in
    coding) MODEL=qwen38-mtp ;;   # Q8 dense + Q8 sidecar MTP head (default)
    doc)    MODEL=qwen38-q8  ;;   # spec-off fallback (unsloth Q8_K_XL)
    *) echo "unknown USAGE='${USAGE}' (use coding|doc)" >&2; exit 1 ;;
  esac
fi

MODEL=${MODEL:-qwen38-mtp}
HOST=${HOST:-127.0.0.1}
PORT=${PORT:-8080}
CTX=${CTX:-131072}
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
    # See LLM/benches.FrameWork-Desktop.md for the bench data.
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
  qwen38-mtp)
    # DEFAULT. Qwen3.8-27B dense (ggml-org), Q8_0 target + Q8_0 SIDECAR MTP
    # draft head (mtp-Qwen3.8-27B-Q8_0.gguf) passed via --model-draft — not
    # embedded like the Agents-A1 models. Both files come from the same repo.
    #
    # This is NOT the pairing benched on 2026-08-15. That run used the Q4
    # pair (Q4_K_M target + q4_0 head) and measured only ~34% draft
    # acceptance, which the bench attributed to the weak Q4/q4_0 match and
    # named a higher-precision head as the fix. This slot is that fix; the
    # acceptance number is therefore UNMEASURED, not ~34%.
    #
    # STILL UNVERIFIED on FreeBSD/Mesa 26: the same bench recorded a RADV
    # GPUVM fault in the draft-mtp dispatch path — `[gfxhub] page fault`,
    # client ID CPC (0x5), then `ring comp_1.x.0 timeout` and
    # ErrorDeviceLost — on a coin-flip of cold starts. It reproduced with an
    # unrelated model too, so it tracks the MTP-on code path, not this GGUF,
    # and it is a Mesa 26 regression (identical binary+GGUF is clean on
    # Mesa 25 / Ubuntu). Quant does not affect it. On a dead load every
    # drafted token is wasted verify compute and throughput falls BELOW
    # spec-off (7.3 t/s vs 11.2 baseline at N=5).
    #
    # So: watch the server log's "draft acceptance = 0.xx" line on every
    # cold start on framework. If it reads 0.00000, restart; if it keeps
    # faulting, fall back to MODEL=qwen38-q8 (spec-off; note that is a
    # different repo and quant, unsloth Q8_K_XL, not these weights).
    hf_repo="ggml-org/Qwen3.8-27B-GGUF"
    hf_file="Qwen3.8-27B-Q8_0.gguf"
    hf_draft="mtp-Qwen3.8-27B-Q8_0.gguf"
    hf_dir="${HF_HUB}/models--ggml-org--Qwen3.8-27B-GGUF"
    model=$(hf_resolve "${hf_dir}" "${hf_file}")
    draft=$(hf_resolve "${hf_dir}" "${hf_draft}")
    alias="Qwen3.8-27B-Q8_0-MTP"
    warmup_flag=""
    # Dense 27B on FreeBSD: --no-host crashes (same class as 3.6 dense).
    [ "${OS}" = "FreeBSD" ] && nohost_flag=""
    if [ -z "${draft}" ] || [ ! -e "${draft}" ]; then
      echo "draft head ${hf_draft} not cached under ${hf_dir}" >&2
      echo "fetch it, or run MODEL=qwen38-q8 for the spec-off fallback" >&2
      exit 1
    fi
    model_extra="--jinja --model-draft ${draft} --spec-type draft-mtp --spec-draft-n-max 4"
    ;;
  qwen38-q8)
    # Spec-off fallback for the default, and the DaemonDocs production recipe.
    # Note this is a DIFFERENT repo+quant from qwen38-mtp: unsloth Q8_K_XL vs
    # ggml-org Q8_0. Keep it — when the MTP path dead-loads on FreeBSD this is
    # the one-env-var recovery, and DaemonDocs runs are graded on accuracy.
    hf_repo="unsloth/Qwen3.8-27B-GGUF"
    hf_file="Qwen3.8-27B-UD-Q8_K_XL.gguf"
    model=$(hf_resolve "${HF_HUB}/models--unsloth--Qwen3.8-27B-GGUF" "${hf_file}")
    alias="Qwen3.8-27B-UD-Q8_K_XL"
    warmup_flag=""
    [ "${OS}" = "FreeBSD" ] && nohost_flag=""
    ;;
  *)
    echo "unknown MODEL='${MODEL}' (use qwen38-mtp|qwen38-q8)" >&2; exit 1 ;;
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
  qwen38-mtp) ;;  # already set in model_extra
  *) [ "${JINJA}" = "1" ] && jinja_flag="--jinja" ;;
esac

# Notes on flags intentionally NOT set (see Framework-desktop.md):
# --no-mmap / --direct-io        : wedge the FreeBSD GPU; ~no benefit on Ubuntu
# --ctk q8_0 / --ctv q8_0        : crash Vulkan on FreeBSD; ~no benefit on Ubuntu
# --kv-unified                   : no effect for single-client (parallel slots only)
# --cache-reuse N                : Qwen3 uses M-RoPE; KV-shifting unsupported
# --batch-size 4096 / --ub 1024  : ~3% slower than 2048/512 on this build
# --ctx-size > 131072            : Qwen3.8-27B base max is 131072; going past it
#                                  needs RoPE scaling. Cold prefill is the cost:
#                                  ~40 s at 32k, ~5 min at 128k on Strix Halo —
#                                  see benches.FrameWork-Desktop.md.
# --parallel > 1                 : slots divide ctx; single-client gets full ctx with -p 1

cd "${LLAMA_DIR}"

exec env ${radv_env} build/bin/llama-server \
  ${model_src} \
  --no-mmproj \
  ${warmup_flag} \
  --alias "${alias}" \
  --device "${device}" \
  --metrics \
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
