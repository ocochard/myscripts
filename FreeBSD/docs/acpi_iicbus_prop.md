# acpi_iicbus: device properties of I2C devices froze the machine

Patch: [acpi_iicbus_prop.patch](acpi_iicbus_prop.patch), two commits for
FreeBSD main of 2026-11-20: `acpi_iicbus: Free the ivars of deleted
children` (a leak since 9b7938dcf338: `acpi_iicbus_child_deleted()`
replaced `iicbus_child_deleted()` without calling it, and used the ivars
without a NULL check), then `acpi_iicbus: Return _DSD properties of the
I2C children`, explained below.
Machine: HP ZBook Ultra G1a 14 (AMD Ryzen AI Max+ PRO 395); the device
used for the test is the CS35L54 speaker amplifier node `\_SB_.I2CB.SPKR`
behind the `ig4iic1` I2C controller.

Written for a first-year computer science student who knows C and what an
operating system does, but not FreeBSD's device tree.

## 1. Background

### 1.1 The device tree and ivars

FreeBSD keeps devices in a tree: `acpi0` has children such as `ig4iic1`
(an I2C controller), which has a child `iicbus18`, which has children such
as `cs35l540` (the amplifier driver). Each device has a parent bus, and the
bus stores per-child private data called *ivars* (`device_get_ivars()`).
Each bus decides what its ivars are: `acpi(4)` uses a `struct
acpi_device`, `acpi_iicbus` uses a `struct acpi_iicbus_ivars` (the I2C
address plus the ACPI handle, `sys/dev/iicbus/acpi_iicbus.c:73`). Only
the bus that created a child knows what its ivars are.

### 1.2 Device properties and _DSD

`device_get_property(dev, name, ...)` (`sys/kern/subr_bus.c:2328`) asks
for a named property of a device, such as `"cirrus,dev-index"`. It calls
the `bus_get_property` method of the device's parent. A bus that does not
implement it inherits `bus_generic_get_property()` (`subr_bus.c:3885`),
which forwards the request to its own parent, with the same child.

On ACPI systems the properties come from the device's `_DSD` object
("Device Specific Data"): a package of name/value pairs. `acpi(4)` answers
with `acpi_bus_get_prop()` (`sys/dev/acpica/acpi.c`), which reads the
child's ivars as a `struct acpi_device`, evaluates `_DSD` on its handle
(`acpi_find_dsd()`) and caches the result in that structure.

## 2. The problem

`acpi_iicbus` has no `bus_get_property` method. So for an I2C device:

```mermaid
flowchart LR
  D["device_get_property(cs35l540)"] --> I["iicbus18 (acpi_iicbus)<br/>no method: bus_generic_get_property"]
  I --> G["ig4iic1<br/>bus_generic_get_property"]
  G --> A["acpi0: acpi_bus_get_prop(child = cs35l540)"]
  A --> X["device_get_ivars(cs35l540) read as struct acpi_device<br/>but it is struct acpi_iicbus_ivars"]
```

`acpi_bus_get_prop()` then follows the fields of a structure that is not
there. Since `device_get_property()` was added (3f9a00e3b577), any
property request on a device below `acpi_iicbus` reached this code. On the
ZBook, the first version of the CS35L54 driver read `cirrus,dev-index` this
way and the laptop froze at `kldload`
([cs35l54_speaker_amp.md](cs35l54_speaker_amp.md), section 3.4). The
driver now evaluates `_DSD` itself to avoid it.

## 3. The fix

`acpi_iicbus` answers for its own children:

```c
static ssize_t
acpi_iicbus_get_property(device_t bus, device_t child, const char *propname,
    void *propvalue, size_t size, device_property_type_t type)
{
	struct acpi_iicbus_ivars *devi;

	/* Deeper devices do not carry our ivars. */
	if (device_get_parent(child) != bus)
		return (-1);
	devi = device_get_ivars(child);
	if (devi->handle == NULL)
		return (-1);
	devi->ad.ad_handle = devi->handle;
	return (acpi_ad_get_property(&devi->ad, propname, propvalue, size,
	    type));
}
```

- The ivars get a `struct acpi_device ad` used only as the `_DSD` cache;
  `acpi_iicbus_child_deleted()` frees the cached buffer.
- `acpi.c` already had all the `_DSD` parsing; it is split so the part
  that works on a `struct acpi_device` is exported as
  `acpi_ad_get_property()`. `acpi_bus_get_prop()` now just passes its
  child's ivars to it, so acpi's own behaviour does not change.
- A request for a device deeper than the I2C children (for example the
  children of an I2C mux) now gets -1 instead of reaching acpi with
  foreign ivars.

### Alternatives

- Refuse, in `acpi_bus_get_prop()`, every child that is not a direct
  child of acpi. This was the first version. It breaks DPAA2:
  `dpaa2_mc_acpi` and `memac_mdio_acpi` give their own children a real
  `struct acpi_device` and forward property requests to acpi, which
  then must answer for those grandchildren (`dpaa2_mac_dev` reads `reg`,
  `memacphy_acpi` reads `phy-channel`).
- Return -1 from `acpi_iicbus` for everything: no freeze, but I2C drivers
  get no properties, while ACPI describes them for these devices.

### What it does not fix

Other buses that forward requests to acpi with foreign ivars keep the
problem: for example `acpi_gpiobus` children, or a PHY under `miibus`
whose request climbs to acpi. Each such bus needs its own method.


## 4. Tested

Test module [acpi_iicbus_prop_test.c](acpi_iicbus_prop_test.c)
([Makefile](acpi_iicbus_prop_test.Makefile)): on load it calls
`device_has_property()` and `device_get_property()` on `cs35l540` (child
of `iicbus18`), prints the `cirrus,dev-index` package, then asks for a
property that does not exist.

| Kernel | Result |
|---|---|
| ZBook kernel with the first version (direct-child check in acpi) | `has` 0, `get` -1: no freeze, no data |
| Test kernel (ZBook source, first version reverted, this patch), loaded twice | `has` 1, `get` 8 (one `ACPI_OBJECT *`), package `0x30 0x31 0x32 0x33`, missing property -1 |
| Stock main | freeze at the first request (see section 2; not repeated) |

The four values are the I2C addresses of the four amplifiers, the same
data the CS35L54 driver reads by evaluating `_DSD` itself. The test kernel
booted with Wi-Fi, amdgpu, amdsmu, the touchpad and `snd_cs35l54`
attached, and no fault in the log.

Child deletion: [acpi_iicbus_prop_deltest.sh](acpi_iicbus_prop_deltest.sh)
runs 20 cycles of `kldunload ig4` / `kldload ig4` (which deletes and
re-creates every `acpi_iicbus` child), loading the test module first each
time so the `cs35l540` `_DSD` cache is filled before its deletion, and
prints the `devbuf` and `acpica` malloc types (`vmstat -m`, in-use count)
before and after:

| Kernel | `devbuf` in use, before / after 20 cycles |
|---|---|
| ZBook kernel (no fix) | 2828 / 3928 (+55 per cycle) |
| Test kernel with both commits, run 1 | 2827 / 2827 |
| same, run 2 | 2827 / 2827 |

`acpica` ended 50 lower than at the start in both kernels (start-up
noise, unrelated). With both commits, the 20 `device_get_property()` calls
returned the package each time, the touchpad and amplifiers reattached
after every cycle, and there was no fault in the log.

Both commits build (`buildkernel GENERIC-NODEBUG`, each commit, no
warning). Untested: DPAA2 (no hardware; this patch does not change its
path).
