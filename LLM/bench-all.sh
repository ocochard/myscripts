#!/bin/sh
# Full refresh of Framework Desktop benches on the current llama.cpp build.
#
# For each (model, quant) pair listed in $MODELS below:
#   1. llama-bench pp4096 + tg128 at d=0, 8192, 32768
#   2. llama-server + bench_model.py at ~4 k and ~32 k depths
# Then for MTP-capable models: --spec-draft-n-max sweep.
#
# Produces:
#   /tmp/bench-all.md    — markdown fragments
#   /tmp/bench-all.jsonl — one JSON line per measurement
#
# Env knobs:
#   OUT, JSONLOG, LLAMA_DIR, HF_HUB, PORT (default 8090)
#   ONLY=agents-a1-mtp,mtp  → run only these model slots (default: all cached)
#   STAGES=llama-bench,server,mtp-sweep  (default: all)
#   FORCE=1                 → run despite stray llama-* procs (unsafe)
set -eu

OUT=${OUT:-/tmp/bench-all.md}
JSONLOG=${JSONLOG:-/tmp/bench-all.jsonl}
LLAMA_DIR=${LLAMA_DIR:-${HOME}/llama.cpp}
SCRIPTS_DIR=${SCRIPTS_DIR:-${HOME}/myscripts/LLM}
HF_HUB=${HF_HUB:-${HOME}/.cache/huggingface/hub}
PORT=${PORT:-8090}
STAGES=${STAGES:-llama-bench,server,mtp-sweep}
MTP_NS=${MTP_NS:-"2 3 4 5 8 16"}

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

# ---------------------------------------------------------------------------
# Model registry.
#
# Fields (colon-separated, one line per model):
#   slot        — short label matched by ONLY=...
#   hf_repo_dir — subdir of $HF_HUB
#   gguf_name   — filename inside snapshots/*/
#   family      — dense | moe   (informational; not used to switch flags)
#   mtp         — 0 | 1         (1 = has draft-mtp head, do N-max sweep)
#   display     — nice name for the tables
# ---------------------------------------------------------------------------
MODELS='
qwen-27b-q4  : models--unsloth--Qwen3.6-27B-GGUF                : Qwen3.6-27B-UD-Q4_K_XL.gguf         : dense : 0 : Qwen3.6-27B Q4_K_XL
qwen-27b-q8  : models--unsloth--Qwen3.6-27B-GGUF                : Qwen3.6-27B-UD-Q8_K_XL.gguf         : dense : 0 : Qwen3.6-27B Q8_K_XL
qwen-moe-q4  : models--unsloth--Qwen3.6-35B-A3B-GGUF            : Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf     : moe   : 0 : Qwen3.6-35B-A3B Q4_K_XL
qwen-moe-q8  : models--unsloth--Qwen3.6-35B-A3B-GGUF            : Qwen3.6-35B-A3B-UD-Q8_K_XL.gguf     : moe   : 0 : Qwen3.6-35B-A3B Q8_K_XL
qwen-mtp-q8  : models--havenoammo--Qwen3.6-27B-MTP-UD-GGUF      : Qwen3.6-27B-MTP-UD-Q8_K_XL.gguf     : dense : 1 : Qwen3.6-27B-MTP Q8_K_XL
agents-a1-q4 : models--InternScience--Agents-A1-Q4_K_M-GGUF     : Agents-A1-Q4_K_M.gguf               : moe   : 0 : Agents-A1 Q4_K_M
agents-a1-mtp: models--protoLabsAI--Agents-A1-MTP-GGUF          : Agents-A1-MTP-Q8_0.gguf             : moe   : 1 : Agents-A1-MTP Q8_0
'

# Filter by ONLY= if set.
filter_only() {
  if [ -z "${ONLY:-}" ]; then cat; return; fi
  awk -v only="${ONLY}" 'BEGIN{n=split(only,a,","); for(i in a)keep[a[i]]=1}
    { slot=$1; gsub(/[ \t]+/,"",slot); if (slot in keep) print }'
}

# Safety: refuse to run alongside stray llama procs.
stray=$(pgrep -f 'llama-(server|cli|bench)' 2>/dev/null | grep -v $$ || true)
if [ -n "${stray}" ]; then
  log "ERROR: stray llama-* processes (would invalidate bench):"
  ps -p ${stray} -o pid,command 2>/dev/null | head -10 >&2
  [ "${FORCE:-0}" = "1" ] || exit 2
fi

BUILD_TAG=$("${LLAMA_DIR}/build/bin/llama-server" --version 2>&1 | awk '/^version:/{print $2}')
BUILD_HASH=$("${LLAMA_DIR}/build/bin/llama-server" --version 2>&1 | awk '/^version:/{print $3}' | tr -d '()')

: > "${OUT}"; : > "${JSONLOG}"; : > /tmp/bench-all.raw.txt

