# devmatch: autoload the drivers that live under hostb and vgapci

Patch: [devmatch_hostb.patch](devmatch_hostb.patch), three commits on FreeBSD
main 46ce9acd6d15 (branch `olivier-devmatch-hostb` of
github.com/ocochard/freebsd-src; also in branch `zbook`):

| Commit | In `zbook` | Subject |
|---|---|---|
| 96aeddeb3a89 | 04cef57b2fbd | devmatch: Match host bridges owned by hostb(4) |
| 0198596f053b | ef7dbe879735 | devmatch: Match hostb and vgapci children on their own bus |
| 7d6d31baace6 | 8d9d9ecc4441 | acpi_video: Let devmatch load the module |

Machine: HP ZBook Ultra G1a, AMD Ryzen AI Max (Strix Halo).

This document explains the work for a first-year computer science student:
someone who knows C and what an operating system does, but has never looked
at how FreeBSD loads drivers.

## 1. Background

### 1.1 Devices, drivers and modules

At boot the kernel builds a tree of devices: `nexus0`, `acpi0`, `pci0`,
and one node per PCI function or ACPI device under them.
Each node gets a driver if one of the drivers already in the kernel accepts
it in its `probe` method; the others stay "unknown" (`devinfo -v` prints
them as `unknown pnpinfo ...`).

Most drivers are not in the kernel but in modules (`.ko` files in
`/boot/kernel`).
`devmatch(8)` (`sbin/devmatch/devmatch.c`) decides which modules to load.
Each module carries a table of the IDs it supports, declared with
`MODULE_PNP_INFO()` together with the name of a bus; `kldxref(8)` copies
these tables into `/boot/kernel/linker.hints`.
devmatch walks the device tree, and for every device without a driver it
looks for a module whose table is for the device's bus and matches the
device's IDs (`find_unmatched()`, `devmatch.c:477`).
At boot, `/etc/rc.d/devmatch` loads every module it prints.

### 1.2 Bus drivers: hostb(4) and vgapci(4)

Two generic PCI drivers exist only to be the bus of more specific drivers:

- `hostb(4)` (`sys/dev/pci/hostb_pci.c:287`) attaches to every *host
  bridge* (the root complex, PCI function 0:0:0).
  On AMD the host bridge is also the door to the System Management Network
  (SMN), through which software reaches the temperature sensors and the
  System Management Unit (SMU).
- `vgapci(4)` attaches to every display controller; drm drivers such as
  amdgpu, and `acpi_video(4)`, attach as its children.

The drivers that attach under them create their own child device from their
`identify` method, which runs when the driver is added to the bus, that is,
when their module is loaded (`amdsmu_identify()`,
`sys/dev/amdsmu/amdsmu.c:55`):

| Driver | Parent | What it does | Table before the patch |
|---|---|---|---|
| `amdsmn(4)` | hostb | SMN register access | host bridge IDs, bus `pci` |
| `amdtemp(4)` | hostb | CPU temperature | host bridge IDs, bus `pci` |
| `amdsmu(4)` | hostb | SMU: S0i3 residency and blockers | host bridge IDs, bus `pci` |
| `acpi_video(4)` | vgapci | brightness keys and ACPI backlight | none |
| amdgpu (drm-kmod) | vgapci | the GPU | GPU IDs, bus `pci` (LinuxKPI `MODULE_DEVICE_TABLE(pci, ...)`) |

`acpi_video` has no table because no device ID identifies it: its probe
accepts any display controller whose ACPI node has the `_DOD` and `_DOS`
methods (`sys/dev/acpica/acpi_video.c:292`).

## 2. The problem

None of the hostb or vgapci children is ever loaded by devmatch.
devmatch skips a device that has a driver (`devmatch.c:483`) or had one
once (`DF_ATTACHED_ONCE`, `devmatch.c:487`), and hostb or vgapci always owns
the device; the children that would really need the module do not exist
before it is loaded.

On the laptop (`hostb0` is 1022:1507, the Strix Halo root complex):

```
$ devmatch -a | grep -E 'amdsmu|amdtemp'
amdsmu.ko
amdtemp.ko
$ devmatch | grep -E 'amdsmu|amdtemp'
$
```

Without amdsmu, every resume prints:

```
acpi0: Resumed from suspend-to-idle on AMD processor but amdsmu(4) is not
attached; unable to verify S0i3 entry.
```

Without acpi_video, the brightness keys do nothing at all: the firmware
reports them as ACPI notifications 0x86 and 0x87 on the panel device
(`\_SB.PCI0.GPPA.GFX0.LCD_`), and only acpi_video registers for them.

The usual workaround is `kld_list="amdtemp amdsmu acpi_video"` in
`/etc/rc.conf`, which each user must know about.

## 3. The fix

### 3.1 devmatch

