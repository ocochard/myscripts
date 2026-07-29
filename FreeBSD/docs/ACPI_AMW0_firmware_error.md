# Reading an ACPI firmware error: the `AMW0` / `EC0._REG` case

*A worked example of diagnosing an ACPI boot-time error on FreeBSD with
`acpica-tools`, written from first principles for someone who has never
looked inside ACPI.*

*Author: Claude (Anthropic Claude Opus 4.8)*

> **Status: DRAFT — NOT PEER-REVIEWED.** This document was written by the
> agent as a side product of a debugging session on a Beelink (AZW) SER
> mini-PC and has not been reviewed by ACPI or FreeBSD maintainers. It is
> *plausible* and internally consistent with the data collected on that
> machine, but treat it as a starting point for your own reading, not a
> finished reference. Where it states a rule of the ACPI specification,
> confirm it against the spec before relying on it.

---

## 1. The symptom

On this machine (`AZW SER`, an AMD-APU mini-PC with an American Megatrends
BIOS), `/var/run/dmesg.boot` contains these three lines during boot:

```
acpi_ec0: <Embedded Controller: GPE 0xb> port 0x62,0x66 on acpi0
Firmware Error (ACPI): Could not resolve symbol [\134_SB.PCI0.SBRG.EC0._REG.AMW0], AE_NOT_FOUND (20260408/psargs-525)
ACPI Error: Aborting method \134_SB.PCI0.SBRG.EC0._REG due to previous error (AE_NOT_FOUND) (20260408/psparse-689)
```

The first line is normal: FreeBSD found and attached the Embedded
Controller. The next two are the OS's ACPI interpreter complaining that
while it was running a piece of firmware code, that code referred to a name
(`AMW0`) that does not exist anywhere in the system. The interpreter gave
up on that one method and moved on.

By the end of this document you will understand every field in those three
lines, the tool used to prove the cause, and why — on this machine — the
error is harmless.

If you want the one-sentence answer first: **the motherboard firmware
contains a bug (a reference to an object its authors forgot to define), the
missing object is only used to notify a Windows-specific management
interface, and FreeBSD has nothing that would consume that notification, so
nothing of value is lost.**

---

## 2. A crash course in ACPI

### 2.1 What ACPI is

**ACPI** — Advanced Configuration and Power Interface — is the contract
between the motherboard firmware and the operating system for everything to
do with *configuration* (what devices exist, where their registers live,
how they are wired to interrupts) and *power* (sleep states, thermal zones,
fans, batteries, the power button). The specification is maintained by the
UEFI Forum.

Before ACPI, an OS had to hard-code knowledge of each chipset. ACPI
inverts that: the firmware *describes itself* to the OS in a set of tables
placed in memory at boot. The OS reads the tables and drives the hardware
according to what they say, without needing built-in knowledge of that
particular board.

The clever and dangerous part is that some of this description is not data
but **code**. The firmware ships small programs that the OS executes to,
say, read a temperature or turn on a device. That code is what failed on
this machine.

### 2.2 The ACPI tables

At boot the firmware leaves a root pointer (the RSDP) in memory. It points
to a root table (the XSDT on modern systems), which is essentially an array
of pointers to every other ACPI table. Each table has a 4-character
**signature**. On this machine, dumping the tables produced these (sizes in
bytes):

