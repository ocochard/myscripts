# Native FreeBSD gamepad backend — study report & design

Status: **design + first implementation** (core Xbox-style pad).
Date: 2026-07-25. Target: ser6 (FreeBSD 16.0-CURRENT, AMD Radeon 680M).

This document records the investigation behind moonshine's FreeBSD
gamepad backend: why the Linux backend can't be reused, which FreeBSD
API is correct (and which look tempting but are wrong), the exact
verified ABI, the design choices, and what's deliberately deferred.

---

## 1. Problem

On FreeBSD, moonshine's gamepad support is a **no-op stub**
(`backend_stub.rs`). When a Moonlight client attaches a controller the
stub logs one warning and drops every button/stick/trigger event, so
games see no controller at all. Keyboard and mouse already work
(they're injected directly into the Smithay `Seat`, a platform-agnostic
path); only the gamepad is missing.

## 2. Why the Linux backend can't be reused

The upstream Linux backend (`backend_inputtino.rs`) uses the
`inputtino` crate, which wraps the C++ `libevdev`. `libevdev`
`#include`s the Linux UAPI headers `linux/input.h` and `linux/uhid.h`.
Those headers do not exist on FreeBSD, so the crate fails to build.

This is a **header/library problem, not a kernel-capability problem.**
FreeBSD ships a Linux-ABI-compatible evdev + uinput subsystem:

- `/dev/uinput` exists (create virtual input devices).
- evdev is live: `/dev/input/event*`, `sysctl kern.evdev.*`.
- The ABI headers live under `/usr/include/dev/evdev/` — `uinput.h`,
  `input.h`, `input-event-codes.h` — with the same struct layouts and
  event codes Linux uses.

So the fix is to speak the uinput ioctl protocol **directly in Rust**
via `libc` (already a dependency), bypassing `libevdev`/`inputtino`
entirely.

## 3. API selection — the tempting-but-wrong options

The user asked whether `hgame(4)`, `ps4dshock(4)`, or `xb360gp(4)` are
the API. They are **not** — they point the wrong direction:

| Driver        | Direction | Role                                             |
|---------------|-----------|--------------------------------------------------|
| `hgame(4)`    | **input** | HID game-controller driver — *consumes* a physical pad |
| `ps4dshock(4)`| **input** | DualShock 4 driver — *consumes* a physical PS4 pad |
| `xb360gp(4)`  | **input** | Xbox 360 gamepad driver — *consumes* a physical pad |

moonshine needs the **opposite**: to *synthesize* a virtual controller
that games read as if it were physical. That is exactly what
**`uinput(4)` + evdev** does — the same subsystem inputtino targets on
Linux. The three drivers above would be relevant only if moonshine were
reading a controller plugged into the *host*, which it never does.

Decision: **`uinput(4)` + evdev, raw ioctl protocol in Rust.**

## 4. The ABI trap — FreeBSD ioctl encoding differs from Linux

This is the single most important finding, and the reason a Linux
uinput crate (e.g. `uinput`, `evdev`) cannot be dropped in even if it
compiled: **the ioctl request numbers are encoded differently.**

Linux `_IOC`: `dir(2) | size(14) | type(8) | nr(8)`, `IOCPARM` 14 bits.
FreeBSD `_IOC` (`sys/ioccom.h`): `IOCPARM_SHIFT = 13`, layout
`I/O(3) | len(13) | group(8) | num(8)`, and crucially the direction
bits differ: `IOC_VOID=0x20000000`, `IOC_OUT=0x40000000`,
`IOC_IN=0x80000000`.

And FreeBSD's uinput.h defines the bit-setting ioctls with a
FreeBSD-specific macro:

```c
#define UI_SET_EVBIT   _IOWINT(UINPUT_IOCTL_BASE, 100)
#define UI_SET_KEYBIT  _IOWINT(UINPUT_IOCTL_BASE, 101)
#define UI_SET_ABSBIT  _IOWINT(UINPUT_IOCTL_BASE, 103)
```

`_IOWINT(g,n) = _IOC(IOC_VOID, g, n, sizeof(int))`. So on FreeBSD these
ioctls are **`IOC_VOID` and take the code as an int passed by value** —
whereas Linux encodes them `_IOW(..., int)` (`IOC_IN`) and the arg is
still an int passed by value. The *encoded number* is what differs;
pass the code as the ioctl's third integer argument either way.

Consequence: we compute the request numbers ourselves with a `const fn`
mirroring FreeBSD's `_IOC`, and never hardcode Linux constants.

