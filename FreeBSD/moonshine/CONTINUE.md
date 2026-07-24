# Continue prompt for next Claude session

Copy the block below verbatim into a fresh Claude session as the
first user message.

---

I'm continuing a FreeBSD port of `hgaiser/moonshine` (a Sunshine-alternative
Moonlight streaming host). End-to-end video AND audio streaming
already work over Tailscale/WireGuard tunnels from ser6 (FreeBSD
16.0-CURRENT, AMD Radeon 680M) to Moonlight-qt on Windows and Mac.

The remaining bug is a **session-startup race** on the initial `/launch`
that requires the user to click Resume 1-3 times before video
appears. Now confirmed **game-independent** (reproduces on vkcube as
well as CWR-CE), so it's a moonshine bug, not a game-specific one.

## Read these first, in order

1. **`~/myscripts/FreeBSD/moonshine/STATE.md`** — full project state.
   §1-19 is background; **§20 is the 2026-07-24 evening handoff with
   the probe-driven diagnosis, the two fixes applied, and the current
   state of investigation.** Read §20 in full.
2. **`~/myscripts/FreeBSD/moonshine/LAUNCH-RACE-TROUBLESHOOTING.md`** —
   everything we've tried and ruled out for the /launch race, with a
   long 2026-07-24-evening section at the bottom. **Read that
   section, and skim the 2026-07-24 morning section above it for
   context on the earlier speculation (buffer-pool wedge — a symptom
   we chased and reverted, but the diagnostic pattern is useful).**
3. **`~/myscripts/FreeBSD/moonshine/memory/`** — 5 memory files
   documenting cross-cutting FreeBSD gotchas. Skim if new to the
   FreeBSD side.

## Current state of the fix

`~/moonshine` branch `freebsd`, working tree has **uncommitted `+53
lines` diff to `moonshine-core/src/session/compositor/state.rs`**.
Two changes bundled:

1. **Extract frame-callback dispatch into `dispatch_frame_callbacks()`**
   and call it at TOP of `render_and_export` before any early-return.
   Previously only the composited path (bottom of function) dispatched
   `wl_surface.frame` callbacks; if the function early-returned via
   the keepalive throttle, buffer-in-use check, or direct-scanout
   success, callbacks were skipped.
2. **Drain `wp_presentation_feedback` on every space window** (not
   just override_surface). Xwayland uses this protocol for X11
   Present.

Both are directionally correct (the callback dispatch was skipped in
early-return paths, which is a bug). Neither resolves the /launch
race by itself.

`git diff moonshine-core/src/session/compositor/state.rs` shows exactly
what changed.

## The remaining bug

Both games we test (CWR-CE / OpenGL-under-Xwayland with XR24 format,
and vkcube / Vulkan with XB4H format) show:

1. Game launches, imports 4-5 initial DMA-BUF buffers into moonshine
   compositor in the first ~200ms.
2. RTSP Play → ENet peer connect → client sends StartB via ENet
   ~4ms after connect (confirmed by instrumenting the ENet Receive
   path; StartB decrypts cleanly).
3. Pipeline unblocks, `create_encoder()` runs ~500ms, enters
   `run_encoding_loop`, starts calling `frame_rx.recv_timeout()`.
4. **Game stops committing new buffers.** `Client DMA-BUF import`
   events silent for 30-45 seconds. `frame_rx.recv_timeout` returns
   Timeout forever.
5. Client Moonlight-qt times out at ~10-13s with "no video".
6. User clicks /resume → RTSP Play on Active session → pipeline
   Reset broadcast → **14 seconds AFTER /resume**, `Resetting video
   frame counter` fires and `Encoding frame 0` follows immediately.
7. Streaming becomes stable.

The 14-second gap between /resume RTSP Play and first Encoding frame
is completely mysterious. Reset does nothing to compositor or game,
yet 14s later frames start flowing.

## The concrete NEXT experiment

**Instrument the game's Wayland protocol traffic with `WAYLAND_DEBUG`.**

Add a `[[application]]` entry to `/tmp/moonshine-test/moonshine.toml`
on ser6:

