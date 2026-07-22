# Porting Moonshine to FreeBSD — feasibility study

Upstream: <https://github.com/hgaiser/moonshine>
Local clone: `~/moonshine`
Study date: 2026-07-20
Version studied: 0.12.0

## What Moonshine is

A Rust-based host for the NVIDIA GameStream / Moonlight protocol. Differentiator
vs. Sunshine: each streaming session runs in its **own isolated Wayland
compositor** (smithay-based), so the host desktop stays usable and no monitor
or HDMI dummy plug is required.

## Code size

~26k lines of Rust across 4 crates:

- `moonshine` — main binary, 125 lines
- `moonshine-core` — the meat, ~9.8k lines under `src/`
- `moonshine-tools` — bench utility
- `moonshine-wsi` — Vulkan WSI layer, ~2.5k lines (`cdylib`)

## Overall complexity: very high — effectively a fork

Four subsystems each require design-level replacement, not mechanical porting.
Two of them (headless smithay compositor, Vulkan-Video HW encode) may not be
achievable on FreeBSD at all today.

## Hard blockers

### 1. systemd + D-Bus for application isolation

- `moonshine-core/src/session/application.rs` (~730 lines) launches every game
  as a transient `systemd-run --user` unit via
  `org.freedesktop.systemd1.Manager` through **zbus**.
- Constants: `SYSTEMD_BUS`, `SYSTEMD_PATH`, `SYSTEMD_MANAGER`, `UNIT_INTERFACE`.
- Handles unit start, stop, signal streams (`JobRemoved`, `NoSuchUnit`), and
  builds properly-typed `a(sasb)` arrays for `ExecStart`/`ExecStartPre`/
  `ExecStopPost`.
- This is *how isolation is enforced*. FreeBSD has no systemd.
- Replacement: rc.d? plain fork+setsid? jails per session? Big design decision.

### 2. smithay compositor (headless Wayland)

- Pulled from moonshine-specific fork:
  `smithay = { git = "https://github.com/hgaiser/smithay", branch = "master-moonshine" }`.
- Features enabled: `backend_drm`, `backend_gbm`, `backend_egl`, `renderer_gl`,
  `wayland_frontend`, `desktop`, `xwayland`, `x11rb_event_source`.
- smithay assumes Linux: **KMS/DRM, GBM, libseat, udev, evdev, libinput**.
- FreeBSD's `drm-kmo` exposes `/dev/dri/*` but the whole logind/udev discovery
  layer is missing.
- Replacement paths: (a) weeks of upstream smithay work to add FreeBSD support,
  or (b) replace the compositor entirely (e.g. the `magic-mirror` approach —
  simpler Vulkan-only compositor).

### 3. inputtino + /dev/uinput + /dev/uhid

- `inputtino = { git = "https://github.com/games-on-whales/inputtino" }` — a
  C++/Rust wrapper around Linux **uinput** and **uhid** for injecting gamepad,
  keyboard, mouse, plus motion/touchpad/haptics.
- `moonshine-core/src/session/stream/control/input/gamepad.rs` uses
  `inputtino::Joypad` directly.
- `keyboard.rs` maps Windows VK codes to **Linux evdev keycodes**.
- FreeBSD has neither `/dev/uinput` nor `/dev/uhid` and no evdev-compatible
  injection interface.
- Replacement: fork inputtino for FreeBSD (nobody has), or write a new backend
  targeting `/dev/atkbd`, `/dev/sysmouse`, or a custom kmod.

### 4. pulseaudio wire protocol + timerfd audio clock

- `moonshine-core/src/session/stream/audio/pulse_server/` reimplements the
  **pulseaudio wire protocol** directly (via `pulseaudio` crate, not `libpulse`).
- Uses `mio_timerfd::TimerFd` on `ClockId::Monotonic` for the audio pacing
  clock. **`timerfd_create` is Linux-only.**
- Replacement: swap `mio-timerfd` for a `kqueue` `EVFILT_TIMER` implementation.
  Protocol layer itself is portable.

### 5. /proc/\<pid\>/{stat,cmdline} walking

