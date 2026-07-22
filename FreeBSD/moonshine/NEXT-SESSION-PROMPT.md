# Prompt for the next session

Copy the block below verbatim into the fresh session as the first user
message.

---

I'm continuing a FreeBSD port of `hgaiser/moonshine` (a Sunshine-alternative
Moonlight host). Full context is in three docs — please read them first:

1. `~/myscripts/FreeBSD/moonshine/README.md` — feasibility study + porting
   plan (crate-by-crate strip strategy, milestones M1–M6).
2. `~/myscripts/FreeBSD/moonshine/STATE.md` — current work state and
   the exact wall we hit.
3. `~/myscripts/FreeBSD/mesa-dri-video-codecs/README.md` — prerequisite
   Mesa fix (already shipped, Bugzilla PR submitted).

Short version:
- Prerequisite Mesa/RADV fix for Vulkan Video encode: **DONE**, deployed to
  ser6, upstream PR pending.
- Fork setup: `~/moonshine` on branch `freebsd`, remotes `origin =
  ocochard/moonshine`, `upstream = hgaiser/moonshine`. All work
  uncommitted.
- Audio clock (mio-timerfd) refactor: **DONE** — new `AudioClock`
  module cfg-gated Linux(timerfd) / other-Unix(pipe+thread).
- `socket-pktinfo` FreeBSD PKTINFO patch (IP_RECVDSTADDR + IP_RECVIF):
  **DONE** in `~/moonshine/vendor/socket-pktinfo/` on branch `freebsd`.
  Wired via `[patch.crates-io]`.
- `cargo check -p moonshine-core` now walks through **smithay,
  pixelforge, pulseaudio, wayland-*, drm, gbm, mdns-sd, zbus_macros,
  rcgen** cleanly on native FreeBSD.
- **Current wall**: `inputtino-sys` C++ build fails — FreeBSD
  `devel/libevdev` is installed but its `libevdev.h` still
  `#include <linux/input.h>`, and `linux/input.h` / `linux/uhid.h` UAPI
  headers are not available on FreeBSD. This is the input-backend slice
  and needs feature-gating out.

**Next task**: feature-gate `inputtino` out on FreeBSD, same pattern as
we did for `mio-timerfd`. Concretely:

1. In `moonshine-core/Cargo.toml`, move the `inputtino = { git = … }`
   line into `[target.'cfg(target_os = "linux")'.dependencies]`.
2. Add compile stubs so `moonshine-core/src/session/stream/control/input/`
   compiles on non-Linux. Preferred pattern: introduce a
   `trait InputBackend` with the Linux (inputtino-backed) impl gated,
   and a no-op FreeBSD impl that logs a warning per call and returns
   `Ok(())`. Consumers of the input crate shouldn't need to know which
   backend is active.
3. Re-run `cargo check -p moonshine-core` from `~/moonshine` and report
   the next wall.

If unsure between a full trait abstraction and a simpler
`#[cfg(target_os = "linux")] pub mod input;` at the module level with a
stub `mod input { ... }` on other platforms, pick the simpler path first
— we can refactor once we know all the input call sites.

Don't touch `~/freebsd-official/ports` (unrelated ports tree). Don't
create GitHub branches or commit anything without asking first. All
build work happens on this host (FreeBSD 16.0-CURRENT — `uname` says
"Linux" because of linuxulator, ignore that). Runtime testing goes
to `ssh ser6` (AMD Radeon 680M, VCN3).
