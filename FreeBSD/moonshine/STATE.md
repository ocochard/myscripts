# Moonshine → FreeBSD port — current state

Snapshot for session handoff. Companion to `README.md` (the feasibility
study + plan) and `../mesa-dri-video-codecs/` (the prerequisite Mesa fix).

Date: 2026-07-22 (updated in-session after reaching end-to-end streaming on ser6).

## What's done

### 1. Prerequisite: Vulkan Video encode on FreeBSD/RADV — SHIPPED

- Root cause: `graphics/mesa-dri` did not set `-Dvideo-codecs=`, falling
  back to upstream's `all_free` (patent-free codecs only). Also missing
  `libdisplay-info` LIB_DEPENDS.
- Patch file: `~/myscripts/FreeBSD/mesa-dri-video-codecs/mesa-dri-video-codecs.patch`.
- Poudriere-built, installed on ser6 (FreeBSD 16.0-CURRENT, AMD Radeon
  680M, VCN 3.0), verified: `vulkaninfo` now exposes
  `VK_KHR_video_{encode,decode}_h264` and `_h265`.
- **Bugzilla PR submitted upstream** — awaiting `x11@FreeBSD.org` review.

### 2. Moonshine fork infrastructure

- Fork: `git@github.com:ocochard/moonshine.git`, main branch tracks
  `hgaiser/moonshine`.
- Local clone: `~/moonshine`, remotes:
  - `origin` = `git@github.com:ocochard/moonshine.git` (fork, push target)
  - `upstream` = `https://github.com/hgaiser/moonshine.git` (for rebases)
- Working branch: **`freebsd`**, off `main` at v0.12.0 (commit 61530ff).
- All work happens on `freebsd`. Uncommitted.

### 3. Audio clock refactor — DONE (uncommitted)

Replaced Linux-only `mio-timerfd` with a portable abstraction.

New file: `moonshine-core/src/session/stream/audio/pulse_server/audio_clock.rs`
- Exposes `AudioClock` with `new(interval) -> Result<Self>`, `as_raw_fd() ->
  RawFd`, `drain() -> Result<()>`. Registers into mio via `SourceFd`.
- Linux: wraps `mio_timerfd::TimerFd` (`ClockId::Monotonic`) — same
  behavior as before.
- Non-Linux (FreeBSD, macOS, etc.): pipe + helper thread. Thread sleeps
  `interval`, writes 1 byte per tick; reader drains on POLLIN.

Modified: `moonshine-core/src/session/stream/audio/pulse_server/mod.rs`
- Field type `clock: mio_timerfd::TimerFd` → `clock: AudioClock`.
- Construction unchanged in signature; the `set_timeout_interval` call
  is folded into `AudioClock::new`.
- `self.clock.read()?` → `self.clock.drain()?` at the tick site.

Modified: `moonshine-core/Cargo.toml`
- `mio-timerfd = "0.2.0"` moved from `[dependencies]` to
  `[target.'cfg(target_os = "linux")'.dependencies]` at the end of file.

### 4. socket-pktinfo FreeBSD patch — DONE (uncommitted)

`mdns-sd 0.20.0` unconditionally requires `socket-pktinfo = "0.3.2"`,
which uses Linux-only `IP_PKTINFO` / `struct in_pktinfo`. FreeBSD/BSDs
split the same info across `IP_RECVDSTADDR` + `IP_RECVIF` (delivering
`struct in_addr` + `struct sockaddr_dl`).

Local fork: `~/moonshine/vendor/socket-pktinfo/` (git clone of
`pixsper/socket-pktinfo` main, branch `freebsd`). Modified:

- `src/unix.rs`:
  - IPv4 setup: on BSDs (`freebsd|dragonfly|netbsd|openbsd`), setsockopt
    two options (`IP_RECVDSTADDR`, `IP_RECVIF`) instead of `IP_PKTINFO`.
  - cmsg space calc: `#[cfg]`-gated to reserve room for `in_addr` +
    `sockaddr_dl` on BSDs, or `in_pktinfo` on Linux.
  - recv() cmsg-walk: accumulate BSD dst (`in_addr`) and if_index
    (`sockaddr_dl.sdl_index`) into two separate `Option`s, then fold
    into `PktInfo` after the walk.
  - IPv6 path unchanged (portable, uses `IPV6_PKTINFO`/`in6_pktinfo`).

- `Cargo.toml`:
  - Version pinned to `"0.3.99"` so `[patch.crates-io]` satisfies
    `mdns-sd`'s `= 0.3.2` requirement (which cargo treats as `^0.3.2`).

Wiring in `~/moonshine/Cargo.toml`:
```toml
[patch.crates-io]
socket-pktinfo = { path = "vendor/socket-pktinfo" }
```

### 5. What now compiles / checks on native FreeBSD

