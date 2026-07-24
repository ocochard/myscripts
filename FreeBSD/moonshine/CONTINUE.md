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
anything. Contains the full data-driven ruling-out of network/framing/
firewall/codec/etc.

### Latest data (2026-07-24 01:57 UTC)

**`-nosplash` tested — did NOT fix the /launch race.** CWR-CE starts
fast (user confirmed "20-year-old game, starts very very fast"), so
the "waiting for slow game" theory was wrong.

**New concrete finding**: between `/launch` (T=0) and the first
`/resume` (T≈22s), moonshine's log shows:
- Compositor imported 3 client DMA-BUF wl_buffer commits from the
  game (at T+0.03s, T+1.04s, T+3.10s). `Client DMA-BUF import
  successful` fires each time. So the **game IS rendering**.
- **Zero `Received video stream PING`** events on port 47998. Client
  Moonlight-common-c's PING thread should fire every 500ms starting
  right after `startVideoStream()`. It never reached moonshine.
- **Zero `Encoding frame`** events. The video pipeline entered
  `run_encoding_loop` at T+3.05s (right after `H.265 encoder created
  successfully`) but never processed a single frame from
  `frame_rx.recv_timeout()`.

So the pipeline task started, is running, has an encoder, but never
sees frames from the compositor. Even though the compositor is
importing dmabufs from the game.

**Suspects** (untested, ranked):
1. **Compositor's `frame_tx.try_send()` never actually calls into
   the pipeline's `frame_rx`.** Two possible reasons:
   a. The screen_dirty rate-limit at `state.rs:645` throttles emission
      to ≤1/sec when nothing has changed — but the game IS committing
      wl_buffers (`handlers.rs:358` sets screen_dirty=true on
      commit), so this shouldn't apply.
   b. The compositor's render pipeline (60Hz `render_and_export`
      timer) may be blocked / not scheduling / not producing frames
      through direct scanout when there's exactly 1 fullscreen game
      window (which is our case). Look at `state.rs:960
      try_direct_scanout`.
2. **The `frame_rx` in the video pipeline is a different channel
   endpoint than the compositor's `frame_tx`.** Sanity-check ownership
   of the `sync_channel(2)` — created in `compositor/mod.rs:140`, sent
   into `MoonshineCompositor` state, and moved into the video
   pipeline's spawn. Confirm both halves survive the move.
3. **On /resume, moonshine calls `Resetting video frame counter and
   forcing IDR` in the pipeline. That call must side-effect the
   compositor somehow (e.g. bumping screen_dirty, triggering a
   re-render, or reconnecting frame_tx→frame_rx).** Whatever it
   does, it's the trigger — because after /resume, encoding starts.

### The exact diagnostic experiment to run next

Add a `tracing::info!` at three critical points in moonshine, rebuild,
deploy, run one `/launch → /resume` cycle:

1. In `compositor/state.rs::render_and_export()`, log at the top of
   the function so we see whether the 60Hz timer fires at all
   between /launch and /resume:
   ```rust
   tracing::info!("render_and_export tick, screen_dirty={}", self.screen_dirty);
   ```
   Down-level to `trace!` after diagnosis.

2. In the same function on `frame_tx.try_send(...)`, log the outcome:
   ```rust
   Ok(()) => tracing::info!("render_and_export: frame_tx sent OK"),
   Err(TrySendError::Full(_)) => tracing::info!("render_and_export: frame_tx FULL, dropped"),
   ```

3. In `pipeline/mod.rs::run_encoding_loop`, log every `recv_timeout`
   outcome (Ok vs Timeout):
   ```rust
   match frame_rx.recv_timeout(frame_interval) {
       Ok(frame) => { tracing::info!("pipeline: got frame from compositor"); ... }
       Err(RecvTimeoutError::Timeout) => { tracing::info!("pipeline: recv_timeout hit"); ... }
   }
   ```
   Down-level after diagnosis.

Run one launch+resume cycle. The log lines above localize which end
of the channel is silent. Then narrow further.

### Also-worth-checking

- **PING thread on the client**. The absence of `Received video
  stream PING` server-side is strange. Look at moonlight-common-c's
  `VideoPingThreadProc` — is there some condition where it fails to
  start? On the client side, tcpdump the outgoing UDP from moonlight's
  PID to `100.123.76.26:47998` to confirm PINGs are actually being
  sent. If they're not, the client's problem is downstream of us and
  no server-side fix will help.

- **6 IDR encodings in ~4s during the (partially-working) 2nd
  /resume**. Client re-requested IDR 6 times. Some IDRs have
  `l0_refs=[(0, 312)]` (non-empty) — should be `[]` for a true IDR
  refresh. May indicate the encoder isn't fully resetting the DPB on
  request_idr. See `pixelforge::encoder::h265::api.rs` line 85+:
  `sequence_start(dpb_config)` is supposed to reset the DPB. Confirm
  the reset actually clears l0_refs.

### Untested fix ideas (from the earlier troubleshooting doc)

The three earlier candidates (A/B/C in `LAUNCH-RACE-TROUBLESHOOTING.md`)
were all speculative. Now with the "compositor imports but pipeline
never sees frames" finding, the ACTUAL fix is likely narrower and
smaller than any of them. Focus first on the diagnostic tracing above.

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
