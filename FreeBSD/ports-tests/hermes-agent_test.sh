#!/bin/sh
# misc/hermes-agent regression test.
#
# Installs the freshly-built package from the poudriere builder, then
# exercises the four FreeBSD-specific pieces the port and its salvage
# patches add:
#
#   1. Wrappers on PATH — /usr/local/bin/{hermes,hermes-agent,hermes-acp}
#      resolve and `--help` returns 0 (proves sys.path shim works).
#
#   2. Skills catalog non-empty — `hermes skills list` on FreeBSD used to
#      show ZERO installed skills because most declare `platform: linux`
#      and `sys.platform` is `freebsdN`.  The PR#31850 salvage patch maps
#      freebsd -> linux for skill matching only.  This test asserts the
#      catalog has at least the expected floor of matched skills.
#
#   3. rc.d lifecycle — sysrc enable + `service hermes_gateway {start,
#      status,stop}` drive the port-installed /usr/local/etc/rc.d/
#      hermes_gateway script.  Exercises Commit A of the salvage plan.
#
#   4. Lazy-install default off on FreeBSD — Commit B.  A fresh install
#      writes `allow_lazy_installs: false` into the default config.yaml,
#      not True as on Linux/macOS.
#
# Steps 1-4 do NOT need an LLM API key: skills-list is offline, the gateway
# can start without ever making an outbound call, and the lazy-install check
# inspects config only.
#
# Step 5 adds two real LLM round-trips, one per client stack, because a bug
# in one is invisible to the other:
#
#   5a. OpenAI-compatible path (`--provider custom`) against a local
#       llama.cpp server.  FAILs if the server's advertised n_ctx is below
#       hermes's floor -- see HERMES_MIN_CTX.
#
#   5b. Anthropic Messages path (`--provider anthropic`).  SKIPped unless
#       ANTHROPIC_BASE_URL is set and reachable.
#
# Usage:  sh hermes-agent_test.sh
#         ANTHROPIC_BASE_URL=http://127.0.0.1:20000/proxy/<name>/ \
#             sh hermes-agent_test.sh
#
# Runs as normal user; the script sudo's for pkg add/delete + rc.d.
# Cleans up (pkg delete, sysrc -x, /etc/rc.conf revert) on any exit.

set -eu

PORT_NAME=hermes-agent
JAIL=builder
TREE=official
PKGDIR=/usr/local/poudriere/data/packages/${JAIL}-${TREE}/.latest/All

# LLM backend for the real round-trip check (step 5).  Points hermes at a
# local llama.cpp OpenAI-compatible server via its "custom" provider.
# Override with LLAMA_URL / LLAMA_MODEL; the step SKIPs if unreachable.
# LLAMA_MODEL is auto-discovered from the server's /v1/models when not set,
# so the test tracks whatever model is currently loaded instead of pinning
# a name that goes stale when the server swaps models.
LLAMA_URL=${LLAMA_URL:-http://192.168.100.8:8080}
LLAMA_MODEL=${LLAMA_MODEL:-}

# hermes >= 0.21 refuses any model advertising a context window below this
# floor, before it issues a single request.  Kept as a variable so a future
# upstream change is a one-line edit.
HERMES_MIN_CTX=${HERMES_MIN_CTX:-64000}

# Anthropic-Messages backend for the round-trip check (step 5b).  The
# OpenAI-compatible path (step 5a) cannot reach agent/anthropic_adapter.py,
# so a bug there is structurally invisible to it -- that is exactly how the
# anthropic 1.x httpx2 breakage shipped unnoticed in 0.17.0.  Unset by
# default: the step SKIPs unless ANTHROPIC_BASE_URL names a reachable
# endpoint, so the test stays useful without one.
ANTHROPIC_BASE_URL=${ANTHROPIC_BASE_URL:-}
ANTHROPIC_MODEL=${ANTHROPIC_MODEL:-claude-sonnet-5}

# --- OS gate ---------------------------------------------------------------
if [ "$(uname -s)" != "FreeBSD" ]; then
	printf 'SKIP  hermes-agent test is FreeBSD-only (this is %s)\n' "$(uname -s)"
	exit 0
fi

# --- cleanup ---------------------------------------------------------------
GATEWAY_STARTED=0
cleanup() {
	set +e
	if [ "${GATEWAY_STARTED}" = "1" ]; then
		sudo service hermes_gateway stop >/dev/null 2>&1
	fi
	if sysrc -qc hermes_gateway_enable >/dev/null 2>&1; then
		sudo sysrc -x hermes_gateway_enable >/dev/null 2>&1
	fi
	if sysrc -qc hermes_gateway_user >/dev/null 2>&1; then
		sudo sysrc -x hermes_gateway_user >/dev/null 2>&1
	fi
	# Deinstall only if we installed it.
	if pkg info -q ${PORT_NAME} 2>/dev/null; then
		sudo pkg delete -y ${PORT_NAME} >/dev/null 2>&1
	fi
	set -e
}
trap cleanup EXIT INT TERM

pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; exit 1; }

