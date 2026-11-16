# iwmbtfw: log errors to syslog

Patch: [iwmbtfw_syslog.patch](iwmbtfw_syslog.patch),
branch `olivier-iwmbtfw-syslog`, based on FreeBSD main 563c2f27e0ff (2026-11-16).
Companion patch: [fwget_usb_intel_bluetooth.md](fwget_usb_intel_bluetooth.md).

## Background

### Who runs iwmbtfw

Intel USB Bluetooth adapters start in bootloader mode and need firmware from the host.
`iwmbtfw(8)` downloads it.
Nobody types that command in normal use: devd(8) runs it.

- `usr.sbin/bluetooth/iwmbtfw/iwmbtfw.conf`: on USB attach of vendor 0x8087 and a known product ID,
  devd runs `iwmbtfw -d $cdev -f /usr/local/share/iwmbt-firmware`.
- `sbin/devd/devd.cc`, `main()`: devd calls `daemon(0, 0)`.
- `lib/libc/gen/daemon.c`: with `noclose` 0, `daemon()` points stdin, stdout and stderr at `/dev/null`.
- `sbin/devd/devd.cc`, `my_system()`: the child of `fork()` keeps these descriptors
  (`closefrom(3)` closes only the others) and runs the action with `sh -c`.

So every program devd starts has its stderr on `/dev/null`.

### How iwmbtfw reported errors

- `iwmbt_dbg.h`: `iwmbt_err()` is `fprintf(stderr, ...)`.
- `iwmbt_fw.c`, `iwmbt_fw_read()`: a missing firmware file gives `warn("%s: open: %s", ...)`, also stderr.

Under devd, all of these messages go to `/dev/null`.

### syslog(3)

`openlog()` sets the program name, options and facility; `syslog()` sends one message to syslogd(8).
Default `/etc/syslog.conf` sends `*.err` to the console and `*.notice` to `/var/log/messages`,
so a `LOG_ERR` message shows in both places.
`usr.sbin/bluetooth/bcmfw/bcmfw.c`, a sibling firmware loader, already logs this way with facility `LOG_USER`.

## The problem

Beelink SER6, Intel AX200 Bluetooth (8087:0029), FreeBSD main of 2026-11-05, without the `iwmbt-firmware` package:
the device stays in bootloader mode, no driver attaches, and

```
$ grep -c iwmbtfw /var/log/messages
0
```

The same lost-message effect, measured with an error that is easy to trigger
(`-d ugen9.9`, no such device) and stderr on `/dev/null` as under devd:

```
$ iwmbtfw -d ugen9.9 </dev/null >/dev/null 2>&1; echo $?
1
```

Exit code 1 and nothing in `/var/log/messages`.

## The fix

```c
#define	iwmbt_err(fmt, ...)	do {					\
	fprintf(stderr, "iwmbtfw: %s: "fmt"\n", __func__, ##__VA_ARGS__);\
	syslog(LOG_ERR, "%s: "fmt, __func__, ##__VA_ARGS__);		\
} while (0)
```

- `iwmbt_err()` writes to stderr, as before, and to syslog.
- `main()` calls `openlog("iwmbtfw", LOG_CONS | LOG_NDELAY | LOG_PID, LOG_USER)` first.
- `LOG_CONS` covers boot. rc.d starts devd (`/etc/rc.d/devd`, `BEFORE: NETWORKING mountcritremote`) long before syslogd
  (`REQUIRE: mountcritremote ...`): `rcorder` puts devd at position 61 and syslogd at 114 on the test machine.
  The USB attach event queued during kernel boot reaches devd, which runs iwmbtfw while `/var/run/log` does not exist yet.
  `syslog()` then fails to send (`lib/libc/gen/syslog.c`), and with `LOG_CONS` it writes the message to `/dev/console`.
  The console driver (`ttyconsdev_write()` in `sys/kern/tty.c`) copies console writes into the kernel message buffer
  (`log_console()` in `sys/kern/subr_prf.c`, `kern.log_console_output=1` by default) with facility `LOG_CONSOLE`.
  `dmesg -a` shows them; plain `dmesg` hides non-kernel facilities.
