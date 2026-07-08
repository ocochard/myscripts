#!/bin/sh
# Bench Agents-A1 Q4_K_M and MTP Q8_0 on the local host (Strix Halo, Vulkan).
#
# Produces markdown fragments suitable for pasting into
# tools/LLM/benches.FrameWork-Desktop.md and a JSONL log for post-processing.
#
# Requirements:
# - llama.cpp built at ~/llama.cpp/build/bin (b9925+ for --spec-type draft-mtp)
# - Both GGUFs already downloaded into ~/.cache/huggingface/hub/
# - ~/myscripts/tools/LLM/bench_model.py, coding_prompt.txt, coding_prompt_32k.txt
#
# Env knobs:
#   STAGES=llama-bench,server-q4,server-mtp,mtp-sweep   (comma list)
#   OUT=/tmp/bench-agents-a1.md
#   JSONLOG=/tmp/bench-agents-a1.jsonl
#   PORT=8090      (listen port; avoid clashing with a running llmsrv on 8080)
#   MTP_NS="2 3 4 5 8 16"   (values for --spec-draft-n-max sweep)
set -eu

OUT=${OUT:-/tmp/bench-agents-a1.md}
JSONLOG=${JSONLOG:-/tmp/bench-agents-a1.jsonl}
LLAMA_DIR=${LLAMA_DIR:-${HOME}/llama.cpp}
SCRIPTS_DIR=${SCRIPTS_DIR:-${HOME}/myscripts/tools/LLM}
HF_HUB=${HF_HUB:-${HOME}/.cache/huggingface/hub}
PORT=${PORT:-8090}
STAGES=${STAGES:-llama-bench,server-q4,server-mtp,mtp-sweep}
MTP_NS=${MTP_NS:-"2 3 4 5 8 16"}

OS=$(uname -s)
HOSTNAME_SHORT=$(hostname | cut -d. -f1)

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
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

# Poll TCP port until server responds (or timeout).
# Max wait: 540 s = 9 min. Cold Q8_0 load can take ~5 min via mmap.
wait_server() {
  deadline=$(( $(date +%s) + 540 ))
  while [ $(date +%s) -lt ${deadline} ]; do
    code=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${PORT}/v1/models" 2>/dev/null || true)
    if [ "${code}" = "200" ]; then
      log "server up"
      return 0
    fi
    if [ -n "${SERVER_PID:-}" ] && ! kill -0 "${SERVER_PID}" 2>/dev/null; then
      log "server (pid ${SERVER_PID}) exited during startup; check /tmp/llama-srv-bench.log"
      return 1
    fi
    sleep 3
  done
  log "server never came up (9 min timeout)"
  return 1
}

kill_server() {
  if [ -n "${SERVER_PID:-}" ]; then
    kill "${SERVER_PID}" 2>/dev/null || true
    # Give server ~5 s to release VRAM cleanly, then SIGKILL if still alive.
    for i in 1 2 3 4 5; do
      kill -0 "${SERVER_PID}" 2>/dev/null || break
      sleep 1
    done
    kill -9 "${SERVER_PID}" 2>/dev/null || true
    wait "${SERVER_PID}" 2>/dev/null || true
    SERVER_PID=""
  fi
  # Belt-and-braces: kill any stray llama-server we might have orphaned.
  # Use pgrep -f to match on full command; ${PORT} is unique enough.
  for pid in $(pgrep -f "llama-server.*${PORT}" 2>/dev/null || true); do
    [ "${pid}" != "$$" ] && kill -9 "${pid}" 2>/dev/null || true
  done
  sleep 3
}

# start_server MODEL_PATH ALIAS [extra args...]
start_server() {
  model_path=$1; alias=$2; shift 2
  kill_server
  log "starting server: ${alias} extras: $*"
  "${LLAMA_DIR}/build/bin/llama-server" \
    --model "${model_path}" \
    --alias "${alias}" \
    --device Vulkan0 \
    --flash-attn on \
    --no-host \
    --no-warmup \
    --no-mmproj \
    --batch-size 2048 --ubatch-size 512 \
    --ctx-size 65536 --parallel 1 \
    --jinja \
    --host 127.0.0.1 --port "${PORT}" \
    "$@" \
    >/tmp/llama-srv-bench.log 2>&1 &
  SERVER_PID=$!
  # wait_server may return 1; don't let set -e kill us — caller decides.
  wait_server || return $?
}

