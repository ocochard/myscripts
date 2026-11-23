#!/bin/sh
# Launch llama-server tuned for Framework Desktop (Strix Halo + RADV).
# Works on all hosts:
#   - framework  (FreeBSD 16-CURRENT, Mesa 26.2, Vulkan; auto-detected)
#   - framework2 (Ubuntu 26.04,       Mesa 26.0, Vulkan)
#   - mac        (macOS, Metal)
#
# Default: flashnext (Qwen3.8-Flash-Next UD-IQ3_XXS + self-contained Q8_0 MTP
# head). Best agentic score of the local models in fbsd-quality and the
# fastest recipe here. If cold starts report 0.00 draft acceptance (Mesa 26
# RADV on FreeBSD), restart or fall back to MODEL=qwen38-mtp / qwen38-q8.
#
# Usage:
#   ./llmsrv.sh                  # default: flashnext (MoE IQ3_XXS + Q8 MTP head)
#   USAGE=coding ./llmsrv.sh     # alias for MODEL=flashnext
#   MODEL=qwen38-mtp ./llmsrv.sh # Qwen3.8-27B dense Q8_0 + Q8 MTP head
#   USAGE=doc    ./llmsrv.sh     # alias for MODEL=qwen38-q8 (spec-off fallback)
#   MODEL=flashnext-abl ./llmsrv.sh  # flashnext + rank-1 abliteration LoRA
#   MODEL=qwen38-q8 ./llmsrv.sh  # Qwen3.8-27B dense Q8, no MTP (DaemonDocs
#                                #   production recipe; see
#                                #   benches.DaemonDocs-model-quality.md)
#   HOST=0.0.0.0 ./llmsrv.sh     # listen on all interfaces (default: 127.0.0.1)
#   CTX=131072 ./llmsrv.sh       # extend ctx past 65536 (TTFT collapses past ~30k
#                                # on Strix Halo — see LLM.benches.FrameWork-Desktop.md)
#   JINJA=0 ./llmsrv.sh          # disable embedded jinja template (default is on)
#   LLAMA_DIR=~/other-llama.cpp ./llmsrv.sh  # override llama.cpp build dir
#                                            # (every slot tested on v1.0.0)
set -eu

usage() {
  cat <<EOF
Usage: [ENV=val ...] $(basename "$0") [-h|--help]

Environment variables:
  USAGE=coding  Alias for MODEL=flashnext (default)
  USAGE=doc     Alias for MODEL=qwen38-q8 (spec-off fallback)
  MODEL=qwen38-mtp
                Qwen3.8-27B dense Q8_0 + Q8_0 sidecar MTP draft head
                (ggml-org). Speculative decoding; v1.0.0: 17.0-17.4 t/s
                decode, acceptance ~0.52-0.55. Draft path still unverified
                on FreeBSD/Mesa 26. See the slot comment.
  MODEL=flashnext-gsq
                EXPERIMENTAL. ISTA-DASLab GSQ-RCO Coder (58.4 GB, half the
                experts pruned) + borrowed unsloth MTP head. SPEC=0 = no MTP.
  MODEL=qwen38-q8
                Qwen3.8-27B dense Q8_K_XL (unsloth), no MTP; v1.0.0:
                7.2-7.3 t/s decode. Best FreeBSD-source doc accuracy in the
                DaemonDocs quality bench, and the fallback when the MTP
                draft path misbehaves.
  MODEL=flashnext
                DEFAULT. Qwen3.8-Flash-Next 125B/6B-active MoE, UD-IQ3_XXS (82 GB) +
                self-contained Q8_0 MTP head at N=2. Mainline llama.cpp
                >= v1.0.0: 38-40 t/s decode, acceptance 0.61-0.70. Takes the full
                131072 CTX. Do not substitute a bigger quant: IQ4_XS
                (93.7 GB) cannot load the draft head at all. MTP is flaky on
                FreeBSD (Mesa 26 RADV).
  MODEL=flashnext-abl
                flashnext with mrfakename's rank-1 abliteration LoRA
                (abliteration-lora.gguf, 2.3 MB) applied at load: refusals
                removed, same weights and MTP head on disk.
  HOST=addr     Listen address (default: 127.0.0.1)
  PORT=port     Listen port (default: 8080)
  CTX=N         --ctx-size (default: 131072 — practical sweet spot on Strix
                Halo, NOT a ceiling: the Qwen3.8-27B GGUF declares Context
                Length 262144, and 262144 loads with no RoPE scaling.
                TG/PP are functions of filled depth, not the declared
                ceiling. Cost is entirely cold-prefill: ~4 s at 4k, ~40 s at
                32k, ~5 min at 128k, ~20 min at 256k. Drop to 65536 for a
                smaller KV footprint if you never work past ~30 k prompts.
                See benches.FrameWork-Desktop.md.)
  LLAMA_DIR=dir llama.cpp build dir (default: ~/llama.cpp for all models;
                every slot tested on mainline llama.cpp v1.0.0)
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
    coding) MODEL=flashnext  ;;   # MoE IQ3_XXS + Q8 MTP head (default)
    doc)    MODEL=qwen38-q8  ;;   # spec-off fallback (unsloth Q8_K_XL)
    *) echo "unknown USAGE='${USAGE}' (use coding|doc)" >&2; exit 1 ;;
  esac
