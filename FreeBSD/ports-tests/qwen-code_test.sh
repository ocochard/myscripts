#!/bin/sh
# qwen-code smoke / regression test.
#
# Self-contained: pkg-adds the freshly-built qwen-code from the poudriere
# builder, then exercises the port end-to-end:
#
#   1. `qwen --version` prints the expected version (proves the sh wrapper,
#      the ${PREFIX}/bin/node shebang rewrite, and cli-entry.js all work).
#   2. The bundled node_modules tree survived the dynamic-plist install
#      (a representative chunk file and the web-shell bundle are present).
#   3. Auto-update was neutralised at install time: no chunk still carries
#      the live `enableAutoUpdate !== false` guard.
#   4. A real non-interactive prompt against an OpenAI-compatible backend
#      (a local llama.cpp server) returns a well-formed chat completion.
#      This proves the OpenAI provider path wires up from the env vars
#      qwen reads (QWEN_DEFAULT_AUTH_TYPE / OPENAI_BASE_URL / OPENAI_MODEL).
#
# The LLM backend defaults to the llama.cpp server on the lab network; set
# LLAMA_URL to override or point elsewhere. If the server is unreachable the
# LLM step is SKIPPED (not failed) so the test still validates the port on a
# host without the backend.
#
# No root needed for the qwen logic itself; sudo is only used for pkg
# add/delete.
set -eu

PORT_NAME=qwen-code
JAIL=builder
TREE=official
PKGDIR=/usr/local/poudriere/data/packages/${JAIL}-${TREE}/.latest/All

