# Continue prompt for next Claude session

Copy the block below verbatim into a fresh Claude session as the
first user message.

---

I'm continuing a FreeBSD port of `hgaiser/moonshine` (a Sunshine-alternative
Moonlight streaming host). End-to-end video AND audio streaming
already work over Tailscale/WireGuard tunnels from ser6 (FreeBSD
16.0-CURRENT, AMD Radeon 680M) to Moonlight-qt on Windows and Mac.

The **/launch black-screen race is SOLVED and FIXED.** Root cause was
`Packetizer::warm_up()` building 213 ReedSolomon FEC matrices
synchronously on the encoder thread before the encode loop's first
recv (~37s debug, 0.77s release; `/resume` never actually fixed
anything — warm_up just finished on its own). The fix moves that build
off-thread so the encode loop starts at frame 0 immediately in any
build. Verified on ser6. See "Current state" below for the commit trail.

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

## Current state — /launch race RESOLVED

The race is fully fixed, verified on ser6, committed and pushed. All
PROBE instrumentation was stripped before commit. Nothing outstanding on
the race.

Commit trail:
- `a804841` (moonshine `freebsd`) — `dispatch_frame_callbacks()` helper
  (dispatch before early-returns) + `wp_presentation_feedback` drain on
  every space window + pool_busy slot-scan fix.
- `f4fa804` (moonshine `freebsd`) — `warm_up` moved off-thread
  (`warm_up_async` + `merge_warm_up` + free `build_fec_encoders`); encode
  loop polls `handle.is_finished()` and merges once ready; lazy
  `get_fec_encoder` covers the first frames.
- `bf3610d` (myscripts `master`) — root-cause doc rewrite.

Verified (release, ser6): Encoding frame 0 fires 11 ms after peer
connect; FEC cache (213 entries) merges 747 ms later off-thread; no
Reset/Resume/panic. Debug builds now also start at frame 0 immediately.

## Remaining work

No known streaming blocker. Video + audio + keyboard/mouse input all
work end-to-end, on LAN AND over the WireGuard/Tailscale tunnel (Mac +
Windows), with the fixed binary. The old "off-LAN tunnel video wall"
(§17) was a misdiagnosed warm_up-era failure — NOT a real bug.

Since then, more has shipped (see STATE.md for detail):
- **Native FreeBSD gamepad backend — DONE.** Core Xbox pad (buttons,
  dpad, 2 sticks, 2 triggers) via raw `/dev/uinput` ioctls in Rust,
  verified end-to-end with an Xbox controller. See `GAMEPAD-FREEBSD.md`.
- **Rumble/FF — WON'T FIX (kernel-blocked).** FreeBSD's evdev/uinput
  stubs out the force-feedback path, so rumble can't work without kernel
  changes. Full analysis + a re-land recipe in `RUMBLE-FREEBSD.md`.
- **notify-rust PIN-URL WARN — DONE** (moonshine `0213e38`): PIN URL is
  logged as a loud banner; desktop notify gated on a D-Bus session bus.
- **Mesa Vulkan-Video-codecs fix — merged to the ports tree**
  (`graphics/mesa-dri` `84fd498712a6`, PR 296968); local patch obsolete.

Remaining non-blocking follow-ups tracked in STATE.md: ENet range-coder
compressor (WON'T FIX); CWR-CE boxart; a firewall rule
(pf/ipfw/ipfilter, none default) for the public IPv6 UDP ports; deferred
gamepad extras (motion/touchpad/battery/non-Xbox layouts).

## Environment

- **FreeBSD 16.0-CURRENT** dev host. The build (`cargo`/`rustc`) and all
  runtime binaries (moonshine, vkcube, CWR-CE, Xwayland) are NATIVE
  FreeBSD. Only claude-code itself runs under linuxlator, so a shell it
  spawns may report `uname` = Linux 5.15 — ignore that; it is the
  claude-code sandbox, not the host or the build.
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
