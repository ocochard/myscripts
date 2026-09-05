#!/bin/sh
# Bootstrap wrapper: creates the venv, installs deps, runs the bench, and tees
# everything to a log.
#
# bench.py itself needs smolagents, which is not in the base system and should
# not be installed into the system python. This script owns that so no manual
# `pip install` step is needed.
#
# The image builder (mkimage.sh) needs NONE of this — it is /bin/sh and base
# tools only.
#
# Usage:
#   sudo ./run.sh --model claude-opus-4-5 \
#        --api-base http://127.0.0.1:20000/proxy/ocochardclaude \
#        --backend anthropic --disk /zroot/vm/fbsdq.img
#
# Everything after the options is passed straight to bench.py.
set -eu

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
VENV=${VENV:-$HERE/.venv}
LOGDIR=${LOGDIR:-$HERE/logs}

# Re-exec check: mdconfig/bhyve need root, but see --agent-user in bench.py —
# the agent's own shell should NOT be root.
[ "$(id -u)" -eq 0 ] || echo "$0: note: not root; VM steps will fail" >&2

if [ ! -x "$VENV/bin/python" ]; then
	echo "==> creating venv at $VENV (--system-site-packages)"
	# --system-site-packages so FreeBSD's own py3xx-* packages stay visible.
	# py312-anthropic is available from pkg and is already installed here;
	# a sealed venv would hide it and force a pip rebuild of the same thing.
	# Prefer pkg for anything pkg ships (it is built and tested against this
	# OS); pip only fills the gaps, i.e. smolagents.
	python3 -m venv --system-site-packages "$VENV"
	"$VENV/bin/python" -m pip install --quiet --upgrade pip
	echo "==> installing $HERE/requirements.txt"
	"$VENV/bin/python" -m pip install --quiet -r "$HERE/requirements.txt"
else
	# Cheap check that the venv is actually usable, rather than assuming.
	"$VENV/bin/python" -c "import smolagents" 2>/dev/null || {
		echo "==> venv exists but smolagents missing; installing"
		"$VENV/bin/python" -m pip install --quiet -r "$HERE/requirements.txt"
	}
fi

# Report which deps came from where, so a log shows whether the pkg or the pip
# copy of a library was in play.
"$VENV/bin/python" - <<'PY'
import importlib
for m in ("smolagents", "anthropic", "openai"):
    try:
        mod = importlib.import_module(m)
        src = "pkg" if "/usr/local/lib" in (mod.__file__ or "") else "venv"
        print(f"    {m:<12} {getattr(mod, '__version__', '?'):<12} [{src}]")
    except ImportError:
        print(f"    {m:<12} (not installed)")
PY

mkdir -p "$LOGDIR"
STAMP=$(date +%Y%m%d-%H%M%S)
LOG="$LOGDIR/bench-$STAMP.log"

echo "==> logging to $LOG"
echo "==> $("$VENV/bin/python" -c 'import smolagents; print("smolagents", smolagents.__version__)')"

# Record the invocation and environment so a log is self-contained when read
# months later.
{
	echo "=== fbsd-quality run $STAMP ==="
	echo "argv: $0 $*"
	echo "host: $(uname -a)"
	echo "host __FreeBSD_version: $(sysctl -n kern.osreldate)"
	echo "python: $("$VENV/bin/python" -V 2>&1)"
	echo "smolagents: $("$VENV/bin/python" -c 'import smolagents; print(smolagents.__version__)' 2>&1)"
	echo "=== begin ==="
} > "$LOG"

# Unbuffered so a tailed log stays live during long agent steps; stderr merged
# because bench.py writes progress there and results to stdout.
PYTHONDONTWRITEBYTECODE=1 "$VENV/bin/python" -u "$HERE/bench.py" "$@" 2>&1 | tee -a "$LOG"
rc=$?

echo "=== end (exit $rc) ===" >> "$LOG"
echo "==> log: $LOG"
exit $rc
