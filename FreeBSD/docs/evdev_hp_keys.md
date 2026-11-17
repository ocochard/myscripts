# evdev: the HP mic mute and programmable keys

Patch: [evdev_hp_keys.patch](evdev_hp_keys.patch), commit 81b24a701a44
"evdev: Map the HP mic mute and programmable keys" on FreeBSD main
46ce9acd6d15 (branch `olivier-evdev-hp-keys` of
github.com/ocochard/freebsd-src; in branch `zbook` as 0d71515aee38).
Machine: HP ZBook Ultra G1a.

This document explains the work for a first-year computer science student:
someone who knows C and what an operating system does, but has never looked
at how a key press reaches a FreeBSD desktop.

## 1. Background

### 1.1 From a key to a scancode

A laptop keyboard is wired to the embedded controller, which emulates the
old PC keyboard controller (i8042).
For every key it sends *scancodes*: one byte when the key goes down (the
"make" code) and the same byte with bit 7 set when it goes up (the "break"
code).
Keys added after the original PC keyboard use a two-byte code that starts
with the prefix 0xE0.
For example, the mute key of this laptop sends `e0 20` when pressed and
`e0 a0` when released.

FreeBSD's `atkbd(4)` driver reads these bytes (`atkbd_read_char()`).

### 1.2 From a scancode to an evdev key

Desktops (X with libinput, Wayland compositors) read keys from evdev devices
(`/dev/input/eventN`), where each key has a number defined by Linux's
`input-event-codes.h`, such as `KEY_MUTE` (113).
atkbd translates scancodes into these numbers with one table,
`evdev_at_set1_scancodes[]` in `sys/dev/evdev/evdev_utils.c`: 128 entries
for the one-byte codes, then 128 for the 0xE0-prefixed ones
(`evdev_scancode2key()`, line 242).
A scancode whose entry is `NONE` is dropped: the key reaches no program.

Linux keeps such vendor-specific mappings out of the kernel: systemd's hwdb
(`hwdb.d/60-keyboard.hwdb`) adds them per machine at run time.
FreeBSD has no hwdb, so the table is the only place to add them.

## 2. The problem

Two keys of the laptop's top row did nothing.
A dtrace probe on the return value of `atkbd_read_char()` showed what they
send:

| Key | Scancodes (make / break) | Table entry |
|---|---|---|
| mic off | `e0 01` / `e0 81` | 0x81 (0xE0 block, entry 0x01): `NONE` |
| HP programmable key | `68` / `e8` | 0x68: `NONE` |
| mute (reference) | `e0 20` / `e0 a0` | `KEY_MUTE` |

A capture of `/dev/input/event4` (`AT keyboard`) during the presses showed
no event for the first two keys.

## 3. The fix

```diff
 	/* 0x60 - 0x7f */
 	NONE,		NONE,		NONE,		NONE,
 	NONE,		NONE,		NONE,		NONE,
-	NONE,		NONE,		NONE,		NONE,
+	KEY_PROG1,	NONE,		NONE,		NONE,		/* 0x68: HP */
 ...
 	/* 0x00 - 0x1f. 0xE0 prefixed */
-	NONE,		NONE,		NONE,		NONE,
+	NONE,		KEY_MICMUTE,	NONE,		NONE,		/* 0x01: HP */
```

The key names follow systemd's hwdb: `KEYBOARD_KEY_81=micmute` in its block
for HP ZBooks, EliteBooks and ProBooks (hwdb writes the 0xE0 code 0x01 as
0x81), and `KEYBOARD_KEY_68=prog1` ("HP Programmable Key") in its block for
the Elite Dragonfly G2.

`KEY_MICMUTE` is 248, and X keycodes stop at 255 (evdev key + 8 = 256).
xf86-input-libinput remaps it to keycode 198, which the XKB evdev keymap
names `XF86AudioMicMute`; that is what X delivered in the test.

### 3.1 Tradeoffs and alternatives

| Alternative | Tradeoff |
|---|---|
| This table entry | Global: every AT keyboard that sends `e0 01` or `68` now reports these keys. systemd's generic HP block maps `e0 01` to `fn_esc` instead, and other vendors may use the codes for other keys. There is precedent: the same table maps the ChromeOS EC codes `e0 11` to `e0 1e`. |
| A per-machine override from userland | Would be the hwdb model, but atkbd's evdev device does not implement `EVIOCSKEYCODE`, so there is no interface for it today. |
| HP WMI hotkey events (`acpi_hp`) | No key of this laptop raised a WMI event during the captures; the scancodes are already there. |

### 3.2 What the patch does not fix

- The desktop still has to act on the keys: XFCE without
  `xfce4-pulseaudio-plugin` does nothing on `XF86AudioMicMute`, and nothing
  is bound to `XF86Launch1` by default.
- The keyboard backlight key sends only a stray break code (`bf`): the
  keyboard firmware handles the backlight itself, and that works.

## 4. Tested

Laptop, 2026-11-17, kernel `zbook-n291269-0d71515aee38` (branch `zbook`).

| Configuration | Measured result |
|---|---|
| Before, mic off and programmable key | no event on `/dev/input/event4` |
| After, mic off | `KEY_MICMUTE` (248) down and up on `AT keyboard` |
| After, programmable key | `KEY_PROG1` (148) down and up on `AT keyboard` |
| After, X (`xinput test-xi2 --root`) | keycode 198 = `XF86AudioMicMute`, keycode 156 = `XF86Launch1` |

Not tested: other keyboards that may send `e0 01` or `68`.
