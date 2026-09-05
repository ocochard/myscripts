# FreeBSD ports regression tests

Hand-written smoke / regression tests for ports maintained by
`olivier@FreeBSD.org`. Run these after a port version bump (or before
committing) to make sure the new package still works end-to-end, not
just that it builds.

These are **not** automated by poudriere — invoke them manually on a
host where the rebuilt package is installed (`pkg install ...` or
`pkg add /usr/local/poudriere/data/packages/.../All/<port>.pkg`).

## Inventory

| Script              | Port(s) tested                  | What it does                                                                                                                                                                                                                | Requires                       |
| ------------------- | ------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------ |
| `amazon-efs-utils_test.sh` | `filesystems/amazon-efs-utils` | **Runs ON an EC2 instance, not the workstation** — a real EFS filesystem, an IAM instance role and EC2 network access are all required, so copy the script + `.pkg` over and run it there as root (`sudo env EFS_FS_ID=fs-… sh amazon-efs-utils_test.sh`). **`EFS_FS_ID` is required and has no default** — this repo is public, so the script never ships pointing at a real filesystem, and an unsuspecting run cannot silently mount someone else's. Exercises the FreeBSD-only code the port patches add, which upstream CI never covers. Preflight refuses to run if IMDS is unreachable or if any efs-proxy / state file already exists (the test asserts on global state, so a pre-existing mount would make it lie). Then: (1) `pkg add`, all 5 artifacts present, `mount_efs` parses as Python and still carries its `@@EFS_LIBDIR@@`-substituted `sys.path` insert, and `efs_utils_common` imports with ports paths (`STATE_FILE_DIR`, `${PREFIX}/etc/amazon/efs`) — this catches the layout regressions that actually bite this port; (2) real `mount_efs <fs-id> <mp> -o tls,iam` (note `-o` must follow the positional fs-id) — success here *is* the NFSv4.1 assertion, since a regression to the Linux `nfsvers=4.1` spelling makes FreeBSD's `mount_nfs` fall back to v3 and EFS RSTs; (3) efs-proxy alive + state file in `/var/run/efs`; (4) the watchdog auto-started via the `rc` init-system branch (`service … onestart`) even though it is installed **disabled** in rc.conf by design; (5) **write a file, `sync`, read it back and compare**, verify it appears in READDIR, then unlink; (6) reads back a pre-existing file if `EFS_SENTINEL` names one (absent when requested is a failure, not a skip); (7) `umount`, then asserts the watchdog's real cleanup contract — *not* prompt: `UNMOUNT_DIFF_TIME` 30s (measured from **mount** time) + 5 consistency polls + `unmount_grace_period_sec` 30s ≈ 65s before `clean_up_mount_state()` SIGTERMs the proxy group and removes the state file; waits up to `WATCHDOG_REAP_TIMEOUT` (150s) for state to be reaped, dumps the watchdog log on timeout, then asserts no efs-proxy survives **and** that the watchdog itself is still polling with zero mounts. | An EC2 instance w/ IAM role, root, `amazon-efs-utils-*.pkg` copied alongside; **`EFS_FS_ID` required**, `EFS_MOUNTPOINT` / `EFS_SENTINEL` / `WATCHDOG_REAP_TIMEOUT` optional |
| `sslh.sh`           | `net/sslh`                      | Self-contained: `pkg add`s the freshly-built `sslh` from the poudriere builder, starts `sslh-ev` listening on 127.0.0.1:8022, forwards to local sshd on :22, runs an `ssh -p 8022` probe, checks the log for the connection, then stops the daemon and `pkg delete`s the package. | Local sshd, sudo, `sslh-*.pkg` in poudriere |
| `bird_test.sh`      | `net/bird2`, `net/bird3`        | Builds a 6-jail vnet lab exercising BGP / RIP / OSPF / BABEL / static between `bird1..bird6`. `start` brings the lab up, `stop` tears it down. Used to validate `bird` after a bump on multi-protocol configs.              | `sudo`, vnet jails, root       |
| `bird_fib_test.sh`  | `net/bird2` (netlink vs `@rtsock`) | Host-only (no jails / no vnet) `start`/`check`/`stop` regression for [PR 279662](https://bugs.freebsd.org/bugzilla/show_bug.cgi?id=279662). Creates `lo901` bound to FIB 1, manually installs `10.55.0.0/24` in FIB 1, then runs `bird` with one `kernel` protocol (`kernel table 1`, `learn`) plus a static `10.123.0.0/24`. Asserts **both directions**: (a) bird learned the FIB-1 kernel route (inbound `learn`) and (b) the bird static landed in kernel FIB 1 (outbound `export`). On `15.0-RELEASE-p9` + netlink the export path passes (kernel fix `f34aca55adef` is MFC'd) but the learn path fails (kernel fix `33acf0f26b49` is main-only at this writing). `@rtsock` passes both directions. | `sudo`, `net.fibs>=2`, root    |
| `frr_test.sh`       | `net/frr8/9/10`                 | Same idea as `bird_test.sh` but for FRR: 7-jail topology covering BGP / RIP / OSPF / ISIS / BABEL / static. Used to catch routing-protocol regressions across FRR major bumps.                                               | `sudo`, vnet jails, root       |
| `frr_tunnel_unnumbered_test.sh` | `net/frr10` (+ `net/bird3` as peer) | Regression for [FRR PR 8132](https://github.com/FRRouting/frr/pull/8132) and [BSDRP#27](https://github.com/ocochard/BSDRP/issues/27) — same root cause (filed 2021, closed unmerged Apr 2026). Two vnet jails wired by an epair, each with a `gif` tunnel carrying a peer-style `inet 10.99.1.X/24 10.99.1.Y` inner address. `frr1` runs frr10 zebra+ospfd, `brd2` runs bird3 OSPF. `start`/`check`/`stop`. Bug: `zebra/connected.c::connected_announce()` flags any address with local prefixlen /32 as `UNNUMBERED` without consulting the peer's prefixlen, so FreeBSD tunnels are always wrongly unnumbered. `check` asserts (a) `vtysh "show interface gif991"` does not print UNNUMBERED, (b) bird3 reaches OSPF state Full, (c) bird3 learned the FRR `/32` loopback via the tunnel inner next-hop, (d) `show ip ospf interface` doesn't report "This interface is UNNUMBERED", (e) on-wire OSPF Hello from FRR carries the correct subnet mask, not `0.0.0.0` (the literal BSDRP#27 wire-level symptom). bird is lenient and accepts the wrong-mask hello, so (b) and (c) pass even when the bug reproduces — strict peers (RouterOS, IOS, Junos) would drop it. | `sudo`, vnet jails, root, both `frr10` and `bird3` installed |
| `mlvpn_test.sh`     | `net/mlvpn`                     | Host-only smoke test: runs two `mlvpn` instances (server + client) bound to different loopback ports, opens two `tun` devices (10.0.16.1/2), verifies the tunnel comes up and forwards ICMP between the endpoints.            | `sudo`, root, `mlvpn` installed |
| `moonshine_test.sh` | `multimedia/moonshine`          | Self-contained regression test for the accept-loop crash fix (fork tag `v0.12.0-freebsd`, PORTREVISION 1). `pkg add`s the freshly-built `moonshine`, starts it on unprivileged loopback ports (no rc.d, no GPU/Wayland needed for the network layer), asserts all three HTTP/HTTPS/RTSP listeners bind, then fires bursts of `SO_LINGER {1,0}` TCP connections (RST-on-close) at each to reproduce the `accept()` `ECONNABORTED` (os error 53) that the buggy build propagated into a global `ShutdownManager` shutdown. Asserts moonshine stays up and that the error was logged at WARN (accept loop continued), then `pkg delete`s (skipped if pre-installed or if reverse deps exist). | sudo, python3, `moonshine-*.pkg` in poudriere |
| `osquery_test.sh`   | `sysutils/osquery`              | Cross-platform (FreeBSD + Linux). Audits `ldd` for the port's `Find<lib>.cmake` hijacks, runs ~30 `osqueryi` SQL queries against core / posix / process / network / filesystem / pci / usb / yara / augeas tables, starts `osqueryd` with a 30 s schedule + event backends (devd/inotify/openbsm), then cross-checks counts against native tools (`arp`, `mount`, `pciconf`, `usbconfig`, `sockstat`, etc.). | `sudo`, `jq`                   |
| `geoip-test.py`     | `net/py-GeoIP2`                 | One-liner: opens a MaxMind DB and looks up a country for a given IP via `geoip2.database.Reader`. Verifies the Python binding loads and a basic query returns the expected country.                                          | `db.data` (see below), Python  |
| `maxminddb-test.py` | `net/py-maxminddb`              | Same shape as `geoip-test.py` but goes through the lower-level `maxminddb` reader and pretty-prints the full record. Verifies the raw binding (no GeoIP2 wrapper).                                                            | `db.data` (see below), Python  |
| `mrtparse_test.sh`  | `net/mrtparse`                  | Self-contained: `pkg add`s the freshly-built `py311-mrtparse`, imports the library, parses a sample MRT RIB dump (`mrtparse-sample.mrt`, shipped here), checks record count + version, exercises the `mrt2json.py` CLI, then `pkg delete`s. | sudo, `py311-mrtparse-*.pkg` in poudriere |
| `py-anthropic_test.sh` | `misc/py-anthropic`         | Self-contained: `pkg add`s the freshly-built `py3XX-anthropic` (flavor discovered from the pkg file, so the script survives the tree's default-python flip), imports the SDK, checks version, constructs an `Anthropic` client (no network call), verifies main types are importable. Skips uninstall if reverse deps (e.g. `hermes-agent`) are installed. | sudo, `py3*-anthropic-*.pkg` in poudriere |
| `py-firecrawl-py_test.sh` | `www/py-firecrawl-py`    | Self-contained: `pkg add`s the freshly-built `py3XX-firecrawl-py` (flavor discovered from the pkg file), imports the SDK, checks version, constructs `Firecrawl` + `AsyncFirecrawl` clients (no network call), verifies `v1`/`v2` proxies and top-level methods (`scrape`, `search`, `map`) resolve, and that legacy `FirecrawlApp`/`AsyncFirecrawlApp` aliases + `V1ScrapeOptions`/`V1JsonConfig` types are importable. | sudo, `py3*-firecrawl-py-*.pkg` in poudriere |
| `py-deepdiff_test.sh` | `devel/py-deepdiff`         | Self-contained: `pkg add`s the freshly-built `py311-deepdiff`, imports the library, exercises the cachebox-backed `DistanceCache` (`deepdiff/lfucache.py`) directly and via `DeepDiff(get_deep_distance=True, cache_size=N)` on both a small nested-dict diff and a 50-item `ignore_order=True` list diff. Catches cachebox API breakage across major bumps — the regression the previous `cachebox>=5.2,<6` upper bound was hiding. | sudo, `py311-deepdiff-*.pkg` in poudriere |
| `py-exa-py_test.sh` | `www/py-exa-py`             | Self-contained: `pkg add`s the freshly-built `py311-exa-py`, imports the SDK, checks version via `importlib.metadata` (no `__version__` exposed), constructs an `Exa` client (no network call), verifies `AsyncExa` subclasses `Exa` and key submodules import. Skips uninstall if reverse deps (e.g. `hermes-agent`) are installed. | sudo, `py311-exa-py-*.pkg` in poudriere |
| `py-PyHive_test.sh` | `databases/py-PyHive` (+ `devel/py-pure-sasl`, `devel/py-thrift_sasl` pulled in transitively via the HIVE option) | Self-contained: `pkg add`s the freshly-built `py312-PyHive`, imports `pyhive` + every DB-API submodule (`hive`/`presto`/`trino`, touching thrift/requests deps), constructs a `puresasl.client.SASLClient` and imports `thrift_sasl` (proves the HIVE-option SASL stack is wired), constructs all five SQLAlchemy dialect classes (`HiveDialect`, `HiveHTTP{,S}Dialect`, `PrestoDialect`, `TrinoDialect`), verifies the `sqlalchemy.dialects` registry entry points resolve back to PyHive's classes (i.e. `create_engine("hive://...")` would work), checks the PEP 249 module attributes, then `pkg delete`s. | sudo, `py312-PyHive-*.pkg` in poudriere |
| `gpac_test.sh`      | `multimedia/gpac`           | Self-contained: `pkg add`s the freshly-built `gpac`, runs `gpac -i <sample>.mp4 inspect` and `MP4Box -info` against the bundled `share/gpac/res/gpac.mp4` sample, asserts the expected PID / codec / Movie Info markers, then `pkg delete`s the package. | sudo, `gpac-*.pkg` in poudriere |
| `cbmc_test.sh`      | `devel/cbmc`                | Self-contained: `pkg add`s the freshly-built `cbmc`, checks `--version`, runs cbmc on a buggy C program (asserts `VERIFICATION FAILED` + non-zero exit) and on a clean program (asserts `VERIFICATION SUCCESSFUL`), then `pkg delete`s the package. | sudo, `cbmc-*.pkg` in poudriere |
| `moon_test.sh`      | `devel/moon`                | Self-contained: `pkg add`s the freshly-built `moon`, checks `moon --version` and `moonx --version` (both binaries), generates a bash completion script via `moon completions --shell bash` and asserts the `_moon()` function is emitted, runs `moon init --yes --minimal` in a tempdir and verifies `.moon/workspace.yml` is created, then `pkg delete`s the package. | sudo, `moon-*.pkg` in poudriere |
| `enkits_test.sh`    | `devel/enkits`              | Self-contained: `pkg add`s the freshly-built `enkits`, verifies headers / `libenkiTS.so` / CMake config landed, builds + runs a C smoke (`TaskScheduler_c.h` parallel atomic-counter, asserts final count) and a C++ smoke (`enki::ITaskSet` parallel reduction, asserts the closed-form sum), then exercises the installed CMake package config via `find_package(enkiTS CONFIG REQUIRED)` + `target_link_libraries(... enkiTS::enkiTS)` and runs the resulting binary, then `pkg delete`s. | sudo, `enkits-*.pkg` in poudriere, `cmake` |
| `hermes-agent_test.sh` | `misc/hermes-agent`          | FreeBSD-only. `pkg add`s the freshly-built package and exercises the four salvage-patch pieces plus **two** real LLM round-trips: (1) the three `bin/` wrappers resolve and `hermes --help` returns 0 (sys.path shim); (2) `hermes skills list` shows a non-empty catalog (PR#31850 freebsd->linux skill mapping - used to be 0); (3) `allow_lazy_installs` resolves to False in a fresh FreeBSD config (the config_defaults.py patch, Commit B); (4) rc.d lifecycle - `service hermes_gateway {start,status,stop}` drive the port-installed rc.d script (Commit A); (5a) a real single-turn completion via hermes' `custom` OpenAI-compatible provider against a local llama.cpp server (default `192.168.100.8:8080`; the model is **auto-discovered** from `/v1/models` so it tracks whatever is loaded, override with `LLAMA_MODEL`). This step **FAILs** - not skips - if the server advertises `n_ctx` below hermes' floor (`HERMES_MIN_CTX`, default 64000), since a too-small `-c` silently disables the only steps that talk to a model; the message names the endpoint, the actual value, and the `-c` to restart with. (5b) the same round-trip through the **Anthropic Messages** path (`--provider anthropic`), which exercises `agent/anthropic_adapter.py` + the anthropic SDK instead of the OpenAI SDK - a stack step 5a structurally cannot reach, and where the anthropic 1.x `httpx`->`httpx2` break shipped unnoticed in 0.17.0. Greps explicitly for an httpx/httpx2 mismatch on top of the generic provider-error check. SKIPs unless `ANTHROPIC_BASE_URL` is set **and** the endpoint answers a probe `POST /v1/messages`; model via `ANTHROPIC_MODEL` (default `claude-sonnet-5`). HOME is redirected to a tempdir in every LLM step so the real `~/.hermes` is untouched. Trap cleans up rc.conf, sysrc, and the package. | sudo, `curl`, `hermes-agent-*.pkg` in poudriere; llama.cpp backend for 5a, Anthropic-compatible endpoint for 5b |
| `qwen-code_test.sh` | `misc/qwen-code`                | Self-contained: `pkg add`s the freshly-built `qwen-code`, asserts `qwen --version` matches the expected version (exercises the `sh` wrapper, the `${PREFIX}/bin/node` shebang rewrite, and `cli-entry.js`), verifies the bundled `node_modules` tree survived the dynamic-plist install (`cli-entry.js`, `chunks/*.js`, `web-shell/index.html` present; vendored ripgrep removed), checks no chunk still carries the live `enableAutoUpdate !== false` auto-update guard, then runs a real non-interactive `qwen --yolo --prompt` against an OpenAI-compatible backend (a local llama.cpp server, default `192.168.100.8:8080`, model `Agents-A1-MTP-Q8_0`, selected via `QWEN_DEFAULT_AUTH_TYPE=openai`/`OPENAI_BASE_URL`/`OPENAI_MODEL`) and asserts a clean round-trip with no provider error. `HOME` is redirected to a tempdir so the real `~/.qwen` is untouched. SKIPs the LLM step (not fails) if the backend is unreachable; skips uninstall if pre-installed. Override the server with `LLAMA_URL`/`LLAMA_MODEL`. | sudo, `curl`, `qwen-code-*.pkg` in poudriere; optional llama.cpp backend |
| `ttygif_test.sh`    | `graphics/ttygif`               | Self-contained: `pkg add`s the freshly-built `ttygif`, asserts `ttygif -v` prints the port's `PORTVERSION` (upstream ships a stale hardcoded `VERSION` in its Makefile — the port rewrites it in `post-patch`, and this is what catches that regressing), checks `-h` usage, then generates a 3-frame ttyrec fixture (little-endian `{tv_sec,tv_usec,len}` headers at t=0.00/0.30/0.65) and drives the full conversion path under `TTYGIF_DEBUG=1`, which makes `system_exec()` print commands instead of running them — so no X11 display or real terminal window is needed. Asserts one `xwd` snapshot per frame (every ttyrec record parsed) and that the assembled `convert` line carries the delays derived from the fixture timestamps (`-delay 30`, `-delay 35`, `-delay 100` for the `last_frame_delay` default) — a real check on the timing maths, not just `--version`. Every invocation sets `WINDOWID=1` because ttygif validates `$WINDOWID` *before* parsing argv, so even `-v` fails without it. Finally asserts a `convert`/`magick` binary is present. | sudo, python3, `ttygif-*.pkg` in poudriere |
| `libyang_test.sh`   | `net/libyang2`, `net/libyang3` | Shared by both ports — `libyang_test.sh [libyang2\|libyang3]` (default `libyang2`). Detects the SONAME major (2 vs 3), the package name, and the log-API symbol (`ly_strerrcode` in 2.x, `ly_strerr` in 3.x) from the selected package. `pkg add`s the freshly-built package, asserts the files landed (esp. the `libyang.so.<major>` SONAME that consumers like `net/frr9`/`net/frr10` link against, plus the concrete `libyang.so.<major>.NN.N`), checks `readelf -d` reports `SONAME [libyang.so.<major>]` (a bump crossing majors would silently break every `LIB_DEPENDS` pinned to the old `.so`), verifies `yanglint --version` matches the major, drives the schema parser via `yanglint -f tree` on the shipped `ietf-inet-types` module, then compiles+links a tiny C program against `-lyang` via the installed `libyang.pc` and runs it (`ly_ctx_new`/`ly_ctx_destroy`). The two ports **conflict** (both own `libyang.pc`/headers): if the sibling is installed *and has reverse deps* (e.g. `libyang3` <- `frr10`), the script **SKIPs** rather than cascade-removing a real daemon — run it in a jail or remove the consumer first. Never uninstalls a package that was already installed or that has reverse deps. | sudo, `cc`, `pkg-config`, `readelf`, `libyang{2,3}-*.pkg` in poudriere |

## Data files

- `db.data.xz` / `db.data` — small MaxMind GeoLite2 country database
  used by both `geoip-test.py` and `maxminddb-test.py`. The `.xz` is
  what's committed; decompress once: `xzcat db.data.xz > db.data`.
- `test.result.txt` — captured output of a previous successful test
  run, kept as a reference baseline.
- `osquery_test.sh~` — editor backup, ignore.

## How to run

```sh
# net/sslh — fast smoke test
sh sslh.sh

# net/bird{2,3} — bring up vnet routing lab
sh bird_test.sh start
sudo jexec bird3 birdc -s /var/run/bird/bird3.ctl
# ...inspect routes / protocols...
sh bird_test.sh stop

# net/bird2 — multi-FIB host-only regression (no jails), both directions
sh bird_fib_test.sh start
sh bird_fib_test.sh check     # exits non-zero if either direction fails
sh bird_fib_test.sh stop

# net/frr{8,9,10} — same idea
sh frr_test.sh start
sh frr_test.sh stop

# net/frr10 — tunnel-unnumbered regression (FRR PR 8132), with bird3 as peer
sh frr_tunnel_unnumbered_test.sh start
sh frr_tunnel_unnumbered_test.sh check    # exits non-zero if bug still present
sh frr_tunnel_unnumbered_test.sh stop

# sysutils/osquery — full regression
sh osquery_test.sh

# net/py-GeoIP2
xzcat db.data.xz > db.data
python geoip-test.py db.data 2.2.2.2     # expects: Country for 2.2.2.2 is Sweden

# net/py-maxminddb
python maxminddb-test.py db.data 2.2.2.2
```

## Coverage gap

Many maintained ports have no test here yet — when bumping one of them,
add a small script in this directory and update the table above. Bias
toward "does the binary run and produce the expected output" smoke
tests over comprehensive coverage; the goal is catching a broken bump,
not exercising every code path.

Currently missing tests for:

- `net/sslh` (only smoke), `net/libyang*`,
  `net/freevrrpd`, `net/pimd`, `net/pkt-gen`, `net/packetdrill`,
  `net/tcptestsuite`, `net/tcplog_dumper`, `net/graphpath`,
  `net/read_bbrlog`
- All `graphics/vulkan-*`, `graphics/crucible`, `graphics/vkrunner`,
  `graphics/openfx-*`, `graphics/ttygif`
- All `www/py-*`, `misc/py-*`, `devel/py-*`, `audio/py-edge-tts`
  (covered so far: `misc/py-anthropic`, `www/py-exa-py`,
  `www/py-firecrawl-py`, `devel/py-deepdiff`, `databases/py-PyHive` +
  transitive `devel/py-pure-sasl`, `devel/py-thrift_sasl`)
- `misc/picoclaw`
- `sysutils/mstflint`, `multimedia/gpac`, `benchmarks/ipc-bench`,
  `devel/bbparse`, `security/rcracki_mt`
