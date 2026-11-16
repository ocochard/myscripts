# iwmbtfw(8): errors are lost when devd runs it

```
Category:  bin
Component: bin
Version:   16.0-CURRENT
```

Patch: [`iwmbtfw_syslog.patch`](iwmbtfw_syslog.patch)
(`usr.sbin/bluetooth/iwmbtfw/iwmbt_dbg.h`, `iwmbt_fw.c`, `iwmbt_hw.c`, `main.c`).
Background for readers new to this code: [`iwmbtfw_syslog.md`](iwmbtfw_syslog.md).

**Summary.** devd(8) runs iwmbtfw on every Intel Bluetooth USB attach, and that is its normal use.
devd's children have stderr on `/dev/null`, and iwmbtfw reports errors only on stderr.
So a failed firmware download, for example a missing `iwmbt-firmware` package, leaves no trace.
The patch sends errors to syslog as well as stderr.
At boot devd starts before syslogd, so the patch also sets `LOG_CONS`, and the message then goes to the console and the kernel message buffer.

## How to repeat

Machine: Beelink SER6, Intel AX200 (Bluetooth part is USB 8087:0029).
FreeBSD 16.0-CURRENT main-n290674, `iwmbt-firmware` not installed, adapter in bootloader mode
(on this machine that needs mains power removed: warm reboot and `shutdown -p` keep the loaded firmware).

```
$ usbconfig | grep -i bluetooth
ugen1.3: <AX200 Bluetooth Intel Corp.> at usbus1, cfg=0 md=HOST spd=FULL (12Mbps) pwr=ON (100mA)
$ devinfo | grep -c ubt
0
$ grep -c iwmbtfw /var/log/messages
0
```

devd did run iwmbtfw at boot. A wrapper around `/usr/sbin/iwmbtfw` recorded:

```
14:10:05 start -d ugen1.3 -f /usr/local/share/iwmbt-firmware ... syslogsock=ls: /var/run/log: No such file or directory
iwmbtfw: iwmbt_fw_read: open: /usr/local/share/iwmbt-firmware/ibt-20-1-3.sfi: No such file or directory
iwmbtfw: main: Firmware download failed!
14:10:05 rc=1
```

Without the wrapper, those two lines go to `/dev/null`.

Shorter repeat, no special hardware state needed:

```
# iwmbtfw -d ugen9.9 </dev/null >/dev/null 2>&1; echo $?
1
```

Nothing reaches `/var/log/messages`.

## Cause

- `sbin/devd/devd.cc` calls `daemon(0, 0)`; `lib/libc/gen/daemon.c` then points stdin, stdout and stderr at `/dev/null`.
  `my_system()` forks, keeps descriptors 0-2 and runs the action with `sh -c`.
- `iwmbt_dbg.h`: `iwmbt_err()` is `fprintf(stderr, ...)`.
- `iwmbt_fw.c`, `iwmbt_fw_read()`: open, stat, calloc and read errors use `warn()`, also stderr.
- Boot order: `rcorder` puts `/etc/rc.d/devd` (`BEFORE: NETWORKING mountcritremote`) at position 61
  and `/etc/rc.d/syslogd` at 114, so at boot `/var/run/log` does not exist yet when devd runs iwmbtfw.

`usr.sbin/bluetooth/bcmfw/bcmfw.c` already logs to syslog with facility `LOG_USER`.

## Fix

- `iwmbt_err()` writes to stderr, unchanged, then calls `syslog(LOG_ERR, ...)`.
- `main()` calls `openlog("iwmbtfw", LOG_CONS | LOG_NDELAY | LOG_PID, LOG_USER)` first.
  With `LOG_CONS`, when syslogd is not running, libc writes the message to `/dev/console`.
  The console driver copies console writes into the kernel message buffer
  (`ttyconsdev_write()` and `log_console()`, `kern.log_console_output=1` by default), where `dmesg -a` shows them.
- The four `warn()` calls in `iwmbt_fw_read()` become `iwmbt_err()` with `strerror(errno)`.
- `iwmbt_info()` and `iwmbt_debug()` stay on stderr; they are for interactive `-I` and `-D`.

Why not `LOG_PERROR`: on current main its stderr copy has the RFC 5424 form,
`iwmbtfw 5169 - - main: device not found`, which changes the terminal output.
The explicit `fprintf()` keeps it unchanged.

Limits:

- At boot the message reaches the console and `dmesg -a` (plain `dmesg` hides the `LOG_CONSOLE` facility),
  not `/var/log/messages`: the default `syslog.conf` has `console.info /var/log/console.log` commented out.
- With syslogd running, an interactive run prints each error twice on the console (stderr plus the `*.err` console rule), as bcmfw does.
- `rtlbtfw(8)` has the same bug; separate report and patch.
- Unrelated, seen while reading: `main()` has a `case 'p'` that `getopt()` never returns, because `"Dd:f:hI"` has no `p`.

## Tested

Beelink SER6, FreeBSD 16.0-CURRENT main-n290674, 2026-11-16. Built with `make WARNS=6`, no warnings.

| Test | Result |
|---|---|
| stock and patched, interactive, `-d ugen9.9` | same output: `iwmbtfw: main: device not found`, `iwmbtfw: main: Firmware download failed!` |
| stock, stdio on `/dev/null` | exit 1, nothing in `/var/log/messages` |
| patched, stdio on `/dev/null` | `iwmbtfw[5184]: main: device not found`, `iwmbtfw[5184]: main: Firmware download failed!` in `/var/log/messages` |
| adapter in bootloader mode, firmware directory missing, devd action run with `daemon -f` | `iwmbtfw[3310]: iwmbt_fw_read: open: /usr/local/share/iwmbt-firmware/ibt-20-1-3.sfi: No such file or directory`, `main: Firmware download failed!` in `/var/log/messages` |
| same state, warm reboot, devd runs patched iwmbtfw before syslogd | `dmesg -a`: `iwmbtfw 1928 - - iwmbt_fw_read: open: /usr/local/share/iwmbt-firmware/ibt-20-1-3.sfi: No such file or directory`, `main: Firmware download failed!` |
| cold boot without `LOG_CONS` (first version of the patch) | nothing in `/var/log/messages`; without `LOG_CONS` libc drops the message (`syslog.c`) |
| first version with `LOG_PERROR` | stderr became `iwmbtfw 5169 - - main: device not found` (dropped) |
| firmware restored, stock iwmbtfw | `ubt0` attaches |

Not tested:

- The boot message on the console screen itself; checked only in `dmesg -a`.
- Adapters of the 7260, 8260 and 9260 families.
