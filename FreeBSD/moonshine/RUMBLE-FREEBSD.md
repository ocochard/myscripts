# Gamepad rumble on FreeBSD — kernel-blocked (future task)

Status: **not achievable on stock FreeBSD**. Rumble is a documented no-op in
moonshine's FreeBSD gamepad backend. This is a missing *kernel* feature, not a
moonshine or userspace-ABI gap. This doc records why, and what implementing it
would take, so it can be picked up later.

Investigated on: FreeBSD **16.0-CURRENT** (ser6, `n286843-75aadc902298`,
2026-06-22). Kernel source under `/usr/src/sys/dev/evdev/`.

## How rumble is supposed to work (Linux model)

moonshine's control channel already carries rumble both directions; only the
host-side device plumbing is platform-specific. On Linux the flow is:

1. moonshine creates a virtual gamepad via `/dev/uinput` and advertises force
   feedback: `UI_SET_EVBIT(EV_FF)` + `UI_SET_FFBIT(FF_RUMBLE)` +
   `uinput_setup.ff_effects_max > 0`.
2. A game opens the resulting `/dev/input/eventN` and uploads a rumble effect
   with `EVIOCSFF` (a `struct ff_effect` of `type = FF_RUMBLE`, carrying
   `strong_magnitude` / `weak_magnitude`). The kernel assigns an effect id.
3. Because the device is uinput-backed, the kernel does **not** apply the effect
   itself — it forwards an *upload request* back to uinput userspace as an
   `input_event` with `type = EV_UINPUT (0x0101)`, `code = UI_FF_UPLOAD`,
   `value = request_id`. moonshine reads that, calls `UI_BEGIN_FF_UPLOAD` to
   fetch the `ff_effect`, stores the magnitudes, sets `retval = 0`, and calls
   `UI_END_FF_UPLOAD`. Erase is the mirror (`UI_FF_ERASE` +
   `UI_BEGIN/END_FF_ERASE`).
4. The game plays the effect by writing an `EV_FF` event (`code = effect_id`,
   `value = 1` play / `0` stop). uinput forwards this to moonshine, which maps
   the stored magnitudes into a `FeedbackCommand::Rumble` and sends it over the
   control channel to the Moonlight client, which vibrates the physical pad.

The moonshine side of steps 1/3/4 is straightforward and was fully implemented
and building for FreeBSD (correct ioctl request numbers for FreeBSD's 13-bit
`ioccom.h`, correct `ff_effect`/`uinput_ff_upload`/`uinput_ff_erase` struct
layouts verified against the target headers, a reader thread servicing the
handshake). It was reverted because the kernel never drives it — see below.

## Why it can't work: FreeBSD evdev/uinput stubs out force feedback

Three layers of the FreeBSD kernel fake FF success and do nothing. All line
numbers are from 16.0-CURRENT `n286843`.

1. **Client upload/remove/query — `sys/dev/evdev/cdev.c:536`:**
   ```c
   case EVIOCSFF:
   case EVIOCRMFF:
   case EVIOCGEFFECTS:
       /* Fake unsupported ioctls */
       return (0);
   ```
   A game's `EVIOCSFF` returns success but assigns no effect id (the caller's
   `ff_effect.id` stays whatever it was, e.g. -1) and generates no upload
   request. Nothing is stored, nothing is forwarded.

2. **uinput FF handshake — `sys/dev/evdev/uinput.c:624`:**
   ```c
   case UI_BEGIN_FF_UPLOAD:
   case UI_END_FF_UPLOAD:
   case UI_BEGIN_FF_ERASE:
   case UI_END_FF_ERASE:
       if (state->ucs_state == UINPUT_RUNNING)
           return (EINVAL);
       /* Fake unsupported ioctl */
       return (0);
   ```
   Even if a request existed, these are no-ops.

3. **`EV_UINPUT` upload-request events are never emitted.** `EV_UINPUT` (0x0101)
   is defined in `uinput.h` for Linux ABI compatibility but appears *nowhere*
   in the kernel `.c` files — the request-forwarding mechanism from step 3 above
   does not exist. `EV_FF` events (`evdev.c`) are only routed to a hardware
   driver's `ev_event` method; there is no relay from an evdev client back out
   to the uinput userspace that created the device.