## 5. Verified ABI (compiled natively on ser6)

A throwaway C program compiled with the system headers on ser6
(`cc -o /tmp/absz /tmp/absz.c`) produced ground truth:

```
input_event=24  input_id=8  input_absinfo=24  uinput_setup=92  uinput_abs_setup=28
timeval=16  tv_sec=8  tv_usec=8
UI_DEV_CREATE=0x20005501  UI_DEV_DESTROY=0x20005502
UI_DEV_SETUP=0x805c5503   UI_ABS_SETUP=0x801c5504
UI_SET_EVBIT=0x20045564   UI_SET_KEYBIT=0x20045565  UI_SET_ABSBIT=0x20045567
```

Struct layouts (little-endian amd64):

- `input_event` = 24 B: `struct timeval time` (tv_sec i64 = 8,
  tv_usec i64 = 8) + `type` u16 + `code` u16 + `value` i32.
  Note tv_usec is a full `long` (8 B) here, matching Linux amd64.
- `input_id` = 8 B: bustype/vendor/product/version, all u16.
- `input_absinfo` = 24 B: value/minimum/maximum/fuzz/flat/resolution,
  all i32.
- `uinput_setup` = 92 B: `input_id id` (8) + `char name[80]` +
  `u32 ff_effects_max` = 92.
- `uinput_abs_setup` = 28 B: `u16 code` (padded to 4 for i32 alignment)
  + `input_absinfo` (24) = 28.

ioctl numbers verify the `const fn _IOC` derivation exactly, so the
Rust side computes them rather than pasting magic numbers.

Event codes (from `input-event-codes.h`, identical to Linux values):
`EV_SYN=0 EV_KEY=1 EV_ABS=3 SYN_REPORT=0`;
`BTN_SOUTH=0x130 EAST=0x131 NORTH=0x133 WEST=0x134 TL=0x136 TR=0x137
SELECT=0x13a START=0x13b MODE=0x13c THUMBL=0x13d THUMBR=0x13e`;
`ABS_X=0 Y=1 Z=2 RX=3 RY=4 RZ=5 HAT0X=0x10 HAT0Y=0x11`; `BUS_USB=0x03`.

## 6. Reference implementation ported

Canonical logic: inputtino's C++ Xbox backend
`~/.cargo/git/checkouts/inputtino-*/f4ce2b0/src/uinput/joypad_xbox.cpp`
(`create_xbox_controller` + `set_pressed_buttons` + `set_stick` +
`set_triggers`), and the Moonlight button-flag bit values in
`.../include/inputtino/input.h`. Those flags are exactly what
moonshine's `GamepadUpdate::button_flags` (u32) already carries.

### Device definition

Bus `BUS_USB`, name "Moonshine XOne controller", vendor `0x045e`,
product `0x02dd`, version `0x0100`.

- `EV_KEY`: BTN_SOUTH, EAST, NORTH, WEST, TL, TR, SELECT, START, MODE,
  THUMBL, THUMBR.
- `EV_ABS`:
  - ABS_HAT0X, ABS_HAT0Y — dpad, absinfo {min −1, max 1}.
  - ABS_X, ABS_Y, ABS_RX, ABS_RY — sticks, {min −32768, max 32767,
    fuzz 16, flat 128}.
  - ABS_Z, ABS_RZ — triggers, {min 0, max 255}.
- EV_FF is **not** enabled this pass (rumble deferred; advertising FF
  without servicing it would be a lie to the client).

### Event mapping (Moonlight flag → evdev)

Button flags (from inputtino input.h): DPAD_UP=0x0001, DOWN=0x0002,
LEFT=0x0004, RIGHT=0x0008, START=0x0010, BACK=0x0020, LEFT_STICK=0x0040,
RIGHT_STICK=0x0080, LEFT_BUTTON=0x0100, RIGHT_BUTTON=0x0200,
HOME=0x0400, A=0x1000, B=0x2000, X=0x4000, Y=0x8000.

- Dpad → hats: `ABS_HAT0Y` = −1 if UP, +1 if DOWN, else 0;
  `ABS_HAT0X` = −1 if LEFT, +1 if RIGHT, else 0.
- START→BTN_START, BACK→BTN_SELECT, LEFT_STICK→BTN_THUMBL,
  RIGHT_STICK→BTN_THUMBR, LEFT_BUTTON→BTN_TL, RIGHT_BUTTON→BTN_TR,
  HOME→BTN_MODE, A→BTN_SOUTH, B→BTN_EAST, X→BTN_NORTH, Y→BTN_WEST.
