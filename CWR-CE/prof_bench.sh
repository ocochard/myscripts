#!/bin/sh
# CWR-CE FPS A/B harness (ser6). Reproducible --benchmark runs on the 197-unit
# Test-profile mission, N runs per config, mean + ministat comparison.
#
# WHY this exists: the exact command kept getting lost to session-temp scratchpad.
# See DEBUGGING.md ("-benchmark mode") and PERF-hotspot-profile.md for the writeup.
#
# The load-bearing detail is --test-mission pointing at the Test-profile mission
# (~/.config/CWR/Users/Test/Missions/Benchmark.Abel, 197 units, ~80 FPS). Do NOT
# use ~/.local/share/Cold War Assault/missions/benchmark.abel (empty, ~1500 FPS),
# and NOT --benchmark alone (sits at the menu on this host).
#
# draw=0 in the BENCHMARK line is a terrain-mesh counter; objects DO render.
# FPS is noisy (sigma ~5); judge CPU/upload opts by the pmcstat profile, not FPS.
#
# Usage:  sh prof_bench.sh [N_runs]        (default 5)
#         env EXTRA="--gpu-skinning" ...    is applied to the "gpu" config below.

set -eu
N="${1:-5}"
DATA="$HOME/.local/share/CWR/base"
MISSION="$HOME/.config/CWR/Users/Test/Missions/Benchmark.Abel"
GAME=/usr/local/bin/PoseidonGame
export DISPLAY="${DISPLAY:-:0}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/xdg}"
mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null || true

# Uncapped FPS (ser6 graphics.cfg is normally vsync=1 -> capped at 60).
CFG="$HOME/.config/CWR/graphics.cfg"
[ -f "$CFG" ] && { cp "$CFG" /tmp/graphics.cfg.bak; sed -i 's/vsync=1;/vsync=0;/' "$CFG"; }
restore() { [ -f /tmp/graphics.cfg.bak ] && cp /tmp/graphics.cfg.bak "$CFG"; }
trap restore EXIT

: > /tmp/fps_base.txt; : > /tmp/fps_gpu.txt
run=0
while [ "$run" -lt "$N" ]; do
  run=$((run + 1))
  for cfg in base gpu; do
    flag=""; [ "$cfg" = gpu ] && flag="--gpu-skinning"
    timeout 22 env DISPLAY="$DISPLAY" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
      "$GAME" -C "$DATA" --no-splash --benchmark --test-mission "$MISSION" $flag \
      >/tmp/run.log 2>&1 || true
    v=$(grep 'BENCHMARK: t=' /tmp/run.log | tail -1 | grep -oE 'aFPS=[0-9.]+' | cut -d= -f2)
    echo "${v:-NA}" >> "/tmp/fps_$cfg.txt"
  done
done

echo "baseline aFPS:"; cat /tmp/fps_base.txt
echo "gpu-skin aFPS:"; cat /tmp/fps_gpu.txt
awk '{s+=$1;n++} END{printf "baseline mean=%.1f (n=%d)\n",s/n,n}' /tmp/fps_base.txt
awk '{s+=$1;n++} END{printf "gpu-skin mean=%.1f (n=%d)\n",s/n,n}' /tmp/fps_gpu.txt
command -v ministat >/dev/null 2>&1 && ministat -c 95 /tmp/fps_base.txt /tmp/fps_gpu.txt || true
