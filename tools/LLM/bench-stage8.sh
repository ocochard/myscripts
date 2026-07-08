#!/bin/sh
# Stage 8: refresh Stage 0/1/3 baseline on current llama.cpp build.
#
# Same recipe as Stage 1/3: llama-bench pp4096 + tg128 at d=0, 8192, 32768,
# fa=1, --no-host on MoE, no --no-host on dense (FreeBSD dense crashes).
#
# Purpose: isolate what fraction of Agents-A1's +30 % tg boost is llama.cpp
# kernels vs the fine-tune. Without this baseline the Stage 7 "delta vs
# baseline" comparison is confounded (different build).
#
# Output: /tmp/bench-stage8.md and /tmp/bench-stage8.jsonl
set -eu

OUT=${OUT:-/tmp/bench-stage8.md}
JSONLOG=${JSONLOG:-/tmp/bench-stage8.jsonl}
LLAMA_DIR=${LLAMA_DIR:-${HOME}/llama.cpp}
HF_HUB=${HF_HUB:-${HOME}/.cache/huggingface/hub}

OS=$(uname -s)
HOSTNAME_SHORT=$(hostname | cut -d. -f1)

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
emit() { printf '%s\n' "$*" >> "${OUT}"; }
jlog() { printf '%s\n' "$*" >> "${JSONLOG}"; }

nproc_portable() {
  if command -v nproc >/dev/null 2>&1; then nproc
  else sysctl -n hw.ncpu 2>/dev/null || echo 8
  fi
}

hf_resolve() {
  for f in "$1"/snapshots/*/$2; do
    [ -e "$f" ] && { echo "$f"; return 0; }
  done
  return 1
}

# Refuse to run if any llama process is holding the GPU.
stray=$(pgrep -f 'llama-(server|cli|bench)' 2>/dev/null | grep -v $$ || true)
if [ -n "${stray}" ]; then
  log "ERROR: other llama-* processes running (would invalidate bench):"
  ps -p ${stray} -o pid,command 2>/dev/null | head -20 >&2
  [ "${FORCE:-0}" = "1" ] || exit 2
fi

BUILD_TAG=$("${LLAMA_DIR}/build/bin/llama-server" --version 2>&1 | awk '/^version:/{print $2}')
BUILD_HASH=$("${LLAMA_DIR}/build/bin/llama-server" --version 2>&1 | awk '/^version:/{print $3}' | tr -d '()')

log "host=${HOSTNAME_SHORT} os=${OS} build=b${BUILD_TAG} (${BUILD_HASH})"

# Model spec: <label>:<repo-dir-under-HF_HUB>:<gguf-filename>
# --no-host is safe for MoE on both OSes but crashes dense 27B on FreeBSD.
MODELS="\
Qwen3.6-27B/Q4:models--unsloth--Qwen3.6-27B-GGUF:Qwen3.6-27B-UD-Q4_K_XL.gguf:dense
Qwen3.6-27B/Q8:models--unsloth--Qwen3.6-27B-GGUF:Qwen3.6-27B-UD-Q8_K_XL.gguf:dense
Qwen3.6-35B-A3B/Q4:models--unsloth--Qwen3.6-35B-A3B-GGUF:Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf:moe
Qwen3.6-35B-A3B/Q8:models--unsloth--Qwen3.6-35B-A3B-GGUF:Qwen3.6-35B-A3B-UD-Q8_K_XL.gguf:moe"

: > "${OUT}"; : > "${JSONLOG}"

emit "## Stage 8 — llama.cpp b${BUILD_TAG} refresh on ${HOSTNAME_SHORT} (${OS})"
emit
emit "- Build: llama.cpp b${BUILD_TAG} (\`${BUILD_HASH}\`)"
emit "- Date: $(date -u +%Y-%m-%d)"
emit "- Recipe: fa=1, b=2048, ub=512, r=2, Vulkan0, mmap"
emit "- \`--no-host 1\` on MoE only (dense 27B crashes on FreeBSD)"
emit
emit "| Model            | Quant | depth | pp4096          | tg128         |"
emit "|------------------|-------|------:|----------------:|--------------:|"

echo "${MODELS}" | while IFS=: read -r label repo file kind; do
  [ -z "${label}" ] && continue
  qfile=$(hf_resolve "${HF_HUB}/${repo}" "${file}") || { log "SKIP ${label}: ${file} not cached"; continue; }
  nohost=1
  # FreeBSD dense 27B crashes with --no-host — drop it there.
  if [ "${OS}" = "FreeBSD" ] && [ "${kind}" = "dense" ]; then
    nohost=0
  fi
  for depth in 0 8192 32768; do
    log "llama-bench ${label} d=${depth} nohost=${nohost}"
    raw=$("${LLAMA_DIR}/build/bin/llama-bench" \
      -m "${qfile}" \
      --device Vulkan0 \
      --flash-attn 1 \
      --batch-size 2048 --ubatch-size 512 \
      --n-prompt 4096 --n-gen 128 \
      --n-depth "${depth}" \
      --no-host ${nohost} \
      --mmap 1 --threads "$(nproc_portable)" \
      --repetitions 2 \
      --output md 2>&1) || { log "  crashed"; raw="CRASH"; }
    pp=$(echo "${raw}" | awk -F'|' '/pp4096/{gsub(/^ *| *$/,"",$(NF-1)); print $(NF-1); exit}')
    tg=$(echo "${raw}" | awk -F'|' '/tg128/{gsub(/^ *| *$/,"",$(NF-1)); print $(NF-1); exit}')
    # Split model+quant back out for readable table
    model_col=$(echo "${label}" | cut -d/ -f1)
    quant_col=$(echo "${label}" | cut -d/ -f2)
    emit "| ${model_col}  | ${quant_col}    | ${depth} | ${pp:-crash} | ${tg:-crash} |"
    jlog "{\"stage\":8,\"host\":\"${HOSTNAME_SHORT}\",\"build\":\"b${BUILD_TAG}\",\"model\":\"${model_col}\",\"quant\":\"${quant_col}\",\"depth\":${depth},\"pp4096\":\"${pp}\",\"tg128\":\"${tg}\"}"
  done
done

emit
log "done. see ${OUT} and ${JSONLOG}"