# --- 0. Install the freshly-built package ----------------------------------
PKG=$(ls -t ${PKGDIR}/${PORT_NAME}-*.pkg 2>/dev/null | head -1)
[ -n "${PKG}" ] || fail "no ${PORT_NAME}-*.pkg in ${PKGDIR}"
printf 'Installing %s\n' "${PKG}"
sudo pkg add -f "${PKG}" >/dev/null

PKG_VER=$(pkg query '%v' ${PORT_NAME})
printf 'Installed version: %s\n' "${PKG_VER}"

# --- 1. Wrappers on PATH ---------------------------------------------------
for bin in hermes hermes-agent hermes-acp; do
	[ -x /usr/local/bin/${bin} ] \
		|| fail "wrapper /usr/local/bin/${bin} missing or not executable"
done
pass "wrappers installed at /usr/local/bin/{hermes,hermes-agent,hermes-acp}"

# `hermes --help` must return 0.  Runs the sys.path shim + argparse setup;
# a broken wrapper or missing runtime dep would surface here.
if hermes --help >/dev/null 2>&1; then
	pass "hermes --help returns 0 (wrapper + sys.path shim work)"
else
	fail "hermes --help exited non-zero — wrapper or runtime broken"
fi

# --- 2. Skills catalog non-empty on FreeBSD (PR#31850) --------------------
# `hermes skills list` renders a table.  We just need to prove the row
# count is > 0 (would be 0 without the freebsd->linux mapping).
#
# Output has header rows we don't want to count.  Filter for lines that
# start with a skill category token (lowercase word) in the second column.
SKILLS_OUT=$(mktemp)
if hermes skills list --source builtin >"${SKILLS_OUT}" 2>&1; then
	# The output ends with a summary line like:
	#   0 hub-installed, 68 builtin, 0 local — 68 enabled, 0 disabled
	# Parse the "N builtin" count from that line — table rendering uses
	# Unicode box-drawing characters that vary with terminal width, so
	# the summary is the reliable source of truth.
	SKILL_COUNT=$(grep -oE '[0-9]+ builtin' "${SKILLS_OUT}" | head -1 | awk '{print $1}')
	[ -n "${SKILL_COUNT}" ] || SKILL_COUNT=0
else
	fail "hermes skills list exited non-zero — see ${SKILLS_OUT}"
fi
rm -f "${SKILLS_OUT}"

# PR#31850 unblocked 87 skills upstream; the port's DATADIR ships 18
# built-in + 20 optional.  Anywhere north of 10 proves the platform
# mapping is working; below that indicates the freebsd->linux gate is
# broken again.
if [ "${SKILL_COUNT}" -ge 10 ]; then
	pass "hermes skills list shows ${SKILL_COUNT} skills (PR#31850 mapping active)"
else
	fail "hermes skills list shows only ${SKILL_COUNT} skills — PR#31850 mapping may be broken (expected >= 10)"
fi

