# Continue prompt for next Claude session

Copy the block below verbatim into a fresh Claude session as the
first user message.

---

I'm continuing a FreeBSD port of `hgaiser/moonshine` (a Sunshine-alternative
Moonlight streaming host). End-to-end video AND audio streaming
already work over Tailscale/WireGuard tunnels from ser6 (FreeBSD
16.0-CURRENT, AMD Radeon 680M) to Moonlight-qt on Windows and Mac.

The **/launch black-screen race is SOLVED.** Root cause was
`Packetizer::warm_up()` building 213 ReedSolomon FEC matrices
synchronously on the encoder thread before the encode loop's first
recv. Debug build: ~37s. Release build: 0.77s and the race is gone.
It is a debug-build artifact; `/resume` never actually fixed anything.

## Read these first, in order

1. **`~/myscripts/FreeBSD/moonshine/STATE.md`** — full project state.
   §1-19 is background; **§20 is the confirmed root-cause analysis**
   (warm_up, the debug/release measurements, the ruled-out theories,
   and the secondary pool_busy latent bug). Read §20 in full.
2. **`~/myscripts/FreeBSD/moonshine/LAUNCH-RACE-TROUBLESHOOTING.md`** —
   the investigation trail. The banner at the top marks everything
   below it as superseded; read the banner, skim the rest only if you
   want the negatives (path-MTU, ENet, firewall etc. all ruled out).
3. **`~/myscripts/FreeBSD/moonshine/memory/`** — memory files
   documenting cross-cutting FreeBSD gotchas. Skim if new to the
   FreeBSD side.

## Current state

- **Root cause confirmed.** Nothing left to diagnose on the race.
- ser6 runs a **release** binary that still carries PROBE
  instrumentation. All PROBE lines across `state.rs`, `mod.rs`,
  `handlers.rs`, `pipeline/mod.rs` must be stripped before any commit.
- `~/moonshine` `freebsd` branch, uncommitted:
  - `+53` state.rs diff: `dispatch_frame_callbacks()` helper +
    `wp_presentation_feedback` drain on every space window. These are
    directionally fine but **do not affect the race**. Decide keep /
    revert / fold.
  - All PROBE instrumentation (info-level tracing) added during the
    investigation.

## Remaining work

1. **Fix the pool_busy slot-pinning bug** in
   `moonshine-core/src/session/compositor/state.rs` (~lines 765-778).
   On the `!consumed` early-return, `render_and_export` returns
   *without* advancing `next_buffer_index`, so one stuck slot pins the
   round-robin cursor and every subsequent tick rechecks the same busy
   slot instead of using the 2 free ones. Fix: scan all slots for a
   free one (or advance past busy slots). Low risk, ~2 lines. Latent —
   only surfaces behind a slow/absent consumer (i.e. the debug warm_up
   window); invisible in release.
2. **Strip all PROBE instrumentation** before any commit.
3. **Decide fate of the B+C state.rs diff** (keep / revert / fold).
4. **(Optional) Move warm_up off the critical path** so even debug
   builds start fast: spawn it on a background thread/task and let the
   lazy `get_fec_encoder` (packetizer.rs:426, already creates-on-demand)
   fill the cache for the first few frames. Or skip warm_up entirely.

## Environment

- **FreeBSD 16.0-CURRENT** via linuxulator on this dev host (`uname`
  says Linux 5.15 — ignore). Runtime binaries (moonshine, vkcube,
  CWR-CE, Xwayland) are all NATIVE FreeBSD; only claude-code runs under
  linuxlator.
- Rust: `rustc/cargo 1.96.1` at `/usr/local/bin/`.
- Build recipe: `RUSTFLAGS="-C link-arg=-L/usr/local/lib -C
  link-arg=-Wl,-rpath,/usr/local/lib" cargo build` from `~/moonshine`.
  Add `--release` for a fast binary (the release build is what makes
  the race disappear).
- ser6 runtime target: `ssh ser6` (FreeBSD 16.0-CURRENT, AMD Radeon
  680M).

## Rules

- Don't push commits without explicit user approval.
- Don't touch `~/freebsd-official/ports` (unrelated ports tree).
- Runtime testing goes to `ssh ser6`. Build happens on this host.
- ser6 has `virtual_oss` running (base-system daemon, enabled via
  `service`). Publishes `/dev/dsp.loop`. Don't disturb it.
- `~/hermes-agent`, `~/moonshine`, `~/myscripts` are separate git
  repos on distinct remotes.

## ser6 test setup (unchanged)

- Binary: `/tmp/moonshine` (scp'd from build host). To replace a
  running binary: `pkill -f /tmp/moonshine; sleep 1; pkill -9 -f
  /tmp/moonshine; rm -f /tmp/moonshine` then scp, then SHA-verify.
- Config: `/tmp/moonshine-test/moonshine.toml` (CWR-CE, vkcube,
  glxgears).
- Runtime dir: `/tmp/moonshine-runtime` (XDG_RUNTIME_DIR)
- Log: `/tmp/moonshine-test/out.log`
- Restart script: `/tmp/moonshine-start.sh`

## Log filter recipe

```
MOONSHINE_LOG="debug,mdns_sd=info,mio::poll=info,calloop=info,rustls=info,hyper=info,h2=info,smithay::backend::egl=info,smithay::backend::renderer=info,smithay::xwayland::xwm=info,smithay::wayland=info,tokio_enet=info"
```
Keeps `Encoding frame`, RTSP, pipeline transitions visible.
