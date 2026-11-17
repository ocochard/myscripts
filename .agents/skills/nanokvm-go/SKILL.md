---
name: nanokvm-go
description: See the screen of, and type into, a machine through a Sipeed NanoKVM-Go (USB-C/HDMI IP KVM) - screenshots, timed screen recordings, pasting text, pressing key combinations. Use when the user asks to look at, record, or type on the zbook (or another host) through its NanoKVM, when a host's network or ssh is down, or to watch a boot, shutdown, suspend or panic screen.
---

# NanoKVM-Go remote screen and keyboard

Script: `.agents/skills/nanokvm-go/scripts/nanokvm.py (in myscripts)` (python3 with
`websockets`, plus `ffmpeg`). Run it with `python3 -I`.

Configuration comes from the environment, never from files in a repo:

```sh
export NANOKVM_HOST=<kvm address>    # zbook: see the reference memory
export NANOKVM_USER=<user> NANOKVM_PASS=<password>   # same place
```

The address and credentials of a KVM are LAN details: never commit them to
myscripts or any public repo.

## Commands

| Goal | Command |
|---|---|
| Check access | `nanokvm.py login` |
| Screenshot (downscaled to 960 px wide) | `nanokvm.py shot /tmp/nanokvm/x.png [--secs 4] [--width 960]` then Read the PNG |
| Record a boot, shutdown or resume | `nanokvm.py record /tmp/nanokvm/boot --secs 90 [--fps 1]` then Read the last few `boot_NNN.png` |
| Type text into the focused window | `nanokvm.py paste 'echo hello\n'` (`\n` = Enter) |
| Press keys | `nanokvm.py key enter`, `nanokvm.py key ctrl+alt+f2`, `nanokvm.py key up up enter` |

Key names: `a`-`z`, `0`-`9`, `f1`-`f12`, `enter`, `esc`, `tab`, `space`,
`backspace`, `delete`, `insert`, `home`, `end`, `pageup`, `pagedown`, arrows
`up down left right`; modifiers `ctrl shift alt meta` (and `rctrl` ...),
joined with `+`.
`paste` is for text (the KVM types it with its own layout); `key` is for
shortcuts and keys that have no character.

To start a recording before an action that cuts the host's network, launch
it in the background first, wait 3-4 s, then trigger the action:

```sh
(python3 -I nanokvm.py record /tmp/nanokvm/off --secs 70 > /tmp/nanokvm/off.log 2>&1 &)
sleep 4; ssh host 'sudo shutdown -p now'
```

## How it works (firmware application 0.2.x)

- Login: `POST /api/auth/login` `{"username","password"}` over HTTPS
  (self-signed certificate) returns `data.token`; every request sends it as
  the cookie `nano-kvm-token`.
- Video: H.264 only, no snapshot or MJPEG endpoint.
  The websocket `/api/stream/h264/direct` sends binary messages; their
  concatenation decodes with `ffmpeg -f h264` (ffmpeg skips the 8-byte
  header of each message).
  Frames are 3840x2160: always downscale before reading an image.
- Text: `POST /api/hid/paste` `{"content": ...}`.
  POSTs need `Origin: https://<kvm>` and `Referer: https://<kvm>/`, or the KVM
  answers "csrf validation failed".
- Keys: binary frames on the websocket `/api/ws`, as the web UI's virtual
  keyboard: a 13-byte header (`03` input router, `01` version, `10` source
  virtual keyboard, `01` type keyboard state, `00` flags, 32-bit sequence,
  32-bit time stamp in ms, little-endian), then an 8-byte HID boot keyboard
  report (modifier byte, reserved, 6 usage IDs). A press is one report with
  the key, then one all-zero report.
  (`/api/hid/shortcut` only stores web UI shortcuts; it sends nothing.)

## Traps

- **Static screen, no frames**: the stream may send nothing for a few seconds
  when nothing changes on screen. Use `--secs 6` to `8` for a screenshot; the
  script says "no video" when it got 0 bytes.
- **The KVM is a monitor of the host.** On the zbook it is a DP Alt Mode
  monitor (`DP-1` in xrandr) on a USB-C port, plus USB HID and a cdce USB
  Ethernet (`ue1`).
  - Xorg may leave `DP-1` off: no video at all.
    Re-enable it with `DISPLAY=:0 xrandr --output DP-1 --mode 3840x2160 --same-as eDP-1`.
  - XFCE opens `xfce4-display-settings -m` when the KVM display appears;
    text typed into that dialog (a space presses a button) can switch DP-1
    off.
  - FreeBSD's shutdown detaches the USB controllers before the final ACPI
    power-off message: the KVM's video stops at the USB detaches
    (`cdce0: detached`), so the last kernel lines (`Powering system off...`)
    are never seen.
- **Check focus before typing** into an X session:
  `DISPLAY=:0 xprop -root _NET_ACTIVE_WINDOW`, then
  `xprop -id <id> _NET_WM_NAME`.
- **Recordings have no wall-clock time**: frame numbers follow the stream's
  own timing; read the time from the screen (console time stamps) instead.
- Never use a screenshot of a camera view in docs: the zbook camera shows the
  user (only text results).

## Known hosts

| Host | Where the KVM is | Notes |
|---|---|---|
| zbook (HP ZBook Ultra G1a) | NanoKVM-Go on a USB-C port | address and credentials in the `reference_zbook_nanokvm_go` memory |
