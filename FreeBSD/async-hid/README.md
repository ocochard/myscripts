# async-hid FreeBSD hardware checks

Hand-run programs that verified the FreeBSD `hidraw(4)` backend against real
devices. Removed from the upstream `async-hid` repo in PR #49: they mostly duplicated
the shared examples, differing only in which device they select, so they were
noise for anyone reading the repo for API guidance.

Kept here because they still document which paths were exercised on hardware.

Design of the backend itself: [async-hid-freebsd-backend.md](async-hid-freebsd-backend.md)
(starter module: [async-hid-freebsd-skeleton.rs](async-hid-freebsd-skeleton.rs)).
Kernel side (`EVFILT_WRITE` in hidraw(4)): [../docs/hidraw_kqueue_evfilt_write.md](../docs/hidraw_kqueue_evfilt_write.md).

## Running

They are `examples/`-shaped, not standalone crates. Drop one into a checkout:

```sh
cp examples/freebsd_read_mouse.rs ~/async-hid/examples/
cd ~/async-hid
cargo run --example freebsd_read_mouse
```

Most select a device by usage page and usage id, so no editing is needed.
`freebsd_read_by_path` and `freebsd_read_mouse_by_vid` take arguments:

```sh
cargo run --example freebsd_read_by_path /dev/hidraw0 5
cargo run --example freebsd_read_mouse_by_vid 0x046d
```

## Coverage

| File | Path exercised |
|---|---|
| `freebsd_read_mouse.rs` | `enumerate` filtered by usage page, `read_input_report` |
| `freebsd_read_mouse_by_vid.rs` | `enumerate` filtered by vendor id plus usage page |
| `freebsd_read_by_path.rs` | `query_devices` with `DeviceId::DevPath`, numbered reports |
| `freebsd_read_gamepad.rs` | `read_input_report` on a gamepad |
| `freebsd_feature_gamepad.rs` | `HIDIOCGFEATURE` via `AsyncHidFeatureHandle` |
| `freebsd_write_kbd_leds.rs` | `write_output_report` |

`freebsd_read_by_path.rs` is the only one covering `DeviceId::DevPath` lookup;
no shared example does. Worth folding into `open_device.rs` upstream some day.

## Runtime requirements

FreeBSD 13+, `hw.usb.usbhid.enable=1`, `hidraw` module loaded. Nodes are
`0600 root:operator`, so non-root access needs a `devfs.rules(5)` entry.
Without it `enumerate` returns nothing instead of an error.
