# rtlbtfw(8): errors are lost when devd runs it

```
Category:  bin
Component: bin
Version:   16.0-CURRENT
```

Patch: [`rtlbtfw_syslog.patch`](rtlbtfw_syslog.patch)
(`usr.sbin/bluetooth/rtlbtfw/rtlbt_dbg.h`, `rtlbt_fw.c`, `rtlbt_hw.c`, `main.c`).
Background for readers new to this code: [`rtlbtfw_syslog.md`](rtlbtfw_syslog.md).
Same bug and same fix as the iwmbtfw report: [`bugreport_iwmbtfw_syslog.md`](bugreport_iwmbtfw_syslog.md).

**Summary.** devd(8) runs rtlbtfw on every Realtek Bluetooth USB attach, and that is its normal use.
devd's children have stderr on `/dev/null`, and rtlbtfw reports errors only on stderr.
So a failed firmware download, for example a missing `rtlbt-firmware` package, leaves no trace.
The patch sends errors to syslog as well as stderr, with `LOG_CONS` for boot, when devd runs before syslogd.

## How to repeat

No Realtek Bluetooth adapter was available; this repeat needs none.
Machine: Beelink SER6, FreeBSD 16.0-CURRENT main-n290674.

```
# rtlbtfw -d ugen9.9 </dev/null >/dev/null 2>&1; echo $?
1
```

Exit code 1 and nothing in `/var/log/messages`.
With an adapter attached and no `rtlbt-firmware` package, devd runs
`/usr/sbin/rtlbtfw -d $cdev -f /usr/local/share/rtlbt-firmware` (`rtlbtfw.conf`),
and the `open` error from `rtlbt_fw_read()` is lost the same way.

## Cause

- `sbin/devd/devd.cc` calls `daemon(0, 0)`, which points stdin, stdout and stderr at `/dev/null`;
  `my_system()` runs each action with descriptors 0-2 inherited.
- `rtlbt_dbg.h`: `rtlbt_err()` is `fprintf(stderr, ...)`.
- `rtlbt_fw.c`, `rtlbt_fw_read()`: open, stat, calloc and mmap errors use `warn()`, also stderr.
- At boot `/etc/rc.d/devd` runs before `/etc/rc.d/syslogd`, so `/var/run/log` does not exist yet.

rtlbtfw copies the structure of iwmbtfw, including this macro.

## Fix

- `rtlbt_err()` writes to stderr, unchanged, then calls `syslog(LOG_ERR, ...)`.
- `main()` calls `openlog("rtlbtfw", LOG_CONS | LOG_NDELAY | LOG_PID, LOG_USER)` first.
  Without syslogd, libc writes the message to `/dev/console`, and the kernel copies it into the message buffer (`dmesg -a`).
- The four `warn()` calls in `rtlbt_fw_read()` become `rtlbt_err()` with `strerror(errno)`.
- `rtlbt_info()` and `rtlbt_debug()` stay on stderr.

Limits: the same as iwmbtfw.
At boot the message reaches the console and `dmesg -a`, not `/var/log/messages`
(the default `syslog.conf` has `console.info` commented out).
An interactive run with syslogd running prints each error twice on the console.

## Tested

Beelink SER6, 2026-11-16. Built with `make WARNS=6`, no warnings; run from `/tmp`.

| Test | Result |
|---|---|
| stock and patched, interactive, `-d ugen9.9` | same output: `rtlbtfw: main: device not found`, `rtlbtfw: main: Firmware download failed!` |
| stock, stdio on `/dev/null` | exit 1, nothing in `/var/log/messages` |
| patched, stdio on `/dev/null` | `rtlbtfw[3304]: main: device not found`, `rtlbtfw[3304]: main: Firmware download failed!` in `/var/log/messages` |
| small program calling the patched `rtlbt_fw_read()` on a missing file, stdio on `/dev/null` | `rtlbtfw[3305]: rtlbt_fw_read: open: /usr/local/share/rtlbt-firmware/rtl8761bu_fw.bin: No such file or directory` in `/var/log/messages` |
| syslogd stopped, patched run as root, stdio on `/dev/null` | `dmesg -a`: `rtlbtfw 3601 - - main: device not found`, `main: Firmware download failed!` |

Not tested:

- Any Realtek adapter: no real download, and no real missing-firmware failure through `main()`.
- Boot through devd. The iwmbtfw patch was tested at boot with the same code.