# run_bench PROMPT_FILE LABEL --> emits TTFT|PP|TOT and jsonl row
run_bench() {
  pfile=$1; label=$2
  log "  bench: ${label} (${pfile##*/})"
  raw=$("${SCRIPTS_DIR}/bench_model.py" \
    -u "http://127.0.0.1:${PORT}" \
    -t 256 -r 2 \
    --prompt-file "${pfile}" 2>&1) || {
      log "  bench_model.py failed for ${label}"
      echo "?|?|?"; return
  }
  # Save raw output for debugging
  printf '\n----- %s -----\n%s\n' "${label}" "${raw}" >> /tmp/bench-agents-a1.raw.txt
  # bench_model.py Min/Max/Avg/P95 table rows — Avg column is the 3rd number.
  # Example: "TTFT (ms)   16063.3   16063.3   16063.3   16063.3"
  ttft=$(echo "${raw}" | awk '/^TTFT \(ms\)/{print $4; exit}')
  pp=$(echo "${raw}"   | awk '/^PP TPS/{print $5; exit}')   # "PP TPS (prompt) M M A P" — Avg is $5
  tot=$(echo "${raw}"  | awk '/^Total TPS/{print $4; exit}')
  jlog "{\"host\":\"${HOSTNAME_SHORT}\",\"label\":\"${label}\",\"ttft_ms\":\"${ttft:-null}\",\"pp_tps\":\"${pp:-null}\",\"total_tps\":\"${tot:-null}\"}"
  echo "${ttft:-?}|${pp:-?}|${tot:-?}"
}

# ---------------------------------------------------------------------------
# resolve model paths + build info
# ---------------------------------------------------------------------------
BUILD_TAG=$("${LLAMA_DIR}/build/bin/llama-server" --version 2>&1 | awk '/^version:/{print $2}')
BUILD_HASH=$("${LLAMA_DIR}/build/bin/llama-server" --version 2>&1 | awk '/^version:/{print $3}' | tr -d '()')
Q4_FILE=$(hf_resolve  "${HF_HUB}/models--InternScience--Agents-A1-Q4_K_M-GGUF"  "Agents-A1-Q4_K_M.gguf")   || { log "Q4 not cached";  exit 1; }
MTP_FILE=$(hf_resolve "${HF_HUB}/models--protoLabsAI--Agents-A1-MTP-GGUF"       "Agents-A1-MTP-Q8_0.gguf") || { log "MTP not cached"; exit 1; }

log "host=${HOSTNAME_SHORT} os=${OS} build=b${BUILD_TAG} (${BUILD_HASH}) port=${PORT}"
log "Q4  = ${Q4_FILE}"
log "MTP = ${MTP_FILE}"

# Refuse to run if any other llama-server/llama-cli is holding the GPU —
# results would be invalid (VRAM contention, KV pressure, thermal effects).
stray=$(pgrep -f 'llama-(server|cli|bench)' 2>/dev/null | grep -v $$ || true)
if [ -n "${stray}" ]; then
  log "ERROR: other llama-* processes running (will invalidate bench):"
  ps -p ${stray} -o pid,command 2>/dev/null | head -20 >&2
  log "kill them (or set FORCE=1 to bypass this check) and retry"
  [ "${FORCE:-0}" = "1" ] || exit 2
fi

: > "${OUT}"; : > "${JSONLOG}"; : > /tmp/bench-agents-a1.raw.txt