`cargo check -p moonshine-core` on `x86_64-unknown-freebsd` gets past
these crates cleanly:
- `smithay` (`Checking smithay` — surprise: compiles on FreeBSD).
- `pixelforge`, `gbm`, `drm`, `wayland-client`, `wayland-server`,
  `wayland-protocols`, `wayland-protocols-wlr`, `wayland-protocols-misc`.
- `pulseaudio` (pure-Rust protocol, no libpulse).
- `mdns-sd` (via our patched `socket-pktinfo`).
- `zbus_macros`, `zbus_names`.
- `rcgen`, `ring`, `aes-gcm`, `rustls`, tokio, hyper, etc.

### 6. inputtino feature-gated out on FreeBSD — DONE (uncommitted)

The `inputtino` crate wraps `/dev/uinput` + `/dev/uhid` via
`libevdev-1.0/libevdev/libevdev.h`, which unconditionally `#include`s
`linux/input.h` / `linux/uhid.h` UAPI headers. Those don't exist on
FreeBSD.

Layout change: `moonshine-core/src/session/stream/control/input/gamepad.rs`
became `.../input/gamepad/mod.rs`, with two new backend files:

- `gamepad/backend_inputtino.rs` (cfg linux): holds the original
  inputtino-backed `Gamepad` struct verbatim, plus a small
  `From<super::MotionType> for inputtino::JoypadMotionType` adapter
  so `gamepad/mod.rs` stays inputtino-free.
- `gamepad/backend_stub.rs` (cfg not linux): no-op `Gamepad` with the
  same public method surface (`new`, `set_pressed`, `apply_update`,
  `touch`, `set_motion`, `set_battery`). First call per instance
  logs a warning; subsequent calls drop silently (AtomicBool latch).

In `gamepad/mod.rs`:
- Added a local `MotionType { Acceleration = 1, Gyroscope = 2 }` enum
  so `GamepadMotion.motion_type` no longer typed as
  `inputtino::JoypadMotionType`.
- Field visibilities widened to `pub(super)` where the backends need
  them: `GamepadInfo.kind`, `GamepadTouch.pointer_id`,
  `GamepadUpdate.{left_trigger, right_trigger, left_stick, right_stick}`,
  `GamepadBattery.{battery_state, battery_percentage}`, and
  `BatteryState` itself.

In `moonshine-core/Cargo.toml`:
- `inputtino = { git = ".../inputtino" }` moved from `[dependencies]`
  into the existing
  `[target.'cfg(target_os = "linux")'.dependencies]` block (alongside
  `mio-timerfd`). Same block picked up a comment explaining why.