devmatch now treats a device owned by hostb or vgapci as if it had no
driver, and looks it up in the hints for *that driver's* bus, `hostb` or
`vgapci`, instead of its parent's bus `pci`:

```c
	busdrv = !unbound_flag && (strcmp(dev->dd_drivername, "hostb") == 0 ||
	    strcmp(dev->dd_drivername, "vgapci") == 0);
	do {
		if (!all_flag && !busdrv && dev->dd_name[0] != '\0')
			break;
		...
		if (!all_flag && !busdrv && dev->dd_flags & DF_ATTACHED_ONCE)
			break;
		parent = devinfo_handle_to_device(dev->dd_parent);
		bus = strdup(busdrv ? dev->dd_drivername : parent->dd_name);
```

Why the driver's own bus: the first version of the patch (commit
96aeddeb3a89) matched a host bridge against the `pci` hints.
Extending that to vgapci would have matched the display controller against
amdgpu's `pci` table, so devmatch would start loading drm drivers by itself.
drm is not autoloaded on purpose (it needs packages and firmware, and on
this very laptop the stock amdgpu panics when it loads).
With the bus named after hostb or vgapci, only tables written for drivers
that attach there can match.

`-u` (list devices that no module matches) is left alone: a host bridge or
a display controller with nothing behind it is not an unattached device.

### 3.2 The drivers' tables

- amdtemp, amdsmn and amdsmu declare their table for bus `hostb` instead
  of `pci`, the bus their driver really attaches to.
- acpi_video declares a one-entry table for bus `vgapci` that matches any
  display controller, using the literal key match `T:class=0x03` (the PCI
  base class 0x03, display; the same mechanism iwm(4) uses for
  `T:vendor=0x8086`).
  The probe then decides; on a machine without the ACPI methods the module
  is loaded but attaches to nothing.

Loading a module again is harmless: `load_kld` in `rc.subr` skips a module
that is already loaded, and hostb or vgapci itself is never replaced.

### 3.3 Alternatives

| Alternative | Why not |
|---|---|
| `kld_list` in `rc.conf` | Works, but every user must find out about it. |
| `devmatch -a` in `rc.d/devmatch` | Loads modules for every device that already has a driver, for example a second driver for the same NIC. |
| Keep matching on the parent's bus `pci` | Also loads drm drivers for the display controller (section 3.1). |
| `device acpi_video` in GENERIC | Changes every amd64 kernel; still leaves the hostb modules. |
| Attach amdsmu to its ACPI device (`AMDI000B`, which Linux amd-pmc uses) | `acpi_spmc(4)` already owns that device, and amdsmu needs the host bridge for SMN access. |

### 3.4 What the patch does not fix

- `devd(8)` nomatch events (`devmatch -p`) are unchanged: they describe one
  unattached device, never a host bridge or a display controller.
- amdsmu on stock main does not list the Strix Halo root complex 1022:1507;
  that comes from branch `olivier-amdsmu-strixhalo`.
- On this OLED panel the ACPI backlight (`hw.acpi.video.lcd0.brightness`,
  firmware method `_BCM`) changes nothing; the panel dims through amdgpu
  (`/dev/backlight/backlight0`).
  acpi_video only turns the keys into `KEY_BRIGHTNESSDOWN`/`UP` events, and
  the desktop must apply them with `backlight(8)`.

## 4. Tested

Laptop, 2026-11-17, kernel `zbook-n291269-0d71515aee38` (branch `zbook`)
as the default boot kernel, devmatch from the same branch as
`/sbin/devmatch`; none of the modules below in `kld_list` or `loader.conf`.

| Configuration | Measured result |
|---|---|
| Stock devmatch, all modules already loaded | prints nothing |
| First version (`pci` bus), same state | `amdsmn.ko amdsmu.ko amdtemp.ko` |
| `devmatch -v`, final version | `Searching hostb0 hostb bus ... vendor=0x1022 device=0x1507`, `Searching vgapci0 vgapci bus ... class=0x038000` |
| Boot, final version | `acpi_video.ko`, `amdsmu.ko`, `amdtemp.ko` and `amdsmn.ko` loaded; `amdsmu0: <AMD System Management Unit> on hostb0`, SMU version 100.7.0; new evdev device `ACPI video extension` |
| `devmatch` after boot | `acpi_video.ko amdsmn.ko amdsmu.ko amdtemp.ko`, not amdgpu (amdgpu loads from `kld_list` only) |
| Brightness keys after boot | `KEY_BRIGHTNESSDOWN` and `KEY_BRIGHTNESSUP` on `ACPI video extension`; X receives `XF86MonBrightnessDown/Up` (keycodes 232, 233) |
| `devmatch -u`, stock vs first version | identical output |

Not tested: Intel host bridges and other display controllers; a machine
whose firmware lacks `_DOD`/`_DOS` (acpi_video should load and not attach).
