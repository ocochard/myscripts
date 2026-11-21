# amdgpio: let devmatch(8) load the AMD GPIO driver

Patch: [amdgpio_pnp.patch](amdgpio_pnp.patch) (commit
`amdgpio: Add PNP info for devmatch`), for FreeBSD main of 2026-11-20.
Machine: HP ZBook Ultra G1a 14 (AMD Ryzen AI Max+ PRO 395), GPIO
controller `AMDI0030` at `\_SB_.GPIO`.

Written for a first-year computer science student who knows C and what an
operating system does, but not how FreeBSD picks drivers.

## 1. Background

### 1.1 Drivers built in, or loaded as modules

A FreeBSD driver is either compiled into the kernel (listed in the kernel
configuration, such as `sys/amd64/conf/GENERIC`) or built as a module
(`amdgpio.ko`) that must be loaded before it can attach. `amdgpio` is only
a module: `GENERIC` has no `device amdgpio` line, and
`sys/modules/Makefile` builds it.

### 1.2 How a module gets loaded without the user asking

At boot, `devmatch(8)` walks the device tree, takes every device that no
driver attached, and looks up its identifiers in
`/boot/kernel/linker.hints`. That file is built by `kldxref(8)` from a
table each module exports with the `MODULE_PNP_INFO()` family of macros.
For ACPI devices, `ACPI_PNP_INFO(table)` (`sys/dev/acpica/acpivar.h:258`)
exports a list of `_HID` strings. A module without such a table is never
proposed by devmatch: the only ways to load it are `kld_list` in
`/etc/rc.conf`, `loader.conf`, or `kldload` by hand.

### 1.3 Who needs the GPIO controller

ACPI describes GPIO lines that other devices use: reset lines, interrupt
lines, power enables. A driver that wants such a line asks the GPIO
controller driver for it. If `amdgpio` is not loaded, there is no
controller and the consumer fails. On the ZBook the four Cirrus Logic
CS35L54 speaker amplifiers have their reset line on this controller
([cs35l54_speaker_amp.md](cs35l54_speaker_amp.md)).

## 2. The problem

`amdgpio_probe()` (`sys/dev/amdgpio/amdgpio.c`) matched `AMD0030` and
`AMDI0030` with a table local to the function, and the module exported no
PNP info. So `linker.hints` has no entry for it, and devmatch never
proposes it:

```
$ devmatch -a -h /boot/kernel/linker.hints | grep amdgpio      # stock main
$
```

The controller stays unattached unless `amdgpio` is in `kld_list`.

## 3. The fix

```diff
+static char *amdgpio_ids[] = { "AMD0030", "AMDI0030", NULL };
+
 static int
 amdgpio_probe(device_t dev)
 {
-	static char *gpio_ids[] = { "AMD0030", "AMDI0030", NULL };
 ...
-	rv = ACPI_ID_PROBE(device_get_parent(dev), dev, gpio_ids, NULL);
+	rv = ACPI_ID_PROBE(device_get_parent(dev), dev, amdgpio_ids, NULL);
 ...
 MODULE_VERSION(amdgpio, 1);
+ACPI_PNP_INFO(amdgpio_ids);
```

The id table moves to file scope so the same table serves the probe and
the PNP export; the two can never disagree. The table stays
NULL-terminated, which `ACPI_ID_PROBE()` needs and `ACPI_PNP_INFO()`
accounts for. `bytgpio.c` (`ACPI_PNP_INFO(bytgpio_gpio_ids)`) does the
same.

### Alternatives

- `device amdgpio` in `GENERIC`: loads it on every amd64 machine, Intel
  ones included; a module loaded on demand costs nothing elsewhere.
- Keep `kld_list`: works, but every AMD user must know about it.

### What it does not do

- It does not make ACPI GPIO events (`_AEI`) work: `gpioaei` is a separate
  module without PNP info, and amd64 has no interrupt support for GPIO
  pins in main (`gpio_alloc_intr_resource()` is a stub returning NULL
  without INTRNG). That is the separate amdgpio interrupt series.
- Scope: `AMD0030`/`AMDI0030` exist on almost every Ryzen system, so
  `amdgpio` will now attach on all of them, with its interrupt filter and
  its suspend/resume code, not only where a user added it to `kld_list`.

## 4. Tested

| Check | Result |
|---|---|
| `devmatch -a -h <hints>` with the stock main kernel's `linker.hints` | no `amdgpio` line |
| same with the patched kernel's `linker.hints` (`/boot/kernel.zbook`) | `gpio0: amdgpio.ko` |
| `amdgpio` attaches, `gpio0 <AMD GPIO Controller> ... _HID=AMDI0030` | yes (`devinfo -v`) |
| Boot without `amdgpio` in `kld_list`, module loaded by devmatch alone | untested: the ZBook still lists it in `kld_list` |
| Other Ryzen systems (`AMD0030`) | untested |
