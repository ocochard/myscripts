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
| `sslh.sh`           | `net/sslh`                      | Self-contained: `pkg add`s the freshly-built `sslh` from the poudriere builder, starts `sslh-ev` listening on 127.0.0.1:8022, forwards to local sshd on :22, runs an `ssh -p 8022` probe, checks the log for the connection, then stops the daemon and `pkg delete`s the package. | Local sshd, sudo, `sslh-*.pkg` in poudriere |
| `bird_test.sh`      | `net/bird2`, `net/bird3`        | Builds a 6-jail vnet lab exercising BGP / RIP / OSPF / BABEL / static between `bird1..bird6`. `start` brings the lab up, `stop` tears it down. Used to validate `bird` after a bump on multi-protocol configs.              | `sudo`, vnet jails, root       |
| `bird_fib_test.sh`  | `net/bird2` (netlink vs `@rtsock`) | Host-only (no jails / no vnet) `start`/`check`/`stop` regression for [PR 279662](https://bugs.freebsd.org/bugzilla/show_bug.cgi?id=279662). Creates `lo901` bound to FIB 1, manually installs `10.55.0.0/24` in FIB 1, then runs `bird` with one `kernel` protocol (`kernel table 1`, `learn`) plus a static `10.123.0.0/24`. Asserts **both directions**: (a) bird learned the FIB-1 kernel route (inbound `learn`) and (b) the bird static landed in kernel FIB 1 (outbound `export`). On `15.0-RELEASE-p9` + netlink the export path passes (kernel fix `f34aca55adef` is MFC'd) but the learn path fails (kernel fix `33acf0f26b49` is main-only at this writing). `@rtsock` passes both directions. | `sudo`, `net.fibs>=2`, root    |
| `frr_test.sh`       | `net/frr8/9/10`                 | Same idea as `bird_test.sh` but for FRR: 7-jail topology covering BGP / RIP / OSPF / ISIS / BABEL / static. Used to catch routing-protocol regressions across FRR major bumps.                                               | `sudo`, vnet jails, root       |
| `frr_tunnel_unnumbered_test.sh` | `net/frr10` (+ `net/bird3` as peer) | Regression for [FRR PR 8132](https://github.com/FRRouting/frr/pull/8132) and [BSDRP#27](https://github.com/ocochard/BSDRP/issues/27) — same root cause (filed 2021, closed unmerged Apr 2026). Two vnet jails wired by an epair, each with a `gif` tunnel carrying a peer-style `inet 10.99.1.X/24 10.99.1.Y` inner address. `frr1` runs frr10 zebra+ospfd, `brd2` runs bird3 OSPF. `start`/`check`/`stop`. Bug: `zebra/connected.c::connected_announce()` flags any address with local prefixlen /32 as `UNNUMBERED` without consulting the peer's prefixlen, so FreeBSD tunnels are always wrongly unnumbered. `check` asserts (a) `vtysh "show interface gif991"` does not print UNNUMBERED, (b) bird3 reaches OSPF state Full, (c) bird3 learned the FRR `/32` loopback via the tunnel inner next-hop, (d) `show ip ospf interface` doesn't report "This interface is UNNUMBERED", (e) on-wire OSPF Hello from FRR carries the correct subnet mask, not `0.0.0.0` (the literal BSDRP#27 wire-level symptom). bird is lenient and accepts the wrong-mask hello, so (b) and (c) pass even when the bug reproduces — strict peers (RouterOS, IOS, Junos) would drop it. | `sudo`, vnet jails, root, both `frr10` and `bird3` installed |
| `mlvpn_test.sh`     | `net/mlvpn`                     | Host-only smoke test: runs two `mlvpn` instances (server + client) bound to different loopback ports, opens two `tun` devices (10.0.16.1/2), verifies the tunnel comes up and forwards ICMP between the endpoints.            | `sudo`, root, `mlvpn` installed |
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
- `misc/picoclaw`, `misc/qwen-code`, `misc/hermes-agent`
- `sysutils/mstflint`, `multimedia/gpac`, `benchmarks/ipc-bench`,
  `devel/bbparse`, `security/rcracki_mt`,
  `filesystems/amazon-efs-utils`
