# `ithwm(4)` and `amdpower(4)`: hardware sensor drivers for the NAS

*Author: Claude (Anthropic Claude Opus 5.5)*

> **Status: out-of-tree, not submitted upstream.** Both drivers build
> cleanly and run on the `nas` host. The IT8613E register details
> come from the Linux `it87` drivers, not from the ITE datasheet. See
> [Open questions](#open-questions).

Two small FreeBSD drivers written for the `nas` host. That box is a
Ryzen 7 PRO 8845HS (Family 19h, Phoenix) on a board with an ITE
IT8613E Super I/O chip. Out of the box FreeBSD shows CPU temperatures
there (`amdtemp(4)`), but no fan speeds, board voltages or power draw.

| Driver | Source of data | Exposes |
|---|---|---|
| `ithwm` | ITE IT8613E hardware monitor (Super I/O LDN 4) | board temperatures, fan RPM, voltages |
| `amdpower` | AMD RAPL energy MSRs | package and per-core power in mW |

For background on how other OSes organise sensors (Linux hwmon,
OpenBSD `hw.sensors`, NetBSD envsys), see [sensors.md](sensors.md).

## Where the code lives

The branches are in the fork
[ocochard/freebsd-src](https://github.com/ocochard/freebsd-src), and
the code is in no other repo:

- [`olivier-ithwm`](https://github.com/ocochard/freebsd-src/tree/olivier-ithwm):
  `ithwm` only.
- [`olivier-amdpower`](https://github.com/ocochard/freebsd-src/tree/olivier-amdpower):
  stacked on `olivier-ithwm`, adds `amdpower`.
  The amdpower commits don't touch any ithwm file. The only file both
  branches change is `share/man/man4/Makefile`, where each adds one
  line. Rebasing amdpower onto `main` on its own is easy.

Files per driver:

```
sys/dev/ithwm/ithwm.c            sys/dev/amdpower/amdpower.c
sys/modules/ithwm/Makefile       sys/modules/amdpower/Makefile
share/man/man4/ithwm.4           share/man/man4/amdpower.4
+ entries in sys/modules/Makefile, sys/conf/files.x86, sys/x86/conf/NOTES
```

Local clones on bigone: `~/freebsd-src` (the fork). The first versions
were written in `~/freebsd-official/src`, which still holds the
pre-review history on local branches of the same names. Searching a
checkout of `main` for these drivers finds nothing. Use
`git log --all -- sys/dev/ithwm`.

## `ithwm`: ITE IT8613E hardware monitor

Attaches as a child of `superio(4)`. The probe accepts only ITE
devid `0x8613`. Other IT87xx chips have different register maps and
are rejected. Register access goes through the index/data port pair
at `iobase+5` / `iobase+6` of the HWM I/O window.

```
$ sysctl dev.ithwm.0
dev.ithwm.0.avcc3: 3300
dev.ithwm.0.vbat: 3146
dev.ithwm.0.vin7: 2200
dev.ithwm.0.vin5: 2288
dev.ithwm.0.vin4: 1947
dev.ithwm.0.vin2: 1947
dev.ithwm.0.vin1: 1364
dev.ithwm.0.vin0: 1364
dev.ithwm.0.fan4: 1369
dev.ithwm.0.fan3: 0
dev.ithwm.0.fan2: 1303
dev.ithwm.0.fan1: 1113
dev.ithwm.0.temp2: 36.0C
dev.ithwm.0.temp1: 34.0C
dev.ithwm.0.temp0: 35.0C
```

| sysctl | Unit | Notes |
|---|---|---|
| `temp0..2` | decikelvin (`IK`, prints as °C) | registers 0x29-0x2b; a sensor reading -128 at attach is not exposed |
| `fan1..4` | RPM | 16-bit counter, `RPM = 1350000 / (count * 2)`; 0 = stalled/absent. No `fan0`: the chip has no FAN1 input |
| `vin0,1,2,4,5` | mV | voltage **at the VIN pin**, 11 mV per ADC step; which rail it watches is board-specific; no `vin3`/`vin6` (not bonded out) |
| `vin7` | mV | VSB, internally halved: 22 mV per step; reads 2.2 V on the WTR MAX (see below) |
| `vbat` | mV | CMOS battery, internally halved: 22 mV per step |
| `avcc3` | mV | register 0x2f, the chip's own 3.3 V supply, internally halved: 22 mV per step; a built-in check of the scaling |

VIN0 to VIN5 are general-purpose ADC inputs (0 to about 3 V). The
board vendor decides which rail each pin watches, and higher rails
(5 V, 12 V) reach the pin through a resistor divider. So `vinN` is the
pin voltage, not the rail voltage. `sysctl -d` says so:
`Voltage at VIN0 pin in millivolts (rail is board-specific)`.

The board in nas is a TianBei "WTR MAX" (AOOSTAR WTR MAX, from `kenv
smbios.planar.*`). There is no published VIN mapping for it. Guesses
from how the values behave (unconfirmed):

| sysctl | Observed | Likely |
|---|---|---|
| `vin0`, `vin1` | 308 to 1364 mV, changes with load | CPU core/SoC rails, read without a divider |
| `vin2`, `vin4` | 1947 mV, constant | a fixed rail (12 V or 5 V?) through a divider |
| `vin5` | 2288 mV, constant | a fixed rail, unknown |

To label them, compare with the BIOS hardware-monitor page; each
multiplier is the BIOS value divided by the `vinN` value. The
[shauno8/it87](https://github.com/shauno8/it87) fork ships an IT8613E
register map (CSV/PDF), the closest thing to a datasheet found so far.

### Register facts and where they come from

All from the Linux drivers, since the datasheet was not at hand:

- `drivers/hwmon/it87.c` (mainline): fan/VIN/temp register addresses,
  and `FAN16_FROM_REG(val) = 1350000 / (val * 2)`, where the comment
  says "the divider is fixed to 2 in 16-bit mode".
- [frankcrawford/it87](https://github.com/frankcrawford/it87)
  (out of tree, the only one with IT8613E support):
  - The IT8613E feature list has `FEAT_16BIT_FANS` but not
    `FEAT_FAN16_CONFIG`, so the tachometers are always 16-bit.
  - It has `FEAT_11MV_ADC`, `FEAT_FIVE_FANS` and `FEAT_IN7_INTERNAL`.
  - The `it8613` branch of `it87_find()` sets: "No fan1", "No VIN3",
    "No VIN6".
  - `in_scaled` doubles the LSB for in7 (VSB) and in8 (Vbat) on chips
    where `has_scaling()` is true, which covers 11 mV ADCs. AVCC3
    (in9, register 0x2f) is doubled the same way.
- [shauno8/it87](https://github.com/shauno8/it87), another IT8613E
  fork: its `ITE_Register_map.csv` lists no VIN registers, only
  `ADC res. 11 mV` for this chip. Its `it87.c` doubles in7 exactly as
  above, and the IT8613E board in its README reads
  `3VSB: 3.28 V` and `+3.3V: 3.30 V`.

### Why vin7 reads 2.2 V

A raw dump of registers 0x20-0x2f on nas (read-only, through
`/dev/io`, same index/data ports as the driver):

```
0x27 (VIN7)  raw=100  x22=2200 mV
0x28 (VBAT)  raw=143  x22=3146 mV
0x2f (AVCC3) raw=149  x22=3278 mV
```

AVCC3 goes through the same internal divider and reads a correct
3.3 V with the doubling. So the scaling is right on this chip, and
the VIN7 pin itself sits at half of 2.2 V. The shauno8 README board
has raw 149 on its 3VSB, not 100. Why the WTR MAX differs is unknown,
which is why the sysctl description says "VIN7 (VSB)" and not "3VSB".

## `amdpower`: AMD RAPL power sensors

Attaches once system-wide, under the first matching AMD root complex
(`hostb`), on Family 17h, 19h and 1Ah CPUs.

```
$ sysctl dev.amdpower.0.interval_ms dev.amdpower.0.pkg_power dev.amdpower.0.core0_power
dev.amdpower.0.interval_ms: 250
dev.amdpower.0.pkg_power: 4257
dev.amdpower.0.core0_power: 16
```

On nas there are `core0_power` .. `core7_power` (8 physical cores, 16
threads).

| sysctl | Unit | Notes |
|---|---|---|
| `pkg_power` | mW | MSR `0xC001029B`, package energy |
| `coreN_power` | mW | MSR `0xC001029A`, one per **physical** core (the description names the logical CPU used) |
| `interval_ms` | ms | read-write, 10..60000, default 250 |

How it works:

- At attach, the energy unit is read from `RAPL_PWR_UNIT` (`0xC0010299`,
  bits 12:8) with `rdmsr_safe()`.
- One logical CPU per physical core is selected: the CPU whose APIC ID
  is a multiple of the threads-per-core count from CPUID
  `0x8000001E` EBX[15:8].
- Each selected CPU is checked with
  `x86_msr_op(MSR_OP_READ | MSR_OP_SAFE | MSR_OP_SCHED_ONE)`.
- A callout fires every `interval_ms`. It reads every counter in one
  `smp_rendezvous_cpus()` round, then divides the 32-bit deltas by the
  measured elapsed time (`sbinuptime()`):
  `mW = delta * 10^9 / (2^energy_shift * dt_us)`.
- The 32-bit counters wrap in about 218 s at 300 W. That is why
  `interval_ms` is capped at 60 s, where one wrap at most is handled
  by unsigned subtraction.

The sampling cost: each snapshot interrupts every sampled CPU, i.e. 4
wakeups per second per core at the default interval. On nas the box
still reported 99.7 % idle with it running.

Sanity check on nas, with a busy loop pinned to cpu0:

```
idle:            pkg_power 4257   core0_power 16
cpuset -l 0 ...: pkg_power 23749  core0_power 11908   core1_power 70
```

## Building out of tree against the running kernel

Build against the source tree the target kernel came from. For nas
that is `/usr/src` on bigone, at `a2fbd988638e`, which matches the
`main-n289791-a2fbd988638e` in nas's `uname -a`:

```sh
K=/usr/obj/usr/src/amd64.amd64/sys/GENERIC-NODEBUG
mkdir -p /tmp/ithwm-build && cd /tmp/ithwm-build
git -C ~/freebsd-src show olivier-amdpower:sys/dev/ithwm/ithwm.c > ithwm.c
printf 'KMOD=\tithwm\nSRCS=\tithwm.c device_if.h bus_if.h\n\n.include <bsd.kmod.mk>\n' > Makefile
make SYSDIR=/usr/src/sys KERNBUILDDIR=$K SRCS="ithwm.c device_if.h bus_if.h" ithwm.ko
# amdpower: same, with SRCS="amdpower.c bus_if.h device_if.h pci_if.h"
```

**Gotcha on bigone:** a plain `make` in a module directory fails with
`don't know how to make atkbdc.c`. Something in bigone's make
environment appends bhyve's source list to `SRCS` and forces
`-include opt_global.h`. The cause hasn't been found yet.
Passing `SRCS=` and `KERNBUILDDIR=` on the command line, as above,
overrides it. Building from the in-tree module directory also works:

```sh
cd ~/freebsd-src/sys/modules/ithwm
make MAKEOBJDIR=/tmp/objchk-ithwm KERNBUILDDIR=$K SYSDIR=$PWD/../..
```

## Deployment on nas

```sh
scp /tmp/ithwm-build/ithwm.ko /tmp/amdpower-build/amdpower.ko nas:/tmp/
ssh nas 'sudo install -m 555 /tmp/ithwm.ko /tmp/amdpower.ko /boot/modules/ \
  && sudo kldxref /boot/modules \
  && sudo kldunload ithwm; sudo kldload ithwm amdpower'
```

- Loading `ithwm` pulls in `superio.ko` automatically
  (`MODULE_DEPEND`).
- Boot-time loading is in `/etc/rc.conf`:
  `kld_list="amdtemp amdgpu ithwm amdpower"`. It is deliberately not in
  `loader.conf`: neither module is needed to boot, and a failing
  `kld_list` entry doesn't stop the boot. The previous rc.conf is saved
  as `/etc/rc.conf.bak-20261012`.
- The original April 2026 module is kept as
  `/boot/modules/ithwm.ko.20260413`.

A monit CPU-temperature check for this host is in
[../monit/monit_temp.sh](../monit/monit_temp.sh). It reads
`dev.amdtemp.0.core0.sensor0`. Fan speeds from `ithwm` would make a
natural companion check.

## History

- **2026-04**: first versions written in `~/freebsd-official/src`.
  The April `ithwm.ko` was installed on nas but not loaded at boot.
- **2026-10-12**: code review, then fixes. The branches were moved to
  the fork and pushed.
  - ithwm:
    - The 16-bit fan mode was "detected" from the wrong register
      (bit 3 of 0x00).
    - The 8-bit fan divisor bit layout was wrong.
    - The 16-bit RPM formula lacked the fixed `* 2`, so fans read at
      twice their speed.
    - The ADC step was 16 mV instead of 11 mV.
    - The probe matched any ITE chip.
    - fan3/fan4 were missing.
    - vin7/vbat weren't scaled.
    - fan0/vin3/vin6 don't exist on this chip.
    - The driver wasn't wired into `sys/modules`.
  - amdpower:
    - The callout migrated the softclock thread with `sched_bind()` and
      dropped its callout mutex mid-handler.
    - The package counter wrap produced garbage (32-bit counter held
      in 64 bits).
    - Power used the nominal interval instead of the measured one.
    - Multi-node CPUs got one instance per root complex: 4 on bigone's
      EPYC 7502P.
    - It used a plain `rdmsr()` on `RAPL_PWR_UNIT`.
    - Cores were selected by CPU number instead of APIC ID.
    - `interval_ms` had no bounds.
  - Running the April `kldload ithwm` that day showed 100 % CPU and
    stalled `kldstat` for a while. The load did complete: `superio0`
    and `ithwm0` were attached and readable afterwards. The cause was
    not captured, and loading the fixed modules didn't reproduce it.

## Open questions

- **vin7 (VSB) reads 2200 mV.** The scaling is ruled out: `avcc3`
  reads 3300 mV through the same divider. What the WTR MAX feeds into
  VIN7 is unknown. A BIOS hardware-monitor reading may name it.
- **Fan RPM**: the new values are half of what the April driver
  showed (e.g. 1113 vs 2102). Linux's formula supports the new
  numbers. A BIOS reading would confirm it.
- **Fans that may be disabled**: frankcrawford/it87 also reads Super I/O
  GPIO config registers (0x27, 0x29, 0x2a) to tell whether fan3, fan4
  and fan5 are actually enabled. `ithwm` doesn't, so a disabled input
  just reads 0.
- **Kernel config**: the `files.x86` / NOTES entries have not been
  tested with a kernel build that includes `device ithwm` or
  `device amdpower`. Only the modules were built.
- **amdpower on multi-socket systems**: `pkg_power` reports only the
  package containing the first sampled core (documented in BUGS).
- **Before submitting upstream**: rebase both branches on current
  `main` and decide whether `amdpower` should expose raw energy
  counters instead of polled power. That is what Linux does, and it
  would remove the periodic wakeups.
