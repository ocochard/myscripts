#!/bin/sh
# Same model on both hosts, so the only variable is the OS.
#
# WHY: running two DIFFERENT models on two different OSes (as the first
# parallel run did) is confounded — a difference cannot be attributed to the
# model or to FreeBSD-vs-Ubuntu. Serving the SAME model on both isolates the
# OS, and the hardware is identical (same Framework Desktop, 8 x 16 GB).
#
# WHAT IT ACTUALLY MEASURES: pass/fail here is a QUALITY signal, and the same
# model should produce the same quality on either OS. So the useful output of
# a swapped run is:
#   * model_s        — is the same model slower to think on one OS?
#   * failure_class  — does one OS trip MTP/RADV faults the other does not?
#                      (frwk-bsd has a documented Mesa-26 CPC-write fault on
#                      the draft-mtp path; frwk-linux/Mesa 25-26 does not)
# A pass/fail DIFFERENCE between the two would be surprising and worth
# investigating as nondeterminism, not celebrated as an OS win.
#
# FAIRNESS WARNING — read before comparing numbers:
# llmsrv.sh pins a different --ctx-size per slot, and this agent loop resends
# its whole history each step, so context is a hard limiter on how far a task
# can get. Measured on the first parallel run:
#     framework  (qwen38-mtp) ctx 131072
#     framework2 (flashnext)  ctx  32768   <- 4x smaller
# flashnext hit "exceed_context_size_error" at 37856 tokens on t2 and the task
# ended there. Serve BOTH hosts with the same model AND the same CTX, or the
# comparison measures the context budget rather than the OS.
#
# Usage:
#   sudo ./swap-run.sh <slot> [ctx]
#     slot: an llmsrv.sh MODEL= slot (qwen38-mtp | qwen38-q8 | flashnext)
#     ctx:  --ctx-size for BOTH endpoints (default: leave llmsrv's own value)
set -eu

SLOT=${1:?usage: $0 <llmsrv-slot> [ctx]}
CTX_ARG=${2:-}

FW1_IP=${FW1_IP:-192.168.100.7}    # framework  — FreeBSD
FW2_IP=${FW2_IP:-192.168.100.8}    # framework2 — Ubuntu
HERE=$(cd -- "$(dirname -- "$0")" && pwd)
DISK=${DISK:-/zroot/vm/fbsdq.img}
SRC=${SRC:-/usr/src}

ctx_env=""
[ -n "$CTX_ARG" ] && ctx_env="CTX=$CTX_ARG"

# ssh must run as the INVOKING user, not root.
#
# This script is run under sudo because the bench needs root for bhyve, but
# root has no ~/.ssh/config and these hostnames exist ONLY as ssh-config
# aliases — `framework2` is NXDOMAIN in DNS. Running ssh as root therefore
# fails with "Could not resolve hostname framework2" and/or "Host key
# verification failed", and the endpoints never start.
SSH_USER=${SUDO_USER:-$(id -un)}
if [ "$(id -un)" = "$SSH_USER" ]; then
	as_user() { "$@"; }
else
	as_user() { su -l "$SSH_USER" -c "$*"; }
fi

echo "==> using ssh as user: $SSH_USER"
echo "==> stopping any running llama-server on both hosts"
for h in framework framework2; do
	as_user "ssh -o ConnectTimeout=10 $h 'pkill -f \"[l]lama-server\" 2>/dev/null; exit 0'" || true
done
sleep 5

echo "==> starting MODEL=$SLOT ${ctx_env:+($ctx_env)} on both hosts"
as_user "ssh -o ConnectTimeout=10 framework \
	'cd ~/myscripts/LLM && MODEL=$SLOT HOST=0.0.0.0 $ctx_env nohup sh ./llmsrv.sh \
	 > /tmp/llmsrv-swap.log 2>&1 < /dev/null & echo started'" || true
as_user "ssh -o ConnectTimeout=10 framework2 \
	'cd ~/myscripts/LLM && MODEL=$SLOT HOST=0.0.0.0 $ctx_env nohup bash ./llmsrv.sh \
	 > /tmp/llmsrv-swap.log 2>&1 < /dev/null & echo started'" || true

echo "==> waiting for both endpoints to serve (up to 20 min; a 93 GB model is slow)"
mid1=""; mid2=""
end=$(( $(date +%s) + 1200 ))
while [ "$(date +%s)" -lt "$end" ]; do
	[ -z "$mid1" ] && mid1=$(curl -s -m 8 "http://$FW1_IP:8080/v1/models" 2>/dev/null |
		sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
	[ -z "$mid2" ] && mid2=$(curl -s -m 8 "http://$FW2_IP:8080/v1/models" 2>/dev/null |
		sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
	[ -n "$mid1" ] && [ -n "$mid2" ] && break
	sleep 15
done
[ -n "$mid1" ] || { echo "$0: framework never served" >&2; exit 1; }
[ -n "$mid2" ] || { echo "$0: framework2 never served" >&2; exit 1; }

# Both must be the SAME model, or this is not an OS comparison at all.
if [ "$mid1" != "$mid2" ]; then
	echo "$0: REFUSING: endpoints serve different models" >&2
	echo "  framework : $mid1" >&2
	echo "  framework2: $mid2" >&2
	exit 1
fi
echo "==> both serving: $mid1"

# Report the context each endpoint actually offers — see the fairness warning.
for pair in "framework $FW1_IP" "framework2 $FW2_IP"; do
	set -- $pair
	c=$(curl -s -m 8 "http://$2:8080/props" 2>/dev/null |
		sed -n 's/.*"n_ctx"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' | head -1)
	echo "    $1 n_ctx=${c:-?}"
done

echo "==> launching both benches in parallel (all 3 tiers)"
cd "$HERE"
env LOGDIR="$HERE/logs" ./run.sh \
	--backend openai --api-base "http://$FW1_IP:8080/v1" \
	--model "$mid1" --api-key none \
	--disk "$DISK" --src "$SRC" --src-mode ro --agent-user olivier \
	--reps 1 --max-steps 30 --run-id "swap-${SLOT}-freebsd" \
	> /tmp/swap-freebsd.out 2>&1 &
sleep 8
env LOGDIR="$HERE/logs" ./run.sh \
	--backend openai --api-base "http://$FW2_IP:8080/v1" \
	--model "$mid2" --api-key none \
	--disk "$DISK" --src "$SRC" --src-mode ro --agent-user olivier \
	--reps 1 --max-steps 30 --run-id "swap-${SLOT}-ubuntu" \
	> /tmp/swap-ubuntu.out 2>&1 &

echo "==> started. run_ids: swap-${SLOT}-freebsd / swap-${SLOT}-ubuntu"
echo "    tail -f /tmp/swap-freebsd.out /tmp/swap-ubuntu.out"
wait