fi

MODEL=${MODEL:-flashnext}
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
#   - MoE:       safe and slightly faster on both OSes / Mesa versions.
#   - Dense 27B: crashes on FreeBSD (Mesa 24 and 25); OK on Ubuntu.
# Default to no-host; cleared below for FreeBSD dense.
nohost_flag="--no-host"

# Per-model extras (chat-template flags etc.). Set inside cases as needed.
model_extra=""

case "${MODEL}" in
  qwen38-mtp)
    # Qwen3.8-27B dense (ggml-org), Q8_0 target + Q8_0 SIDECAR MTP
    # draft head (mtp-Qwen3.8-27B-Q8_0.gguf) passed via --model-draft. Both
    # files come from the same repo. v1.0.0: 17.0-17.4 t/s decode,
    # acceptance ~0.52-0.55 (bench-all.sh slot `qwen38-mtp-q8`).
    #
    # The dense pick for doc accuracy, not speed: it wins the
    # DaemonDocs hallucination bench at 6.4 mean violations
    # (benches.DaemonDocs-model-quality.md). That bench never tested
    # flashnext, so whether it is also more accurate is an OPEN question.
    #
    # STILL UNVERIFIED on FreeBSD/Mesa 26: the same bench recorded a RADV
    # GPUVM fault in the draft-mtp dispatch path — `[gfxhub] page fault`,
    # client ID CPC (0x5), then `ring comp_1.x.0 timeout` and
    # ErrorDeviceLost — on a coin-flip of cold starts. It reproduced with an
    # unrelated model too, so it tracks the MTP-on code path, not this GGUF,
    # and it is a Mesa 26 regression (identical binary+GGUF is clean on
    # Mesa 25 / Ubuntu). Quant does not affect it. On a dead load every
    # drafted token is wasted verify compute and throughput falls BELOW
    # spec-off.
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
    # Dense 27B on FreeBSD: --no-host crashes.
    [ "${OS}" = "FreeBSD" ] && nohost_flag=""
    if [ -z "${draft}" ] || [ ! -e "${draft}" ]; then
      echo "draft head ${hf_draft} not cached under ${hf_dir}" >&2
      echo "fetch it, or run MODEL=qwen38-q8 for the spec-off fallback" >&2
      exit 1
    fi
    # probabilistic drafts at the request temp (0.6 here): a small gain on
    # this slot. Needs llama.cpp with #27694 (v1.0.0 has it).
    model_extra="--jinja --model-draft ${draft} --spec-type draft-mtp --spec-draft-n-max 4 --spec-draft-sampling probabilistic"
    ;;
  flashnext|flashnext-abl)
    # DEFAULT. Qwen3.8-Flash-Next, 125B/6B-active `qwen4exp` MoE, UD-IQ3_XXS (82 GB) +
    # the self-contained Q8_0 sidecar MTP head. v1.0.0: 38-40 t/s decode with
    # N=2, acceptance 0.61-0.70.
    #
    # THREE hard requirements, all of them load-time failures if unmet:
    #
    # 1. The SELF-CONTAINED head re-uploaded 2026-10-05, not the `shared-`
    #    one: mainline cannot borrow the main model's embedding
    #    (`tensor 'token_embd.weight' not found`), and the pre-Oct-05 upload of
    #    the self-contained head aborts with `GGML_ASSERT(buffer) failed`.
    # 2. IQ3_XXS (82 GB), NOT IQ4_XS (93.7 GB). One quant step up and the
    #    draft head cannot load at ANY --ctx-size: 93.7 GB resident leaves the
    #    driver unable to fund a second model's command submission
    #    (`radv/amdgpu: Not enough memory for command submission` →
    #    ErrorDeviceLost). Q8_0 is 192 GB and never fits 128 GB UMA.
    # 3. CTX: the full 131072 FITS with MTP on (`n_ctx_slot = 131072`, no
    #    ErrorDeviceLost), so this slot does NOT clamp it. The old 32768
    #    clamp was derived for IQ4_XS and does not apply to IQ3_XXS.
    #    A large ctx costs nothing until you fill it; MTP does not
    #    accelerate prefill, so cold TTFT is the cost of filling it.
    #
    # FreeBSD caveat: MTP is flaky here, NOT unusable. Some cold starts hit
    # the Mesa-26 RADV compute-write fingerprint documented for qwen38-mtp
    # (`[gfxhub] page fault`, client ID CPC (0x5), `ring comp_1.1.0
    # timeout`). Watch the draft acceptance on cold start as with
    # qwen38-mtp: 0.00000 means a dead head; restart, or drop --spec-type
    # for a spec-off run.
    #
    # DO NOT substitute IQ4_XS (93.7 GB) here to "get more quality". On
    # frwk-linux that combination needs amdgpu.gttsize raised well past the
    # 65.9 GB default, and doing so KERNEL-PANICKED the host on 7.0.0-31:
    #   BUG: unable to handle page fault for address: 0000000000004008
    #   RIP: ttm_resource_manager_next+0x130/0x370 [ttm]  Comm: llama-server
    # (see benches.FrameWork-Desktop.md, "gttsize=120000 panicked the Linux
    # kernel"). IQ3_XXS is both safer and faster.

    # No CTX clamp: 131072 with MTP on is verified to load on this quant (see
    # note 3 above). Only warn past the model's native 262144, which would
    # need RoPE scaling.
    if [ "${CTX}" -gt 262144 ] 2>/dev/null; then
      echo "warning: CTX=${CTX} exceeds the model's native 262144 context;" >&2
      echo "  that needs RoPE/YaRN scaling and is untested here" >&2
    fi
    hf_repo="unsloth/Qwen3.8-Flash-Next-GGUF"
    # Sharded: pass shard 00001 (the tensor-free header); llama.cpp opens 2/3.
    # QUANT overrides the default IQ3_XXS (no other quant is cached). IQ4_XS
    # will not load the draft head (the load wedges at "loading draft model")
    # and the gttsize it needs panicked Linux (see above); keep QUANT for
    # spec-off experiments only.
    q="${QUANT:-UD-IQ3_XXS}"
    hf_file="${q}/Qwen3.8-Flash-Next-${q}-00001-of-00003.gguf"
    hf_draft="MTP/mtp-Qwen3.8-Flash-Next-Q8_0.gguf"
    hf_dir="${HF_HUB}/models--unsloth--Qwen3.8-Flash-Next-GGUF"
    model=$(hf_resolve "${hf_dir}" "${hf_file}")
    draft=$(hf_resolve "${hf_dir}" "${hf_draft}")
    alias="Qwen3.8-Flash-Next-${q}-MTP"
    warmup_flag=""
    # Not A/B'd on this arch; keep the FreeBSD-dense precedent of leaving it off.
    [ "${OS}" = "FreeBSD" ] && nohost_flag=""
    if [ -z "${draft}" ] || [ ! -e "${draft}" ]; then
      echo "draft head ${hf_draft} not cached under ${hf_dir}" >&2
      echo "MTP is the point of this slot; fetch the head or pick another MODEL" >&2
      exit 1
    fi
    # N=2 was the measured peak on both hosts in the last N sweep (pre-v1.0.0;
    # not re-swept on v1.0.0).
    model_extra="--model-draft ${draft} --spec-type draft-mtp --spec-draft-n-max 2"
    if [ "${MODEL}" = "flashnext-abl" ]; then
      # Uncensored variant: mrfakename's abliteration as a rank-1 LoRA, so the
      # cached IQ3_XXS and MTP head are reused (no second 82 GB download). It
      # projects one refusal direction (strength 1.6) out of o_proj,
      # linear_attn.out_proj and shared_expert.down_proj in all 48 layers;
      # routed experts, embeddings and the MTP layer are untouched. Author
      # measured on Q8_0: refusals 99 -> 7 /100, harmless KL 0.068.
      # v1.0.0 on framework (2026-11-19): loads on IQ3_XXS + Vulkan with MTP
      # on; decode and draft acceptance match flashnext (see README.md).
      # The per-request `"lora":[{"id":0,"scale":0}]` field turns it off for
      # an A/B on the same server.
      lora_dir="${HF_HUB}/models--mrfakename--Qwen3.8-Flash-Next-abliterated-GGUF"
      lora=$(hf_resolve "${lora_dir}" "abliteration-lora.gguf")
      if [ -z "${lora}" ]; then
        echo "abliteration-lora.gguf not cached under ${lora_dir}; fetch it:" >&2
        echo "  mkdir -p ${lora_dir}/snapshots/main && curl -fL -o ${lora_dir}/snapshots/main/abliteration-lora.gguf \\" >&2
        echo "    https://huggingface.co/mrfakename/Qwen3.8-Flash-Next-abliterated-GGUF/resolve/main/abliteration-lora.gguf" >&2
        exit 1
      fi
      alias="Qwen3.8-Flash-Next-${q}-abliterated-MTP"
      model_extra="${model_extra} --lora ${lora}"
    fi
    ;;
  flashnext-gsq)
    # EXPERIMENTAL. ISTA-DASLab GSQ-RCO Coder: Flash-Next with half the routed
    # experts pruned (256/512 kept, 10 active) and the rest at ~3.5 bpw.
    # 2 shards, 58.4 GB: shard 1 = transformer, shard 2 = n-gram table.
    # The repo ships no MTP head; this slot borrows the unsloth self-contained
    # head trained on the UNPRUNED model. SPEC=0 runs it spec-off.
    # v1.0.0 on framework: 41.7 t/s at N=2, acceptance 0.81, but fbsd-quality
    # 9/15 vs flashnext's 12/15 (benches.FrameWork-Desktop.md).
    hf_repo="ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-Coder-GGUF"
    hf_file="IQ1_M/Qwen3.8-Flash-Next-GSQ-RCO-IQ1_M-00001-of-00002.gguf"
    hf_dir="${HF_HUB}/models--ISTA-DASLab--Qwen3.8-Flash-Next-GSQ-RCO-Coder-GGUF"
    model=$(hf_resolve "${hf_dir}" "${hf_file}")
    alias="Qwen3.8-Flash-Next-GSQ-RCO-Coder-IQ1_M"
    warmup_flag=""
    [ "${OS}" = "FreeBSD" ] && nohost_flag=""
    if [ "${SPEC:-1}" = "1" ]; then
      draft=$(hf_resolve "${HF_HUB}/models--unsloth--Qwen3.8-Flash-Next-GGUF" \
        "MTP/mtp-Qwen3.8-Flash-Next-Q8_0.gguf")
      if [ -z "${draft}" ] || [ ! -e "${draft}" ]; then
        echo "unsloth MTP head not cached; fetch it or run SPEC=0" >&2
        exit 1
      fi
      alias="${alias}-MTP"
      model_extra="--model-draft ${draft} --spec-type draft-mtp --spec-draft-n-max 2"
    fi
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
    echo "unknown MODEL='${MODEL}' (use qwen38-mtp|qwen38-q8|flashnext|flashnext-abl|flashnext-gsq)" >&2; exit 1 ;;
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
# clients (qwen-code, aider). qwen38-mtp already sets it via model_extra; skip
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
# --ctx-size > 262144            : the Qwen3.8-27B GGUF declares
#                                  `Context Length: 262144`, so 262144 is
#                                  NATIVE and needs no RoPE scaling. (An
#                                  earlier version of this note claimed the
#                                  base max was 131072 — that was wrong; read
#                                  it off the GGUF, not from memory.) Cold
#                                  prefill is the real cost: ~40 s at 32k,
#                                  ~5 min at 128k on Strix Halo, and KV
#                                  reservation scales linearly with ctx —
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
