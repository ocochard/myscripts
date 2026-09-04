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
  MODEL=flashnext
                Qwen3.8-Flash-Next 125B/6B-active MoE, UD-IQ3_XXS (82 GB) +
                shared-Q8_0 MTP head at N=2. ~37/35 t/s Total TPS at ~4 k,
                acceptance 0.74-0.84. REQUIRES ~/llama.cpp-mtp built from
                llama.cpp PR #28243 (still open — mainline has no qwen4exp MTP
                graph); forces LLAMA_DIR and lowers CTX to 32768. Do not
                substitute a bigger quant: IQ4_XS (93.7 GB) cannot load the
                draft head at all. MTP is flaky on FreeBSD (Mesa 26 RADV).
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
# Remember whether the caller set CTX explicitly: a slot may need a lower
# ceiling than the 131072 default (flashnext), but must not silently override
# a value the caller asked for.
CTX_EXPLICIT=${CTX:+1}
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
  flashnext)
    # Qwen3.8-Flash-Next, 125B/6B-active `qwen4exp` MoE, UD-IQ3_XXS (82 GB) +
    # the shared-Q8_0 sidecar MTP head. ~37 t/s Total TPS at ~4 k on FreeBSD
    # (35 on Ubuntu) with N=2, draft acceptance 0.74-0.84.
    #
    # THREE hard requirements, all of them load-time failures if unmet:
    #
    # 1. NEEDS ~/llama.cpp-mtp, NOT the default ~/llama.cpp. Mainline has no
    #    MTP graph for qwen4exp; llama.cpp PR #28243 (`qwen4exp/mtp`) adds it
    #    and is still OPEN. Mainline accepts --spec-type draft-mtp as a FLAG
    #    (it exists for other archs) and then fails on a missing tensor, so a
    #    successful --help proves nothing. LLAMA_DIR is forced below.
    # 2. IQ3_XXS (82 GB), NOT IQ4_XS (93.7 GB). One quant step up and the
    #    draft head cannot load at ANY --ctx-size: 93.7 GB resident leaves the
    #    driver unable to fund a second model's command submission
    #    (`radv/amdgpu: Not enough memory for command submission` →
    #    ErrorDeviceLost). Q8_0 is 192 GB and never fits 128 GB UMA.
    # 3. CTX must stay low. 32768 is proven with MTP on; 65536 is proven
    #    spec-off (benched: holds a real 32 919-token prompt on both hosts).
    #    The script-wide 131072 default does NOT fit here, so this slot
    #    overrides CTX unless the caller set it explicitly.
    #    CTX=65536 with MTP on is BENCHED GOOD on both hosts (loads clean;
    #    29.6/27.6 Total TPS at ~32 k vs 21.8/20.6 spec-off — the MTP gain
    #    actually widens with depth, +36 %/+34 %, and acceptance holds at
    #    0.77-0.79). The cost is cold TTFT only: ~118 s (FreeBSD) / ~135 s
    #    (Ubuntu) to first token at ~32 k of filled depth, since prefill runs
    #    at ~280 t/s and MTP does not accelerate prefill. Raise CTX to 65536
    #    when you work at depth across many warm turns; keep 32768 for
    #    interactive use where cold TTFT dominates.
    #
    # FreeBSD caveat: MTP is flaky here, NOT unusable. 2 of 6 N values faulted
    # in the bench with the Mesa-26 RADV compute-write fingerprint already
    # documented for qwen38-mtp (`[gfxhub] page fault`, client ID CPC (0x5),
    # `ring comp_1.1.0 timeout`). N=2 and N=4 ran clean. Watch the draft
    # acceptance on cold start as with qwen38-mtp: 0.00000 means a dead head —
    # restart, or drop --spec-type for a spec-off run.
    LLAMA_DIR="${HOME}/llama.cpp-mtp"
    if [ -z "${CTX_EXPLICIT}" ]; then
      CTX=32768
    elif [ "${CTX}" -gt 65536 ] 2>/dev/null; then
      echo "warning: CTX=${CTX} is above what IQ3_XXS was proven to load" >&2
      echo "  (32768 with MTP on, 65536 spec-off); expect ErrorDeviceLost" >&2
    fi
    hf_repo="unsloth/Qwen3.8-Flash-Next-GGUF"
    # Sharded: pass shard 00001 (the tensor-free header); llama.cpp opens 2/3.
    hf_file="UD-IQ3_XXS/Qwen3.8-Flash-Next-UD-IQ3_XXS-00001-of-00003.gguf"
    hf_draft="MTP/mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf"
    hf_dir="${HF_HUB}/models--unsloth--Qwen3.8-Flash-Next-GGUF"
    model=$(hf_resolve "${hf_dir}" "${hf_file}")
    draft=$(hf_resolve "${hf_dir}" "${hf_draft}")
    alias="Qwen3.8-Flash-Next-UD-IQ3_XXS-MTP"
    warmup_flag=""
    # Not A/B'd on this arch; keep the FreeBSD-dense precedent of leaving it off.
    [ "${OS}" = "FreeBSD" ] && nohost_flag=""
    if [ ! -x "${LLAMA_DIR}/build/bin/llama-server" ]; then
      echo "MODEL=flashnext needs a PR #28243 build at ${LLAMA_DIR}" >&2
      echo "  git clone https://github.com/ggml-org/llama.cpp ~/llama.cpp-mtp" >&2
      echo "  git -C ~/llama.cpp-mtp fetch origin refs/pull/28243/head" >&2
      echo "  git -C ~/llama.cpp-mtp checkout FETCH_HEAD" >&2
      echo "  (then cmake -B build -DGGML_VULKAN=ON -DGGML_CCACHE=OFF ...)" >&2
      exit 1
    fi
    if [ -z "${draft}" ] || [ ! -e "${draft}" ]; then
      echo "draft head ${hf_draft} not cached under ${hf_dir}" >&2
      echo "MTP is the point of this slot; fetch the head or pick another MODEL" >&2
      exit 1
    fi
    # N=2 is the measured peak on BOTH hosts, and there is no cliff (N=16 still
    # beats spec-off) — unlike the agents-a1-mtp MoE cliff at N>=8. Mean accepted
    # draft length is only ~1.8 tokens, so a larger N buys nothing here.
    model_extra="--model-draft ${draft} --spec-type draft-mtp --spec-draft-n-max 2"
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
    echo "unknown MODEL='${MODEL}' (use qwen38-mtp|qwen38-q8|flashnext)" >&2; exit 1 ;;
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
  qwen38-mtp) ;;  # sets --jinja itself in model_extra; JINJA=0 cannot disable it
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