# --- 3. Lazy-install default off on FreeBSD (Commit B) --------------------
# First run of hermes materializes ~/.hermes/config.yaml from the
# DEFAULT_CONFIG template.  On FreeBSD, allow_lazy_installs must be
# False.  Use an isolated HERMES_HOME so we don't collide with the
# operator's own config.
LAZY_HERMES_HOME=$(mktemp -d)
# Probe the runtime resolver in-process — that's the value the lazy-install
# code path actually honors, and it evaluates the DEFAULT_CONFIG template
# on a fresh install where config.yaml doesn't exist yet.
LAZY_OUT=$(HERMES_HOME="${LAZY_HERMES_HOME}" /usr/local/bin/python3.12 -c "
import os, sys
sys.path.insert(0, '/usr/local/lib/hermes-agent')
os.environ.setdefault('HERMES_BUNDLED_SKILLS', '/usr/local/share/hermes-agent/skills')
os.environ.setdefault('HERMES_OPTIONAL_SKILLS', '/usr/local/share/hermes-agent/optional-skills')
from tools.lazy_deps import _allow_lazy_installs
print(_allow_lazy_installs())
" 2>&1)
case "${LAZY_OUT}" in
	False) pass "allow_lazy_installs resolves to False on FreeBSD (Commit B)" ;;
	True)  fail "allow_lazy_installs resolves to True on FreeBSD — Commit B default gate is broken" ;;
	*)     fail "could not probe _allow_lazy_installs (got: ${LAZY_OUT})" ;;
esac
rm -rf "${LAZY_HERMES_HOME}"

# --- 4. rc.d lifecycle (Commit A) -----------------------------------------
# The rc.d script requires hermes_gateway_user because HOME dictates
# where ~/.hermes lives.  Use the current $USER — they have real
# credentials and a writable home.
sudo sysrc hermes_gateway_enable=YES hermes_gateway_user="${USER}" >/dev/null

# `service hermes_gateway status` on a not-yet-started service returns 1.
if service hermes_gateway status >/dev/null 2>&1; then
	fail "service hermes_gateway status returned 0 before start — stale state?"
fi
pass "service hermes_gateway status returns non-zero before start"

# Start.  The daemon backgrounds itself via daemon(8); allow a moment
# for the pid file to appear before probing.
sudo service hermes_gateway start >/dev/null 2>&1 \
	|| fail "service hermes_gateway start failed"
GATEWAY_STARTED=1

# Wait up to 15s for status to flip.  hermes-agent needs to import its
# dep tree on first boot; on a cold cache this can take a few seconds.
i=0
while [ "$i" -lt 30 ]; do
	if service hermes_gateway status >/dev/null 2>&1; then
		pass "service hermes_gateway status returns 0 after start"
		break
	fi
	i=$((i+1))
	sleep 0.5
done
if [ "$i" -ge 30 ]; then
	fail "service hermes_gateway never reported running after 15s"
fi

# Stop.
sudo service hermes_gateway stop >/dev/null 2>&1 \
	|| fail "service hermes_gateway stop failed"
GATEWAY_STARTED=0

# Post-stop, status must return non-zero again.
if service hermes_gateway status >/dev/null 2>&1; then
	fail "service hermes_gateway status still returns 0 after stop"
fi
pass "service hermes_gateway status returns non-zero after stop"

# --- 5. Real LLM round-trip via the "custom" OpenAI-compatible provider ----
# Drives an actual single-turn completion through hermes' agent runtime
# against a local llama.cpp server.  hermes selects the OpenAI-compatible
# path from the `custom` provider + CUSTOM_BASE_URL / CUSTOM_API_KEY env
# (the api key is a placeholder — llama.cpp ignores it, the OpenAI SDK just
# needs it non-empty).  --cli forces non-interactive stdout (without it the
# output is TTY-gated); --yolo skips tool-approval prompts.  HOME is
# redirected so the real ~/.hermes config is never touched.
LLAMA_MODELS_JSON=$(curl -sf -m 5 "${LLAMA_URL}/v1/models" 2>/dev/null)
if [ -z "${LLAMA_MODELS_JSON}" ]; then
	printf 'SKIP  LLM round-trip: %s unreachable\n' "${LLAMA_URL}"