`UI_SET_FFBIT` (`uinput.c:582`) *is* honored (it records the FF bit), so a
device can *advertise* `FF_RUMBLE` — but that capability is a dead end because
the request path behind it is absent.

## Runtime confirmation

With the full implementation deployed on ser6 and a live Moonlight session +
Xbox controller (two `Moonshine XOne controller` evdev nodes created, reader
threads alive in `select`):

- A synthetic probe doing `EVIOCSFF(FF_RUMBLE)` returned success but left
  `effect.id == -1` (no id assigned), and the subsequent `EV_FF` play write
  failed `EINVAL` (code -1 invalid).
- moonshine logged **zero** upload/play requests — the kernel never forwarded
  anything to userspace. The reader threads never woke.

This matches the source exactly.

## What a fix would require (future task, kernel work)

This is a FreeBSD kernel project, independent of moonshine:

- Implement `EVIOCSFF`/`EVIOCRMFF`/`EVIOCGEFFECTS` in `cdev.c`: allocate effect
  slots, assign ids, and — for uinput-backed devices — enqueue an `EV_UINPUT` /
  `UI_FF_UPLOAD` (or `UI_FF_ERASE`) request event to the owning uinput client
  instead of applying it.
- Implement the `UI_BEGIN/END_FF_UPLOAD` and `UI_BEGIN/END_FF_ERASE` handshake
  in `uinput.c` (buffer the pending `struct ff_effect`, expose it to
  `UI_BEGIN_FF_UPLOAD`, capture `retval` on `UI_END_FF_UPLOAD`).
- Route `EV_FF` play/stop writes from an evdev client on a uinput device back to
  that uinput client's read queue.
- Track per-device effect tables and `ff_effects_max`.

Effort is non-trivial (touches evdev client cdev, uinput cdev, and the event
routing in `evdev.c`) and would need upstream review. Reference implementation
is Linux `drivers/input/{evdev,uinput}.c` and `ff-core.c`; FreeBSD already
mirrors the structs and ioctl numbers, so the ABI surface is settled — only the
behavior is missing.

Until then: rumble stays a no-op on FreeBSD, and moonshine advertises no FF
capability (so games see a controller without rumble rather than one that claims
rumble and silently drops it).

## moonshine side (for whoever revives this)

The host-side code is small and was proven to build. To re-land once the kernel
supports FF, in
`moonshine-core/src/session/stream/control/input/gamepad/backend_freebsd.rs`:

- Open `/dev/uinput` `O_RDWR` (not `O_WRONLY`).
- In `setup()`: `UI_SET_EVBIT(EV_FF)`, `UI_SET_FFBIT(FF_RUMBLE)`, set
  `UinputSetup.ff_effects_max` (e.g. 16).
- Add FF ABI: `iowr<T>` helper (`IOC_IN|IOC_OUT`), ioctls `UI_SET_FFBIT`
  (iowint,107), `UI_BEGIN_FF_UPLOAD` (iowr,200), `UI_END_FF_UPLOAD` (iow,201),
  `UI_BEGIN_FF_ERASE` (iowr,202), `UI_END_FF_ERASE` (iow,203); structs
  `FfEffect` (48B — the union `u` at offset 16 needs 8-byte alignment;
  `#[repr(C, align(8))] struct FfUnion([u8;32])`), `UinputFfUpload` (104B),
  `UinputFfErase` (12B). Guard all with `size_of` asserts.
- Spawn a reader thread that `poll()`s the fd, services `EV_UINPUT` upload/erase
  requests (store `ff_rumble_effect` magnitudes keyed by effect id), and on
  `EV_FF` play/stop sends `FeedbackCommand::Rumble(RumbleCommand { id: index,
  low_frequency: strong_magnitude, high_frequency: weak_magnitude })` up the
  existing `feedback_tx` (already passed to `Gamepad::new`). Stop the thread via
  an `Arc<AtomicBool>` + join in `Drop` before `UI_DEV_DESTROY`.

The client-side plumbing (`feedback.rs` `RumbleCommand::as_packet`, the control
channel) is backend-agnostic and needs no changes.