emit "## Agents-A1 bench — ${HOSTNAME_SHORT} (${OS})"
emit
emit "- Build: llama.cpp b${BUILD_TAG} (\`${BUILD_HASH}\`)"
emit "- Date: $(date -u +%Y-%m-%d)"
emit "- Q4:  \`InternScience/Agents-A1-Q4_K_M-GGUF\` — Qwen3.6-35B-A3B MoE agentic fine-tune"
emit "- MTP: \`protoLabsAI/Agents-A1-MTP-Q8_0-GGUF\` — same weights + grafted MTP head"
emit

trap 'kill_server' EXIT INT TERM

# ---------------------------------------------------------------------------
# Stage A — llama-bench pp/tg depth sweep
# ---------------------------------------------------------------------------
stage_llama_bench() {
  emit "### llama-bench — pp4096 + tg128 (fa=1, b=2048, ub=512, --no-host, Vulkan, r=2)"
  emit
  emit "| Model             | Quant | depth | pp4096          | tg128         |"
  emit "|-------------------|-------|------:|----------------:|--------------:|"
  for pair in "Q4:${Q4_FILE}" "Q8_0:${MTP_FILE}"; do
    qname=$(echo "${pair}" | cut -d: -f1)
    qfile=$(echo "${pair}" | cut -d: -f2-)
    for depth in 0 8192 32768; do
      log "llama-bench ${qname} d=${depth}"
      raw=$("${LLAMA_DIR}/build/bin/llama-bench" \
        -m "${qfile}" \
        --device Vulkan0 \
        --flash-attn 1 \
        --batch-size 2048 --ubatch-size 512 \
        --n-prompt 4096 --n-gen 128 \
        --n-depth "${depth}" \
        --no-host 1 \
        --mmap 1 --threads "$(nproc_portable)" \
        --repetitions 2 \
        --output md 2>&1) || { log "  crashed"; raw="CRASH"; }
      pp=$(echo "${raw}" | awk -F'|' '/pp4096/{gsub(/^ *| *$/,"",$(NF-1)); print $(NF-1); exit}')
      tg=$(echo "${raw}" | awk -F'|' '/tg128/{gsub(/^ *| *$/,"",$(NF-1)); print $(NF-1); exit}')
      emit "| Agents-A1         | ${qname}  | ${depth} | ${pp:-crash} | ${tg:-crash} |"
      jlog "{\"stage\":\"llama-bench\",\"host\":\"${HOSTNAME_SHORT}\",\"quant\":\"${qname}\",\"depth\":${depth},\"pp4096\":\"${pp}\",\"tg128\":\"${tg}\"}"
    done
  done
  emit
}

# ---------------------------------------------------------------------------
# Stage B — plain Q4 server bench at ~4k and ~32k
# ---------------------------------------------------------------------------
stage_server_q4() {
  emit "### llama-server + bench_model.py — Agents-A1 Q4_K_M (plain)"
  emit
  emit "| Host       | Depth | TTFT (ms) | PP t/s | Total TPS |"
  emit "|------------|-------|----------:|-------:|----------:|"
  if ! start_server "${Q4_FILE}" "Agents-A1-Q4_K_M"; then
    emit "| ${HOSTNAME_SHORT} | (server failed to start — see /tmp/llama-srv-bench.log) | | | |"
    emit
    return
  fi
  for pair in "~4 k:${SCRIPTS_DIR}/coding_prompt.txt" "~32 k:${SCRIPTS_DIR}/coding_prompt_32k.txt"; do
    depth=$(echo "${pair}" | cut -d: -f1)
    pfile=$(echo "${pair}" | cut -d: -f2)
    res=$(run_bench "${pfile}" "q4:${depth}")
    ttft=$(echo "${res}" | cut -d'|' -f1)
    pp=$(echo "${res}"   | cut -d'|' -f2)
    tot=$(echo "${res}"  | cut -d'|' -f3)
    emit "| ${HOSTNAME_SHORT} | ${depth} | ${ttft} | ${pp} | ${tot} |"
  done
  kill_server
  emit
}