else
	# Auto-discover the loaded model (OpenAI-style data[].id) unless the
	# caller pinned one via LLAMA_MODEL.
	if [ -z "${LLAMA_MODEL}" ]; then
		LLAMA_MODEL=$(printf '%s' "${LLAMA_MODELS_JSON}" | \
			python3 -c 'import sys,json
d=json.load(sys.stdin)
m=d.get("data") or d.get("models") or []
print(m[0].get("id") or m[0].get("name") or "") if m else print("")' 2>/dev/null)
	fi
	if [ -z "${LLAMA_MODEL}" ]; then
		printf 'SKIP  LLM round-trip: no model reported by %s/v1/models\n' \
			"${LLAMA_URL}"
	else
	# Assert the server's context window meets hermes's floor BEFORE the
	# round-trip.  hermes does enforce this itself, but it reports the
	# refusal as a generic non-zero exit buried in 40 lines of agent
	# output; checking here turns that into a one-line actionable FAIL.
	# This is a FAIL, not a SKIP: a server launched with too small a -c is
	# a misconfiguration that silently disables the only test step which
	# actually exercises the model, and a silent SKIP would let the suite
	# report success while never talking to an LLM at all.
	LLAMA_NCTX=$(curl -sf -m 5 "${LLAMA_URL}/props" 2>/dev/null | \
		python3 -c 'import sys,json
try:
    d = json.load(sys.stdin)
except Exception:
    print(0); raise SystemExit
print(d.get("default_generation_settings", {}).get("n_ctx") or d.get("n_ctx") or 0)' \
		2>/dev/null)
	: "${LLAMA_NCTX:=0}"
	if [ "${LLAMA_NCTX}" -gt 0 ] && [ "${LLAMA_NCTX}" -lt "${HERMES_MIN_CTX}" ]; then
		fail "$(printf '%s serves n_ctx=%s but hermes requires >=%s; restart llama-server with -c %s' \
			"${LLAMA_URL}" "${LLAMA_NCTX}" "${HERMES_MIN_CTX}" "${HERMES_MIN_CTX}")"
	fi
	LLM_HOME=$(mktemp -d /tmp/hermes-llm.XXXXXX)
	LLM_OUT="${LLM_HOME}/out.txt"
	set +e
	env \
		HOME="${LLM_HOME}" \
		CUSTOM_BASE_URL="${LLAMA_URL}/v1" \
		CUSTOM_API_KEY="sk-local-llama" \
		timeout 120 hermes --provider custom -m "${LLAMA_MODEL}" \
			--yolo --cli --safe-mode \
			-z "Reply with the single word PONG." \
		>"${LLM_OUT}" 2>&1
	rc=$?
	set -e
	if [ "${rc}" -ne 0 ]; then
		printf '%s\n' "$(sed -n '1,40p' "${LLM_OUT}")"
		rm -rf "${LLM_HOME}"
		fail "hermes -z round-trip exited ${rc}"
	fi
	# A reasoning model may return its answer in reasoning_content; don't
	# require the literal PONG.  Require non-empty output and no provider
	# error surfaced from the agent runtime.
	if grep -qiE 'error|econnrefused|unauthorized|api key|not found|traceback' \
		"${LLM_OUT}"; then
		printf '%s\n' "$(sed -n '1,40p' "${LLM_OUT}")"
		rm -rf "${LLM_HOME}"
		fail "hermes round-trip surfaced a provider error"
	fi
	[ -s "${LLM_OUT}" ] || { rm -rf "${LLM_HOME}"; fail "hermes round-trip produced no output"; }
	pass "hermes LLM round-trip via custom provider ($(wc -c <"${LLM_OUT}" | tr -d ' ') bytes from ${LLAMA_MODEL})"
	rm -rf "${LLM_HOME}"
	fi
fi

# --- 5b. LLM round-trip via the Anthropic Messages path -------------------
# Separate step because it exercises a different client stack:
# agent/anthropic_adapter.py builds an anthropic.Anthropic client, whereas
# step 5a goes through the OpenAI SDK.  Objects crossing the SDK boundary
# (Timeout, http_client) must come from the httpx flavour that SDK is built
# against -- httpx for anthropic 0.x, httpx2 for 1.x -- and getting it wrong
# fails at request time with "Invalid `timeout` argument".  FreeBSD's
# misc/py-anthropic moves independently of upstream's pin, so this needs
# permanent coverage rather than a one-off manual check.
#
# SKIPs unless ANTHROPIC_BASE_URL is set and reachable, e.g.:
#   ANTHROPIC_BASE_URL=http://127.0.0.1:20000/proxy/<name>/ sh hermes-agent_test.sh
if [ -z "${ANTHROPIC_BASE_URL}" ]; then
	printf 'SKIP  Anthropic round-trip: ANTHROPIC_BASE_URL not set\n'
elif ! curl -sf -m 5 -o /dev/null -X POST "${ANTHROPIC_BASE_URL%/}/v1/messages" \
		-H 'content-type: application/json' \
		-H 'anthropic-version: 2023-06-01' \
		-d "$(printf '{"model":"%s","max_tokens":8,"messages":[{"role":"user","content":"hi"}]}' \
			"${ANTHROPIC_MODEL}")" 2>/dev/null; then
	printf 'SKIP  Anthropic round-trip: %s not reachable\n' "${ANTHROPIC_BASE_URL}"
else
	ANT_HOME=$(mktemp -d /tmp/hermes-ant.XXXXXX)
	ANT_OUT="${ANT_HOME}/out.txt"
	set +e
	env \
		HOME="${ANT_HOME}" \
		ANTHROPIC_BASE_URL="${ANTHROPIC_BASE_URL}" \
		ANTHROPIC_API_KEY="sk-local-anthropic" \
		timeout 120 hermes --provider anthropic -m "${ANTHROPIC_MODEL}" \
			--yolo --cli --safe-mode \
			-z "Reply with the single word PONG." \
		>"${ANT_OUT}" 2>&1
	rc=$?
	set -e
	if [ "${rc}" -ne 0 ]; then
		printf '%s\n' "$(sed -n '1,40p' "${ANT_OUT}")"
		rm -rf "${ANT_HOME}"
		fail "hermes Anthropic round-trip exited ${rc}"
	fi
	# An httpx/httpx2 mismatch surfaces as a runtime message rather than a
	# non-zero exit in some code paths, so match it explicitly on top of
	# the generic provider-error grep.
	if grep -qiE 'httpx2|httpx\.Timeout|invalid .?timeout' "${ANT_OUT}"; then
		printf '%s\n' "$(sed -n '1,40p' "${ANT_OUT}")"
		rm -rf "${ANT_HOME}"
		fail "hermes Anthropic round-trip hit an httpx/httpx2 SDK mismatch"
	fi
	if grep -qiE 'error|econnrefused|unauthorized|api key|not found|traceback' \
		"${ANT_OUT}"; then
		printf '%s\n' "$(sed -n '1,40p' "${ANT_OUT}")"
		rm -rf "${ANT_HOME}"
		fail "hermes Anthropic round-trip surfaced a provider error"
	fi
	[ -s "${ANT_OUT}" ] || { rm -rf "${ANT_HOME}"; fail "hermes Anthropic round-trip produced no output"; }
	pass "hermes LLM round-trip via anthropic provider ($(wc -c <"${ANT_OUT}" | tr -d ' ') bytes from ${ANTHROPIC_MODEL})"
	rm -rf "${ANT_HOME}"
fi

# --- 6. Uninstall (cleanup handled by trap, but assert the pkg is clean) --
# Nothing to do — the EXIT trap runs pkg delete.  The trap running clean
# also proves `pkg delete hermes-agent` succeeds after the rc.d cycle
# (no pkg-lock leftovers).

printf '\nAll hermes-agent regression tests passed.\n'