- `session/compositor/handlers.rs` walks **procfs** to correlate Wayland
  windows with Steam AppIDs (mimicking gamescope's `get_appid_from_pid`).
- Reads `/proc/<pid>/stat` (field 22 for starttime, field 4 for PPID) and
  `/proc/<pid>/cmdline` looking for `SteamLaunch AppId=N`.
- FreeBSD's `linprocfs` is optional and doesn't emit identical layouts.
- Replacement: `kvm_getprocs()` or `sysctl kern.proc.*`.

### 6. DMA-BUF zero-copy pipeline

- `session/stream/video/pipeline/dmabuf.rs` + smithay's `wp_linux_dmabuf_v1`
  handoff to the Vulkan Video encoder.
- FreeBSD drm-kmo can export dmabuf FDs on some drivers, but the full
  `GBM → dmabuf → Vulkan Video encode` chain is untested territory and
  depends on driver-specific FreeBSD support.

### 7. Vulkan Video encode hardware paths

- Needs `graphics/vulkan-loader` + `graphics/vulkan-headers` + a driver that
  exposes `VK_KHR_video_encode_h264/h265/av1`.
- On FreeBSD:
  - **AMD (RDNA2+)** — via drm-kmo + Mesa: probably works in theory.
  - **NVIDIA RTX** — the FreeBSD NVIDIA driver historically lags on
    Vulkan Video.
  - **Intel Arc** — unsupported on FreeBSD.
- This alone could make the port pointless for the RTX/Arc audience.

## Medium (mechanical) issues

- `dist/moonshine@.service` — systemd template unit. Rewrite as `rc.d` script.
- `dist/60-moonshine.rules` — udev rules for `/dev/uinput`, `/dev/uhid`,
  hidraw, input groups. Rewrite as `devd.conf` + devfs rules (once uinput/uhid
  replaced).
- `dist/start-moonshine.sh` — assumes `XDG_RUNTIME_DIR`,
  `DBUS_SESSION_BUS_ADDRESS`, `loginctl enable-linger`. Rewrite for FreeBSD
  service startup.
- `zbus` client for `org.freedesktop.Notifications` (via `notify-rust`) —
  works if user runs a session bus; make it optional.
- `steamlocate`, `.desktop` scanner — Linux path defaults, but portable code.
- `dist/moonshine-modules.conf` — loads `uinput` and `uhid` kmods. Drop
  entirely.

## Small / portable

- `moonshine-wsi` (Vulkan+Wayland shim, ~2.5k lines) — Wayland runs on FreeBSD,
  portable modulo which compositor is running.
- Crypto stack: `aes-gcm`, `rustls`, `aws-lc-rs`, `rcgen`, `sha2`, `rsa`,
  `x509-parser`, `pkcs8` — all portable.
- Networking: `tokio`, `hyper`, `hyper-util`, `rtsp-types`, `sdp-types`,
  `mdns-sd`, `network-interface`, `socket2`, `tokio-enet`, `tokio-rustls` — all
  portable.
- Config/utility: `toml`, `serde`, `clap`, `tracing`, `walkdir`, `shellexpand`,
  `dirs`, `tempfile` — portable.

## Third-party fork dependencies (already need custom sources)

- `smithay` — `hgaiser/smithay` branch `master-moonshine`
- `pixelforge` — `hgaiser/pixelforge` rev `199bce28…`
- `ash` — pinned to a specific git rev
- `inputtino` — `games-on-whales/inputtino` git

Any FreeBSD fork would layer on top of these, or replace them.

## Realistic paths forward

### Option A — full FreeBSD fork ("moonshine-freebsd")

Weeks of focused work minimum. Rough phases:

1. **Compositor** — replace smithay with a simpler Vulkan-only compositor
   inspired by `magic-mirror`. This is the single biggest chunk.
2. **Input** — write a FreeBSD input backend (replace inputtino). Possibly
   requires a small kmod for gamepad/keyboard/mouse injection.
3. **App isolation** — drop systemd; use rc.d + fork or per-session jails.
4. **Audio clock** — port `mio-timerfd` usage to kqueue `EVFILT_TIMER`.
5. **procfs walking** — rewrite via sysctl.
6. **Driver/Vulkan-Video validation** — go/no-go check on the GPU + FreeBSD
   driver combo the user actually has.

Real risk of getting stuck at (6) before a frame ever streams.

### Option B — don't fork; use Sunshine

- `net-im/sunshine`-equivalent (upstream has FreeBSD PRs) covers the same
  Moonlight protocol.
- Loses the "isolated per-session compositor" differentiator — the exact part
  that doesn't port.
- Much cheaper if the isolation feature isn't a hard requirement.

## Recommended first probe (go/no-go for Option A)

Before committing effort to the compositor rewrite, verify on the target
FreeBSD machine (15.x + current drm-kmo):

- Which GPU is present, which driver, which Vulkan version.
- Whether `vulkaninfo` reports `VK_KHR_video_encode_h264` /
  `_h265` / `_av1`.
- Whether GBM + dmabuf FD export works with that driver.

If Vulkan Video encode is not exposed by the driver, Option A is dead on
arrival for that host — regardless of how much compositor work gets done.

## Probe result — ser6 (2026-07-20)

Host: FreeBSD 16.0-CURRENT, Vulkan instance 1.4.356.

GPU0: **AMD Radeon 680M (RADV REMBRANDT)** — VCN3 hardware, iGPU
- driver: `DRIVER_ID_MESA_RADV`, Mesa 26.1.3
- apiVersion: 1.4.348

Encode infrastructure present:
- `VK_KHR_video_queue` rev 8
- `VK_KHR_video_encode_queue` rev 12
- `VK_KHR_video_encode_intra_refresh` rev 1
- `VK_KHR_video_encode_quantization_map` rev 2
- `VK_KHR_video_maintenance1` / `_maintenance2`
- `VK_VALVE_video_encode_rgb_conversion` rev 1
- queue family with `QUEUE_VIDEO_ENCODE_BIT_KHR` exposed

**Codec-specific encode extensions: NONE.** Missing all of:
- `VK_KHR_video_encode_h264`
- `VK_KHR_video_encode_h265`
- `VK_KHR_video_encode_av1`

Decode side is partial too: `VK_KHR_video_decode_av1` and `_vp9` are present,
but H.264/H.265 decode extensions are also absent.

### Implication

Moonshine's video pipeline requires a codec-specific encode extension. The
generic `VK_KHR_video_encode_queue` alone is not usable — every codec-agnostic
path in Moonshine/Sunshine-style hosts is a thin wrapper over an
`H264/H265/AV1PictureInfoKHR`. On ser6 as configured today, **there is no HW
encode path for Moonshine**.

### Linux support status for this hardware (confirmed)

Cross-checked online 2026-07-20:

- **Radeon 680M is VCN 3.0**. HW-supported codecs on VCN3:
  - H.264 encode + decode
  - H.265 (HEVC) encode + decode
  - VP9 decode
  - AV1 **decode only** — VCN3 has no AV1 encoder block (that arrived with
    VCN4 on Phoenix / RDNA3)
- **Linux RADV shipped H.264/H.265 Vulkan Video encode in Mesa 24.1** (May
  2024). Since then Mesa 26.0/26.1 landed large refinements: DPB sizes,
  reference management, non-aligned resolutions, intra-only without DPB,
  quantization maps, screen-content tools.
- **Build gate**: Mesa must be configured with
  `-Dvideo-codecs=h264enc,h265enc` (comma-list, on top of the decode codecs).
  Without this, RADV compiles but does not expose the encode extensions.
- **Runtime gate**: older Mesa also required `RADV_PERFTEST=video_encode`.
  Removed in newer Mesa once the feature stabilized.

Sources:
- [Phoronix — Open-Source Radeon Driver Enables Support For Vulkan Video H.264/H.265 Encode](https://www.phoronix.com/news/RADV-Vulkan-VIdeo-H265-H264)
- [VideoCardz — Open-source Radeon Vulkan driver enables H.264 and H.265 video encoding](https://videocardz.com/newz/open-source-radeon-vulkan-driver-enables-h-264-and-h-265-video-encoding)
- [Igor's Lab — RADV brings hardware-accelerated H.264/H.265 encoding for AMD GPUs](https://www.igorslab.de/en/attention-linux-users-radv-brings-hardware-accelerated-h-264h-265-encoding-for-amd-gpus/)
- [Mesa 26.0 release notes summary](https://en.linuxadictos.com/Mesa-26.0-strengthens-Vulkan-support-and-adds-dozens-of-key-extensions-to-radv--anv--nvk--panvk--Venus--and-other-drivers..html)
- [Mesa 26.1 unified decode](https://www.techedubyte.com/amd-video-decode-unified-mesa-26-1-radeonsi-radv/)
- [Mesa RADV docs](https://docs.mesa3d.org/drivers/radv.html)

### Diagnosis for FreeBSD (root-caused)

Mesa upstream `meson.options` (26.1.3):

```
option(
  'video-codecs',
  type : 'array',
  value : ['all_free'],
  choices: ['all', 'all_free', 'vc1dec', 'h264dec', 'h264enc', 'h265dec',
            'h265enc', 'av1dec', 'av1enc', 'vp9dec', 'mpeg12dec', 'jpegdec'],
  ...
```

Default is **`all_free`** — non-patent-encumbered codecs only. H.264, H.265,
and AV1 encoders are all patent-encumbered => excluded by default. That's
why `vulkaninfo` on ser6 shows AV1/VP9 decode but no `VK_KHR_video_encode_h*`.

FreeBSD Mesa port layout (26.1.5 at time of study):

- **`graphics/mesa-libs`** (line 63 of `Makefile`):
  `MESON_ARGS+= -Dvideo-codecs="all"` — override present. Builds the gallium
  path (radeonsi VA-API) with **all** codecs enabled, including encoders.
- **`graphics/mesa-dri`** (`Makefile` + `Makefile.common`): sets
  `-Dvulkan-drivers=…radv…` but has **no `-Dvideo-codecs=` override**. Falls
  back to `all_free` => RADV Vulkan Video encode extensions stripped.
- **`graphics/mesa-devel`** (line 38): `-Dvideo-codecs=all` — override
  present.

**Confirmed bug in `graphics/mesa-dri`**: the meson override that `mesa-libs`
gets is not mirrored in `mesa-dri`, so Vulkan Video *decode* codecs like
h264/h265/av1dec are also silently missing from RADV (only `all_free` ones —
av1dec is free, vp9dec is free, but h264dec/h265dec are patent-encumbered and
gated).

### Fix

One-line change in `graphics/mesa-dri/Makefile.common` (shared with mesa-libs
via include but currently only mesa-libs sets it locally — the cleanest
place is Makefile.common or the mesa-dri Makefile itself):

```
MESON_ARGS+= -Dvideo-codecs=all
```

Rebuild in poudriere, install on ser6, re-run `vulkaninfo`. Expected new
extensions on GPU0 (AMD 680M, VCN3):

- `VK_KHR_video_encode_h264` (VCN3 HW-supported)
- `VK_KHR_video_encode_h265` (VCN3 HW-supported)
- `VK_KHR_video_decode_h264` (VCN3 HW-supported)
- `VK_KHR_video_decode_h265` (VCN3 HW-supported)

**AV1 encode remains unavailable** — VCN3 has no AV1 encoder block, requires
VCN4+ (Phoenix/RDNA3). Not a driver issue, HW limitation. Fine for
Moonshine: H.264/H.265 covers the whole Moonlight ecosystem; AV1 is flagged
experimental in the upstream README.

## Prerequisite work — status

### 1. Vulkan Video codecs on FreeBSD/RADV — DONE (2026-07-21)

- Root-caused: `graphics/mesa-dri` did not override `-Dvideo-codecs=`,
  falling back to upstream's `all_free` default (patent-free codecs only).
  Also missing `LIB_DEPENDS+= libdisplay-info.so` (stage-qa gap surfaced
  by the extra codecs enabling ANV's HDR/EDID paths).
- Patch: `~/myscripts/FreeBSD/mesa-dri-video-codecs/mesa-dri-video-codecs.patch`.
- poudriere-built, installed on ser6, verified: `vulkaninfo` now exposes
  `VK_KHR_video_{encode,decode}_h264` and `_h265` on the 680M.
- Bugzilla PR submitted upstream against `x11@FreeBSD.org` maintainership.
- Duplicate check: no other port ships or overrides Vulkan Video codecs
  (only `x11/nvidia-driver*` provides an independent Vulkan ICD, and
  `linux-rl9-vulkan` is just the loader for Linux-compat binaries).

Encode path unblocked on VCN3+ AMD hardware. Next: the actual porting work.

## Moonshine porting plan — Option A ("moonshine-freebsd" fork)

### Fork setup — DONE

- Fork: `git@github.com:ocochard/moonshine.git`.
- Local clone: `~/moonshine`, remotes rewired:
  - `origin` = ocochard fork (push target)
  - `upstream` = hgaiser/moonshine (for future rebases)
- Working branch: `freebsd` off upstream v0.12.0 (commit 61530ff).

### Build workflow

- **All builds happen on this workstation** (this host, x86_64, no GPU).
- Use a **poudriere jail** or `bhyve` FreeBSD guest here to compile —
  gives a clean FreeBSD userland without ser6 dependency.
- `scp` the compiled `moonshine` binary + any `.so` (moonshine-wsi
  Vulkan layer) to ser6 for runtime testing.
- ser6 (AMD 680M / VCN3) is the runtime target; this box is the build
  target only. Compile-clean here is necessary but not sufficient —
  runtime validation always requires ser6.

### Strip-linux-bits, crate by crate

Order = easiest → hardest, each independently verifiable with `cargo build`.
Each slice gets its own commit on the `freebsd` branch.

1. **moonshine-tools** — bench binary. Thin, likely portable.
   Sanity check for the toolchain.
2. **moonshine-wsi** (~2.5k lines) — Vulkan+Wayland shim. Wayland runs
   on FreeBSD; expect near-portable modulo `ash` git-pin quirks.
3. **moonshine-core**, in slices:
   - a. **crypto/network/config** — `aes-gcm`, `rustls`, `hyper`,
     `tokio-enet`, `mdns-sd`, `rtsp-types`, `sdp-types`, `toml`, `serde`.
     All portable — expect clean.
   - b. **audio clock** — swap `mio-timerfd` for a `kqueue` `EVFILT_TIMER`
     implementation. Pulseaudio wire protocol layer itself is portable.
   - c. **procfs walking** (`session/compositor/handlers.rs`) — swap
     `/proc/<pid>/{stat,cmdline}` for `sysctl kern.proc.*` or
     `kvm_getprocs()`. Gamescope-style AppID detection.
   - d. **app scanner + notifications** — mostly portable. Make
     `notify-rust`/D-Bus dependency graceful when session bus absent.
     `steamlocate`, `.desktop` scanner paths already portable code.
   - e. **input backend** (`session/stream/control/input/`) — replace
     `inputtino` (Linux uinput/uhid) with a FreeBSD input backend.
     Options: `/dev/atkbd` + `/dev/sysmouse` (limited), or write a
     minimal kmod (`inputtino-bsd`). Also remap `keyboard.rs` Linux
     evdev codes.
   - f. **session/application** (~730 lines) — replace systemd D-Bus
     transient-unit launch with either plain fork+setsid, per-session
     jails, or rc.d/service integration.
   - g. **compositor** — replace smithay (KMS/DRM/GBM/udev/logind
     assumptions). Two options:
     - Fork `hgaiser/smithay` and add FreeBSD support (weeks of work).
     - Replace with `magic-mirror`-style Vulkan-only compositor (cleaner
       but requires reworking the render pipeline).
4. **moonshine** main binary — small glue. Drop
   `sd-notify`/`XDG_RUNTIME_DIR` Linux assumptions.

### Milestone gates

- **M1 — Compiles**: `cargo build --release` on the freebsd branch
  finishes on this box in a FreeBSD jail. No functionality claim yet.
- **M2 — Runs & pairs**: `moonshine --help` runs on ser6 without
  panics; the pairing HTTP endpoint responds.
- **M3 — Compositor comes up**: an isolated session launches and holds
  a Wayland socket. Nothing rendered yet.
- **M4 — First frame encoded**: Vulkan encoder produces at least one
  H.264 packet (validates the whole `dmabuf → Vulkan Video` path on
  the fixed Mesa/RADV stack).
- **M5 — Moonlight client connects**: RTSP handshake completes, video
  stream reaches Moonlight. Audio can lag.
- **M6 — Input works**: mouse + keyboard injection round-trip; gamepad
  optional depending on how far the input backend gets.

Anything past M4 is real deliverable territory. M1–M3 are just plumbing.

### Runtime kill-switches to plan for

Even at M4+, expect these to bite:
- DMA-BUF handoff on FreeBSD drm-kmo — export works on some drivers,
  the whole `GBM → dmabuf → Vulkan Video encode` chain is untested.
- FreeBSD Wayland stack (`graphics/wayland`, `-protocols`) parity with
  what smithay expects (or its replacement expects).
- `libseat` / logind equivalents — smithay's session backend expects
  these; even a Vulkan-only compositor may want a devnode arbiter.

## Files inspected

- `Cargo.toml`, `Cargo.lock` (workspace + all four crates)
- `README.md`, `CHANGELOG.md`
- `src/main.rs`
- `moonshine-core/src/{lib,config,crypto,discovery,rtsp,state,tls,clients}.rs`
- `moonshine-core/src/app_scanner/{mod,steam,desktop}.rs`
- `moonshine-core/src/session/{application,manager,mod}.rs`
- `moonshine-core/src/session/compositor/*.rs`
- `moonshine-core/src/session/stream/{mod,control,audio,video}/`
- `moonshine-core/src/webserver/{mod,pairing}.rs`
- `moonshine-wsi/src/*.rs`
- `dist/{moonshine@.service,60-moonshine.rules,start-moonshine.sh,moonshine-modules.conf,VkLayer_moonshine_wsi.json}`