- The four `warn()` calls in `iwmbt_fw_read()` become `iwmbt_err()` with `strerror(errno)`,
  so the missing-file case reaches syslog too. `<err.h>` is no longer used there.
- `iwmbt_info()` and `iwmbt_debug()` stay on stderr: they exist only with `-I` and `-D`, for interactive use.

Why both stderr and syslog instead of `LOG_PERROR`: `LOG_PERROR` makes `syslog()` copy the message to stderr,
but the copy on current main has the RFC 5424 form, which changes what a user sees at the terminal:

```
iwmbtfw 5169 - - main: device not found
```

The explicit `fprintf()` keeps the old terminal output byte for byte.

Alternatives:

- Change the devd rule to `logger`-pipe the output (`iwmbtfw ... 2>&1 | logger -t iwmbtfw`).
  One-line change, but it fixes only the devd path and hides the exit status of iwmbtfw from devd.
- Make devd keep stderr of its children somewhere. Changes every devd action; not this patch's job.

What the patch does NOT fix:

- At boot the message reaches the console and `dmesg -a`, not `/var/log/messages`:
  the default `/etc/syslog.conf` has `console.info /var/log/console.log` commented out.
  The rest of the time it lands in `/var/log/messages`.
- Interactive use with syslogd running prints each error twice on the console
  (stderr, plus the `*.err` console rule).
  Same behavior as bcmfw and most daemons.
- `rtlbtfw(8)` (Realtek) has the same stderr-only `rtlbt_err()` macro: separate patch, see [rtlbtfw_syslog.md](rtlbtfw_syslog.md).
- Unrelated: `main()` has a `case 'p'` that `getopt()` never returns, because `"Dd:f:hI"` has no `p`.

## Tested

Beelink SER6, FreeBSD 16.0-CURRENT main-n290674, 2026-11-16.
Binary built on another FreeBSD main host with `make WARNS=6` (no warnings) and copied to `/tmp`.

| Test | Result |
|---|---|
| stock, interactive, `-d ugen9.9` | `iwmbtfw: main: device not found`, `iwmbtfw: main: Firmware download failed!` |
| patched, interactive, `-d ugen9.9` | the same two lines, same format |
| stock, stdio on `/dev/null` | exit 1, nothing in `/var/log/messages` |
| patched, stdio on `/dev/null` | `iwmbtfw[5184]: main: device not found` and `iwmbtfw[5184]: main: Firmware download failed!` in `/var/log/messages` |
| first try with `LOG_PERROR` (dropped) | stderr became `iwmbtfw 5169 - - main: device not found` |
| harness calling the patched `iwmbt_fw_read()` on a missing file, stdio on `/dev/null` | `iwmbtfw[3279]: iwmbt_fw_read: open: /usr/local/share/iwmbt-firmware/ibt-0041-0041.sfi: No such file or directory` in `/var/log/messages` |
| warm reboot, patched binary installed, firmware directory moved away | adapter kept its firmware: `ubt0` attached, nothing to log |
| `shutdown -p`, power button | adapter still kept its firmware (`Firmware has already been downloaded`) |
| power cord unplugged about 10 s, then boot | adapter in bootloader mode (`ugen1.3`, no `ubt0`); without `LOG_CONS`, nothing logged |
| trace wrapper around iwmbtfw, warm reboot | devd runs `iwmbtfw -d ugen1.3 -f /usr/local/share/iwmbt-firmware` at boot, `/var/run/log` missing, exit 1 |
| after boot, `daemon -f` running the devd action | `iwmbtfw[3310]: iwmbt_fw_read: open: /usr/local/share/iwmbt-firmware/ibt-20-1-3.sfi: No such file or directory` and `main: Firmware download failed!` in `/var/log/messages` |
| with `LOG_CONS`, warm reboot (adapter still in bootloader mode) | `dmesg -a`: `iwmbtfw 1928 - - iwmbt_fw_read: open: /usr/local/share/iwmbt-firmware/ibt-20-1-3.sfi: No such file or directory`, then `main: Firmware download failed!` |
| restore: firmware back, stock iwmbtfw run by hand | `ubt0` attached |

Not tested:

- The boot message on the console screen: checked only in `dmesg -a`.
- `rtlbtfw` and other loaders.