log "host=${HOSTNAME_SHORT} os=${OS} build=b${BUILD_TAG} port=${PORT} stages=${STAGES}"

emit "# bench-all results — ${HOSTNAME_SHORT} (${OS}), b${BUILD_TAG}"
emit
emit "- Date: $(date -u +%Y-%m-%d)"
emit "- Build: llama.cpp b${BUILD_TAG} (\`${BUILD_HASH}\`)"
emit "- CPU governor / powerd: $([ "${OS}" = "Linux" ] && cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo powerd)"
emit "- Bench script: \`${0##*/}\`"
emit

# ---------------------------------------------------------------------------
# Server lifecycle
# ---------------------------------------------------------------------------
SERVER_PID=""

wait_server() {
  deadline=$(( $(date +%s) + 540 ))
  while [ $(date +%s) -lt ${deadline} ]; do
    code=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${PORT}/v1/models" 2>/dev/null || true)
    if [ "${code}" = "200" ]; then log "  server up"; return 0; fi
    if [ -n "${SERVER_PID}" ] && ! kill -0 "${SERVER_PID}" 2>/dev/null; then
      log "  server (pid ${SERVER_PID}) exited during startup"
      return 1
    fi
    sleep 3
  done
  log "  server never came up (9 min timeout)"
  return 1
}

kill_server() {
  if [ -n "${SERVER_PID}" ]; then
    kill "${SERVER_PID}" 2>/dev/null || true
    for i in 1 2 3 4 5; do
      kill -0 "${SERVER_PID}" 2>/dev/null || break
      sleep 1
    done
    kill -9 "${SERVER_PID}" 2>/dev/null || true
    wait "${SERVER_PID}" 2>/dev/null || true
    SERVER_PID=""
  fi
  for pid in $(pgrep -f "llama-server.*${PORT}" 2>/dev/null || true); do
    [ "${pid}" != "$$" ] && kill -9 "${pid}" 2>/dev/null || true
  done
  sleep 3
}

# start_server MODEL_PATH ALIAS FAMILY [extra args...]
start_server() {
  model_path=$1; alias=$2; family=$3; shift 3
  kill_server
  log "  starting server: ${alias} extras: $*"
  "${LLAMA_DIR}/build/bin/llama-server" \
    --model "${model_path}" \
    --alias "${alias}" \
    --device Vulkan0 \
    --flash-attn on \
    --no-warmup \
    --no-mmproj \
    --batch-size 2048 --ubatch-size 512 \
    --ctx-size 131072 --parallel 1 \
    --jinja \
    --host 127.0.0.1 --port "${PORT}" \
    "$@" \
    >/tmp/llama-srv-bench.log 2>&1 &
  SERVER_PID=$!
  wait_server || return $?
}

trap 'kill_server' EXIT INT TERM

# run_bench PROMPT_FILE LABEL --> emits TTFT|PP|TOT
run_bench() {
  pfile=$1; label=$2
  log "  bench: ${label} (${pfile##*/})"
  raw=$("${SCRIPTS_DIR}/bench_model.py" \
    -u "http://127.0.0.1:${PORT}" \
    -t 256 -r 2 \
    --prompt-file "${pfile}" 2>&1) || {
      log "  bench_model.py failed"
      echo "?|?|?"; return
  }
  printf '\n----- %s -----\n%s\n' "${label}" "${raw}" >> /tmp/bench-all.raw.txt
  ttft=$(echo "${raw}" | awk '/^TTFT \(ms\)/{print $4; exit}')
  pp=$(echo "${raw}"   | awk '/^PP TPS/{print $5; exit}')
  tot=$(echo "${raw}"  | awk '/^Total TPS/{print $4; exit}')
  echo "${ttft:-?}|${pp:-?}|${tot:-?}"
}

