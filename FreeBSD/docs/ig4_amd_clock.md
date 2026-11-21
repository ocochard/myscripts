# ig4: the I2C bus of AMD AMDI0010 controllers ran above 400 kHz

Patch: [ig4_amd_clock.patch](ig4_amd_clock.patch) (commit
`ig4: Use the 150 MHz clock of AMDI0010 controllers`), for FreeBSD main
of 2026-11-20.
Machine: HP ZBook Ultra G1a 14 (AMD Ryzen AI Max+ PRO 395), four AMDI0010
I2C controllers (`ig4iic0` to `ig4iic3`): touchpad, touchscreen and the
four CS35L54 speaker amplifiers.

This document is written for a first-year computer science student who
knows C and what an operating system does, but not I2C or this driver.

## 1. Background

### 1.1 I2C and its clock

I2C is a two-wire bus: SCL carries the clock, SDA the data. The
controller (the "master") generates SCL. Fast mode allows at most
400 kHz, and each SCL period has a minimum high time (600 ns) and low
time (1300 ns). Devices also need SDA to stay stable for a while after
SCL falls (the "SDA hold time"). A bus that runs faster than the
device allows can work on one board and fail on another, or fail only
with long wires or at high temperature.

### 1.2 The DesignWare controller counts input clock cycles

The AMD controllers are Synopsys DesignWare I2C cores, driven by
FreeBSD `ig4(4)` (`sys/dev/ichiic/`). The core does not know what
400 kHz is: the driver writes how many cycles of the controller input
clock SCL stays high (`FS_SCL_HCNT`) and low (`FS_SCL_LCNT`), and how
many cycles SDA is held (`SDA_HOLD`). The cycle counts are computed by
`ig4iic_clk_params()` (`ig4_iic.c:750`):

```
hcnt = (ic_clock_rate * (thigh + sda_fall_time) + 500) / 1000 - 3
lcnt = (ic_clock_rate * (tlow + scl_fall_time) + 500) / 1000 - 1
```

`ic_clock_rate` is the input clock in MHz. It comes from the table
`ig4iic_hw[]` (`ig4_iic.c:91`), indexed by the controller generation
`sc->version`. If the driver assumes the wrong input clock, every count
is wrong by the same ratio.

### 1.3 Who decides the timings

`ig4iic_get_config()` takes the counts from the table, then lets the
ACPI methods `SSCN` and `FMCN` override them when the firmware has
them (`ig4_iic.c:892`, only with the default `debug.ig4_timings=0`).
The ZBook firmware has neither (`acpidump -dt | grep -c FMCN` gives 0),
so the table decides.

### 1.4 `sc->version` also chooses the register path

`ig4_acpi.c` gives every ACPI-enumerated controller that is not eMAG
or Haswell `sc->version = IG4_ATOM`, AMDI0010 included. The version
also selects which non-standard registers the driver touches:
`IG4_HAS_ADDREGS(vers)` (`ig4_var.h:56`) is true from `IG4_SKYLAKE`
on, and enables the Intel LPSS private registers (resets at 0x204, LTR,
`DEVIDLE_CTRL`), which the AMD cores do not have. AMD cores must stay
on the Atom path.

## 2. The problem

The Atom entry assumes a 100 MHz input clock. The AMDI0010 cores run
from 150 MHz: Linux gives them a fixed 150 MHz clock
(`drivers/acpi/acpi_apd.c`, `wt_i2c_desc`, used by AMDI0010 and
AMDI0019). No public AMD document states the clock; the Linux value
and the measurement below agree.

With the Atom timings (sda_fall 280 ns, scl_fall 240 ns, hold 60 ns):

| Assumed clock | HCNT | LCNT | SDA_HOLD | SCL on a 150 MHz core |
|---|---|---|---|---|
| 100 MHz (stock) | 85 | 153 | 6 cycles = 40 ns | about 610 kHz before rise time |
| 150 MHz (patch) | 129 | 230 | 9 cycles = 60 ns | about 410 kHz before rise time |

### How to repeat

Read 1 KB from a CS35L54 amplifier (address 0x30 on the bus of
`ig4iic1`, `/dev/iic18` here) 200 times, timing each `i2c(8)` call, and
take the median. Each read is the 1-byte offset write, a repeated start
and 1024 data bytes, so about 9.2 kbit; the process start-up time is
included, so the "effective" rate is below the real SCL rate. The
amplifiers sometimes NACK while they leave hibernation: those reads are
skipped and counted. Script: [ig4_amd_clock_bench.pl](ig4_amd_clock_bench.pl)
(unload `snd_cs35l54` first so the driver does not use the bus).

