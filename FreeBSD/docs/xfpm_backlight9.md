# xfce4-power-manager: brightness through backlight(9)

Patch: [xfpm_backlight9.patch](xfpm_backlight9.patch), against the ports tree
(`sysutils/xfce4-power-manager` 4.20.1, `PORTREVISION` 1): it extends the
port's existing `files/patch-src_xfpm-backlight-helper.c`.
Not committed; to be sent to the port maintainer (xfce@FreeBSD.org).
Machine: HP ZBook Ultra G1a, 2.8K OLED panel, amdgpu.

This document explains the work for a first-year computer science student:
someone who knows C and what an operating system does, but has never looked
at how a desktop changes the screen brightness on FreeBSD.

## 1. Background

### 1.1 Two ways to set the brightness on FreeBSD

| Interface | Provided by | Userland access |
|---|---|---|
| ACPI video | `acpi_video(4)`, which calls the firmware method `_BCM` of the panel | sysctls `hw.acpi.video.lcd0.brightness`, `.levels`, `.active` |
| backlight(9) | the graphics driver (amdgpu, i915 through drm-kmod) | `/dev/backlight/backlightN`, ioctls `BACKLIGHTGETSTATUS` and `BACKLIGHTUPDATESTATUS` in `<sys/backlight.h>`; tool `backlight(8)` |

backlight(9) devices report their brightness as a percentage (0-100) and a
type, panel or keyboard (`BACKLIGHTGETINFO`).
`/dev/backlight/*` belongs to group `video`, mode 0660.

On this laptop only backlight(9) changes the panel: setting
`hw.acpi.video.lcd0.brightness` to 20 left the screen as it was, and
`lcd0.active` is 0.
Linux makes the same choice: it ignores the ACPI backlight on such machines
and uses the GPU driver's one ("native").

### 1.2 How xfce4-power-manager sets the brightness

The daemon never touches the hardware: it runs a small helper,
`xfpm-power-backlight-helper`, with `--get-brightness` and
`--get-max-brightness` as the user, and with `--set-brightness N` through
`pkexec` (polkit action `org.xfce.power.backlight-helper`, allowed for the
active session).
The helper has one backend per OS (`src/xfpm-backlight-helper.c`): sysfs
for Linux, and for FreeBSD only the ACPI video sysctls.
It selects the first `lcdN`, `crtN`, ... device whose `.active` sysctl is 1.

## 2. The problem

On the laptop, with xfce4-power-manager 4.20.1:

```
$ xfpm-power-backlight-helper --get-max-brightness; echo $?
255
```

No ACPI video output is active, so the helper finds no device and fails.
The daemon then has no brightness control: the brightness keys
(`XF86MonBrightnessDown/Up`, which X receives) and the brightness slider do
nothing.

## 3. The fix

Three small functions in the FreeBSD part of the helper:

- `backlight_dev_open()` opens `/dev/backlight/backlight0` to `backlight7`
  and returns the first one whose `BACKLIGHTGETINFO` type is
  `BACKLIGHT_TYPE_PANEL` (a keyboard backlight is skipped);
- `backlight_dev_get_brightness()` returns its `brightness`;
- `backlight_dev_set_brightness()` reads the current status, changes
  `brightness` (clamped to 0-100) and writes it back.

`main()` uses them for `--get-brightness`, `--get-max-brightness` (always
100) and `--set-brightness` when such a device answers, and falls back to the
existing ACPI video code otherwise.
`--get-brightness-switch` and `--set-brightness-switch` control the ACPI
video key handling, so they keep using the ACPI device, and fail when there
is none.

The get calls run as the user: they need read access to `/dev/backlight`,
which users of group `video` have.
For other users the open fails and the helper falls back to ACPI video, as
before.
The set call runs as root through pkexec.

### 3.1 Tradeoffs

- backlight(9) is preferred whenever a panel device exists.
  On a machine where both interfaces work, a brightness key now goes through
  backlight(9) while acpi_video(4) also steps the ACPI level on its own:
  the brightness may move twice per press.
  Not seen here (the ACPI level does nothing); not tested elsewhere.
- Only the first panel device is used, like `backlight(8)` without `-f`.

### 3.2 Alternatives

| Alternative | Why not |
|---|---|
| Keyboard shortcuts calling `backlight(8)` | Works, but each user must set it up, the brightness slider stays dead and no popup shows. |
| A backlight(9) backend upstream in xfce4-power-manager | The right long-term place; the port patch already carries the FreeBSD backend, so this extends it first. |

## 4. Tested

`poudriere testport` and `bulk`, jail `builder` (16.0-CURRENT), package
`xfce4-power-manager-4.20.1_1`, installed on the laptop with `pkg add -f`,
2026-11-17.

| Configuration | Measured result |
|---|---|
| Before: `--get-max-brightness`, `--get-brightness` | exit 255, no output |
| After, as the user | `100`, exit 0; `100`, exit 0 |
| After, daemon restarted, brightness keys | the screen dims and brightens, XFCE's brightness popup shows; `backlight -f /dev/backlight/backlight0` reads 85 after the presses |

Not tested: a machine with both a working ACPI backlight and a backlight(9)
device; a user outside group `video`; Wayland sessions.

## 5. Proposed commit message

```
sysutils/xfce4-power-manager: Set brightness through backlight(9)

The FreeBSD backend of the backlight helper only knew acpi_video(4).
On panels whose ACPI methods do nothing, such as the OLED panel of an
HP ZBook Ultra G1a driven by amdgpu, the brightness keys and slider had
no effect.  Prefer a panel backlight(9) device, and keep acpi_video as
the fallback.

PR:		<bug number>
Approved by:	xfce (maintainer)
```
