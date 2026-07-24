# /launch → /resume retry race — troubleshooting log

Session-scoped bug in moonshine's initial-/launch code path. Ships as
"user needs 1-3 /resume clicks after every /launch failure before video
appears." Video via /resume works reliably; audio (via virtual_oss
loopback, see STATE.md §19) works too. This document captures every
data point and dead-end from 2026-07-23 through 2026-07-24 so the next
session can pick up without re-tracing.

## User-visible symptom

1. Client (Moonlight-qt on Mac via WireGuard tunnel; Moonlight-qt on
   Windows via Tailscale — both platforms show identical behaviour)
   hits Play → CWR-CE.
2. Moonshine spawns the app, RTSP handshake completes, `Session
   streams started successfully` logs.
3. **~10 seconds pass with no video** on the client. Moonlight-qt log:
   ```
   Received first audio packet after 0 ms
   IDR frame request sent
   ...
   Terminating connection due to lack of video traffic
   UDP port 47998 test successful   ← client-side probe, NOT proof of receipt
   UDP port 48000 test successful
   Connection terminated: -100
   No video received from host.
   ```
4. User clicks Resume. Sometimes /resume works on the first try;
   sometimes 2-3 retries are needed. Once video appears, streaming is
   stable at 60 fps.

## What we proved is NOT the bug

Each of these was chased separately and ruled out with paired
tcpdump captures and controlled experiments.

### Not path MTU / tunnel size
- 6-run experiment matrix from `MAC-CLIENT-PROMPT.md`
  (packet900/700/h264/bitrate2m/dualpcap) showed video packets DO
  arrive on utun4/tailscale0 in every non-baseline run, 9k-56k UDP
  packets per session at 704/912/1040 byte sizes.
- iperf3 UDP 5 Mbps at 1040-byte payloads over Tailscale: 12021/12021
  delivered, 0% loss, 0.667ms jitter.
- Reproduces on both Tailscale (Windows) and WireGuard (Mac), so not
  tunnel-encapsulator-specific.

### Not the ENet compression mismatch
- Sunshine enables `enet_host_compress_with_range_coder`; moonshine's
  tokio-enet doesn't. Warning fires (`received compressed packet but
  no compressor configured`) but the control channel has perfect
  138/137 packet parity in every capture. Audio worked without the
  compressor. Real conformance gap, not this bug.

### Not the SO_SNDBUF ENOBUFS drops
- Fixed at commit `f90df5a`. Reduced ENOBUFS from many-per-run to 0-1
  per session. Bug persists after fix.

### Not video codec (H.264 vs HEVC)
- Forcing H.264 client-side yielded 10305 packets on the wire.
  Client-side still reports "no video traffic." Same failure mode.

### Not Windows Firewall
- Disabled all profiles, no change.

### Not client-socket bind wrong interface
- `Get-NetUDPEndpoint` on Windows during a failing stream shows
  moonlight bound `100.73.1.39:<eph>` (correct Tailscale IP).
- Server-side pcap shows moonshine sending `100.123.76.26.47998 →
  100.73.1.39.<same-eph>`. Ports match.

### Not moonshine's RTP framing
- Raw packet dump: RTP V=2, sequence numbers monotonically increment
  from 0, timestamp starts at 0 (pixelforge uses `pts=display_order`
  so this is correct for frame 0 shards).
- Moonlight-common-c's `VideoReceiveThreadProc` logs `"Received first
  video packet after N ms"` on ANY UDP arrival with 1+ bytes on
  rtpSocket — before any RTP validation. So framing correctness is
  irrelevant if that log line doesn't fire.

## What we proved IS happening

### On /launch (fails)

Timing from the 01:46:08 session on 2026-07-24:

| T (s) | Event |
|---|---|
| 0.000 | `GET /launch` received |
| 0.024 | Compositor started 1280x720 @ 60Hz |
| 0.107 | CWR-CE launched, pid recorded |
| 0.615 | RTSP Options |
| 0.992 | RTSP Describe |
| 1.334 | RTSP Setup #1 (video) |
| 1.672 | RTSP Setup #2 (audio) |
| 2.018 | RTSP Setup #3 (control) |
| 2.355 | RTSP Announce (stream context received) |
| 2.696 | **RTSP Play** — this fires `start_notify` |
| 2.696 | Video pipeline unblocks, calls `create_encoder()` |
| 2.697 | OssCapture starts (audio capture) |
| 2.716 | Audio frame drops begin (encoder gated on RTSP PLAY too) |
| 2.866 | Client ENet control-channel connect (peer_id=0) |
| 3.040 | Vulkan device created |
| 3.046 | H.265 encoder created successfully |
| ...   | **No `Encoding frame` events between here and /resume at T+26.7s** |

Client hits its `FIRST_FRAME_TIMEOUT` (~10s) at T+~13s and disconnects.

### On /resume (usually works)

From the same session (26s after /launch):

| T (s) | Event |
|---|---|
| 26.700 | `GET /resume` |
| 28.932 | RTSP Announce (2.23s for handshake) |
| 29.276 | `Resuming active session: resetting video frame counter and treating PLAY as no-op` |
| 29.444 | New ENet peer connect |
| 29.611 | peer connected |
| **35.005** | **`Resetting video frame counter for resumed client and forcing IDR`** — 5.4s after ENet connect |
| 35.005 | `IDR frame channel lagged by 3 messages` — client sent 4 RequestIdrFrame during those 5.4s |
| 35.005 | First `Encoding frame ... type=Idr` — game finally rendering |
| 40.010 | `Frame latency summary: frames=278 fps=56 keyframes=1` |
| 45.011 | `frames=300 fps=60` — sustained streaming |

Key data: **first compositor→encoder frame at T+35s** (~26s after
CWR-CE spawn). That's the delay CWR-CE takes to produce its first
Wayland surface (splash screens + data loading).

## Convergent root cause

**On initial /launch, moonshine has no way to emit anything to the
client before the game produces its first Wayland surface.** CWR-CE
takes 25+ seconds; Moonlight's `FIRST_FRAME_TIMEOUT` is 10 seconds.

The compositor renders 60Hz internally but throttles the
frame_tx→pipeline channel to 1 frame/sec when nothing has changed
(`session/compositor/state.rs:645`):
```rust
if !self.screen_dirty && self.last_frame_sent_at.elapsed() < Duration::from_secs(1) {
    return;
}
```

So during the 25s startup, the pipeline could see ~25 frames — one
per second — but every single one is an empty "no windows" render.
Never traced whether those actually reach the encoder or get dropped
somewhere in the pipeline. **Zero `Encoding frame` traces confirms
they don't reach the encoder path** but doesn't localize where they
die.

## The workaround that just works

**Force /resume path to reset frame counter + force IDR** already
exists at `session/stream/video/pipeline/mod.rs:398-404` and is
exactly what makes /resume succeed. The initial /launch path has
no equivalent.

## 2026-07-24 01:57 update — `-nosplash` didn't fix it

Applied `-nosplash` to CWR-CE's launch args in
`/tmp/moonshine-test/moonshine.toml` and restarted moonshine.
Retested: **initial /launch still fails, still needed /resume.**
User confirmed CWR-CE is a 20-year-old game and starts "very very
fast" — so the earlier "waiting for slow game rendering" theory
was wrong.

**Concrete evidence between /launch (T=0) and first /resume (T≈22s):**

- Compositor: `Client DMA-BUF import successful` at T+0.03s, T+1.04s,
  T+3.10s. So the **game IS rendering** and committing wl_buffers.
- Client: **zero `Received video stream PING`** events on port 47998
  server-side. Client's PING thread should have fired every 500ms.
- Pipeline: **zero `Encoding frame`** events. `run_encoding_loop`
  entered but `frame_rx.recv_timeout()` never returned an Ok(frame).

**So the actual bug**: the video pipeline is running, the encoder
is created, the game is producing dmabufs, and the compositor is
importing them — but the compositor's 60Hz `render_and_export()`
call isn't reaching the pipeline via `frame_tx → frame_rx`.
`sync_channel(2)` is somewhere silent.