# ---------------------------------------------------------------------------
# Stage C — MTP server bench at N=5 (peak) vs MTP-off baseline (Q8_0 same file)
# ---------------------------------------------------------------------------
stage_server_mtp() {
  emit "### llama-server + bench_model.py — Agents-A1 MTP Q8_0 (spec-type draft-mtp, N=5)"
  emit
  emit "| Host       | MTP | Depth | TTFT (ms) | PP t/s | Total TPS |"
  emit "|------------|-----|-------|----------:|-------:|----------:|"
  # MTP off baseline (same weights)
  if ! start_server "${MTP_FILE}" "Agents-A1-MTP-Q8_0"; then
    emit "| ${HOSTNAME_SHORT} | off | (server failed — see /tmp/llama-srv-bench.log) | | | |"
  else
  for pair in "~4 k:${SCRIPTS_DIR}/coding_prompt.txt" "~32 k:${SCRIPTS_DIR}/coding_prompt_32k.txt"; do
    depth=$(echo "${pair}" | cut -d: -f1)
    pfile=$(echo "${pair}" | cut -d: -f2)
    res=$(run_bench "${pfile}" "mtp-off:${depth}")
    ttft=$(echo "${res}" | cut -d'|' -f1)
    pp=$(echo "${res}"   | cut -d'|' -f2)
    tot=$(echo "${res}"  | cut -d'|' -f3)
    emit "| ${HOSTNAME_SHORT} | off | ${depth} | ${ttft} | ${pp} | ${tot} |"
  done
  fi
  # MTP on, N=5
  if ! start_server "${MTP_FILE}" "Agents-A1-MTP-Q8_0" --spec-type draft-mtp --spec-draft-n-max 5; then
    emit "| ${HOSTNAME_SHORT} | on  | (server failed — see /tmp/llama-srv-bench.log) | | | |"
    kill_server; emit; return
  fi
  for pair in "~4 k:${SCRIPTS_DIR}/coding_prompt.txt" "~32 k:${SCRIPTS_DIR}/coding_prompt_32k.txt"; do
    depth=$(echo "${pair}" | cut -d: -f1)
    pfile=$(echo "${pair}" | cut -d: -f2)
    res=$(run_bench "${pfile}" "mtp-on-n5:${depth}")
    ttft=$(echo "${res}" | cut -d'|' -f1)
    pp=$(echo "${res}"   | cut -d'|' -f2)
    tot=$(echo "${res}"  | cut -d'|' -f3)
    emit "| ${HOSTNAME_SHORT} | on  | ${depth} | ${ttft} | ${pp} | ${tot} |"
  done
  kill_server
  emit
}

# ---------------------------------------------------------------------------
# Stage D — --spec-draft-n-max sweep at ~4k
# ---------------------------------------------------------------------------
stage_mtp_sweep() {
  emit "### --spec-draft-n-max sweep — Agents-A1 MTP Q8_0 at ~4 k"
  emit
  emit "| n_max | TTFT (ms) | PP t/s | Total TPS |"
  emit "|------:|----------:|-------:|----------:|"
  for n in ${MTP_NS}; do
    start_server "${MTP_FILE}" "Agents-A1-MTP-Q8_0" --spec-type draft-mtp --spec-draft-n-max "${n}"
    res=$(run_bench "${SCRIPTS_DIR}/coding_prompt.txt" "mtp-sweep-n${n}")
    ttft=$(echo "${res}" | cut -d'|' -f1)
    pp=$(echo "${res}"   | cut -d'|' -f2)
    tot=$(echo "${res}"  | cut -d'|' -f3)
    emit "| ${n} | ${ttft} | ${pp} | ${tot} |"
    kill_server
  done
  emit
}

# ---------------------------------------------------------------------------
# dispatch
# ---------------------------------------------------------------------------
IFS=,
for stage in ${STAGES}; do
  IFS=' '
  case "${stage}" in
    llama-bench) stage_llama_bench ;;
    server-q4)   stage_server_q4 ;;
    server-mtp)  stage_server_mtp ;;
    mtp-sweep)   stage_mtp_sweep ;;
    *) log "unknown stage: ${stage}" ;;
  esac
done

log "done. see ${OUT} and ${JSONLOG}"