```
# kldunload snd_cs35l54
# perl ig4_amd_clock_bench.pl stock /dev/iic18
stock: median 19.52 ms, min 19.39 ms per 1 KB read, effective 472 kHz (median), 0 NACKed reads skipped
```

472 kHz effective, with process overhead included, means the bus runs
above the 400 kHz fast-mode limit.

## 3. The fix

```diff
--- sys/dev/ichiic/ig4_acpi.c
 		/* All the other HIDs matched are Atom SOCs. */
 		sc->version = IG4_ATOM;
+		/* AMDI0010 runs from a 150 MHz clock, not 100 MHz. */
+		if (strcmp(str, "AMDI0010") == 0)
+			sc->ic_clock_rate = 150;
--- sys/dev/ichiic/ig4_iic.c (ig4iic_get_config)
-		hw = &ig4iic_hw[sc->version];
+		hw = ig4iic_hw[sc->version];
+		if (sc->ic_clock_rate != 0)
+			hw.ic_clock_rate = sc->ic_clock_rate;
--- sys/dev/ichiic/ig4_var.h (struct ig4iic_softc)
+	uint32_t	ic_clock_rate;	/* MHz, 0: from ig4iic_hw */
```

The controller keeps `sc->version = IG4_ATOM`, so every register access
stays as before. Only the clock used to compute the counts changes. The
softc is allocated zeroed, so PCI controllers and the other ACPI IDs
keep the table clock.

### Alternatives

- A new `IG4_AMD` generation with its own table entry. This was the
  first version of the patch. Added at the end of `enum ig4_vers`, it
  sorts after `IG4_SKYLAKE`, so `IG4_HAS_ADDREGS()` became true and the
  AMD cores were sent down the Intel LPSS path (writes to registers
  that do not exist on AMD, the FIFO depth read and the component
  version check skipped). Placing it before `IG4_SKYLAKE` works, but
  every `== IG4_ATOM` test (seven in `ig4_iic.c`) then needs `|| IG4_AMD`. A clock
  override is smaller and cannot change the register path.
- Program the counts in ACPI `FMCN`: the firmware is not ours to change.
- A tunable: users would have to know the clock; the driver knows it
  from the ACPI ID.

### What the patch does not fix

- `AMD0010` (older Carrizo-era cores) still uses 100 MHz, while Linux
  gives it 133 MHz (`cz_i2c_desc`). Not changed: no hardware here to
  measure it.
- The stale first word of reads from the CS35L54 amplifiers
  ([cs35l54_speaker_amp_plan.md](cs35l54_speaker_amp_plan.md), "The ig4
  read problem") is not a timing problem: it remains with this patch.

## 4. Tested

Kernel `zbook-n291269-0d71515aee38` (zbook branch of 2026-11-17), with
`ig4.ko` built from the same source in three variants and swapped with
`kldunload`/`kldload`. Each row with two values ran twice, with the same result.

| `ig4.ko` | Median per 1 KB read | Effective rate |
|---|---|---|
| stock (zbook source, ig4 commit reverted) | 19.52 ms, 19.53 ms | 472 kHz |
| this patch | 26.49 ms, 26.48 ms | 348 kHz |
| first version (`IG4_AMD` enum, `/boot/kernel.zbook/ig4.ko`) | 26.48 ms, 26.48 ms | 348 kHz |

The first version gives the same counts, so the same rate: the patch
changes the register path, not the timings. (An earlier run of this
table showed 471 kHz for the first version after a reload; that module
came from `/boot/kernel`, a stock main kernel, not from the running
kernel's directory.)

| Check | Result |
|---|---|
| Touchpad (`iichid0`) and amplifiers (`cs35l540`) reattach after each module swap | yes, `devinfo` |
| `snd_cs35l54` attach after the swap: calibration read, firmware download | yes, 4 amplifiers, firmware 3.11.18 |
| ACPI `SSCN`/`FMCN` present | no (`acpidump`) |
| `ig4.ko` builds against main 6dc19a71f70c | yes, no warning |
| Attach at boot (patched `ig4.ko` in `/boot/kernel`) | untested: only module swaps were tested |
| Suspend and resume with the patch | untested (register path identical to stock) |
| Speaker playback, touchpad use | untested in this run |
| Other AMDI0010 machines, Intel controllers | untested (Intel: code path unchanged, clock override is 0) |