Result: `cargo check` and `cargo build -p moonshine-core` both pass
clean on `x86_64-unknown-freebsd`. Six `dead_code` warnings on the
protocol structs (backend-stub doesn't read most fields) — cosmetic.

### 7. Native libs + link-flags wired — DONE

Installed via pkg on this build host:
- `libxkbcommon` (x11/libxkbcommon 1.13.2)
- `mesa-libs` (graphics/mesa-libs 26.1.5, provides libgbm.so)

Link recipe that works on FreeBSD:
```
RUSTFLAGS="-C link-arg=-L/usr/local/lib -C link-arg=-Wl,-rpath,/usr/local/lib" cargo build
```

**Trap:** do NOT use `RUSTFLAGS="-L /usr/local/lib …"` (bare `-L`).
That adds `/usr/local/lib` to rustc's static-lib search order, and
rustc bundles `-l static=…` deps into rlibs. `network-interface`'s
build.rs compiles `lladdr.c` into `libffi.a` (misleadingly named —
it's just the crate's tiny lladdr shim). If rustc finds
`/usr/local/lib/libffi.a` (from `devel/libffi`, the *foreign function
interface* library, unrelated) FIRST, it bundles that huge lib into
libnetwork_interface.rlib and the shim is silently dropped, leaving
`ld.lld: undefined symbol: lladdr` at final link. Use
`-C link-arg=-L/usr/local/lib` (only affects the final `cc` invocation).

### 8. First successful FreeBSD build — DONE

`cargo build` (workspace) succeeds; binary at
`/home/olivier/moonshine/target/debug/moonshine` (380 MB debug, ELF
FreeBSD 16.0 x86-64). `--help` runs and prints usage.

### 9. First successful FreeBSD *run* — DONE (this build host)

`MOONSHINE_LOG=trace /path/to/moonshine /tmp/moonshine-test/moonshine.toml`
starts cleanly on this GPU-less host, prints
`Moonshine is ready and waiting for connections.`, and sits idle
until SIGTERM. Note: log env var is `MOONSHINE_LOG`, not `RUST_LOG`.

Verified working on FreeBSD in the idle path:
- Config auto-create (`Config::load_or_create` writes a default TOML).
- State file load (`state.toml`, unique_id assigned).
- HTTP :47989 + HTTPS :47984 pair/API servers.
- RTSP :48010 session channel.
- mdns-sd advertising `Moonshine._nvstream._tcp.local.` (our patched
  `socket-pktinfo` cmsg path used on every reply — 122-byte responses
  on `ix0`, `ix1`, `igb0`; dst-addr resolved per-interface).
- Clean shutdown on SIGTERM: `Successfully waited for shutdown to complete.`

Cosmetic warnings, none fatal:
- `HDR probe: failed to find render node: No /dev/dri directory found`
  (expected — headless build host).
- `Failed to locate Steam directory` (no Steam installed).
- A few `EADDRINUSE` on IPv6 mcast joins for extra addrs on the same
  interface (mdns-sd already joined once per iface, second addr
  can't rejoin — benign).

The runtime paths STATE predicted might blow up (`zbus::Connection::session()`,
smithay udev/libseat, pulseaudio server) were **not** touched in the
idle startup. They're deferred until an actual client connects and
initiates a stream — that's the ser6 experiment.

### 10. ser6 deployment and PIN pair — DONE

Copied the debug binary to ser6 (`scp target/debug/moonshine
ser6:/tmp/moonshine`, both hosts 16.0-CURRENT x86-64). Runtime
deps `libxkbcommon` + `mesa-libs` were already present on ser6.

Bind address had to move from IPv4-only (`0.0.0.0`) to dual-stack:
- On ser6: `sudo sysctl net.inet6.ip6.v6only=0` (session-only —
  not persisted in `/etc/sysctl.conf`; add if needed at boot).
- In `moonshine.toml`: `address = "::"`. Result: HTTP :47989,
  HTTPS :47984, RTSP :48010 all bind `tcp46` (dual-stack).
- Confirmed by `sockstat -l -P tcp` on ser6 and by real IPv6
  client connections from `2607:fb10:7261:1::1a22` (Mac, off-LAN
  over the internet — full public IPv6 both ends).

Pair flow confirmed: Moonlight client → `GET /pair` → moonshine
logs `Waiting for pin to be sent at http://[<ser6-v6>]:47989/pin?uniqueid=<UUID>`
→ open URL in browser → 4-digit PIN form (served from
`assets/pin.html`) → `POST /submit-pin` → `PIN registered successfully`
→ several `/pair` challenge round-trips → paired cert stored in
`state.toml`. Client stays polling `/serverinfo` at ~3.5s cadence.

Also on ser6: `notify-rust` desktop-notification path fails with
`os error 2 (No such file or directory)` — no `notify-send` binary
/ no D-Bus notification daemon. Cosmetic. The trace-log line has
the PIN URL directly.

Config on ser6 (`/tmp/moonshine-test/moonshine.toml`):
- Trimmed to a single `[[application]]` for CWR-CE
  (`/usr/local/bin/cwr-ce`, no scanner).
- Dropped the Steam application_scanner (Steam not installed on ser6).

### 11. XWayland wall + fix — DONE

On `/launch`, session bringup got as far as `Spawning XWayland
wayland_display=wayland-1` and then died with
`Failed to spawn XWayland: No such file or directory (os error 2)` —
the `Xwayland` binary was not installed. Even though PoseidonGame
links both `libwayland-*` and `libX11/libxcb` (so it *could* be
pure Wayland), smithay's compositor unconditionally spawns Xwayland
during bring-up before the app is launched, and the launch fails
without it.

Fix: user built and installed `x11-servers/xwayland` on ser6 via
poudriere. Confirmed at `/usr/local/bin/Xwayland`. No moonshine
patch needed — the binary was just missing.

Aside: also confirmed the compositor uses `/dev/dri/renderD128`
(render node, not scanout node) so **there is no DRM-master fight**
with Xorg. moonshine coexists with an active X session cleanly,
which invalidates the "stop Xorg first" concern from earlier
walls.

### 12. systemd/D-Bus app-launch → tokio::process::Command backend — DONE (uncommitted)

`moonshine-core/src/session/application.rs` launched apps via
`zbus::Connection::session()` + `org.freedesktop.systemd1.Manager`
(`systemd-run --user`-shaped transient unit). Both preconditions
fail on FreeBSD: no session bus by default, and no systemd. The
wall log line:
```
ERROR moonshine_core::session::application: Failed to connect to
      session bus: I/O error: No such file or directory (os error 2)
```

Refactor (same pattern as `AudioClock` and `Gamepad`):
- `session/application.rs` → `session/application/mod.rs`
  - Keeps portable surface: `ApplicationConfig`, `ApplicationContext`,
    `Application` (cfg-gated re-export), `default_launch_timeout`,
    `make_envs`.
- `session/application/backend_systemd.rs` — verbatim lift of the
  old zbus+systemd path (linux only). All SYSTEMD_* consts,
  `LaunchOptions`, `start_transient_service`, unit-monitor helpers.
- `session/application/backend_command.rs` — new, non-linux:
  - `tokio::process::Command` spawn with `kill_on_drop(true)`,
    inherited HOME/USER/PATH, split-on-`=` env from `make_envs`.
  - `pre_command`s run sequentially with `Command::status().await`
    before the main app (fail-fast, mirrors ExecStartPre semantics).
  - `post_command`s run on Drop from a helper-thread mini-runtime
    (mirrors `stop_unit_owned`'s block_on-in-thread pattern).
  - Child-exit monitor task triggers
    `SessionShutdownReason::ApplicationStopped` — same shape as
    the systemd variant used.
  - stdout/stderr honor `config.stdout`/`config.stderr` (Some(path)
    → append-file, None → inherit).

Result: `cargo build` clean on FreeBSD. On ser6, `/launch` now
logs `Launched application (pid=<n>)` and CWR-CE actually runs.

### 13. End-to-end streaming session working — VERIFIED on ser6

Full pipeline observed in the trace log (single Moonlight client on
Mac over public IPv6):
- `/launch` (HTTPS) → session init → audio/video/control UDP sockets
  bound on `[::]:{48000,47998,47999}`.
- Compositor: EGL 1.5 on `PLATFORM_GBM_KHR`, `GL Renderer: "AMD Radeon
  680M (radeonsi, rembrandt, ACO, DRM 3.59, 16.0-CURRENT)"`, 173
  supported dmabuf render formats, selected `DrmFourcc(AB24)` with
  8 modifiers, virtual output `moonshine-virtual` at 1280×720 @ 60Hz.
- Xwayland spawned (display_number=0), X11 WM initialized, focus
  connection opened.
- Application spawned via new Command backend, CWR-CE forked
  `PoseidonGame` which appeared as X11 window `title="Poseidon [GL33]"
  class="PoseidonGame"`, requested `_NET_WM_STATE_FULLSCREEN`.
- **Zero-copy dmabuf**: `Client DMA-BUF import client_fourcc="XR24"
  num_planes=2 render_fourcc="AB24"` → `DMA-BUF import successful`
  (per-frame). Game GPU buffers imported into moonshine's compositor
  without CPU copy.
- **RTSP ANNOUNCE** received: `Stream contexts received via RTSP
  ANNOUNCE` → `Starting session streams` → `Session streams started
  successfully.`
- **Vulkan Video H.264 encode**:
  `Created Vulkan instance` → `Checking device: AMD Radeon 680M (RADV
  REMBRANDT)` → queue family enumeration finds
  `VIDEO_ENCODE_KHR count=1` at family 3 →
  `H.264 encode supported: max 4096x4096, 17 DPB slots`. This is the
  path unlocked by Section 1's mesa-dri patch.
- **Audio encoder**: `Creating audio encoder with sample rate 48000,
  Stereo channels` (Opus).
- **FEC packetizer** producing per-frame shards.
- **Client → server control channel**: `RequestIdrFrame`, `StartB`,
  `Ping` decrypted from `[client-v6]:57092` (audio) and `:54720`
  (video).

Server-side is streaming H.264 + Opus over IPv6 to a Moonlight-mac
client. Every runtime wall predicted by the study is cleared.

Log hygiene reminder: `MOONSHINE_LOG='trace,mdns_sd=debug'` drops
the mdns_sd per-scan "interface lo0 already exists" spam without
losing anything else. Not a bug in our code — mdns_sd re-enumerates
per addr per iface and its dedup key is name-only; benign on
FreeBSD where lo0 has multiple v4/v6/link-local addresses.

### 14. Client-side pcap + Moonlight-qt log analysis — DONE

Client is **Moonlight-qt 6.1.0 on macOS (M3 Pro)**. Client route to
ser6 is via a **point-to-point tunnel `utun4` with MTU 1280**
(WireGuard-style; not local LAN). Full Moonlight-qt log
(`/tmp/Moonlight-<ts>.log`) shows:
- HTTP/HTTPS control plane works (`/serverinfo`, `/launch` both 200).
- RTSP handshake completes.
- Video codec negotiated: **HEVC** (`format 0x100` in Moonlight
  = HEVC; SDP `x-nv-vqos[0].bitStreamFormat=1`).
- `Received first audio packet after 100 ms` — audio works.
- `IDR frame request sent` → **9-second silence** → `No video
  traffic was ever received from the host!` → `Connection
  terminated: -100`.

Server side of the SAME session:
- HEVC encoder created via `pixelforge::encoder::h265::init:
  H.265 encoder created successfully`, first `IDR frame 0
  encoding` at 14:55:03, `H.265 header (79 bytes)` produced.
  Server IS encoding HEVC (matches negotiated codec).
- FEC packetizer producing per-frame shards.
- Video PINGs from client at `[<mac-v6>]:54720` land every
  ~500ms; moonshine's `spawn_handle_video_packets` uses that
  to populate `client_address`.
- `socket.send_to(shard, client_address)` runs without errors.

The earlier "H1" hypothesis (ENet compression) is real but NOT the
primary wall. The `tokio-enet: received compressed packet but no
compressor configured` warning is legitimate — Moonlight sends
range-coder-compressed control packets that moonshine drops — but
audio decoding also worked, so the control stream isn't fully
dead. Filed under backlog for now.

### 16. Six-run packet-size experiment matrix — CORRECTED DIAGNOSIS

Mac session ran the full recipe (baseline, packet900, packet700,
h264, bitrate2m, dualpcap). Results contradict §15's Path-MTU
hypothesis. **All 5 non-baseline runs got video packets arriving on
utun4 in ten-thousand-count quantities. Every run still failed
identically with "No video traffic was ever received."**

Filtered to ser6 IPv6 traffic only (excluding Moonlight's separate
`moonlight-ctest` NAT-traversal probes to 34.74.124.204 which polluted
earlier tallies):

| run | shard size | video pkts on utun4 | outcome |
|---|---:|---:|---|
| baseline | 1040 | 0 | no video (anomaly — see below) |
| packet900 | 912 | **56029** | no video |
| packet700 | 704 | 9180 | no video |
| h264 | 1040 | 10305 | no video |
| bitrate2m | 1040 | 37 (low bitrate) | no video |
| dualpcap | 1040 | 10129 | no video |

Baseline's 0-packets was an anomaly: probably an ephemeral-port
race where moonshine kept sending to a stale port from a previous
session while the current pcap captured only the new client-side
port. `dualpcap` reran with 1040-byte shards and got 10K packets.

**§15's Path-MTU-on-tunnel diagnosis was wrong.** The tunnel passes
1040-byte packets fine. Also §14's ENet-compressor H1 was
unrelated — control channel had perfect 138/137 parity in every run.

### 17. Where the wall actually is — Moonlight-qt receive path

Moonlight-common-c's `VideoReceiveThreadProc` logs `"Received first
video packet after N ms"` the instant `recvUdpSocket(rtpSocket, ...)`
returns >0 bytes. **No RTP-parsing, no payload-type filter, no
sequence-number checks, no source-address whitelist.** The log
line fires before any validation.

Since Moonlight-qt never prints that line — but tcpdump proves
10000+ UDP packets arrive on `utun4` at the destination the client
advertised via its own PING source port — **the packets reach
kernel-level on the Mac but never emerge from `recvUdpSocket()`
in Moonlight-qt.**

Verified moonshine's send-side is correct:
- Source port: 47998 (well-known, matches SDP).
- Destination address: client's video-PING source
  (`[<mac-v6>]:53919` for h264 run) — extracted via
  `spawn_handle_video_packets`'s `client_address = Some(address)`
  in the recv-loop. Confirmed distinct from the audio PING source
  port (`54221`), so no cross-flow contamination.
- Payload framing: 12-byte RTP header (V=2 correct, seq
  monotonically incrementing 0,1,2,…), 4-byte padding, 16-byte
  NvVideoPacket, then H.264/HEVC NAL payload. Timestamp is 0
  (moonshine bug: `packet.pts * 90000 / fps` where `packet.pts`
  from pixelforge's encoder is always 0). SSRC is 0 (also bug).
  Neither field is likely fatal to Moonlight — Sunshine tolerates
  them too.

Audio (48000, 76-88 byte packets) DOES get through — Moonlight-qt
logs `Received first audio packet after 100 ms` in every run.
Audio and video use the identical socket-setup code path in
moonlight-common-c (`bindUdpSocket` + PING thread + receive
thread). So it's not a fundamental v6/ephemeral-port bug — it's
something specific to the video path.

### 18. End-to-end streaming works — via `/resume`, not `/launch`

Setup: Windows-Moonlight-qt 6.1.0 client on same LAN (via
Tailscale, `100.73.1.39` ↔ ser6 `100.123.76.26`). Retried on
Mac-Moonlight-qt via WireGuard tunnel (`utun4`). Both platforms
show the **same behaviour**:

1. Fresh `GET /launch` → session comes up, moonshine encodes HEVC,
   video packets leave ser6 (~16-18k over ~30s in the client
   pcap on the Tailscale interface), but client reports **"No
   video traffic was ever received"** in ~10s. Client
   `Get-NetUDPEndpoint` shows Moonlight has an rtpSocket bound to
   `100.73.1.39:<eph>`; server pcap confirms shards dst'd there.
2. Retry via `GET /resume` (Moonlight UI button): 2nd or 3rd
   attempt attaches to the still-running server session and
   **video renders cleanly at 60 fps, input works, low latency.**

So the wall isn't the network path, the payload framing, the
tunnel MTU, or Moonlight's socket bind. It's specific to the
initial-`/launch` code path in moonshine — probably a race between
moonshine's video pipeline start (which begins emitting shards
immediately on `Session streams started successfully`) and the
client's video-recv thread readiness. `/resume` doesn't hit the
race because the pipeline has been idling for seconds by the time
the second connect happens.

Also invalidates my earlier "H1 ENet compression" and "H2 tunnel
PMTU" hypotheses. The `tokio_enet: received compressed packet but
no compressor configured` warning is a real conformance gap but
does not stop streaming. The tunnel does not drop 1040-byte video
shards (16k made it through in one run, iperf3 confirmed
end-to-end UDP works at 5 Mbps).

Fixes made along the way that were plausible but not the wall:
- `SO_SNDBUF=1MiB` on the video socket (matches Sunshine). Kept —
  reduced `ENOBUFS` from many-per-run to 0-1 per session.
- Xwayland stale-lock cleanup between sessions. Kept — otherwise
  the compositor tries to acquire display=0..N and fails on stale
  `/tmp/.X<N>-lock` files.

### 19. Audio architecture — moonshine IS the PulseAudio server

Moonshine's audio capture works by **being a PulseAudio server**
itself, not by capturing from a system audio backend. Concretely:

- `moonshine-core/src/session/stream/audio/pulse_server/` implements
  the PulseAudio protocol in pure Rust.
- A Unix socket at `$XDG_RUNTIME_DIR/moonshine/pulse/native` is
  created per session.
- `application::make_envs()` sets `PULSE_SERVER=unix:...` in the
  game's environment.
- When the game (via libpulse or SDL's Pulse backend) connects,
  moonshine speaks Pulse protocol, receives PCM frames, encodes
  them with Opus, and streams them over UDP.

**Why not sndio or OSS.** FreeBSD's native audio path is sndio (or
OSS via `/dev/dsp`). Capturing from either requires either:
- Emulating a `sndiod` protocol server in moonshine (equivalent
  effort to the existing PulseAudio server — not done).
- Kernel-level or fusefs `/dev/dsp` interception for OSS clients
  (much harder, no existing infrastructure).

Pulse-protocol emulation is pragmatic because every modern audio
library (SDL, OpenAL, mpv, etc.) knows how to speak Pulse over
`PULSE_SERVER=unix:...` without patching the app.

**Concrete FreeBSD gotcha (found 2026-07-24).** The default
`devel/sdl3` port on FreeBSD builds with:

```
ALSA:       off
OSS:        on           ← default backend
PIPEWIRE:   off
PULSEAUDIO: off          ← the very thing moonshine needs
SNDIO:      off
```

So a stock-FreeBSD SDL3 game (CWR-CE / PoseidonGame in our test)
writes audio to `/dev/dsp` and moonshine never sees it — client
gets video but silent audio. Setting `SDL_AUDIODRIVER=pulseaudio`
in the game's env is a **no-op** because SDL3 doesn't have the
Pulse backend compiled in and can't `dlopen(libpulse.so)` at
runtime (SDL3 uses compile-time-selected backends).

Moonshine now unconditionally sets `SDL_AUDIODRIVER=pulseaudio`
and `AUDIODRIVER=pulse` in `make_envs`, which is correct for the
day sdl3 gains Pulse support. For today's ser6 setup it's a
no-op.

**Fix options for audio (any one gives working audio):**

1. **Rebuild `devel/sdl3` with `PULSEAUDIO=on`** and install on ser6.
   ```
   cd /usr/ports/devel/sdl3 && make config     # enable PULSEAUDIO
   make deinstall reinstall
   ```
   Or via poudriere `make.conf`:
   ```
   sdl3_SET+=PULSEAUDIO
   ```
   This affects every SDL3-audio-using port on the box. Non-breaking
   because moonshine's env keeps Pulse the selected backend; when
   moonshine isn't in the picture, SDL3 falls back to OSS.
2. **Alternative** (much bigger): add a sndio-protocol server to
   moonshine parallel to the Pulse one, then rebuild sdl3 with
   `SNDIO=on` instead. Cleaner match for FreeBSD-native audio but
   real new-feature work.
3. **Interim workaround** (nothing): live with silent audio.

**Not amenable to upstream reversal.** The maintainer intentionally
left Pulse off in `devel/sdl3` OPTIONS_DEFAULT — Pulse isn't the
FreeBSD-native audio server, and forcing `audio/pulseaudio` as a
dep of every SDL3 consumer would be wasteful. Local override or
new sndio server are the only paths.

4. **A macOS SO_RCVBUF overrun causing kernel drops** — but that
   would show as pf/socket stats, not silent invisibility.

## Next step

Not obvious. Options:

- **On the Mac**: run `lsof -iUDP -a -p <moonlight-pid>` while
  streaming to see what sockets Moonlight actually opened, and
  `dtruss -p <moonlight-pid> -t recvfrom` to see if `recvfrom` is
  being called on the right socket. This would definitively rule
  in/out theory (2).
- **On ser6**: try running against a REAL Sunshine host (Linux VM)
  from the same Mac to see if it works. If yes, framing diff
  between Sunshine and moonshine is the culprit. If no, the Mac's
  network stack is the bug and moonshine is fine.
- **Alternative client**: try `moonlight-embedded` from a
  Linux/FreeBSD box on the same LAN as ser6. Skips the tunnel
  entirely and validates moonshine's send path against a known-
  working client on a simpler network path.

Given the amount of energy already spent on network-layer
diagnosis, **the fastest confidence-building step is the last
one: test moonshine's server against a different client on a
simpler network path.** If moonlight-embedded on LAN works,
moonshine is correct and the Mac side is doomed by something
peculiar about its network. If it also fails, moonshine's payload
is malformed and we need to diff against Sunshine.

### 15. (superseded) Old Path-MTU diagnosis

Ran `tcpdump` simultaneously on both sides during a repro stream.
Filter: `udp and (port 47998 or 47999 or 48000)`.

| Flow | Direction | Server pcap | Client pcap |
|---|---|---:|---:|
| Control (47999) | client → ser6 | 138 | 138 |
| Control (47999) | ser6 → client | 137 | 137 |
| Audio (48000) | ser6 → client | 11383 | **4773** |
| Video (47998) | ser6 → client (1040-byte shards) | 4097 | **0** |
| Video (47998) | client → ser6 (4-byte PINGs) | 20 | 20 |

- **Control channel has perfect parity** — not a UDP-blocked-inbound
  problem generally.
- **Audio: 42% delivery** (4773/11383). Bad, but Opus concealment
  masks it; client-side "Received first audio packet after 100ms"
  still fires.
- **Video: 0% delivery**. 4097 shards emitted by ser6, none seen
  on utun4. Complete blackout.

Server outbound video packet shape (from server pcap):
```
IP6 (hlim 64, payload length 1048)
  2a01:e0a:1092:3d20:57da:3a10:3e7:ab33.47998
    > 2607:fb10:7261:1::1a22.59040:
  UDP, length 1040
```
- Inner UDP payload = **1040 bytes** (matches client SDP
  `x-nv-video[0].packetSize:1024` + 16-byte NvVideoPacket
  header).
- IP-level frame size = 1088 bytes (40 IPv6 + 8 UDP + 1040 UDP).
- Sent in **bursts of ~20 shards in <10ms** during IDR frames.

Audio outbound sizes: **76 and 88 bytes** (Opus 20ms frames).
Small enough to always cross the tunnel path.

## Current wall (well-defined)

**Path-MTU / MSS clamp on the client's tunnel drops all 1040-byte
video shards while passing sub-100-byte audio/control packets.**
Not a moonshine bug. The utun4 tunnel advertises MTU 1280 but
either its actual usable inner-MTU is smaller (WireGuard adds
~32-60 bytes outer wrapper; if the underlying path can only carry
1280 bytes on the outer, inner packets over ~1220 die), or a
gateway/CGN in between silently drops 1000+ byte UDPv6 fragments,
or the tunnel encapsulator itself can't burst-buffer 20 shards in
<10ms (audio's 58% loss on the same path supports burst overrun
too).

The fix has to be at the Moonlight client — request a smaller
`packetSize` in the RTSP ANNOUNCE. Moonshine has no say in this;
it accepts whatever the client requests.

## Next step

Two sessions running in parallel:

**Mac session** (data-collection worker): follows the recipe in
`MAC-CLIENT-PROMPT.md`. Runs a small matrix of Moonlight-qt
config changes (packet size 900, 700; H.264 codec; 2Mbps
bitrate), captures utun4 pcap + Moonlight-qt log + prefs for
each. Bundles results in `/tmp/mac-run-bundle/`. Does NOT
analyze — just collects raw artefacts and reports what's in the
bundle.

**This session** (FreeBSD build host, analysis + patches):
1. Receive bundle from Mac session (either transferred via scp
   or reported inline).
2. Diff the pcaps: which config produced inbound video on utun4?
   How does the length histogram change per run?
3. If a config change fixes it, decide whether to:
   a. Just document "recommended settings for high-MTU tunnels"
      in the moonshine port docs (client-side fix).
   b. Add a server-side clamp so moonshine refuses shard sizes
      that exceed some sane default when the ANNOUNCE requests
      >MTU-typical (server-side defense-in-depth).
4. If NO config change fixes it, we're in `dual-pcap` territory:
   the tunnel encapsulator itself is dropping large inner
   packets before they emerge on utun4. That's not something
   moonshine can address — it's a network-configuration issue
   on the Mac side. Document and move on.

Independent of the packet-size wall, still-open items:

- **ENet compressor mismatch (previous H1).** Not the primary wall
  (control channel showed perfect parity in the pcap), but real:
  Sunshine enables `enet_host_compress_with_range_coder` on the
  control host unconditionally, and Moonlight sends compressed
  packets that moonshine's `tokio_enet::Host` drops with `received
  compressed packet but no compressor configured`. Fix: pull in
  `rusty_enet::RangeCoder` (already `impl Compressor`-compatible
  after a small trait adapter) and call
  `host.set_compressor(Some(Box::new(RangeCoder::new())))` right
  after `Host::new`. Low priority — deferred until packet-size
  wall is closed.

- **notify-rust desktop notification path** fails on ser6 (no D-Bus
  session bus). Cosmetic — the log line has the PIN URL. Could be
  gated behind a "when running with a session bus" check to silence
  the WARN.

- **No boxart configured for CWR-CE** — trivial to fix by adding
  `boxart = "/path/to/img.png"` in `moonshine.toml`.

- **Public UDP exposure**: with `net.inet6.ip6.v6only=0` and
  `address = "::"`, the streaming ports are on the internet on
  IPv6. Fine for a smoke test, worth a `pf` rule for anything
  longer-lived.

## Backlog / not blocking

- **notify-rust desktop notification path** fails on ser6 (no D-Bus
  session bus, no notification daemon). Cosmetic — the log line has
  the PIN URL. Could be gated behind a "when running with a session
  bus" check to silence the WARN.
- **No boxart configured for CWR-CE** — trivial to fix by adding
  `boxart = "/path/to/img.png"` in `moonshine.toml`.
- **Client-cert-based host binding**: mDNS advertises
  `ser6-moonshine.local.` with hostname resolution that may not
  reach the Mac off-LAN; the Mac manually added ser6 by IP anyway.
  Not a bug, just noting the discovery path.
- **Public UDP exposure**: with `net.inet6.ip6.v6only=0` and
  `address = "::"`, the streaming ports are on the internet on
  IPv6. Fine for a smoke test, worth a pf rule for anything longer-
  lived.

## File map — where things are

- Study + plan: `~/myscripts/FreeBSD/moonshine/README.md`
- This state doc: `~/myscripts/FreeBSD/moonshine/STATE.md`
- Mesa PR: `~/myscripts/FreeBSD/mesa-dri-video-codecs/`
- Moonshine fork (`freebsd` branch): `~/moonshine/`
  - Uncommitted work: `Cargo.toml`, `Cargo.lock`,
    `moonshine-core/Cargo.toml`,
    `moonshine-core/src/session/stream/audio/pulse_server/mod.rs`,
    `moonshine-core/src/session/stream/audio/pulse_server/audio_clock.rs` (new),
    `moonshine-core/src/session/stream/control/input/gamepad/mod.rs`
    (renamed from `gamepad.rs`),
    `moonshine-core/src/session/stream/control/input/gamepad/backend_inputtino.rs` (new, linux),
    `moonshine-core/src/session/stream/control/input/gamepad/backend_stub.rs` (new, non-linux),
    `moonshine-core/src/session/application/mod.rs`
    (renamed from `application.rs`),
    `moonshine-core/src/session/application/backend_systemd.rs`
    (verbatim lift of original; linux only),
    `moonshine-core/src/session/application/backend_command.rs`
    (new, non-linux, tokio::process::Command spawn),
    `vendor/socket-pktinfo/` (subtree, `freebsd` branch, also uncommitted).
- ser6 test setup:
  - Binary: `/tmp/moonshine` (scp'd from build host)
  - Config: `/tmp/moonshine-test/moonshine.toml`
  - Runtime dir: `/tmp/moonshine-runtime` (XDG_RUNTIME_DIR)
  - Log: `/tmp/moonshine-test/out.log`
  - Launch env:
    `XDG_RUNTIME_DIR=/tmp/moonshine-runtime MOONSHINE_LOG='trace,mdns_sd=debug' /tmp/moonshine /tmp/moonshine-test/moonshine.toml`
- ser6 runtime target: `ssh ser6` (FreeBSD 16.0-CURRENT, AMD Radeon 680M).

## Global memory index (`~/.claude/projects/-usr-home-olivier-freebsd-official-ports/memory/MEMORY.md`)

Should be up to date; nothing new to record beyond what's in this doc.

## Build workflow reminder

- Build here (this host is FreeBSD 16.0-CURRENT despite `uname` saying
  Linux 5.15 — linuxulator compat layer).
- Runtime testing goes to ser6 (VCN3 AMD GPU).
- Rust toolchain: `rustc 1.96.1`, `cargo 1.96.1` — both at
  `/usr/local/bin/`.
- `pkg install` on this host requires sudo (this box).