Also strange: **client never sent a PING** during the 22-second
failing window. Either the client's PING thread didn't start, or
its PINGs got dropped before reaching ser6's UDP :47998. Given
the tunnel is proven fine (iperf3), the client-side is more likely.
But moonlight-common-c starts the PING thread synchronously right
after `bindUdpSocket` — should always start.

## 2026-07-24 01:57 update — a resumed session showed 6 IDRs in 4s

On the eventual successful /resume, client asked for `RequestIdrFrame`
**6 times in ~4 seconds**. Each request emitted a fresh IDR (frame 0,
157, 178, 188, 205, 221). Two possible causes:

1. **Client rejects each IDR and re-requests.** IDR-with-refs would
   trigger this: some IDRs logged `l0_refs=[(0, 312)]` or `[(1, 40)]`
   — non-empty ref lists on a true "instantaneous decoder refresh"
   frame violates HEVC spec.
2. **Client is testing** — sends redundant requests during initial
   sync until it locks on.

The `l0_refs` thing is a strong candidate for its own bug. Look at
`pixelforge/src/encoder/h265/api.rs` line 85+ — `sequence_start()`
is supposed to reset the DPB on IDR, but the log shows non-empty
`l0_refs` after that reset was called.

## Diagnostic experiment for next session

**Add three `tracing::info!` lines** to localize where the frame
channel goes silent. See CONTINUE.md for the exact code positions
and log strings. Should take <1 hour to rebuild + deploy + retest
+ localize.

## Fix directions (untested)

Ranked by tractability:

### A. Emit a splash / preparation frame on RTSP PLAY (simplest)

At `Session streams started successfully`, force the encoder to
produce an IDR of an internally-generated frame (solid color, or
"streaming preparing..." graphic). Client's `Received first video
packet` fires immediately, timeout is reset, and the pipeline
switches to real compositor frames once they arrive. Sunshine
does something like this.

Implementation: after `create_encoder()` in the pipeline loop,
before entering the `frame_rx.recv_timeout()` cycle, encode the
encoder's `input_image()` (which is already allocated but empty)
as an IDR and send.

### B. Emit compositor frames unconditionally at 60Hz (bigger)

Remove the "skip if not screen_dirty" throttle at
`state.rs:645`. Compositor produces 60 frames/sec regardless of
window state. Empty renders (black frame) satisfy the client's
timeout. Wasteful on GPU/network but effective. Actually the
current 1-frame/sec IS delivering empty frames but they don't
reach the encoder for a reason we haven't pinned.

### C. Cut CWR-CE's startup time (partial, user-side)

The `-nosplash` argument on CWR-CE skips 2 splash screens. **Just
applied to `/tmp/moonshine-test/moonshine.toml` on ser6.** Should
reduce startup from 25s to something shorter — but game data
loading still takes time, and 10s is a tight budget. Worth testing
whether this alone brings the initial /launch success rate to
~100%. If yes, A/B are optional polish.

## Data locations

- ser6 live log: `/tmp/moonshine-test/out.log` (currently 297 MB from
  earlier trace-level captures; last session ~2 MB after switching
  to `MOONSHINE_LOG=debug`).
- ser6 pcaps: `/tmp/moonshine-*.pcap` (multiple, from various
  experiments).
- Mac bundle: `/tmp/mac-run-bundle/` (six Moonlight-qt logs, six
  utun4 pcaps, six prefs snapshots).
- Windows Moonlight log: `/tmp/logdrop/*-moonlight.log` on ser6.
- Windows Moonlight pcap (Tailscale iface): `/tmp/logdrop/*.pcapng`
  on ser6.

## Log filter recipe

For a clean investigation session, use this env:
```
MOONSHINE_LOG="debug,mdns_sd=info,mio::poll=info,calloop=info,rustls=info,hyper=info,h2=info,smithay::backend::egl=info,smithay::backend::renderer=info,smithay::xwayland::xwm=info,smithay::wayland=info,tokio_enet=info"
```
Keeps `Encoding frame`, RTSP events, and pipeline transitions
visible without the compositor-render trace flood.
