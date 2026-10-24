#!/usr/local/bin/bash
# Static-weapon group remount regression check (see ../BUG-static-mg-group-remount.md).
#
# Runs MGTest.Demo headlessly with the harness control channel open and counts
# how often the surviving MG gunner changes seat state after the other gunner
# dies.  Before the AIGroupCmd fix this loops at ~1 Hz forever (125 transitions
# in 220 s); with the fix it must stay at 0.
#
# Usage: verify_static_mg_fix.sh [sim-seconds]   (default 300)
set -eu

MISSION_DIR=$(cd "$(dirname "$0")" && pwd)
DATA_ROOT=${CWR_DATA:-$HOME/.local/share/CWR/base}
DURATION=${1:-300}
WORK=$(mktemp -d)
STAGE=$WORK/MGTest.Demo          # --simulate wants <Name>.<World>
LOG=$WORK/server.log

cleanup() {
	[ -n "${SRV_PID:-}" ] && kill "$SRV_PID" 2>/dev/null || true
	rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

mkdir -p "$STAGE"
cp "$MISSION_DIR/mission.sqm" "$STAGE/"

env -u DISPLAY XDG_RUNTIME_DIR=/tmp/xdg PoseidonServer -C "$DATA_ROOT" \
	--simulate "$STAGE" --duration $((DURATION + 60)) --harness 0 --no-sound \
	--log-level info --log-file "$LOG" > "$WORK/stdout" 2>&1 &
SRV_PID=$!

PORT=""
for _ in $(seq 1 60); do
	PORT=$(grep -a -m1 HARNESS_PORT "$WORK/stdout" 2>/dev/null | cut -d= -f2 || true)
	[ -n "$PORT" ] && break
	sleep 1
done
[ -n "$PORT" ] || { echo "FAIL  harness never came up"; tail -5 "$WORK/stdout"; exit 1; }

# 4th arg "natural" waits for the firefight to kill a gunner instead of
# scripting the death; that is flaky, so the default forces it.
python3 "$MISSION_DIR/probe_mg_seats.py" "$PORT" "$DURATION" 1 "${2:-forced}" \
	> "$WORK/timeline.txt"

python3 - "$WORK/timeline.txt" <<'EOF'
import re, sys
rows = [m.groups() for m in
        (re.search(r't=([\d.]+) Lalive=(\w+) Lin=(\w+) Falive=(\w+) Fin=(\w+)', l)
         for l in open(sys.argv[1])) if m]
if not rows:
    print("FAIL  probe produced no samples"); sys.exit(1)

death = next((r[0] for r in rows if r[1] == "false"), None)
flips, prev = 0, None
for r in rows:
    if prev is not None and r[4] != prev:
        flips += 1
    prev = r[4]

print(f"samples={len(rows)}  t={rows[0][0]}..{rows[-1][0]}  "
      f"leader_died_at={death or 'never'}  seat_transitions={flips}")
if death is None:
    print("INCONCLUSIVE  no gunner died during the run - rerun, longer")
    sys.exit(2)
print("PASS  surviving gunner stayed seated" if flips == 0 else
      f"FAIL  surviving gunner cycled {flips} times")
sys.exit(0 if flips == 0 else 1)
EOF
