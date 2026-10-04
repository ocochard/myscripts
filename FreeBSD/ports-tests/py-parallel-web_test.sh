#!/bin/sh
# www/py-parallel-web smoke test.
#
# Installs the freshly-built py-parallel-web package from the poudriere
# builder, then drives the sync and async clients against a local mock HTTP
# server (base_url override): checks request path, x-api-key header and JSON
# body, and that the response parses into the SearchResult model.  Exercises
# the full httpx + pydantic request/response stack without an API key.
#
# No network needed; the mock server binds 127.0.0.1 on an ephemeral port.
set -eu

JAIL=builder
TREE=official
PKGDIR=/usr/local/poudriere/data/packages/${JAIL}-${TREE}/.latest/All

PKG=$(ls -t ${PKGDIR}/py3*-parallel-web-*.pkg | head -1)
PORT_NAME=$(basename "${PKG}" | sed 's/-[^-]*\.pkg$//')
PY=$(echo "${PORT_NAME}" | sed -E 's/^py([0-9])([0-9]+)-.*/python\1.\2/')

PREEXISTED=0
HAS_REVDEPS=0

cleanup() {
	if [ "${HAS_REVDEPS}" = 1 ]; then
		echo "Leaving ${PORT_NAME} installed (other packages depend on it)"
	elif [ "${PREEXISTED}" = 0 ]; then
		sudo pkg delete -y "${PORT_NAME}" 2>/dev/null || true
	else
		echo "Leaving ${PORT_NAME} installed (was present before test)"
	fi
}
trap cleanup EXIT INT TERM

# 0. Record pre-test state
if pkg info -E "${PORT_NAME}" >/dev/null 2>&1; then
	PREEXISTED=1
fi
if [ -n "$(pkg query '%rn-%rv' ${PORT_NAME} 2>/dev/null)" ]; then
	HAS_REVDEPS=1
	echo "Note: ${PORT_NAME} has reverse dependencies, will not uninstall after test:"
	pkg query '  %rn-%rv' "${PORT_NAME}" 2>/dev/null
fi

# 1. Install fresh package
echo "Installing ${PKG}"
sudo pkg install -fy "${PKG}"

# 2. Verify version.  -s ignores any pip --user copy in ~/.local.
PKG_VER=$(pkg query '%v' ${PORT_NAME})
PY_VER=$(${PY} -s -c 'import parallel; print(parallel.__version__)')
echo "Package version: ${PKG_VER}   parallel.__version__: ${PY_VER}"
[ "${PKG_VER%_*}" = "${PY_VER}" ] || {
	echo "FAIL  version mismatch (pkg=${PKG_VER} module=${PY_VER})"
	exit 1
}

# 3. Sync + async client against a local mock server
${PY} -s - <<'PY'
import asyncio, json, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from parallel import AsyncParallel, Parallel
from parallel.types import SearchResult

seen = []

class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        seen.append((self.path, self.headers.get("x-api-key"), body))
        out = json.dumps({
            "search_id": "s-1", "session_id": "sess-1",
            "results": [{"url": "https://www.freebsd.org/",
                         "title": "FreeBSD", "excerpts": ["The Power to Serve"]}],
        }).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def log_message(self, *a):
        pass

srv = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=srv.serve_forever, daemon=True).start()
base = f"http://127.0.0.1:{srv.server_address[1]}"

def check(r, label):
    assert isinstance(r, SearchResult), type(r)
    assert r.search_id == "s-1" and r.results[0].title == "FreeBSD"
    path, key, body = seen[-1]
    assert path == "/v1/search", path
    assert key == "test-key", key
    assert body["search_queries"] == ["freebsd ports"], body
    print(f"PASS  {label}.search -> {path}, SearchResult parsed")

c = Parallel(api_key="test-key", base_url=base, max_retries=0)
check(c.search(search_queries=["freebsd ports"], objective="test"), "Parallel")

async def run_async():
    async with AsyncParallel(api_key="test-key", base_url=base, max_retries=0) as ac:
        return await ac.search(search_queries=["freebsd ports"])
check(asyncio.run(run_async()), "AsyncParallel")

srv.shutdown()
PY

echo "PASS  py-parallel-web ${PKG_VER}"
