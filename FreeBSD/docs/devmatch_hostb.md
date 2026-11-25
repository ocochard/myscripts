# devmatch: autoload the drivers that live under hostb

Patch: [devmatch_hostb.patch](devmatch_hostb.patch), one commit on FreeBSD
main 655407eeea5b, the version under review:

| Commit | Subject |
|---|---|
| 4d3d79812920 | devmatch: Match hostb(4) devices |

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
device's IDs (`find_unmatched()`, `devmatch.c:486`).
At boot, `/etc/rc.d/devmatch` loads every module it prints.

### 1.2 A bus driver: hostb(4)

`hostb(4)` (`sys/dev/pci/hostb_pci.c:287`) attaches to every *host bridge*
(the root complex, PCI function 0:0:0) only to be the bus of more specific
drivers.
On AMD the host bridge is also the door to the System Management Network
(SMN), through which software reaches the temperature sensors and the
System Management Unit (SMU).

The drivers that attach under hostb create their own child device from
their `identify` method, which runs when the driver is added to the bus,
that is, when their module is loaded (`amdsmu_identify()`,
`sys/dev/amdsmu/amdsmu.c:55`):

| Driver | What it does | Table before the patch |
|---|---|---|
| `amdsmn(4)` | SMN register access | host bridge IDs, bus `pci` |
| `amdtemp(4)` | CPU temperature | host bridge IDs, bus `pci` |
| `amdsmu(4)` | SMU: sleep hint, S0i3 residency and blockers | host bridge IDs, bus `pci` |

## 2. The problem

devmatch never loads these modules.
It skips a device that has a driver or had one once (`DF_ATTACHED_ONCE`),
and hostb always owns the host bridge; the children that would really need
the module do not exist before it is loaded.

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

and suspend-to-idle never sends the SMU its sleep hint.
The usual workaround is `kld_list="amdtemp amdsmu"` in `/etc/rc.conf`, which
each user must know about.

## 3. The fix

### 3.1 devmatch

devmatch now treats a device owned by hostb as if it had no driver, and
looks it up in the hints for bus `hostb` instead of its parent's bus `pci`:

```c
	busdrv = !unbound_flag && strcmp(dev->dd_drivername, "hostb") == 0;
	do {
		if (!all_flag && !busdrv && dev->dd_name[0] != '\0')
			break;
		...
		if (!all_flag && !busdrv && dev->dd_flags & DF_ATTACHED_ONCE)
			break;
		parent = devinfo_handle_to_device(dev->dd_parent);
		bus = strdup(parent->dd_name);
		...
		/* -a still reports the matches on the parent bus. */
		if (!busdrv || all_flag)
			search_bus(dev, bus);
		if (busdrv)
			search_bus(dev, dev->dd_drivername);
```

`devmatch -a` (list matches for every device, attached or not) searches a
host bridge in both: the parent bus `pci`, as before, and `hostb`.

Why a bus of its own instead of the `pci` hints: a `pci` table names a
device that the driver attaches to directly. Matching an attached host
bridge against those tables would load any module that lists the host
bridge ID. With the tables declared for bus `hostb`, only drivers written
to attach below hostb can match.

`-u` (list devices that no module matches) is left alone: a host bridge
with nothing behind it is not an unattached device.

### 3.2 The drivers' tables

amdtemp, amdsmn and amdsmu declare their table for bus `hostb` instead of
`pci`, the bus their driver really attaches to.

Loading a module again is harmless: `load_kld` in `rc.subr` skips a module
that is already loaded, and hostb itself is never replaced.

### 3.3 Alternatives

| Alternative | Why not |
|---|---|
| `kld_list` in `rc.conf` | Works, but every user must find out about it. |
| `devmatch -a` in `rc.d/devmatch` | Loads modules for every device that already has a driver, for example a second driver for the same NIC. |
| Match attached host bridges against the `pci` hints | Loads any module whose `pci` table lists the host bridge, not only the drivers that attach below hostb (section 3.1). |
| Attach amdsmu to its ACPI device (`AMDI000B`, which Linux amd-pmc uses) | `acpi_spmc(4)` already owns that device, and amdsmu needs the host bridge for SMN access. |

### 3.4 What the patch does not cover

- `acpi_video(4)`, which turns the brightness keys into events, attaches
  below `vgapci(4)` and has the same problem. Matching vgapci the same way,
  with a `T:class=0x03` table in acpi_video, loads it at boot. wulf
  objected in review: autoloading acpi_video "can break display brightness
  control on systems that support ACPI-controlled brightness due to driver
  loading order dependency. We must switch to backlight(8) before". So it
  is not in this patch, and the laptop still needs
  `kld_list="acpi_video"` for its brightness keys.
- `devd(8)` nomatch events (`devmatch -p`) are unchanged: they describe one
  unattached device, never a host bridge.
- amdsmu on stock main does not list the Strix Halo root complex 1022:1507;
  that comes from PR #129.

## 4. Tested

Laptop, 2026-11-25, kernel `zbook-n291269-0d71515aee38`, whose
`linker.hints` has the `hostb` tables; devmatch built from the same diff as
4d3d79812920 and run from `/tmp`, devd stopped:

| Test | Measured result |
|---|---|
| Installed devmatch (hostb and vgapci matching) | `amdsmn.ko amdsmu.ko amdtemp.ko acpi_video.ko` |
| `devmatch`, this patch | `amdsmn.ko amdsmu.ko amdtemp.ko` |
| `devmatch -v`, this patch | 13 `Searching bus hostb dev hostbN` lines (hostb0 is 1022:1507), no vgapci search |
| `kldunload amdsmu acpi_video`, then the `rc.d/devmatch` loop with this patch | amdsmu loaded, `amdsmu0: <AMD System Management Unit> on hostb0`, SMU version 100.7.0; acpi_video not loaded |
| `devmatch -a`, this patch | `hostb0: amdsmn.ko`, `amdsmu.ko`, `amdtemp.ko`; no drm module |

Not tested: Intel host bridges.

## 5. Review

[#123](https://ron-dev.freebsd.org/FreeBSD/src/pulls/123):

- imp: "I like all but the devmatch stuff. I don't understand how that
  works", on the acpi_video table ("I didn't think devd could match on the
  description"). That table is no longer in the patch.
- wulf: acpi_video autoload breaks ACPI brightness through load order; see
  section 3.4.
