# acpi_spmc: accept Intel constraints without a device-specific state

Patch: [`acpi_spmc_intel_constraints.patch`](acpi_spmc_intel_constraints.patch), commit 0f969b17ba76 on main d5f0768e13f3
(tested build: same change on base 6dc19a71f70c).
Machine: Intel NUC 13 Pro (see [../Intel.NUC13.Pro.md](../Intel.NUC13.Pro.md)).

In short: the firmware sends FreeBSD a list of power rules, one per device. The Intel specification says each rule
has two numbers and an optional third one. FreeBSD required the third number, so it rejected 84 of the 119 rules
and printed one warning per rejected rule at every boot. The patch makes the third number optional.

## Background

### Low-power idle and device constraints

Modern laptops and mini PCs can sleep without leaving S0, the running state: the OS stops the devices, and the CPU and
chipset drop into a very deep idle state ("S0ix", "suspend-to-idle", "Modern Standby").
The chipset reaches that deep state only if every device is already in a low-power state.
The firmware publishes these rules, called device constraints: for each device, the shallowest power state
(D0 = on, D3 = off) that still lets the platform reach low-power idle.
An OS can use them to find the device that blocks the deep state.

### The PEP device and its _DSM

The firmware exposes these rules through an ACPI device with the ID `PNP0D80`, often called the PEP device
(`\_SB.PEPD` on this NUC). ACPI devices can carry a `_DSM` (Device Specific Method): a function in the firmware's AML
bytecode that the OS calls with a UUID, a revision and a function number.
For Intel the UUID is `c4eb40a0-6cd2-11e2-bcfd-0800200c9a66` (`sys/dev/acpica/acpi_spmc.c` line 132),
and function 1 returns the device constraints.

FreeBSD's `acpi_spmc(4)` driver (`sys/dev/acpica/acpi_spmc.c`) attaches to that device, calls function 1 at attach
(line 468), and parses the answer in `acpi_spmc_parse_constraints_intel()` (line 617).

### ACPI packages

An ACPI package is an array whose elements can be integers, strings or other packages.
In the ACPICA library, a package is an `ACPI_OBJECT` with `Package.Count` (number of elements) and `Package.Elements`
(pointer to the array), see `sys/contrib/dev/acpica/include/actypes.h` line 1100.
Reading `Elements[n]` with `n >= Count` reads past the end of the array, so a parser must check `Count` first.

### The constraint format

