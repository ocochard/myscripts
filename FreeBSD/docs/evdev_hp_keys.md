# evdev: the HP mic mute and programmable keys

Patch: [evdev_hp_keys.patch](evdev_hp_keys.patch), commit 2ee07098c642
"evdev: Map the HP mic mute and programmable keys on HP only" on FreeBSD
main, which fixes the landed d34baf1b5ca0 (#122); in review as
[#130](https://ron-dev.freebsd.org/FreeBSD/src/pulls/130).
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

The scan codes `e0 01` and `68` are vendor keys. systemd's hwdb
(`60-keyboard.hwdb`, which writes the 0xE0 code 0x01 as `81`) gives them
many meanings:

| Code | Meanings in hwdb |
|---|---|
| `e0 01` (`81`) | micmute on HP ZBook, EliteBook, ProBook, Elite Dragonfly and some others; fn_esc on consumer HP; playpause on Dell; touchpad_toggle on Alienware; insert on IdeaPad 5; rfkill on other IdeaPads; prog1 on Lenovo LOQ; `!esc` on Samsung (no release code) |
| `68` | prog1 on the Elite Dragonfly G2; `!performance` on Dell and Alienware (no release code); leftmeta or setup on ThinkPad tablets; up on an Acer; f17; unknown on the EliteBook 845 G7 |

`evdev_at_set1_scancodes[]` is one table for every AT keyboard (`atkbd`,
`kbdmux`, `hv_kbd`), so a code can only be mapped where SMBIOS names the
machine, like hwdb's DMI match:

```c
static const struct evdev_at_quirk {
	const char	*maker;		/* prefix of smbios.system.maker */
	const char	*product;	/* substring of smbios.system.product */
	uint8_t		index;
	uint16_t	keycode;
} evdev_at_quirks[] = {
	{ "HP",		"ZBook",		0x81,	KEY_MICMUTE },
	...
	{ "HP",		"ZBook Ultra G1a",	0x68,	KEY_PROG1 },
};
```

A `SYSINIT` at `SI_SUB_TUNABLES` reads `smbios.system.maker` and
`smbios.system.product` with `getenv_string()` and writes the matching
entries into the table once, before any keyboard attaches. The lookup
path is unchanged, and `evdev_support_all_known_keys()` advertises only
the keys that apply to the machine. The table entries themselves stay
`NONE`.

The key names follow hwdb: micmute for the HP business models, prog1
("HP Programmable Key") for the Elite Dragonfly G2; the ZBook Ultra G1a
sends `68` for its programmable key (measured, section 4).

`KEY_MICMUTE` is 248, and X keycodes stop at 255 (evdev key + 8 = 256).
xf86-input-libinput remaps it to keycode 198, which the XKB evdev keymap
names `XF86AudioMicMute`.

### 3.1 Tradeoffs and alternatives

| Alternative | Tradeoff |
|---|---|
| A global table entry | Gives every vendor HP's meaning: Insert toggles mic mute on an IdeaPad 5, and on Dell a key without release code leaves `KEY_PROG1` held. |
| A per-machine override from userland (`EVIOCSKEYCODE`) | The hwdb model, but `atkbd` does not implement `ev_set_keycode`, and FreeBSD has no hwdb applier in userland. Also needs force-release for the `!` keys. |
| HP WMI hotkey events (`acpi_hp`) | No key of this laptop raised a WMI event during the captures; the scancodes are already there. |

### 3.2 What the patch does not fix

- The desktop still has to act on the keys: XFCE without
  `xfce4-pulseaudio-plugin` does nothing on `XF86AudioMicMute`, and nothing
  is bound to `XF86Launch1` by default.
- The keyboard backlight key sends only a stray break code (`bf`): the
  keyboard firmware handles the backlight itself, and that works.

## 4. Tested

Laptop, 2026-11-23, kernel built from the laptop's source tree with this
`evdev_utils.c`. [evbit.c](evdev_hp_keys_evbit.c) prints, for each
`/dev/input/event*`, whether `EVIOCGBIT` reports `KEY_MICMUTE` and
`KEY_PROG1`; DTrace reads the two table entries.

| Boot | `smbios.system.product` | table `0x81` / `0x68` | AT keyboard and kbdmux advertise |
|---|---|---|---|
| normal | HP ZBook Ultra G1a 14 inch Mobile Workstation PC | 248 (`KEY_MICMUTE`) / 148 (`KEY_PROG1`) | MICMUTE, PROG1 |
| `nextboot -e smbios.system.product="Test Laptop 15"` | Test Laptop 15 | 0 / 0 | MICMUTE (from the ChromeOS `e0 1b` entry), no PROG1 |

Earlier, with the keys mapped (2026-11-17):

| Key | Measured result |
|---|---|
| mic off | `KEY_MICMUTE` (248) down and up on `AT keyboard` |
| programmable key | `KEY_PROG1` (148) down and up on `AT keyboard` |
| X (`xinput test-xi2 --root`) | keycode 198 = `XF86AudioMicMute`, keycode 156 = `XF86Launch1` |

`buildkernel GENERIC` on main: no warning. Not tested: key presses on the
new kernel (the table holds the same values as the kernel tested on
2026-11-17), other HP models.

## 5. Review

The first version (d34baf1b5ca0, #122, approved by wulf) put both codes
in the global table. The FreeBSD commit review then reported both
problems of section 3.1 (POSTCR-d34baf1b5ca0...-1 and -2); this commit is
the fix.