```
[[application]]
title = "vkcube-wldbg"
command = ["/bin/sh", "-c", "WAYLAND_DEBUG=client exec /usr/local/bin/vkcube 2>/tmp/vkcube-wl.log"]
launch_timeout_secs = 5
```

- Deploy the current binary (`scp ~/moonshine/target/debug/moonshine
  ser6:/tmp/moonshine`), restart via `/tmp/moonshine-start.sh`.
- From Moonlight-qt, pick "vkcube-wldbg". Let it hit the wedge.
- Read `/tmp/vkcube-wl.log` on ser6.

The log will contain lines like:
```
[TIMESTAMP] -> wl_surface@N.commit()
[TIMESTAMP]  wl_display@1.done(...)
[TIMESTAMP] wl_buffer@N.release()
[TIMESTAMP]  wl_callback@N.done(...)
```

Look for what the game's last outgoing request is during the wedge,
and what INCOMING event it expects but doesn't receive. Common
suspects:

- **`wl_buffer.release`** — if moonshine holds imported dmabufs
  without releasing them, the game runs out of buffers and stops
  committing. This is my top current hypothesis. Check whether the
  compositor's dmabuf import path releases the client's wl_buffer
  after import completes — smithay usually does this via the
  buffer pool's consumed atomic, but our code might be holding
  buffers longer than necessary.
- **`wp_linux_dmabuf_feedback.tranche_done`** — if moonshine doesn't
  send this on second/later imports, the game blocks.
- **`wl_output.done`** — if the game's WSI is waiting for output
  events.
- **`wl_callback.done` from a specific callback ID** — if the game
  sent `wl_surface.frame(callback_id=N)` and we're firing done on
  a different callback_id, that could stall it.

Once WAYLAND_DEBUG reveals the missing event, the fix is likely
localized to moonshine's compositor handlers — either add the missing
event, or fix the timing/ordering of an existing one.

## Environment

- **FreeBSD 16.0-CURRENT** via linuxulator on this dev host (`uname`
  says Linux 5.15 — ignore).
- Rust: `rustc/cargo 1.96.1` at `/usr/local/bin/`.
- Build recipe: `RUSTFLAGS="-C link-arg=-L/usr/local/lib -C
  link-arg=-Wl,-rpath,/usr/local/lib" cargo build` from `~/moonshine`.
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

- Binary: `/tmp/moonshine` (scp'd from build host)
- Config: `/tmp/moonshine-test/moonshine.toml`
  - Currently has 3 apps: CWR-CE, vkcube, glxgears. Old CWR-CE-only
    config backed up at `/tmp/moonshine-test/moonshine.toml.bak`.
- Runtime dir: `/tmp/moonshine-runtime` (XDG_RUNTIME_DIR)
- Log: `/tmp/moonshine-test/out.log`
- Restart script: `/tmp/moonshine-start.sh` — pkill's moonshine,
  truncates out.log, restarts with the standard MOONSHINE_LOG filter.

## Log filter recipe

```
MOONSHINE_LOG="debug,mdns_sd=info,mio::poll=info,calloop=info,rustls=info,hyper=info,h2=info,smithay::backend::egl=info,smithay::backend::renderer=info,smithay::xwayland::xwm=info,smithay::wayland=info,tokio_enet=info"
```
Keeps `Encoding frame`, RTSP, pipeline transitions, and my probe
lines visible.

## Uncommitted work summary

- `~/moonshine` on branch `freebsd`: **uncommitted +53 lines in
  `moonshine-core/src/session/compositor/state.rs`** (dispatch_frame_callbacks
  helper + wp_presentation_feedback drain). Not committed yet
  because fix alone doesn't resolve the race — waiting to bundle
  with the follow-up fix from the WAYLAND_DEBUG investigation.
- `~/myscripts`: STATE.md §20 + LAUNCH-RACE-TROUBLESHOOTING.md
  2026-07-24-evening section + this CONTINUE.md rewrite are
  uncommitted. Commit them along with any state updates you make.