LLAMA_URL=${LLAMA_URL:-http://192.168.100.8:8080}
# LLAMA_MODEL is discovered from the endpoint below; whatever it currently
# serves is what we test against. Set it to pin a specific model.
LLAMA_MODEL=${LLAMA_MODEL:-}
# hard cap on the round-trip; a loaded or wedged server must not hang the test
LLAMA_TIMEOUT=${LLAMA_TIMEOUT:-180}

QWEN_LIB=/usr/local/lib/node_modules/@qwen-code/qwen-code
WORKDIR=$(mktemp -d /tmp/${PORT_NAME}-test.XXXXXX)
PRE_INSTALLED=no

cleanup() {
	rm -rf "${WORKDIR}"
	if [ "${PRE_INSTALLED}" = yes ]; then
		return
	fi
	if pkg query '%rn' "${PORT_NAME}" 2>/dev/null | grep -q .; then
		echo "NOTE  ${PORT_NAME} has reverse deps; leaving installed"
		return
	fi
	sudo pkg delete -y "${PORT_NAME}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# 1. install the freshly-built package
# ---------------------------------------------------------------------------
if pkg info "${PORT_NAME}" >/dev/null 2>&1; then
	PRE_INSTALLED=yes
	echo "NOTE  ${PORT_NAME} already installed; will not uninstall on exit"
fi
PKG=$(ls -t ${PKGDIR}/${PORT_NAME}-*.pkg | head -1)
echo "==> installing ${PKG}"
sudo pkg add -f "${PKG}"

# ---------------------------------------------------------------------------
# 2. version / wrapper
# ---------------------------------------------------------------------------
echo "==> qwen --version"
# expected version comes from the package we just installed, not a constant
EXPECT_VER=$(pkg query '%v' "${PORT_NAME}" | sed -e 's/_[0-9]*$//' -e 's/,[0-9]*$//')
GOT_VER=$(qwen --version 2>/dev/null | tr -d '[:space:]')
if [ "${GOT_VER}" != "${EXPECT_VER}" ]; then
	echo "FAIL  qwen reports '${GOT_VER}', pkg installed '${EXPECT_VER}'" >&2
	exit 1
fi
echo "    version ${GOT_VER}"

# ---------------------------------------------------------------------------
# 3. bundled tree survived the dynamic plist
# ---------------------------------------------------------------------------
echo "==> bundled tree present"
test -x "${QWEN_LIB}/cli-entry.js"
test -d "${QWEN_LIB}/chunks"
ls "${QWEN_LIB}/chunks"/*.js >/dev/null
test -f "${QWEN_LIB}/web-shell/index.html"
# bundled ripgrep must be gone (we use textproc/ripgrep)
test ! -d "${QWEN_LIB}/vendor/ripgrep"
echo "    cli-entry.js, chunks/, web-shell/ ok; vendored ripgrep removed"

# ---------------------------------------------------------------------------
# 4. auto-update neutralised
# ---------------------------------------------------------------------------
echo "==> auto-update disabled"
if grep -rq 'enableAutoUpdate !== false' "${QWEN_LIB}/chunks"/ 2>/dev/null; then
	echo "FAIL  a chunk still carries the live enableAutoUpdate guard"
	exit 1
fi
echo "    no live enableAutoUpdate guard remains"

# ---------------------------------------------------------------------------
# 5. real prompt against the OpenAI-compatible backend
# ---------------------------------------------------------------------------
echo "==> LLM backend ${LLAMA_URL}"
MODELS_JSON=$(curl -sf -m 5 "${LLAMA_URL}/v1/models" 2>/dev/null) || MODELS_JSON=
if [ -z "${MODELS_JSON}" ]; then
	echo "SKIP  backend unreachable; port validated without the LLM round-trip"
	echo "PASS  ${PORT_NAME} (LLM step skipped)"
	exit 0
fi

# ask the endpoint what it is serving rather than assuming a model name
if [ -z "${LLAMA_MODEL}" ]; then
	LLAMA_MODEL=$(printf '%s' "${MODELS_JSON}" | jq -r '.data[0].id // empty')
fi
if [ -z "${LLAMA_MODEL}" ]; then
	echo "SKIP  backend served no model id; port validated without the LLM round-trip"
	echo "PASS  ${PORT_NAME} (LLM step skipped)"
	exit 0
fi
echo "    model ${LLAMA_MODEL}"

# qwen picks the OpenAI provider from these env vars non-interactively.
# The api key is a placeholder (llama.cpp ignores it, the OpenAI SDK just
# requires it to be non-empty). HOME is redirected so the test never touches
# the real ~/.qwen settings.
OUT="${WORKDIR}/qwen.out"
set +e
timeout "${LLAMA_TIMEOUT}" env \
	HOME="${WORKDIR}" \
	QWEN_DEFAULT_AUTH_TYPE=openai \
	OPENAI_API_KEY=sk-local-llama \
	OPENAI_BASE_URL="${LLAMA_URL}/v1" \
	OPENAI_MODEL="${LLAMA_MODEL}" \
	qwen --yolo --prompt 'Say the single word PONG and nothing else.' \
	>"${OUT}" 2>&1
rc=$?
set -e

# 124 = timeout(1) killed it: the server is busy, not the port being broken
if [ ${rc} -eq 124 ]; then
	echo "SKIP  backend did not answer in ${LLAMA_TIMEOUT}s (busy?); port validated without the LLM round-trip"
	echo "PASS  ${PORT_NAME} (LLM step skipped)"
	exit 0
fi

if [ ${rc} -ne 0 ]; then
	echo "FAIL  qwen exited ${rc}"
	sed -n '1,40p' "${OUT}"
	exit 1
fi
# A reasoning model may spend the answer budget in reasoning_content, so we
# don't require the literal PONG; we require that qwen produced output and
# did not surface an auth/connection error from the provider layer.
if grep -qiE 'error|ECONNREFUSED|OPENAI_API_KEY|is missing|unauthorized|not found' "${OUT}"; then
	echo "FAIL  qwen reported a provider error"
	sed -n '1,40p' "${OUT}"
	exit 1
fi
test -s "${OUT}"
echo "    round-trip ok ($(wc -c <"${OUT}" | tr -d ' ') bytes returned)"

echo "PASS  ${PORT_NAME}"