# ---------------------------------------------------------------------------
# Stage A: llama-bench for all models
# ---------------------------------------------------------------------------
stage_llama_bench() {
  emit "## llama-bench — depth sweep (Vulkan, fa=1, b=2048, ub=512, r=2)"
  emit
  emit "Recipe: no \`--no-host\` (A/B on framework2 showed it's a no-op on this stack; on FreeBSD dense at d=32k it costs 6-9 %). Q8 dense on FreeBSD can hit a cold-start GTT OOM — automatic retry once."
  emit
  emit "| Model                    | Quant   | depth | pp4096          | tg128         |"
  emit "|--------------------------|---------|------:|----------------:|--------------:|"
  echo "${MODELS}" | filter_only | while IFS=: read -r slot repo file family mtp display; do
    slot=$(echo "${slot}"|tr -d ' \t'); repo=$(echo "${repo}"|tr -d ' \t')
    file=$(echo "${file}"|tr -d ' \t'); family=$(echo "${family}"|tr -d ' \t')
    display=$(echo "${display}" | sed 's/^ *//;s/ *$//')
    [ -z "${slot}" ] && continue
    qfile=$(hf_resolve "${HF_HUB}/${repo}" "${file}") || { log "SKIP ${slot}: not cached"; continue; }
    for depth in 0 8192 32768; do
      log "llama-bench ${slot} d=${depth}"
      attempt=1
      while [ ${attempt} -le 2 ]; do
        raw=$("${LLAMA_DIR}/build/bin/llama-bench" \
          -m "${qfile}" \
          --device Vulkan0 \
          --flash-attn 1 \
          --batch-size 2048 --ubatch-size 512 \
          --n-prompt 4096 --n-gen 128 \
          --n-depth "${depth}" \
          --mmap 1 --threads "$(nproc_portable)" \
          --repetitions 2 \
          --output md 2>&1) && break
        # cold-start GTT OOM (observed on FreeBSD Mesa 26 Q8 dense): retry once
        if echo "${raw}" | grep -q "ErrorOutOfDeviceMemory" && [ ${attempt} -eq 1 ]; then
          log "  OOM on attempt 1, retrying"
          attempt=$((attempt+1))
          sleep 3
          continue
        fi
        log "  crashed"; raw="CRASH"; break
      done
      pp=$(echo "${raw}" | awk -F'|' '/pp4096/{gsub(/^ *| *$/,"",$(NF-1)); print $(NF-1); exit}')
      tg=$(echo "${raw}" | awk -F'|' '/tg128/{gsub(/^ *| *$/,"",$(NF-1)); print $(NF-1); exit}')
      # Split into "Model | Quant" if display has a space near end
      model_col=$(echo "${display}" | sed 's/ [A-Z][0-9_]*_[A-Z]*_[A-Z0-9]*$//')
      quant_col=$(echo "${display}" | sed "s|^${model_col} ||")
      emit "| ${model_col} | ${quant_col} | ${depth} | ${pp:-crash} | ${tg:-crash} |"
      jlog "{\"stage\":\"llama-bench\",\"host\":\"${HOSTNAME_SHORT}\",\"build\":\"b${BUILD_TAG}\",\"slot\":\"${slot}\",\"depth\":${depth},\"pp4096\":\"${pp}\",\"tg128\":\"${tg}\"}"
    done
  done
  emit
}

# ---------------------------------------------------------------------------
# Stage B: llama-server + bench_model.py for all models
# ---------------------------------------------------------------------------
stage_server() {
  emit "## llama-server + bench_model.py at ~4 k and ~32 k (b${BUILD_TAG})"
  emit
  emit "| Model                    | Quant   | Depth | TTFT (ms) | PP t/s | Total TPS |"
  emit "|--------------------------|---------|-------|----------:|-------:|----------:|"
  echo "${MODELS}" | filter_only | while IFS=: read -r slot repo file family mtp display; do
    slot=$(echo "${slot}"|tr -d ' \t'); repo=$(echo "${repo}"|tr -d ' \t')
    file=$(echo "${file}"|tr -d ' \t'); family=$(echo "${family}"|tr -d ' \t')
    mtp=$(echo "${mtp}"|tr -d ' \t')
    display=$(echo "${display}" | sed 's/^ *//;s/ *$//')
    [ -z "${slot}" ] && continue
    qfile=$(hf_resolve "${HF_HUB}/${repo}" "${file}") || continue
    model_col=$(echo "${display}" | sed 's/ [A-Z][0-9_]*_[A-Z]*_[A-Z0-9]*$//')
    quant_col=$(echo "${display}" | sed "s|^${model_col} ||")
    # For MTP models, run once WITHOUT --spec-type (baseline) — spec-on is in stage_mtp_sweep.
    if ! start_server "${qfile}" "${slot}" "${family}"; then
      emit "| ${model_col} | ${quant_col} | (server failed) | | | |"
      continue
    fi
    for pair in "~4 k:${SCRIPTS_DIR}/coding_prompt.txt" "~32 k:${SCRIPTS_DIR}/coding_prompt_32k.txt"; do
      depth=$(echo "${pair}" | cut -d: -f1)
      pfile=$(echo "${pair}" | cut -d: -f2)
      res=$(run_bench "${pfile}" "${slot}:${depth}")
      ttft=$(echo "${res}" | cut -d'|' -f1)
      pp=$(echo "${res}" | cut -d'|' -f2)
      tot=$(echo "${res}" | cut -d'|' -f3)
      emit "| ${model_col} | ${quant_col} | ${depth} | ${ttft} | ${pp} | ${tot} |"
      jlog "{\"stage\":\"server\",\"host\":\"${HOSTNAME_SHORT}\",\"build\":\"b${BUILD_TAG}\",\"slot\":\"${slot}\",\"depth\":\"${depth}\",\"ttft_ms\":\"${ttft}\",\"pp_tps\":\"${pp}\",\"total_tps\":\"${tot}\",\"mtp\":\"off\"}"
    done
  done
  kill_server
  emit
}