- Sticks: LS→(ABS_X = x, ABS_Y = **−y**); RS→(ABS_RX = x,
  ABS_RY = **−y**). Y is inverted (evdev up is negative).
- Triggers: left→ABS_Z, right→ABS_RZ (0..255).
- `EV_SYN`/`SYN_REPORT`=0 after each batch of events.

## 7. Design choices

- **Raw ioctl in Rust, self-contained.** No new crate; `libc` gives
  `open`/`ioctl`/`write`/`close`. All ABI structs/constants are defined
  locally in `backend_freebsd.rs`, `#[repr(C)]`, sized to match §5.
- **ioctl numbers computed, not pasted.** A `const fn ioc()` mirrors
  FreeBSD `_IOC`; `UI_DEV_SETUP`/`UI_ABS_SETUP` derive their size from
  `size_of` so a struct-layout mistake can't silently desync the
  request number from the payload.
- **Modern setup path** (`UI_ABS_SETUP` + `UI_DEV_SETUP`), not the
  legacy `uinput_user_dev` write. Cleaner and matches inputtino.
- **Core pad only, always Xbox layout** (confirmed with user). One
  evdev device regardless of client `GamepadKind`. PS5/Switch layouts
  are a follow-up.
- **RAII teardown.** The fd lives in a struct whose `Drop` runs
  `UI_DEV_DESTROY` then `close`, so ending a session removes the evdev
  node and can't leak fds across connect/disconnect cycles.
- **Same 6-method surface as the stub** (`new`, `set_pressed`,
  `apply_update`, `touch`, `set_motion`, `set_battery`) so
  `gamepad/mod.rs` only needs a cfg line, no dispatch changes.
- **No third backend variant.** Per the port's convention we keep
  linux=inputtino / freebsd=this / other=stub; we do not fork a
  "generic BSD" path.

## 8. Runtime requirement — /dev/uinput permissions

`/dev/uinput` is `crw------- root wheel`. moonshine runs as `olivier`
(uid 1001, groups wheel/audio/video) — **not** root, and mode 0600
means group `wheel` has no access either. So device creation will fail
with `EACCES` until one of:

1. Run moonshine as root (simplest for testing, worst hygiene).
2. A devfs rule granting the moonshine user/group rw on `uinput`,
   e.g. in `/etc/devfs.rules`:
   ```
   [localrules=10]
   add path 'uinput' mode 0660 group video
   ```
   plus `devfs_system_ruleset="localrules"` in `/etc/rc.conf` and a
   `service devfs restart` (olivier is already in `video`).
3. `chmod`/`chown` `/dev/uinput` ad hoc (non-persistent).

Least-privilege for the actual deployment is option 2. Pick and record
the chosen approach in STATE.md at test time.

## 9. Verification plan

1. Build release on the dev host (standard RUSTFLAGS recipe), scp
   `/tmp/moonshine`, SHA-verify, restart.
2. Grant `/dev/uinput` access (§8), attach a controller on the
   Moonlight client, confirm a new node appears:
   `ls /dev/input/event*` grows and
   `sysctl kern.evdev.input | grep -i moonshine` shows
   "Moonshine XOne controller".
3. Confirm events land: `evtest`/`sdl2-jstest` on the new node, or a
   controller-aware app inside the session, while pressing on the
   client.
4. Best proof: launch a game that reads a controller and drive it from
   the client — buttons/sticks/triggers respond (same bar used for the
   keyboard/mouse verification).
5. Teardown: end session, confirm the evdev node disappears (Drop →
   UI_DEV_DESTROY) and no fd leak across reconnect cycles.

## 10. Out of scope (deferred, kept no-op)

Rumble (needs EV_FF + a `UI_BEGIN_FF_UPLOAD` reader thread and FF_RUMBLE
codes not in the FreeBSD header), gyro/accel motion, PS5 touchpad,
battery, LED, adaptive trigger effects, and honoring `GamepadKind`
(PS/Nintendo layouts). Each is a follow-up once the core pad is proven.

## 11. Files

- New: `moonshine-core/src/session/stream/control/input/gamepad/backend_freebsd.rs`
- Edit: `moonshine-core/src/session/stream/control/input/gamepad/mod.rs`
  (cfg selection: linux→inputtino, freebsd→this, other→stub).
