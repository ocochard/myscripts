#!/bin/sh
# CLIENT determinism gate batch: PoseidonGame --benchmark --determinism-log N times.
# --benchmark runs a FIXED frame count, so the per-tick DETERMINISM sequence has a
# deterministic length -> clean full-sequence compare. Any run whose sequence
# differs from run 1 = a determinism divergence (the residual). This is the vehicle
# the residual was historically characterized on (client, not server --simulate).
set -u
N="${1:-100}"; TAG="${2:-client}"
DATA="$HOME/.local/share/CWR/base"
MISSION="$HOME/.config/CWR/Users/Test/Missions/Benchmark.Abel"
# discover the active local X session (NOT :0): running Xorg's display + user auth
DISP=$(ps auxww | grep -m1 '[X]org' | grep -oE ' :[0-9]+' | tr -d ' ')
: "${DISP:=:0}"
export DISPLAY="$DISP" XAUTHORITY="$HOME/.Xauthority" XDG_RUNTIME_DIR=/tmp/xdg
echo "using DISPLAY=$DISPLAY XAUTHORITY=$XAUTHORITY"
OUT=/tmp/cdetgate_$TAG; rm -rf "$OUT"; mkdir -p "$OUT"

r=0
while [ "$r" -lt "$N" ]; do
  r=$((r + 1))
  timeout 90 env DISPLAY="$DISPLAY" XAUTHORITY="$XAUTHORITY" XDG_RUNTIME_DIR=/tmp/xdg \
    PoseidonGame -C "$DATA" --no-splash --no-sound --benchmark --test-mission "$MISSION" \
    --determinism-log --log-file "$OUT/run_$r.log" >/dev/null 2>&1
  grep 'DETERMINISM:' "$OUT/run_$r.log" | sed -E 's/.*DETERMINISM: //; s/ n=[0-9]+//' > "$OUT/seq_$r.txt"
  [ $((r % 10)) -eq 0 ] && echo "run $r: $(wc -l < "$OUT/seq_$r.txt") ticks"
done
echo "RESULT batch done: $OUT"
