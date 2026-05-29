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
| `mlvpn_test.sh`     | `net/mlvpn`                     | Host-only smoke test: runs two `mlvpn` instances (server + client) bound to different loopback ports, opens two `tun` devices (10.0.16.1/2), verifies the tunnel comes up and forwards ICMP between the endpoints.            | `sudo`, root, `mlvpn` installed |
| `osquery_test.sh`   | `sysutils/osquery`              | Cross-platform (FreeBSD + Linux). Audits `ldd` for the port's `Find<lib>.cmake` hijacks, runs ~30 `osqueryi` SQL queries against core / posix / process / network / filesystem / pci / usb / yara / augeas tables, starts `osqueryd` with a 30 s schedule + event backends (devd/inotify/openbsm), then cross-checks counts against native tools (`arp`, `mount`, `pciconf`, `usbconfig`, `sockstat`, etc.). | `sudo`, `jq`                   |
| `geoip-test.py`     | `net/py-GeoIP2`                 | One-liner: opens a MaxMind DB and looks up a country for a given IP via `geoip2.database.Reader`. Verifies the Python binding loads and a basic query returns the expected country.                                          | `db.data` (see below), Python  |
| `maxminddb-test.py` | `net/py-maxminddb`              | Same shape as `geoip-test.py` but goes through the lower-level `maxminddb` reader and pretty-prints the full record. Verifies the raw binding (no GeoIP2 wrapper).                                                            | `db.data` (see below), Python  |
| `mrtparse_test.sh`  | `net/mrtparse`                  | Self-contained: `pkg add`s the freshly-built `py311-mrtparse`, imports the library, parses a sample MRT RIB dump (`mrtparse-sample.mrt`, shipped here), checks record count + version, exercises the `mrt2json.py` CLI, then `pkg delete`s. | sudo, `py311-mrtparse-*.pkg` in poudriere |
| `py-anthropic_test.sh` | `misc/py-anthropic`         | Self-contained: `pkg add`s the freshly-built `py311-anthropic`, imports the SDK, checks version, constructs an `Anthropic` client (no network call), verifies main types are importable. Skips uninstall if reverse deps (e.g. `hermes-agent`) are installed. | sudo, `py311-anthropic-*.pkg` in poudriere |
| `py-exa-py_test.sh` | `www/py-exa-py`             | Self-contained: `pkg add`s the freshly-built `py311-exa-py`, imports the SDK, checks version via `importlib.metadata` (no `__version__` exposed), constructs an `Exa` client (no network call), verifies `AsyncExa` subclasses `Exa` and key submodules import. Skips uninstall if reverse deps (e.g. `hermes-agent`) are installed. | sudo, `py311-exa-py-*.pkg` in poudriere |

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
- `misc/picoclaw`, `misc/qwen-code`, `misc/hermes-agent`
- `sysutils/mstflint`, `multimedia/gpac`, `benchmarks/ipc-bench`,
  `devel/cbmc`, `devel/bbparse`, `security/rcracki_mt`,
  `filesystems/amazon-efs-utils`