| Signature | What it is |
|---|---|
| `DSDT` | **D**ifferentiated **S**ystem **D**escription **T**able — the main body of firmware code and device descriptions |
| `SSDT` ×13 | **S**econdary SDTs — extra code that is merged into the same namespace as the DSDT |
| `FACP` | The **F**ixed ACPI Description Table (historically "FADT") — fixed hardware register locations; also points to the DSDT |
| `FACS` | Firmware ACPI Control Structure — wake vector and the global lock |
| `APIC` | Interrupt controller topology (a.k.a. MADT) |
| `MCFG` | Base address of PCIe memory-mapped configuration space |
| `BGRT` | Boot Graphics Resource Table — the vendor logo shown at boot |
| `CRAT`, `CDIT`, `IVRS` | AMD-specific: APU resource/locality topology and the IOMMU description |
| `VFCT` | AMD video BIOS container (the GPU's option ROM) |
| `TPM2`, `WSMT`, `FIDT`, `FPDT` | TPM 2.0, Windows SMM mitigations, firmware ID and boot-performance data |

You do not need to know all of these. The point is that a real machine has
*many* tables, but the two that carry executable code — and therefore the
two that can carry bugs like ours — are the **DSDT** and the **SSDTs**.

### 2.3 DSDT vs SSDT

Both the DSDT and the SSDTs contain the same kind of content: definitions of
devices, methods (functions), and named values. The difference is only
organisational:

- The **DSDT** is the single mandatory table. Think of it as `main`.
- **SSDTs** are optional, and there can be many. They are loaded after the
  DSDT and their contents are *merged into the same shared namespace*.
  Vendors use them to keep optional or generated pieces separate — CPU
  power-state definitions, per-SKU tweaks, and so on.

This merging matters for our bug: an object referenced in the DSDT is
allowed to be *defined* in an SSDT. So "the DSDT mentions `AMW0` but does
not define it" is not automatically a bug — we have to check every SSDT too
before concluding the object is truly missing. (We did; it is.)

### 2.4 The namespace

All of that merged content forms a single tree called the **ACPI
namespace**, very much like a filesystem. Some standard nodes:

```
\                     the root
\_SB                  "System Bus" — the tree of real devices
\_SB.PCI0             the root PCI bridge
\_SB.PCI0.SBRG        the South Bridge (chipset I/O hub)
\_SB.PCI0.SBRG.EC0    the Embedded Controller device
\_GPE                 General Purpose Events (see §3.1)
```

Names are exactly **four characters** at each level (padded with `_` if
shorter — that is why it is `_SB` and not `SB`). A full path is written
with `.` separators and a leading `\` for the root, exactly like an
absolute filesystem path. This is where the odd `\134` in the error message
comes from: `\134` is the **octal escape for the backslash character**
(`134` octal = `92` decimal = ASCII `\`). The kernel printed the root `\`
using its octal code. So `\134_SB.PCI0.SBRG.EC0._REG` simply means
`\_SB.PCI0.SBRG.EC0._REG`.

Name resolution also works like a filesystem with an implicit search path:
when code inside `\_SB.PCI0.SBRG.EC0._REG` refers to a bare name `AMW0`,
the interpreter looks for it starting at the current scope and walks
*upward* toward the root:

```
\_SB.PCI0.SBRG.EC0._REG.AMW0     ← tried first (this is what the error prints)
\_SB.PCI0.SBRG.EC0.AMW0
\_SB.PCI0.SBRG.AMW0
\_SB.PCI0.AMW0
\_SB.AMW0
\AMW0
```

If none of those exist, resolution fails with `AE_NOT_FOUND`. The error
message shows the *first* (deepest) path it tried, which is why it reads
`...EC0._REG.AMW0` even though the object was really "supposed" to live at
`\_SB.AMW0`.

### 2.5 AML, ASL, and ACPICA

The code in the DSDT/SSDTs is stored as **AML** — ACPI Machine Language, a
compact bytecode. Humans write it in **ASL** — ACPI Source Language — and
compile ASL to AML. When we *disassemble* AML back to readable form, a
modern tool emits **ASL+**, a variant with C-like operators (`==`, `&&`,
`=`) instead of the original LISP-like function forms; it is easier to read
and is what you will see in the listings below.

The program that executes AML inside the OS is an interpreter. Nearly
everyone uses the same one: **ACPICA**, the *ACPI Component Architecture*,
Intel's reference implementation. It is embedded in the FreeBSD kernel
(under `sys/contrib/dev/acpica`) and in Linux. The two long numbers in our
error, `20260408`, are the ACPICA **version** (a date stamp — 8 April
2026). `psargs-525` and `psparse-689` are the source file and line number
*inside ACPICA* that emitted the message (`psargs.c` and `psparse.c`) —
they tell an ACPICA developer where in the interpreter the failure was
detected. They are **not** memory addresses and not anything on your
machine.

---

## 3. The specific objects in our error

Three ACPI concepts meet in this bug: the Embedded Controller, the `_REG`
method, and the WMI device `AMW0`.

### 3.1 The Embedded Controller (EC)

The line

```
acpi_ec0: <Embedded Controller: GPE 0xb> port 0x62,0x66 on acpi0
```

describes a real piece of hardware. The **Embedded Controller** is a small
microcontroller found on almost every laptop and many desktops/mini-PCs. It
handles the slow, always-on housekeeping the main CPU should not: the power
button, the lid switch, battery gauge, thermal sensors and fan control, and
often the keyboard controller.

The OS talks to it through two 8-bit I/O ports, shown here as
`port 0x62,0x66`: `0x62` is the data port and `0x66` is the command/status
port. This is the standard ACPI EC register pair.

`GPE 0xb` is the **General Purpose Event** the EC uses to get the CPU's
attention. When the EC has something to report (temperature crossed a
threshold, button pressed), it raises the ACPI System Control Interrupt,
and the OS sees that General Purpose Event number 11 fired; a handler in the
firmware (a method named `_L0B`/`_E0B` under `\_GPE`) then runs to service
it. None of this is broken here — the EC attached fine.

### 3.2 Operation regions and the `_REG` method

AML code frequently needs to read and write hardware registers. It does so
through an **Operation Region**: a declared window into some *address
space*. ACPI defines several address spaces, each with a numeric ID:

| ID | Address space |
|---|---|
| 0 | System memory |
| 1 | System I/O ports |
| 2 | PCI configuration space |
| 3 | **Embedded Controller** |
| 4 | SMBus |
| … | … |

Crucially, AML cannot touch a region until the OS has installed a
**handler** for that address space. For the EC (space 3), the handler is
the OS's EC driver — which only exists once the EC has been attached, as we
just saw it be.

To let the firmware know *when* a region becomes usable, ACPI defines the
`_REG` **method** (short for "region availability"). Whenever the OS
installs or removes an address-space handler, ACPICA calls the `_REG`
method of the relevant device with two arguments:

- **Arg0** = the address-space ID (so `3` means "the EmbeddedControl space").
- **Arg1** = `1` if the region just became available, `0` if it is going away.

So `EC0._REG` is the firmware's chance to run "now that the OS can talk to
the EC, do my EC-dependent initialisation." That is exactly the method that
failed.

### 3.3 WMI and the `AMW0` device

The failing reference is `AMW0`, and the operation that references it is
`Notify (AMW0, 0xBC)`.

**WMI** — *Windows Management Instrumentation* — is a Windows framework for
management data. **ACPI-WMI** is a bridge (device ID `PNP0C14`) that lets
firmware expose vendor-specific data and events to Windows: hotkey presses,
LED/fan control from a vendor utility, "performance mode" toggles, and the
like. `AMW0` is a conventional name (used by AMI/AMD firmware) for that
ACPI-WMI mapper device.

**`Notify(device, code)`** is how firmware pushes an asynchronous event up
to the OS: it says "something of type *code* happened on *device*; run
whatever driver is bound to it." Codes `0x80` and above are
device-specific; `0xBC` here is a vendor-defined WMI event.

Put together, the intent of the firmware is: *"as soon as the OS can talk
to the EC, poke the WMI device so a vendor agent can react."* On Windows,
with the vendor's WMI driver loaded, that Notify would be delivered. On
FreeBSD there is no consumer for this particular vendor event, so even if
the Notify succeeded, nothing would act on it.

---

## 4. The tool: `acpica-tools`

To go from "an error mentions `AMW0`" to "here is the exact bug," you need
to read the firmware's own code. The `acpica-tools` package provides the
two programs for that: `acpidump` (extract the tables from the running
machine) and `iasl` (the compiler/**disassembler**).

```sh
pkg install acpica-tools
```

### 4.1 A gotcha: two different `acpidump`s

FreeBSD's **base system** ships its own `/usr/sbin/acpidump`, whose `-d`
flag disassembles the DSDT directly:

```sh
acpidump -dt > acpi.asl        # base-system acpidump
```

The `acpica-tools` package installs the **upstream ACPICA** `acpidump` into
`/usr/local/bin`, which has *different flags* — there is no `-d`; instead
you dump raw binaries with `-b` and disassemble them separately with
`iasl`. Because `/usr/local/bin` is usually ahead of `/usr/sbin` in
`PATH`, after installing the package the upstream one wins, and the base
syntax fails:

```
$ acpidump -dt > acpi.asl
Illegal option: -d
```

If you hit that, you are using the ACPICA version; switch to the two-step
workflow below. (Either tool gets you there; just do not mix their flags.)

### 4.2 Dumping the tables

Both dumpers need to read physical memory, so they need root:

```sh
sudo acpidump -b          # ACPICA version: writes dsdt.dat, ssdt1.dat, ... into cwd
```

This produced one `.dat` file per table — `dsdt.dat`, thirteen `ssdt*.dat`,
plus the smaller tables from §2.2. The `.dat` files are the raw AML/table
bytes.

### 4.3 Disassembling with cross-references resolved

Now turn the bytecode back into readable ASL+. The important flag is `-e`,
which supplies the *other* tables as "external" references so that names
defined in one table but used in another resolve cleanly during
disassembly:

```sh
iasl -e ssdt*.dat -d dsdt.dat      # -e: external tables, -d: disassemble
```

This writes `dsdt.dsl` — the human-readable source of the firmware's main
code. (You can disassemble any SSDT the same way to read those too.)

### 4.4 Searching for the culprit

With source in hand, finding `AMW0` is a plain text search across every
disassembled table:

```sh
grep -Hn AMW0 *.dsl
```

which on this machine returned only two hits, both in `dsdt.dsl`:

```
dsdt.dsl:25:    External (_SB_.AMW0, DeviceObj)
dsdt.dsl:6424:                    Notify (AMW0, 0xBC) // Device-Specific
```

---

## 5. The analysis

Two references, no definition. That gap is the whole bug.

### 5.1 The dangling `External`

Line 25 is a declaration, not a definition:

```asl
External (_SB_.AMW0, DeviceObj)
```

`External` is the ASL equivalent of a C `extern` / forward declaration: it
tells the *compiler* "an object named `\_SB.AMW0`, of type Device, exists
somewhere else — trust me, don't error at compile time." It reserves the
name but creates nothing at runtime.

For that promise to hold, some table must actually *define* `\_SB.AMW0`
(with `Device (AMW0) { … }`). We checked all of them:

```sh
grep -rn -E 'Device \(AMW0|Scope .*AMW0' *.dsl   # → no matches
```

Nothing, in the DSDT or in any of the thirteen SSDTs, ever defines `AMW0`.
The `External` is a promise the firmware never keeps. This is the defect —
and it is the firmware author's mistake, not the OS's.

### 5.2 Where it blows up

Line 6424 sits at the very end of the EC's `_REG` method. Here is the
method, lightly trimmed:

```asl
Method (_REG, 2, NotSerialized)     // Arg0 = address space, Arg1 = available?
{
    If ((Arg0 == 0x03))             // 3 = EmbeddedControl space
    {
        ECOK = Arg1                 // remember the EC is now usable
    }

    If (((Arg0 == 0x03) && (Arg1 == One)))   // EC just became available
    {
        OSFG = One
        SMUF = 0x13
        SMUD = 0xAFC8
        ALIB (0x0C, XX11)           // an AMD SMU/power call — runs fine
        If ((FCMO == Zero)){}
        ElseIf ((FCMO == One)){}
        Else {}

        Notify (AMW0, 0xBC)         // ← fails: AMW0 cannot be resolved
    }
}
```

Read it top to bottom, because the order is what makes this benign. When
the EC region becomes available, the method sets several flags, programs
the AMD SMU (System Management Unit) values, and calls `ALIB` — **all of
which execute successfully**. The `Notify(AMW0, 0xBC)` is the *last*
statement. Only when the interpreter reaches it does name resolution fail,
raising `AE_NOT_FOUND` and aborting the method — with nothing left to run
after it.

That is precisely what the two error lines report:

```
Could not resolve symbol [\134_SB.PCI0.SBRG.EC0._REG.AMW0], AE_NOT_FOUND   ← the Notify's target
Aborting method \134_SB.PCI0.SBRG.EC0._REG due to previous error           ← so _REG stops here
```

### 5.3 Decoding the error, field by field

Now every piece of the original message should be legible:

| Fragment | Meaning |
|---|---|
| `Firmware Error (ACPI)` | ACPICA is blaming the firmware's AML, not the OS |
| `Could not resolve symbol` | a name lookup failed |
| `\134_SB.PCI0.SBRG.EC0._REG.AMW0` | `\_SB…._REG.AMW0` — the deepest path searched for `AMW0` (`\134` = `\`) |
| `AE_NOT_FOUND` | the ACPICA error code for "no such name" |
| `20260408` | the ACPICA version (date stamp) |
| `psargs-525`, `psparse-689` | source file/line *inside ACPICA* that reported it — not your addresses |
| `Aborting method … _REG` | because the argument couldn't be resolved, the whole `_REG` method is abandoned |

---

## 6. Impact: why this is harmless here

The only thing lost is the final `Notify(AMW0, 0xBC)` — a single WMI event
aimed at a Windows-oriented management interface:

- Everything `_REG` needed to do to the **EC and the SMU** already ran
  before the failing line, so thermal/fan/battery/button handling is
  unaffected.
- The Notify targets the **ACPI-WMI** device, whose only job is to hand
  vendor events to a vendor agent. FreeBSD ships `acpi_wmi(4)` but has no
  driver that consumes this vendor's `0xBC` event, so even a *successful*
  Notify would be dropped.

Net effect on FreeBSD: **cosmetic boot-log noise, no functional loss.** The
correct place to fix it is the firmware; you can confirm there is no newer
BIOS from the vendor, and optionally report the missing `\_SB.AMW0`
definition.

---

## 7. If you really want to silence it

Because only one object is missing, you *can* make the error disappear by
supplying a custom DSDT that defines a stub `AMW0` device, so the name
resolves and the Notify simply goes nowhere useful (which is already the
case functionally).

**This is optional and carries real risk — read the caveats first.**

1. Edit the disassembled `dsdt.dsl`. Remove the `External (_SB_.AMW0, …)`
   line and instead define the object, e.g. inside `Scope (\_SB)`:

   ```asl
   Scope (\_SB)
   {
       Device (AMW0)
       {
           Name (_HID, "PNP0C14")   // ACPI-WMI device ID
           Name (_UID, 0)
       }
   }
   ```

2. Bump the DSDT's OEM revision (so it is clearly your build) and recompile:

   ```sh
   iasl -tc dsdt.dsl        # produces dsdt.aml; fix any compile errors it reports
   cp dsdt.aml /boot/dsdt.aml
   ```

3. Tell the loader to override the firmware's DSDT with yours, in
   `/boot/loader.conf`:

   ```
   acpi_dsdt_load="YES"
   acpi_dsdt_name="/boot/dsdt.aml"
   ```

**Caveats, in plain terms:**

- You are replacing the *entire* 24 KB DSDT of a live machine to silence
  one benign log line. A mistake here can break power management, or
  prevent boot. Keep a way to revert (comment the two `loader.conf` lines
  from the loader prompt).
- A disassemble/recompile round trip is not guaranteed byte-identical;
  modern AMD DSDTs often need small fix-ups before `iasl` will compile them
  cleanly.
- Any **BIOS update wipes this** — the firmware ships a fresh DSDT and your
  override name may no longer match, so you must redo the process.

For a cosmetic message, the honest recommendation is: **don't.** Leave the
line in the log, and file/monitor a BIOS bug with the vendor instead.

---

## 8. Recap — the general method

The specific bug matters less than the workflow, which applies to *any*
`AE_NOT_FOUND` / "Firmware Error (ACPI)" message:

1. **Read the message as a namespace path.** Translate `\134` back to `\`;
   the bracketed symbol is what could not be resolved, and the "Aborting
   method" line tells you which firmware routine gave up.
2. **Dump the tables** with `acpidump` (mind the base-vs-ACPICA flag
   difference), then **disassemble** the DSDT with `iasl -e ssdt*.dat -d`.
3. **`grep` for the symbol** across *all* `.dsl` files — remember an object
   may legitimately be defined in an SSDT, so search everything.
4. **Classify each hit** as a *declaration* (`External`), a *definition*
   (`Device`/`Scope`/`Name`/`Method`), or a *use*. A symbol with a
   declaration and a use but no definition is a dangling reference — a
   firmware bug.
5. **Read the enclosing method top-to-bottom** to judge impact: what ran
   before the failing line, and does anything the OS relies on depend on
   the part that was skipped?
6. **Decide.** Usually the answer is "firmware bug, functionally harmless,
   leave it and report upstream." Overriding the DSDT is a last resort.

---

## Appendix A: glossary

- **ACPI** — Advanced Configuration and Power Interface: firmware↔OS
  contract for device configuration and power management.
- **ACPICA** — the reference ACPI interpreter (Intel), embedded in FreeBSD
  and Linux. Its version is a date stamp (here `20260408`).
- **AML / ASL / ASL+** — the bytecode / its source language / the modern
  C-like disassembly dialect.
- **DSDT** — the main firmware code+description table.
- **SSDT** — secondary table(s) merged into the same namespace.
- **FACP/FADT, FACS, MADT/APIC, MCFG, …** — other, mostly data-only ACPI
  tables (see §2.2).
- **Namespace** — the tree of ACPI objects (`\_SB.PCI0.…`), resolved like a
  filesystem with an upward search.
- **EC** — Embedded Controller: microcontroller for power/thermal/keyboard
  housekeeping, reached via I/O ports `0x62`/`0x66`.
- **GPE** — General Purpose Event: the mechanism by which devices like the
  EC raise the ACPI interrupt (SCI).
- **Operation Region** — a declared window into an address space (memory,
  I/O, PCI config, EmbeddedControl=3, …).
- **`_REG`** — method called when an address-space handler is
  installed/removed; `(Arg0=space, Arg1=available?)`.
- **`Notify(dev, code)`** — firmware→OS asynchronous event; codes ≥ `0x80`
  are device-specific.
- **WMI / ACPI-WMI (`PNP0C14`)** — Windows management bridge; `AMW0` is a
  common name for the mapper device.
- **`External`** — an ASL forward declaration; reserves a name but defines
  nothing. A use with no matching definition is the classic firmware bug.
- **`AE_NOT_FOUND`** — ACPICA error: name not present in the namespace.

## Appendix B: commands used, in order

```sh
pkg install acpica-tools

# dump every ACPI table to raw .dat files (ACPICA acpidump needs root)
sudo acpidump -b

# disassemble the DSDT, giving the SSDTs as externals so names resolve
iasl -e ssdt*.dat -d dsdt.dat

# find the unresolved symbol across all disassembled tables
grep -Hn AMW0 *.dsl

# confirm it is declared/used but never defined
grep -rn -E 'Device \(AMW0|Scope .*AMW0' *.dsl   # → no matches
```
