# ig4: the I2C bus of AMD AMDI0010 controllers ran above 400 kHz

Patch: [ig4_amd_clock.patch](ig4_amd_clock.patch) (commit
`ig4: Add an AMD generation with a 150 MHz clock`) on FreeBSD main
02e1b1cd1fb1, in review as
[#114](https://ron-dev.freebsd.org/FreeBSD/src/pulls/114).
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
`DEVIDLE_CTRL`), which the AMD cores do not have.

The Atom path itself has seven `sc->version == IG4_ATOM` tests in
`ig4_iic.c`. Two read standard DesignWare registers: `COMP_PARAM1`
(FIFO depths, `ig4iic_get_config()`) and `COMP_VER` (refuse a too old
core, `ig4iic_set_config()`). The others touch Intel LPSS private
registers (`RESETS_HSW`, `GENERAL`, `CLK_PARMS`) or only dump registers
for debugging. The `RESETS_HSW` write runs only when a reset is asked,
and the driver asks for one only when `IG4_HAS_ADDREGS()` is true.

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

AMDI0010 controllers get their own generation, as the reviewer (wulf)
asked:

```diff
--- sys/dev/ichiic/ig4_var.h (enum ig4_vers)
 	IG4_ATOM,
+	IG4_AMD,
 	IG4_SKYLAKE,
--- sys/dev/ichiic/ig4_iic.c (ig4iic_hw[])
+	[IG4_AMD] = {
+		.ic_clock_rate = 150,
+		.sda_fall_time = 280,
+		.scl_fall_time = 240,
+		.sda_hold_time = 60,
+		.txfifo_depth = 32,
+		.rxfifo_depth = 32,
+	},
--- sys/dev/ichiic/ig4_acpi.c (ig4iic_acpi_attach)
+	} else if (strcmp(str, "AMDI0010") == 0) {
+		sc->version = IG4_AMD;
```

and `|| sc->version == IG4_AMD` in the two DesignWare checks of section
1.4 (`COMP_PARAM1`, `COMP_VER`).

- `IG4_AMD` sits before `IG4_SKYLAKE`, so `IG4_HAS_ADDREGS()` stays
  false: no Intel LPSS register is touched.
- The table entry is the Atom entry with a 150 MHz clock: the same fall
  and hold times the AMD cores ran with as Atom, so only the clock
  changes the counts.
- The AMD cores no longer read the Intel `GENERAL` register at attach;
  those reads had no effect.
- `AMD0010` and `AMDI0510` stay on the Atom entry (no hardware here).

### Alternatives

- Keep AMDI0010 as Atom and override only the clock with a softc field.
  Smaller, but the softc then carries a per-controller exception to the
  generation table, and the AMD cores keep touching Intel registers.
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

Kernel built from the ZBook source tree of 2026-11-17 (with the IOMMU
patches), `ig4.ko` built from the same tree with this commit's
`sys/dev/ichiic` files, swapped in with `kldunload ig4`/`kldload`.
Bus rate: [ig4_amd_clock_bench.pl](ig4_amd_clock_bench.pl) on
`/dev/iic18` (amplifier bus) with `snd_cs35l54` unloaded, 200 timed 1 KB
reads, twice.

| `ig4.ko` | Median per 1 KB read | Effective rate |
|---|---|---|
| stock (ig4 as Atom, 100 MHz) | 19.52 ms, 19.53 ms | 472 kHz |
| this commit | 26.48 ms, 26.47 ms | 348 kHz |

| Check | Result |
|---|---|
| All four controllers attach after the swap (`ig4iic0` to `ig4iic3`) | yes |
| Touchpad: `iichid0`, `hmt0` SYNA3133 TouchPad | attached |
| `snd_cs35l54`: calibration of the 4 amplifiers, firmware download | yes, firmware 3.11.18 |
| Speaker playback: two 3 s 440 Hz tones, recorded from the microphones and measured with [cs35l54_tone_measure.py](cs35l54_tone_measure.py) | 3.00 s and 2.95 s |
| ig4 timeouts or errors in `dmesg` | 0 |
| ACPI `SSCN`/`FMCN` present | no (`acpidump`) |
| `buildkernel GENERIC` on main 02e1b1cd1fb1 | no warning |
| Attach at boot, suspend and resume | untested (module swaps only) |
| Other AMDI0010 machines, Intel controllers | untested (Intel: code path unchanged) |

## 5. Review

[#114](https://ron-dev.freebsd.org/FreeBSD/src/pulls/114): wulf asked for
a new `enum ig4_vers` item and `struct ig4_hw` entry instead of a softc
field; this is that design.
