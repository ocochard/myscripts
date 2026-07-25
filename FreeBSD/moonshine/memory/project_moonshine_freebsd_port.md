---
name: moonshine-freebsd-port
description: "FreeBSD port of hgaiser/moonshine (Sunshine-alternative Moonlight streaming host). End-to-end streaming verified on ser6 (AMD Radeon 680M) — HEVC via Vulkan Video, dmabuf zero-copy, Opus audio, keyboard/mouse input. /launch black-screen race root-caused to warm_up() FEC-matrix build and FIXED off-thread. Video+audio+input work on LAN AND over WireGuard/Tailscale tunnel. No known streaming blocker remains."
metadata: 
  node_type: memory
  type: project
  originSessionId: f3e4c030-b385-40b6-994b-1c49dba1ffa4
  modified: 2026-07-22T15:48:39.222Z
---

Working tree: `~/moonshine` on branch `freebsd`, remotes:
- `origin` = `git@github.com:ocochard/moonshine.git`
- `upstream` = `https://github.com/hgaiser/moonshine.git`

Live state doc: `~/myscripts/FreeBSD/moonshine/STATE.md` — read that
first (500+ lines). Companion: `~/myscripts/FreeBSD/moonshine/README.md`
(feasibility study), `../mesa-dri-video-codecs/` (prerequisite mesa
patch — Bugzilla submitted). Mac client handoff:
`~/myscripts/FreeBSD/moonshine/MAC-CLIENT-PROMPT.md`.

Cfg-gated backends (all pattern-matched via mio-timerfd's original
Linux/non-Linux split):
- `moonshine-core/src/session/stream/audio/pulse_server/audio_clock.rs`
  — linux uses `mio_timerfd::TimerFd`, other Unix uses pipe+thread.
  Committed as `7bf1be1`.
- `moonshine-core/src/session/stream/control/input/gamepad/` — linux
  backend_inputtino.rs (original), non-linux backend_stub.rs (no-op
  with warn-once AtomicBool latch). Local MotionType enum replaces
  inputtino::JoypadMotionType in the cross-platform GamepadMotion.
  Committed as `1eb3369`.
- `moonshine-core/src/session/application/` — linux backend_systemd.rs
  (verbatim lift of the original zbus + systemd-run --user unit
  path), non-linux backend_command.rs (tokio::process::Command
  spawn, kill_on_drop, pre_command fail-fast, post_command on Drop
  from helper-thread mini-runtime). Committed as `c3e753e`.
- `vendor/socket-pktinfo/` — subtree fork of pixsper/socket-pktinfo
  with BSD IP_RECVDSTADDR+IP_RECVIF cmsg handling to replace
  Linux-only IP_PKTINFO. Wired via `[patch.crates-io]`. Committed
  as `47332dd`.

**Why:** every runtime path in moonshine assumes systemd/D-Bus/uinput.
The four cfg-gates above are the minimum needed to compile and run
on FreeBSD without patching upstream systemd assumptions into
Linux-only fallbacks.

**How to apply:** when working on this port, always check `STATE.md`
for the current wall before starting. When adding new backends,
follow the linux/backend_X + non-linux/backend_stub pattern in these
four sites — do NOT introduce a third variant (BSD-specific, etc.);
non-linux fallbacks stay portable.

Build recipe: `RUSTFLAGS="-C link-arg=-L/usr/local/lib -C link-arg=-Wl,-rpath,/usr/local/lib" cargo build`
— see [[rustflags-dash-L-bundles-wrong-static-a]] for the trap that
bare `-L` triggers on FreeBSD.

Runtime deps on host: `x11-servers/xwayland`, `graphics/mesa-libs`,
`x11/libxkbcommon`. Also needs `net.inet6.ip6.v6only=0` if
`address = "::"` — see [[freebsd-sysctl-v6only-for-rust-dualstack]].

Current state: the `/launch` black-screen race is FIXED. Root cause was
`Packetizer::warm_up()` building 213 ReedSolomon FEC matrices
synchronously on the encoder thread (~37s debug / 0.77s release) before
the first encode; moved off-thread (`warm_up_async` + `merge_warm_up`,
commit `f4fa804`) plus a `pool_busy` slot-scan fix (commit `a804841`).
Verified on ser6: frame 0 fires ~11ms after peer connect. Video +
audio work end-to-end BOTH on LAN and over the WireGuard/Tailscale
tunnel (Mac + Windows) with the fixed binary. Keyboard/mouse input
verified end-to-end too. Two earlier "walls" were both WRONG: the
"tunnel MTU drops 1040-byte shards" theory (disproven by a six-run
capture matrix) and the "client-side Moonlight-qt recvUdpSocket" theory
(§17) — the latter was just the warm_up race misdiagnosed, since the
debug build blocked the encoder ~37s past the client's timeout. No
known streaming blocker remains. See STATE.md §16/§17/§20 and
[[moonshine-udp-pmtu-diagnosis-pattern]].

Related: [[rustflags-dash-L-bundles-wrong-static-a]],
[[freebsd-sysctl-v6only-for-rust-dualstack]],
[[moonshine-udp-pmtu-diagnosis-pattern]],
[[enet-range-coder-required-for-sunshine-protocol]].