The Intel specification, "Intel ACPI Low Power S0 Idle", revision 002 (May 2017), section 3.1
([PDF on uefi.org](https://uefi.org/sites/default/files/resources/Intel_ACPI_Low_Power_S0_Idle.pdf)),
defines function 1's answer as a package of entries, nested like this:

```
Package {                                 one entry per device (Table 7)
    "\\_SB.PC00.HDAS",                    device name
    1,                                    enabled
    Package {                             detail (Table 8)
        0,                                revision, always zero
        Package {                         constraint package (Table 9)
            0xFF,                         LPI UID (0xFF: all low-power states)
            0,                            minimum D-state
            0x81                          minimum device-specific state: "Optional"
        }
    }
}
```

Table 9 marks the third field "Optional device-specific information".
The specification's own example uses both forms:

```
Package() {"\\_SB.PCI0.GFX0", 0x1, Package() {0, Package(){0xFF, 3}}},
Package() {"\\_SB.PCI0.SAT0", 0x1, Package() {0, Package(){0xFF, 0, 0x81}}}
```

## The problem

Every boot of the NUC on FreeBSD main-n291498-6dc19a71f70c (GENERIC-NODEBUG) logs 84 lines like:

```
acpi_spmc0: Intel: Wrong package length for constraint 0's constraint package.
```

(`grep -c 'constraint package' /var/run/dmesg.boot`: 84.)

The check in `acpi_spmc_parse_constraints_intel()`:

```c
		if (constraint_package->Package.Count != 3) {
			device_printf(sc->dev, "Intel: Wrong package length "
			    "for constraint %zu's constraint package.\n", i);
			goto skip;
		}
```

What the firmware returns: the `_DSM` returns a named package `\_SB.PEPD.DEVY` after it edits some entries.
The DSDT copied from the NUC (`acpidump -o dsdt.aml`) and loaded in `acpiexec` on another machine
(`dump \_SB.PEPD.DEVY`) shows 119 entries:

| Constraint package | Entries | Example |
|---|---|---|
| 2 elements: LPI UID, minimum D-state | 85 | `\_SB.PR00`: `{0xFF, 0}` |
| 3 elements: with device-specific state | 34 | `\_SB.PC00.HDAS`: `{0xFF, 0, 0x81}` |

The live answer rejects 84 entries, not 85, because the `_DSM` changes `DEVY` before it returns it
(for example, it stores `PPD0` or `PPD3` into entry 9 and sets the enabled flags).
Either way, the firmware follows the specification and FreeBSD is too strict.

Impact today: only boot noise. The driver stores `min_d_state` for a constraint check that is still under
`#ifdef notyet` (`acpi_spmc_check_constraints()`, line 905), and the NUC suspends with S3, not suspend-to-idle.
Once that check is enabled, the rejected entries would be the missing ones: 84 of the 119 devices, among them all
32 processor entries (`\_SB.PR00` and up), which all use the 2-element form.

History: the parser first read `Elements[2]` without a check, so on a 2-element package it read one element past the
array. Commit 508efe35e577 ("acpi_spmc: Check Intel constraint packages") added the length checks, and `!= 3` turned
that out-of-bounds read into a rejection.

## The fix

```diff
-		if (constraint_package->Package.Count != 3) {
+		if (constraint_package->Package.Count < 2) {
 			device_printf(sc->dev, "Intel: Wrong package length "
 			    "for constraint %zu's constraint package.\n", i);
 			goto skip;
@@
 		constraint->min_d_state =
 		    constraint_package->Package.Elements[1].Integer.Value;
+		/* The minimum device-specific state is optional. */
 		constraint->min_dev_specific_state =
-		    constraint_package->Package.Elements[2].Integer.Value;
+		    constraint_package->Package.Count > 2 ?
+		    constraint_package->Package.Elements[2].Integer.Value : 0;
```

Bounds: `Elements[0]` and `Elements[1]` are read only after `Count < 2` was rejected, so `Count >= 2`.
`Elements[2]` is read only when `Count > 2`. An entry without the third field gets 0, the value `M_ZERO` already gave
the field; the field is "Currently filled but unused" (line 230).

A package with more than 3 elements is accepted and the extra elements are ignored, as for any other version 0
field the specification may add later.

### Alternatives

| Option | Gain | Cost |
|---|---|---|
| This patch: require 2, read the third if present | matches Table 9; smallest change | still trusts that the elements are integers |
| Accept exactly 2 or 3 | rejects packages the specification does not describe | a firmware that appends a field loses the whole constraint |
| Parse by element type, as Linux `drivers/acpi/x86/s2idle.c` does | tolerant of reordered fields | larger rewrite of a parser that just got strict checks on purpose (508efe35e577) |
| Only quiet the message | no behaviour change | the 84 constraints stay lost |

What the patch does not fix:

- Element types: `Integer.Value` is read without checking that the element is an integer, in this function and the
  AMD one. A string element gives a wrong value, not an out-of-bounds read (it reads the same union).
- The constraint check itself is still `#ifdef notyet`.
- One message per rejected entry: a truly malformed table would still print one line per entry.

## Tested

Intel NUC 13 Pro, 2026-11-24.

| Kernel | `constraint package` messages | Constraints kept |
|---|---|---|
| stock main-n291498-6dc19a71f70c | 84 | 35 (119 - 84) |
| patched, same base | 0 | 119, read with kgdb on the live kernel: 56 enabled, 34 with a device-specific state (`\_SB.PC00.HDAS`: `uid=0xff min_d=0 devspec=0x81`) |

kgdb read the softc through the `acpi_spmc` devclass (`kgdb kernel.debug /dev/mem`, then
`devclasses` list, `devices[0]->softc`, `constraint_count`, `constraints[i]`).

Untested: AMD machines (the AMD parser is not changed), machines that return 3-element packages only,
suspend-to-idle (the NUC uses S3).
