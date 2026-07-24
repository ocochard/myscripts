# Continue prompt for next Claude session

Copy the block below verbatim into a fresh Claude session as the
first user message.

---

I'm continuing a FreeBSD port of `hgaiser/moonshine` (a Sunshine-alternative
Moonlight streaming host). End-to-end video AND audio streaming
already work over Tailscale/WireGuard tunnels from ser6 (FreeBSD
16.0-CURRENT, AMD Radeon 680M) to Moonlight-qt on Windows and Mac.
The remaining bug is a **session-startup race** on the initial `/launch`
that requires the user to click Resume 1-3 times before video appears.

## Read these first, in order

1. **`~/myscripts/FreeBSD/moonshine/STATE.md`** — full project state.
   The port is at §1-§19; the /launch race is the primary open issue.
2. **`~/myscripts/FreeBSD/moonshine/LAUNCH-RACE-TROUBLESHOOTING.md`** —
   everything we've tried and ruled out for the /launch race, plus
   the current best-guess root cause + fix candidates. **This is the
   most important file for you.**
3. **`~/myscripts/FreeBSD/moonshine/memory/`** — 5 memory files
   documenting cross-cutting FreeBSD gotchas (v6only sysctl, RUSTFLAGS
   -L trap, PMTU pcap diagnosis pattern, ENet range coder, sysrc vs
   service enable). Skim these if you're new to the FreeBSD side of
   the codebase.

## The moonshine repo

- `~/moonshine` on branch `freebsd`, remotes `origin =
  ocochard/moonshine`, `upstream = hgaiser/moonshine`.
- All FreeBSD-specific work is committed on the `freebsd` branch. Last
  commit as of 2026-07-24: `546c50f` (rate-limit audio-drop log).
- Build recipe: `RUSTFLAGS="-C link-arg=-L/usr/local/lib -C
  link-arg=-Wl,-rpath,/usr/local/lib" cargo build` (see memory file
  `feedback_rustflags_dash_L_bundles_wrong_a.md` for why).
- Deploy to ser6: `pkill moonshine on ser6; scp
  target/debug/moonshine ser6:/tmp/moonshine; restart` — see
  STATE.md's "ser6 test setup" section for the exact launch env.

## Where you likely need to start

Read `LAUNCH-RACE-TROUBLESHOOTING.md` **cover to cover** before doing
anything. That doc lists three fix directions (A/B/C). The user has
already applied C (added `-nosplash` to CWR-CE's launch args in
`/tmp/moonshine-test/moonshine.toml` on ser6) — untested at time of
handoff. Retest first:

1. On ser6, start moonshine (see ser6 launch env in STATE.md).
2. From Moonlight-qt (Windows via Tailscale `100.123.76.26` or Mac
   via IPv6 `2a01:e0a:1092:3d20:57da:3a10:3e7:ab33`), click Play →
   CWR-CE.
3. Count the number of retries needed before video appears. If it's
   consistently 0-1, fix C may be enough. If it's still 2+, move on
   to fix A (server-side splash-frame emission on RTSP PLAY).

## Rules

- Don't push commits without explicit user approval.
- Don't touch `~/freebsd-official/ports` (unrelated ports tree).
- Runtime testing goes to `ssh ser6`. Build happens on this host.
- ser6 has `virtual_oss` running (base-system daemon, not enabled by
  default — user has enabled it via `service virtual_oss enable`
  + `service virtual_oss start`). It publishes `/dev/dsp.loop` which
  moonshine's OSS capture backend reads. Don't disturb it.
- `~/hermes-agent`, `~/moonshine`, `~/myscripts` are all separate git
  repos on distinct remotes.

## Environment

- FreeBSD 16.0-CURRENT via linuxulator (`uname` says Linux 5.15 —
  ignore it).
- Rust toolchain: rustc/cargo 1.96.1 at `/usr/local/bin/`.
- Native runtime deps on ser6 (all already installed): `libxkbcommon`,
  `mesa-libs`, `mesa-dri` (patched with video-codecs=all,h264enc,h265enc
  — see STATE.md §1), `xwayland`.

## Client-side data if you need it

- Moonlight-qt logs on Windows/Mac end up under `/tmp/Moonlight-*.log`
  (Mac) or `%LOCALAPPDATA%\Moonlight Game Streaming
  Project\Moonlight\Logs\` (Windows).
- ser6 runs a Python log-drop HTTP receiver on `47990` (`/tmp/logdrop.py`
  — see STATE.md for the recipe). Any bundle from the client can be
  POST'd there and lands in `/tmp/logdrop/<timestamp>-<label>`.

## Meta

Uncommitted work in `~/moonshine`: none as of 2026-07-24 01:47 UTC.
All fixes made today (audio backend, SO_SNDBUF, cfg-gated audio env,
drop-log rate-limit) are committed and pushed to `ocochard/moonshine`
`freebsd` branch.

Uncommitted work in `~/myscripts`: two new docs pending commit —
`LAUNCH-RACE-TROUBLESHOOTING.md` and this file. Commit + push them
along with any STATE.md updates you make.
