# async-hid: FreeBSD backend

Upstream: `sidit77/async-hid` — cross-platform HID access crate used by
OpenLogi (and consumers like the `hidpp` ecosystem). It ships backends for
Linux (hidraw), macOS (IOHIDManager), and Windows (Win32 / WinRT). No
FreeBSD backend exists.

This doc plans the FreeBSD backend and how to regression-test it on real
hardware before proposing upstream.

## 1. Grounded facts

### 1.1 The trait surface (from `src/traits.rs` + `src/backend/mod.rs`)

Six methods total:

- `AsyncHidRead::read_input_report(&mut self, buf) -> HidResult<usize>`
- `AsyncHidWrite::write_output_report(&mut self, buf) -> HidResult<()>`
- `AsyncHidFeatureHandle::read_feature_report(&mut self, buf) -> HidResult<usize>`
- `AsyncHidFeatureHandle::write_feature_report(&mut self, buf) -> HidResult<()>`
- `Backend::enumerate(&self) -> HidResult<DeviceInfoStream>`
- `Backend::watch(&self) -> HidResult<Boxed<DeviceEvent>>`
- `Backend::query_info(&self, &DeviceId) -> HidResult<Vec<DeviceInfo>>`
- `Backend::open(&self, &DeviceId, read, write) -> HidResult<(Option<Reader>, Option<Writer>)>`
- `Backend::open_feature_handle(&self, &DeviceId) -> HidResult<FeatureHandle>`

Backends are wired via a `dyn_backend_impl!` macro block in
`src/backend/mod.rs`. Adding a new backend is: (a) a new module gated on
`cfg(target_os = "freebsd")`, (b) one macro entry, (c) one match arm in
`Default for DynBackend`.

### 1.2 FreeBSD kernel HID surface

`hidraw(4)` exists since FreeBSD 13 (Vladimir Kondratyev). It exposes both
its native ioctl set AND a **Linux-compatible** ioctl set:

- `HIDIOCGRDESCSIZE` — get descriptor size (int)
- `HIDIOCGRDESC` — get descriptor (`struct hidraw_report_descriptor`)
- `HIDIOCGRAWINFO` — VID/PID/bustype (`struct hidraw_devinfo`)
- `HIDIOCGRAWNAME(len)` — device description
- `HIDIOCGRAWPHYS(len)` — newbus path
- `HIDIOCGFEATURE(len)` / `HIDIOCSFEATURE(len)` — get/set feature report
- `HIDIOCGINPUT(len)` / `HIDIOCSINPUT(len)` — get/set input report
- `HIDIOCGOUTPUT(len)` / `HIDIOCSOUTPUT(len)` — get/set output report

`read(2)` and `write(2)` on `/dev/hidraw?` transfer input/output reports.
Numbered-report vs single-report semantics match Linux hidraw: first byte
is report id (0 for unnumbered devices).

**Not enabled by default** on FreeBSD 15: `hw.usb.usbhid.enable=0` on this
host, and `/dev/hidraw*` is absent (only `/dev/uhid0`). To use hidraw the
user sets `hw.usb.usbhid.enable=1` in `loader.conf` (with `usbhid_load="YES"`
plus `hidraw_load="YES"` if not compiled in). This is a documented
requirement for the backend — same posture as Linux, where hidraw needs to
be built in.

Older `uhid(4)` path still exists and could be a fallback. Deliberately
out of scope for v1; document as a known limitation.

### 1.3 `nix` crate on FreeBSD

