# rtlbtfw: log errors to syslog

Patch: [rtlbtfw_syslog.patch](rtlbtfw_syslog.patch),
branch `olivier-rtlbtfw-syslog`, based on FreeBSD main 563c2f27e0ff (2026-11-16).

Same bug and same fix as the Intel loader: read [iwmbtfw_syslog.md](iwmbtfw_syslog.md) first.
It explains why devd(8) children have stderr on `/dev/null`, why devd runs before syslogd at boot,
and how `LOG_CONS` reaches the kernel message buffer.
This page lists only what differs.

## Background

`rtlbtfw(8)` loads firmware into Realtek USB Bluetooth adapters (vendor 0x0bda and others).
`usr.sbin/bluetooth/rtlbtfw/rtlbtfw.conf` runs it from devd on USB interface attach:
`/usr/sbin/rtlbtfw -d $cdev -f /usr/local/share/rtlbt-firmware`.
The firmware files come from the `comms/rtlbt-firmware` port.

rtlbtfw was written after iwmbtfw and copies its structure:
`rtlbt_dbg.h` has the same stderr-only `rtlbt_err()` macro,
and `rtlbt_fw_read()` in `rtlbt_fw.c` reports a missing file with `warn()`.

## The problem

No Realtek Bluetooth adapter was available. Measured with errors that need no hardware,
on a Beelink SER6, FreeBSD 16.0-CURRENT main-n290674, 2026-11-16:

```
$ rtlbtfw -d ugen9.9 </dev/null >/dev/null 2>&1; echo $?
1
```

Exit code 1 and nothing in `/var/log/messages`.
Under devd, a missing `rtlbt-firmware` package fails the same silent way.

## The fix

Identical to the iwmbtfw patch:

- `rtlbt_err()` writes to stderr, unchanged, and to syslog at `LOG_ERR`.
- `main()` calls `openlog("rtlbtfw", LOG_CONS | LOG_NDELAY | LOG_PID, LOG_USER)` first.
- The four `warn()` calls in `rtlbt_fw_read()` (open, stat, calloc, mmap) become `rtlbt_err()` with `strerror(errno)`.
  `<err.h>` is no longer used in `rtlbt_fw.c`.
- `rtlbt_info()` and `rtlbt_debug()` stay on stderr.

What the patch does NOT fix: the same limits as iwmbtfw.
At boot the message reaches the console and `dmesg -a`, not `/var/log/messages`.

## Tested

Binary built with `make WARNS=6` (no warnings), run from `/tmp`.

| Test | Result |
|---|---|
| stock and patched, interactive, `-d ugen9.9` | same output: `rtlbtfw: main: device not found`, `rtlbtfw: main: Firmware download failed!` |
| stock, stdio on `/dev/null` | exit 1, nothing in `/var/log/messages` |
| patched, stdio on `/dev/null` | `rtlbtfw[3304]: main: device not found`, `rtlbtfw[3304]: main: Firmware download failed!` in `/var/log/messages` |
| harness calling the patched `rtlbt_fw_read()` on a missing file, stdio on `/dev/null` | `rtlbtfw[3305]: rtlbt_fw_read: open: /usr/local/share/rtlbt-firmware/rtl8761bu_fw.bin: No such file or directory` |
| syslogd stopped, patched run as root, stdio on `/dev/null` | `dmesg -a`: `rtlbtfw 3601 - - main: device not found`, `main: Firmware download failed!` |
| same, run as a normal user | nothing: `/dev/console` is `crw------- root`; devd runs actions as root |

Not tested:

- Any Realtek adapter, so no real firmware download or real missing-firmware failure through `main()`.
- Boot through devd. The iwmbtfw patch covers that path with the same code.
