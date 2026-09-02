#!/bin/sh
# misc/py-anthropic smoke test.
#
# Installs the freshly-built py-anthropic package from the poudriere builder,
# imports the library, checks version + main surface (Anthropic client class,
# message stream types), instantiates a client without making a network call,
# then uninstalls the package.
#
# The offline stages need no key and no network.  If ~/.claude/settings.json
# points ANTHROPIC_BASE_URL at a reachable Anthropic-compatible endpoint, a
# final stage also does one real round-trip through the SDK; otherwise that
# stage SKIPs.  The goal is still to catch packaging breakage, not to test the
# upstream SDK.
#
# The FreeBSD package name carries the active python flavor prefix
# (py311-, py312-, ...).  This script derives the prefix from the pkg
# file itself so it keeps working when the tree's default python flips.
set -eu

PORT_BASE=anthropic         # module + suffix of the pkg name
JAIL=builder
TREE=official
PKGDIR=/usr/local/poudriere/data/packages/${JAIL}-${TREE}/.latest/All

# Discover the freshly-built package: py3XX-anthropic-<ver>.pkg
PKG=$(ls -t ${PKGDIR}/py3*-${PORT_BASE}-*.pkg 2>/dev/null | head -1)
[ -n "${PKG}" ] || {
	echo "FAIL  no py3*-${PORT_BASE}-*.pkg in ${PKGDIR}"
	exit 1
}
PKG_NAME=$(basename "${PKG}" | sed -E 's/-[0-9].*$//')  # py3XX-anthropic

# Skip uninstall if something else on the host depends on the package
# (e.g. hermes-agent depends on py-anthropic).  `pkg delete -y` would
# cascade and remove the consumer too.
PREEXISTED=0
HAS_REVDEPS=0

cleanup() {
	if [ "${HAS_REVDEPS}" = 1 ]; then
		echo "Leaving ${PKG_NAME} installed (other packages depend on it)"
	elif [ "${PREEXISTED}" = 0 ]; then
		sudo pkg delete -y "${PKG_NAME}" 2>/dev/null || true
	else
		echo "Leaving ${PKG_NAME} installed (was present before test)"
	fi
}
trap cleanup EXIT INT TERM

# 0. Record pre-test state
if pkg info -E "${PKG_NAME}" >/dev/null 2>&1; then
	PREEXISTED=1
fi
if [ -n "$(pkg query '%rn-%rv' ${PKG_NAME} 2>/dev/null)" ]; then
	HAS_REVDEPS=1
	echo "Note: ${PKG_NAME} has reverse dependencies — will not uninstall after test:"
	pkg query '  %rn-%rv' "${PKG_NAME}" 2>/dev/null
fi

# 1. Install fresh package
echo "Installing ${PKG}"
sudo pkg add -f "${PKG}"

# 2. Verify python import + version
PKG_VER=$(pkg query '%v' ${PKG_NAME})
PY_VER=$(python3 -c 'import anthropic; print(anthropic.__version__)')
echo "Package version: ${PKG_VER}   anthropic.__version__: ${PY_VER}"
[ "${PKG_VER%_*}" = "${PY_VER}" ] || {
	echo "FAIL  version mismatch (pkg=${PKG_VER} module=${PY_VER})"
	exit 1
}

# 3. Probe the SDK's public surface: main client + a representative
#    message type.  Catches missing submodules, broken imports, vendored
#    deps that didn't get installed, etc.
#
# Surface notes for the 1.x line (SDK 1.0.0, Aug 2026):
#   * The legacy Text Completions API was REMOVED — there is no
#     client.completions any more.  Asserting its absence keeps this test
#     honest about which major we are on.
#   * The HTTP layer moved from httpx to httpx2 (RUN_DEPENDS www/py-httpx2).
#   * The `distro` dependency was dropped entirely.
python3 - <<'PY'
import importlib, sys
import anthropic
from anthropic import Anthropic, AsyncAnthropic
from anthropic.types import Message, MessageParam, TextBlock

major = int(anthropic.__version__.split(".")[0])

# Instantiate without a key + without making any network call.
# Anthropic() reads ANTHROPIC_API_KEY from env; passing a dummy key is
# enough to construct the object — the request would fail later.
c = Anthropic(api_key="sk-test-not-real")
assert c.messages is not None, "client.messages missing"
print(f"PASS  Anthropic client constructed (base_url={c.base_url})")
print("PASS  types: Message, MessageParam, TextBlock importable")

if major >= 1:
    # Text Completions removed in 1.0.0.
    assert not hasattr(c, "completions"), \
        "client.completions present — expected it gone in anthropic>=1"
    print("PASS  legacy completions API absent (1.x)")

    # 1.x talks httpx2, not httpx.  Prove the dep the port declares is the
    # one actually imported, so a stale RUN_DEPENDS gets caught here.
    import httpx2
    import anthropic._base_client as bc
    assert bc.httpx2 is httpx2, "_base_client is not using httpx2"
    print(f"PASS  HTTP layer is httpx2 {httpx2.__version__}")

    # `distro` was dropped as a dependency in 1.0.0 — the SDK must not
    # import it any more.
    assert "distro" not in sys.modules, "distro imported despite being dropped"
    print("PASS  distro not imported")