`nix` first-tier supports `x86_64-unknown-freebsd` and `i686-unknown-freebsd`
(README's "Supported Platforms" list). Covers everything the Linux backend
needs from `nix`:

- `nix::fcntl::OFlag`, `nix::unistd::{read, write, access}` — same syscalls
- `nix::sys::event` (kqueue) — FreeBSD's analog to epoll; `async-io` uses
  kqueue on BSDs transparently, so `Async<OwnedFd>` should just work
- Ioctl macros (`nix::request_code_read!` / `_write!` / `_readwrite!`) —
  same on FreeBSD (`_IOR`/`_IOW`/`_IOWR` share the Linux encoding)

No `nix::sys::socket::NetlinkAddr` on FreeBSD — that's fine, we don't
use netlink; devd replaces it.

### 1.4 devd for hotplug

FreeBSD's device-state-change daemon. Two sockets:

- `/var/run/devd.pipe` — SOCK_STREAM, newline-delimited text
- `/var/run/devd.seqpacket.pipe` — SOCK_SEQPACKET, one message per read

Line format (from devd(8)):

```
!system=USB subsystem=DEVICE type=ATTACH ugen=ugen0.4 ...
+uhid0 at bus=0 hubaddr=1 port=1 devaddr=4 ...
-uhid0 at bus=0 ...
```

`+` = device added, `-` = device removed, `!` = notify event. hidraw
devices will show up as `!system=HID subsystem=hidraw type=ATTACH` (or
similar; verify empirically — this is not documented in stone).

Use the seqpacket variant to avoid line-reassembly. Non-blocking, drive
via `async-io` (kqueue).

## 2. Design

### 2.1 Directory layout

Mirror the Linux backend, one file per concern:

```
src/backend/freebsdhid/
├── mod.rs         Backend impl, HidDevice (Reader/Writer/FeatureHandle)
├── descriptor.rs  Report-descriptor parsing (lift from hidraw backend)
├── ioctl.rs       HIDIOC* ioctl wrappers via nix::ioctl_*
└── devd.rs        devd socket parsing for watch()
```

`descriptor.rs` should be a straight copy (or shared module) — the report
descriptor format is USB-HID standard, not Linux-specific.

### 2.2 DeviceId

Linux uses `DeviceId::DevPath(PathBuf)` pointing into `/sys/class/hidraw/`.
For FreeBSD, use `/dev/hidraw?` directly (no `/sys` equivalent). Same
`PathBuf` shape — hopefully no changes to `DeviceId` needed. If enum needs
extending, prefer a per-target cfg over new variants.

### 2.3 `enumerate`

Walk `/dev/`, filter for `hidraw*`. For each, open O_RDONLY, ioctl
`HIDIOCGRAWINFO` (VID/PID), `HIDIOCGRDESCSIZE` + `HIDIOCGRDESC` (descriptor
for usage-page/usage), `HIDIOCGRAWNAME` (product string). Close. Emit
`DeviceInfo`. No sysfs walk needed — everything is in the ioctls.

Bustype: `hidraw_devinfo.bustype` is `BUS_USB` / `BUS_I2C` (from
`dev/evdev/input.h`). Same values as Linux — reuse.

### 2.4 `open`, read, write

Open `/dev/hidraw?` with the flags requested (O_RDONLY / O_WRONLY /
O_RDWR), wrap in `async-io`'s `Async<OwnedFd>`. `read_input_report` =
async `read()`. `write_output_report` = async `write()`.

Numbered-report handling: identical to Linux (first byte = report id or
0). No translation needed.

### 2.5 Feature reports

`HIDIOCGFEATURE(len)` / `HIDIOCSFEATURE(len)` — first byte of buf is
report id. Wrap in `nix::ioctl_readwrite_buf!` and `nix::ioctl_write_buf!`.
Numbers differ from Linux — read them from `<dev/hid/hidraw.h>` (not
Linux's `<linux/hidraw.h>`). Get/set input/output is available too but
async-hid doesn't expose those; skip.

### 2.6 `watch`

Connect to `/var/run/devd.seqpacket.pipe`. Wrap in `Async`. On each
message, parse — if it's a hidraw attach/detach, emit `DeviceEvent::Connected`
or `DeviceEvent::Disconnected` with a `DeviceId::DevPath("/dev/hidrawN")`.

**Fallback:** if `devd` isn't running or the socket path doesn't exist,
return `HidError::Unsupported` from `watch()`. Same shape as Linux picks
between udev-group and kernel-group at runtime.

**Optional simplification for v1:** return `Err(HidError::Unsupported)`
unconditionally, ship the rest, add `watch()` in a follow-up. Most
consumers don't need hotplug.

### 2.7 Cargo.toml

Add to workspace `Cargo.toml`:

```toml
[target.'cfg(target_os = "freebsd")'.dependencies]
nix = { version = "…", features = ["fs", "ioctl", "poll", "event", "socket"] }
async-io = "…"  # already a dep on Linux; verify shared
log = { workspace = true }
```

Same crate versions as the Linux path — no new deps.

## 3. Implementation order

Land in tight commits so each step can be tested independently.

1. **Skeleton.** New module gated on `cfg(target_os = "freebsd")`, all
   trait methods return `Err(HidError::Unsupported)`. Wire into
   `dyn_backend_impl!`. `cargo check --target x86_64-unknown-freebsd`
   passes.
2. **`enumerate`** + `HIDIOCGRAWINFO` / `HIDIOCGRAWNAME` /
   `HIDIOCGRDESC(SIZE)`. Verify with `examples/enumerate_devices.rs`.
3. **`open` + `read_input_report`** via `Async<OwnedFd>`. Verify with
   `examples/open_device.rs` + `examples/read_write.rs` (read side).
4. **`write_output_report`.** Verify with `examples/read_write.rs`
   write side against a keyboard (NumLock LED via output report) or a
   Pico/RP2040 running a HID example.
5. **`AsyncHidFeatureHandle`** (both directions). Verify with
   `examples/read_feature_report.rs` and
   `examples/write_feature_report.rs`.
6. **`watch`** via devd. Verify with `examples/watch_devices.rs`
   + plug/unplug cycles. Land as `Unsupported` first if devd parsing
   proves hairy.

Each step is a commit. Each commit's message names the example used to
verify it. Keeps the PR reviewable.

## 4. Testing

### 4.1 Static checks

Local, before every push:

```
cargo check --target x86_64-unknown-freebsd
cargo clippy --target x86_64-unknown-freebsd -- -D warnings
cargo fmt -- --check
```

Cross-compile from Linux with `rustup target add x86_64-unknown-freebsd`
plus a FreeBSD sysroot (e.g. via `cross`), or just build on the FreeBSD
host directly. Cross is faster to iterate; native is what CI would run.

### 4.2 Example-driven hardware tests

`async-hid/examples/` covers every trait method. Running each one
against a real device IS the regression suite. Concretely:

| Example | Trait method(s) verified |
|---|---|
| `enumerate_devices` | `Backend::enumerate` + descriptor decode |
| `open_device` | `Backend::open` |
| `read_write` | `AsyncHidRead::read_input_report`, `AsyncHidWrite::write_output_report` |
| `read_feature_report` | `AsyncHidFeatureHandle::read_feature_report` |
| `write_feature_report` | `AsyncHidFeatureHandle::write_feature_report` |
| `read_ds4_callibration` | Real-world descriptor + feature-report parse (DualShock 4) |
| `read_with_timeout` | Async fd is really async (doesn't block executor) |
| `watch_devices` | `Backend::watch` |
| `open_all_once` | Multiple concurrent opens |

### 4.3 Hardware matrix

One device isn't enough — different device shapes exercise different code
paths.

- **Boot-protocol HID** (any USB keyboard or mouse). Baseline open/read.
- **Vendor-specific HID with feature reports** (gaming mouse, MCU dev
  board running a HID example, game controller). Exercises the
  `HIDIOC[GS]FEATURE` path.
- **Composite device with multiple HID interfaces** (a keyboard with a
  media-keys interface, or almost any modern gaming keyboard).
  Exercises enumeration when one physical device is N `/dev/hidraw*`
  nodes.
- **Numbered-report device** (most modern HID). First-byte-is-report-id
  path.
- **Single-report device** (very old / simple HID). First-byte-is-0
  path.

Kbd + mouse + Pico + a controller covers this.

### 4.4 Cross-platform parity check

The strongest test: same device, same example, on FreeBSD AND on
Linux/macOS. Diff the output.

- Report descriptor bytes (`enumerate_devices` output): must match
  byte-for-byte across platforms. Catches ioctl argument-struct bugs,
  endian bugs, off-by-ones.
- Read reports from an idle device: values should match.
- Feature-report round-trip (write X, read X back): must round-trip
  on both platforms.

Automate this once, don't do it by hand. See `regression-runner.sh`
below.

### 4.5 CI

GitHub Actions has no FreeBSD runner. Two useful options:

1. **`cargo check --target x86_64-unknown-freebsd`** on Linux runners.
   Catches "PR breaks compilation on FreeBSD" — the most common
   post-merge regression. No hardware, no tests, just typecheck.
2. **Cirrus CI** for native FreeBSD builds + `cargo test` on the
   non-hardware pieces (descriptor parser, devd line parser). Cirrus
   is free for OSS. Propose in a follow-up if maintainer wants it —
   don't bundle with the initial PR.

## 5. Delivery to upstream

Order things so the PR is easy to accept:

1. Open an **issue** first with the design summary from §2. Ask if the
   maintainer wants FreeBSD support before writing the code. Save
   yourself the "we don't want to maintain this" outcome.
2. If yes: PR one commit per implementation step from §3. Each commit
   compiles and passes cargo check.
3. PR description names the FreeBSD versions tested (13.x / 14.x / 15
   -CURRENT / 16-CURRENT), the required sysctl
   (`hw.usb.usbhid.enable=1`), the hardware matrix, and any known
   limitations (e.g. `watch` unsupported v1).
4. Offer CI as a follow-up, don't bundle it.

## 6. Fallbacks if upstream declines

- Vendor the fork under `ports/misc/rust-async-hid-freebsd` and
  document the git rev in patches.
- Or maintain a `patch-freebsd-backend.diff` in whichever port
  consumes async-hid on FreeBSD.

Prefer upstream. Downstream patches rot fast against a workspace of
this size.

## Known caveats (from hardware verification)

- **hkbd(4) intercepts NumLock/CapsLock LED writes.** `write_output_report`
  bytes reach the kernel and the wire (verified with Scroll Lock on a
  TypeMatrix keyboard: lit 3s, dark 3s), but hkbd rewrites NumLock and
  CapsLock from its own state within ms — visible flip is not observable.
  Scroll Lock passes through because no console driver tracks it. Document
  in the PR; not a backend bug. Same class of issue Linux consumers see
  with the input subsystem holding a claim on the LED collection.

- **Unnumbered devices still need a leading 0x00 byte.** FreeBSD hidraw
  requires it in hidraw mode ("first byte should be set to 0 and the
  report data itself should begin at the second byte" — hidraw(4)). This
  matches async-hid's cross-platform rule; no per-target divergence in
  the user-facing API.

- **/dev/hidraw* is 0600 root:operator by default.** For non-root testing
  add a devfs.rules(5) entry; runtime tests here used sudo.

## 7. Open questions to resolve during implementation

- Does `Async<OwnedFd>` from `async-io` behave the same on FreeBSD
  (kqueue) as on Linux (epoll) for a `/dev/hidraw?` fd? Verify by
  running `read_with_timeout` example — a timeout that fires means
  the executor isn't blocked, i.e. the fd is properly async.
- Are the `HIDIOC[GS]FEATURE` ioctl numbers ABI-identical to Linux, or
  do we need per-target constants? Linux uses `_IOC(_IOC_READ|_IOC_WRITE,
  'H', 0x07, len)`; FreeBSD uses `_IOWR('U', 0x64, ...)` per
  `<dev/hid/hidraw.h>`. Answer: define constants locally, don't
  assume ABI match.
- Does devd emit hidraw attach/detach lines, or only USB-level events?
  Empirically test on a live system with `nc -U /var/run/devd.seqpacket.pipe`
  during a plug cycle; log the exact lines.

## Related files in this directory

- `async-hid-freebsd-skeleton.rs` — starter module, all methods
  returning `Unsupported`, ready to drop into
  `src/backend/freebsdhid/mod.rs`.
- `regression-runner.sh` — shell driver that runs every `async-hid`
  example against every device path listed in a config file, captures
  output, diffs against golden files. TODO — write once the skeleton
  compiles.
