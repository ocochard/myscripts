# fwget: firmware for ACPI-only devices

Patch: [fwget_acpi.patch](fwget_acpi.patch) (commit d39f06e50dcd
`fwget: Add ACPI device support`), for FreeBSD main of 2026-11-20.
Machine: HP ZBook Ultra G1a 14, whose four Cirrus Logic CS35L54 speaker
amplifiers (ACPI `CSC3554`) need a firmware package
([cs35l54_speaker_amp.md](cs35l54_speaker_amp.md)).

Written for a first-year computer science student who knows C and what an
operating system does, but not how FreeBSD finds firmware.

## 1. Background

### 1.1 Firmware packages and fwget(8)

Many devices run code of their own that the driver must upload: Wi-Fi
chips, GPUs, audio amplifiers. FreeBSD ships that code as packages
(`gpu-firmware-amd-kmod`, `wifi-firmware-mt76-kmod`, ...). `fwget(8)`
(`usr.sbin/fwget/`) looks at the hardware present and installs the
matching packages, so a user does not have to know which one a chip needs.

### 1.2 Subsystems and vendor scripts

`fwget.sh` walks a list of *subsystems*, `pci` and `usb` on main. Each
subsystem is a shell file in `/usr/libexec/fwget/` that lists device ids
(for PCI, from `pciconf -l`), maps each vendor id to a vendor script
(`pci_video_amd`, `usb_ralink`, ...), and the vendor script calls
`addpkg` with the package name for a device id. At the end `fwget` runs
one `pkg install` for every package collected.

### 1.3 Devices with only an ACPI id

Some devices are on neither bus. The CS35L54 amplifiers sit on an I2C bus
and are described only by ACPI, with a hardware id (`_HID`) of
`CSC3554`. No PCI or USB id exists, so `fwget` never saw them.
`devinfo -v` prints every device with its ACPI `pnpinfo`, attached or
not: `acpi_pnpinfo()` (`sys/dev/acpica/acpi.c`) writes
`_HID=... _UID=... _CID=...`, and `acpi_iicbus` appends the same string
for its I2C children.

## 2. The problem

On the ZBook, `fwget -n` (print, do not install) on main lists only the
Wi-Fi firmware; the amplifier firmware is never proposed:

```
$ fwget -n
Needed firmware packages: 'wifi-firmware-mt76-kmod-mt7925'
```

## 3. The fix

A third subsystem, `acpi`, searched by default:

- `acpi/acpi`: takes every `_HID=` value from `devinfo -v`, maps its
  vendor prefix (`CSC` for Cirrus Logic) to a vendor script, and calls it,
  the same structure as `usb` and `usb_ralink`;
- `acpi/acpi_cirrus`: `CSC3554` gives `sound-firmware-cirrus-cs35l54`;
- `fwget.sh` and `fwget.8` list `acpi` with `pci` and `usb`.

### Ordering: this commit must land last

`fwget` installs every package it found with one `pkg install`, and pkg
rejects the whole job when one name is unknown. Until the package
`sound-firmware-cirrus-cs35l54` exists in the repositories, plain
`fwget` on this laptop would fail to install anything, the Wi-Fi and GPU
firmware included. The package is also useless without the
`snd_cs35l54` driver. So the order is: the `audio/sound-firmware-cirrus`
port, the `snd_cs35l54` driver, then this commit.

### Alternatives

- Land the `acpi` subsystem without the `CSC3554` mapping: an empty
  subsystem with no user; a reviewer would ask what it is for.
- Install packages one by one so a missing name does not block the others:
  a behaviour change of `fwget` for every user, out of scope here.

## 4. Tested

HP ZBook Ultra G1a, 2026-11-22, the patched `fwget.sh` and scripts copied
to `/tmp` (with `LIBEXEC_PATH` pointing there), dry runs only:

| Run | Result |
|---|---|
| stock `fwget -n` | `'wifi-firmware-mt76-kmod-mt7925'` |
| patched `fwget -n` | `'sound-firmware-cirrus-cs35l54 wifi-firmware-mt76-kmod-mt7925'` |
| patched `fwget -n -v acpi` | `Trying to match device CSC3554 with acpi_cirrus`, then the Cirrus package |
| `pkg search sound-firmware-cirrus` | no result: the package is not in a repository yet (why the commit waits) |

Untested: an actual `pkg install` (no repository has the package), other
ACPI vendors, FDT systems (no `_HID=`: the subsystem finds nothing).