# ---------------------------------------------------------------------------
# Stage C: MTP-on + N-max sweep (only for mtp=1 slots)
# ---------------------------------------------------------------------------
stage_mtp_sweep() {
  echo "${MODELS}" | filter_only | while IFS=: read -r slot repo file family mtp display; do
    slot=$(echo "${slot}"|tr -d ' \t'); repo=$(echo "${repo}"|tr -d ' \t')
    file=$(echo "${file}"|tr -d ' \t'); family=$(echo "${family}"|tr -d ' \t')
    mtp=$(echo "${mtp}"|tr -d ' \t')
    display=$(echo "${display}" | sed 's/^ *//;s/ *$//')
    [ -z "${slot}" ] && continue
    [ "${mtp}" = "1" ] || continue
    qfile=$(hf_resolve "${HF_HUB}/${repo}" "${file}") || continue

    emit "## MTP: ${display} — MTP-on vs off + N-max sweep at ~4 k"
    emit
    emit "### MTP on/off summary (N=5)"
    emit
    emit "| MTP | Depth | TTFT (ms) | PP t/s | Total TPS |"
    emit "|-----|-------|----------:|-------:|----------:|"
    # off-baseline
    if start_server "${qfile}" "${slot}" "${family}"; then
      for pair in "~4 k:${SCRIPTS_DIR}/coding_prompt.txt" "~32 k:${SCRIPTS_DIR}/coding_prompt_32k.txt"; do
        depth=$(echo "${pair}" | cut -d: -f1)
        pfile=$(echo "${pair}" | cut -d: -f2)
        res=$(run_bench "${pfile}" "${slot}:off:${depth}")
        emit "| off | ${depth} | $(echo "${res}"|cut -d'|' -f1) | $(echo "${res}"|cut -d'|' -f2) | $(echo "${res}"|cut -d'|' -f3) |"
        jlog "{\"stage\":\"mtp\",\"host\":\"${HOSTNAME_SHORT}\",\"slot\":\"${slot}\",\"mtp\":\"off\",\"depth\":\"${depth}\",\"n_max\":null,\"raw\":\"${res}\"}"
      done
    fi
    # on N=5 (peak from Stage 5/7 sweeps)
    if start_server "${qfile}" "${slot}" "${family}" --spec-type draft-mtp --spec-draft-n-max 5; then
      for pair in "~4 k:${SCRIPTS_DIR}/coding_prompt.txt" "~32 k:${SCRIPTS_DIR}/coding_prompt_32k.txt"; do
        depth=$(echo "${pair}" | cut -d: -f1)
        pfile=$(echo "${pair}" | cut -d: -f2)
        res=$(run_bench "${pfile}" "${slot}:on-N5:${depth}")
        emit "| on N=5 | ${depth} | $(echo "${res}"|cut -d'|' -f1) | $(echo "${res}"|cut -d'|' -f2) | $(echo "${res}"|cut -d'|' -f3) |"
        jlog "{\"stage\":\"mtp\",\"host\":\"${HOSTNAME_SHORT}\",\"slot\":\"${slot}\",\"mtp\":\"on\",\"depth\":\"${depth}\",\"n_max\":5,\"raw\":\"${res}\"}"
      done
    fi
    emit
    # N-max sweep at ~4 k
    emit "### \`--spec-draft-n-max\` sweep at ~4 k"
    emit
    emit "| n_max | TTFT (ms) | PP t/s | Total TPS |"
    emit "|------:|----------:|-------:|----------:|"
    for n in ${MTP_NS}; do
      if start_server "${qfile}" "${slot}" "${family}" --spec-type draft-mtp --spec-draft-n-max "${n}"; then
        res=$(run_bench "${SCRIPTS_DIR}/coding_prompt.txt" "${slot}:sweep-N${n}")
        emit "| ${n} | $(echo "${res}"|cut -d'|' -f1) | $(echo "${res}"|cut -d'|' -f2) | $(echo "${res}"|cut -d'|' -f3) |"
        jlog "{\"stage\":\"mtp-sweep\",\"host\":\"${HOSTNAME_SHORT}\",\"slot\":\"${slot}\",\"n_max\":${n},\"raw\":\"${res}\"}"
      else
        emit "| ${n} | (server failed) | | |"
      fi
      kill_server
    done
    emit
  done
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
IFS=,
for stage in ${STAGES}; do
  IFS=' '
  case "${stage}" in
    llama-bench) stage_llama_bench ;;
    server)      stage_server      ;;
    mtp-sweep)   stage_mtp_sweep   ;;
    *) log "unknown stage: ${stage}" ;;
  esac
done

log "DONE. see ${OUT} and ${JSONLOG}"