else:
    assert c.completions is not None, "client.completions missing"
    print("PASS  legacy completions API present (0.x)")
PY

# 4. Live round-trip through the SDK (optional).
#
# Reuses the endpoint Claude Code is already configured against, rather than
# hardcoding one:  env ANTHROPIC_BASE_URL wins, else the `env` block of
# ~/.claude/settings.json.  The model is DERIVED from GET /v1/models -- never
# hardcoded, since a stale model constant fails in a way that looks like a
# hang rather than a bad test.
#
# SKIPs (does not fail) when there is no endpoint, no key, or nothing
# listening: the packaging checks above are the part that must always run.
SETTINGS=${CLAUDE_SETTINGS:-${HOME}/.claude/settings.json}

BASE_URL=${ANTHROPIC_BASE_URL:-}
if [ -z "${BASE_URL}" ] && [ -r "${SETTINGS}" ]; then
	BASE_URL=$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
print((d.get("env") or {}).get("ANTHROPIC_BASE_URL", ""))
' "${SETTINGS}" 2>/dev/null || true)
	[ -n "${BASE_URL}" ] && echo "Using ANTHROPIC_BASE_URL from ${SETTINGS}"
fi

# A key must be present but need not be valid: local proxies commonly ignore
# it.  apiKeyHelper in settings.json is the same hook Claude Code itself uses.
API_KEY=${ANTHROPIC_API_KEY:-${ANTHROPIC_AUTH_TOKEN:-}}
if [ -z "${API_KEY}" ] && [ -r "${SETTINGS}" ]; then
	HELPER=$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
print(d.get("apiKeyHelper", ""))
' "${SETTINGS}" 2>/dev/null || true)
	[ -n "${HELPER}" ] && API_KEY=$(eval "${HELPER}" 2>/dev/null || true)
fi

if [ -z "${BASE_URL}" ]; then
	echo "SKIP  live API test (no ANTHROPIC_BASE_URL in env or ${SETTINGS})"
elif [ -z "${API_KEY}" ]; then
	echo "SKIP  live API test (no API key available)"
elif ! curl -fsS --max-time 10 -o /dev/null \
	-H "x-api-key: ${API_KEY}" -H "anthropic-version: 2023-06-01" \
	"${BASE_URL%/}/v1/models" 2>/dev/null; then
	echo "SKIP  live API test (${BASE_URL} not reachable)"
else
	echo "Live endpoint: ${BASE_URL}"
	# rc 124 = timeout expired -> SKIP, not FAIL: a wedged endpoint is an
	# environment problem, not a packaging regression.
	set +e
	timeout 90 env ANTHROPIC_BASE_URL="${BASE_URL}" ANTHROPIC_API_KEY="${API_KEY}" \
		python3 - <<'PY'
import os, sys
from anthropic import Anthropic

client = Anthropic()

# Derive the model from the endpoint itself.
models = [m.id for m in client.models.list()]
assert models, "GET /v1/models returned no models"
print(f"PASS  models.list() -> {len(models)} model(s), e.g. {models[0]}")

model = os.environ.get("ANTHROPIC_MODEL") or models[0]

# max_tokens is generous because thinking models spend budget before any
# text; a small cap yields stop_reason=max_tokens and no text at all.
msg = client.messages.create(
    model=model,
    max_tokens=1024,
    messages=[{"role": "user", "content": "Reply with exactly: PONG"}],
)
text = "".join(b.text for b in msg.content if b.type == "text").strip()
print(f"PASS  messages.create({model}) -> {text!r} "
      f"(in={msg.usage.input_tokens} out={msg.usage.output_tokens})")
assert msg.stop_reason, "no stop_reason on response"
assert msg.content, "empty content on response"
assert "PONG" in text.upper(), f"unexpected reply: {text!r}"

# Streaming exercises a different code path (SSE decoding) than create().
#
# Assert on EVENTS, not on text:  models with adaptive thinking enabled
# (claude-opus-5 &c) may spend the whole budget on a thinking block and
# emit no text at all, so a text-only assertion fails for a healthy SDK.
# max_tokens is generous here for the same reason.
with client.messages.stream(
    model=model,
    max_tokens=1024,
    messages=[{"role": "user", "content": "Count: 1 2 3"}],
) as stream:
    events = [ev.type for ev in stream]
    final = stream.get_final_message()
assert "message_start" in events, f"no message_start in stream: {events}"
assert "message_stop" in events, f"no message_stop in stream: {events}"
assert final.content, "stream produced an empty message"
kinds = sorted({b.type for b in final.content})
print(f"PASS  messages.stream() -> {len(events)} event(s), "
      f"block types={kinds}, stop_reason={final.stop_reason}")
PY
	rc=$?
	set -e
	if [ "${rc}" = 124 ]; then
		echo "SKIP  live API test (timed out after 90s)"
	elif [ "${rc}" != 0 ]; then
		echo "FAIL  live API test (exit ${rc})"
		exit 1
	fi
fi

echo "PASS  ${PKG_NAME} ${PKG_VER}"
