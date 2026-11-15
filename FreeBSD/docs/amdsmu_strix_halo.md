# amdsmu(4) and suspend-to-idle on Strix Halo (HP ZBook Ultra G1a)

Status, analysis and patch for suspend-to-idle on the AMD Ryzen AI Max+ PRO
395 (Strix Halo, family 1Ah model 70h) on FreeBSD 16.0-CURRENT.
Hardware context: [HP.ZBook.Ultra.G1a.md](../HP.ZBook.Ultra.G1a.md#suspend).
Patches, in commit order. Rows 1-6 are on main 83c8ec72ac6a, row 7 on main
cf58c8667cfd. Branches:
[olivier-amdsmu-strixhalo](https://github.com/ocochard/freebsd-src/compare/main...olivier-amdsmu-strixhalo) (1-2),
[olivier-s2idle-wake](https://github.com/ocochard/freebsd-src/compare/main...olivier-s2idle-wake) (3-5),
[olivier-pci-d3hot](https://github.com/ocochard/freebsd-src/compare/main...olivier-pci-d3hot) (7).

| # | Commit | Patch | Files | Status | Depends on |
|---|---|---|---|---|---|
| 1 | amdsmu: Add Strix Halo support | [0001](amdsmu/0001-amdsmu-Add-Strix-Halo-support.patch) [ef5cf02d0c68](https://github.com/ocochard/freebsd-src/commit/ef5cf02d0c68) | `amdsmu.h`, `amdsmu_reg.h` | done, tested: attaches, SMU 100.7.0, same 19 IP blocks as Linux; ready to send | nothing |
| 2 | amdsmu: Diagnose S0i3 blockers on Strix Halo | [0002](amdsmu/0002-amdsmu-Diagnose-S0i3-blockers-on-Strix-Halo.patch) [d01374ae8a23](https://github.com/ocochard/freebsd-src/commit/d01374ae8a23) | `amdsmu.c` | done, tested: blocker report after resume, USB4_1 garbage filtered | 1 |
| 3 | acpi: let drivers add wake interrupts for suspend-to-idle | [0001](amdsmu/s2idle/0001-acpi-let-drivers-add-wake-interrupts-for-suspend-to-.patch) [a7953aee9189](https://github.com/ocochard/freebsd-src/commit/a7953aee9189) | `acpi.c`, `acpivar.h` | done, tested: `do_idle()` unmasks the registered IRQ | nothing |
| 4 | amdgpio: arm the _AEI wake pins for suspend-to-idle | [0002](amdsmu/s2idle/0002-amdgpio-arm-the-_AEI-wake-pins-for-suspend-to-idle.patch) [f6dffc5c60ea](https://github.com/ocochard/freebsd-src/commit/f6dffc5c60ea) | `amdgpio.c`, `amdgpio.h` | done, tested: pins armed and restored; power button (pin 54) still does not wake | 3 |
| 5 | acpi_cpu: use the deepest Cx state during suspend-to-idle | [0003](amdsmu/s2idle/0003-acpi_cpu-use-the-deepest-Cx-state-during-suspend-to-.patch) [37464069e6be](https://github.com/ocochard/freebsd-src/commit/37464069e6be) | `acpi_cpu.c` | done, tested: key wakes, clean resume with the default `cx_lowest` C1 | nothing |
| 6 | pci: power down driverless USB4 hosts on suspend | not exported, a28c828ac613 (local, not pushed) | `pci.c` | tested: NHI0/NHI1 reach D3cold, blockers unchanged; not proposed | nothing |
| 7 | pci: Accept D3hot in pci_set_powerstate_method() | [pci_d3hot.patch](pci_d3hot.patch) [d60158ffee8f](https://github.com/ocochard/freebsd-src/commit/d60158ffee8f), tutorial [pci_d3hot.md](pci_d3hot.md) | `pci.c` | done, tested (same code in the test kernel): GPU reaches D3hot, resume fine; S0i3 blockers unchanged; bug on its own since 84bbfc32a3f4 | nothing |

Linux reference data:
[amdsmu/linux_s2idle_reference.txt](amdsmu/linux_s2idle_reference.txt),
[amdsmu/linux_gpio_debug.txt](amdsmu/linux_gpio_debug.txt).

## Status (2026-11-15)

| | FreeBSD, no amdsmu | FreeBSD + amdsmu | FreeBSD + amdsmu + `olivier-s2idle-wake` | Linux 7.0 (Ubuntu) |
|---|---|---|---|---|
| Sleep entered | yes, shallow | yes | yes | yes |
| S0i3 reached | no | unknown (never resumed) | no: DISPLAY, GFX, JPEG_1, USB3_0/1, MPM stay active | yes, 32.4 s |
| Wakes on a key | yes | no, fans spin up | yes | yes |
| Wakes on the power button | not tried | no | no | not tried |
| After resume | NVMe controller fails, no network | forced power off | network, NVMe and amdgpu fine | fine |

`amdsmu(4)` attaches with a one-row patch; with the C-state fix suspend and
resume work, but the SoC does not reach S0i3 yet, so sleeping still drains
the battery.

## Background: what suspend-to-idle needs on AMD

This laptop has no S3 ("suspend to RAM" done by the firmware): the firmware
only offers S4/S5 (`hw.acpi.supported_sleep_state`). Modern laptops use
*suspend-to-idle* instead, where the OS itself puts every device into a low
power state and then idles the CPUs. The SoC can then drop into its deepest
idle state, called **S0i3** on AMD, which uses about as little power as S3.

Two pieces of firmware cooperate with the OS on AMD:

- the **SMU** (System Management Unit) firmware decides whether the SoC may
  enter S0i3. The OS sends it a *sleep hint* before idling, and the SMU
  keeps statistics: how long it took to enter S0i3, how long it stayed, and
  which internal blocks ("IP blocks": display, GPU, USB controllers, ...)
  were still busy if it could not enter.
- **ACPI** firmware (and the embedded controller, EC, which handles the
  keyboard, lid and power button) delivers *wake events* back to the OS.

On FreeBSD `amdsmu(4)` talks to the SMU, `acpi_spmc(4)` runs the ACPI
"low power S0 idle" notifications, and `acpi(4)` runs the suspend itself.

## The patch: amdsmu(4) for Strix Halo

`amdsmu(4)` keeps a table of supported chips, keyed by the PCI device ID of
the host bridge (the "root complex") and optionally the CPU model; each row
gives the SMU mailbox message register, the idle-mask register, and the
names of the IP blocks in the order the SMU reports them. Strix Halo was
missing: its root complex is 1022:1507 and the driver loaded without
attaching.

Linux's `amd_pmc` driver (`drivers/platform/x86/amd/pmc/pmc.c`) treats
1022:1507 (`PCI_DEVICE_ID_AMD_1AH_M20H_ROOT`) exactly like 1022:1122
(`1AH_M60H_ROOT`, FreeBSD's Krackan Point): for CPU model 0x70 it uses
`amd_1ah_m70_cpu_info`, i.e. message register 0x938, idle-mask (scratch)
register 0xF14 and the 25-entry IP block table `soc15_ip_blk_v2`. FreeBSD's
Krackan Point model-0x70 row already has these values, and FreeBSD's
`amdsmu_ip_blocks_names_v2` is identical to Linux's table, so the patch is
one device ID and one table row:

```c
#define PCI_DEVICEID_AMD_STRIX_HALO_ROOT	0x1507

	{ CPU_VENDOR_AMD,	PCI_DEVICEID_AMD_STRIX_HALO_ROOT,	0x70,
	    SMU_REG_IDLEMASK_KRACKAN,	25,	amdsmu_ip_blocks_names_v2,
	    SMU_REG_MSG_KRACKAN },
```

`amdsmu_match()` walks the table from the end, so a model-specific row wins
and a model-only row works without a generic one. Linux also supports other
CPU models on 1022:1507 (family 1Ah model 20h) with the 22-entry table; no
such hardware here, so that row is not added.

Result on the laptop:

```
amdsmu0: <AMD System Management Unit> on hostb0
amdsmu0: SMU version: 100.7.0 (program 10)
amdsmu0: Active IP blocks: DISPLAY VDD VDD_CCX VCN_0 VCN_1 ISP DF USB3_0
    USB3_1 USB4_RT0 USB4_RT1 USB4_0 USB4_1 MPM JPEG_0 JPEG_1 IPU UMSCH VPE
dev.amdsmu.0.metrics.table_version: 3
```

Linux's `amd_pmc` lists the same 19 active IP blocks in the same order,
which independently confirms the table row. One value is garbage on both
systems (`USB4_1` active time), matching the driver's existing comment for
Phoenix and Krackan Point.

## Suspend with amdsmu on FreeBSD: hangs

With the module loaded (and mt76 unloaded), `zzz` suspends: the power LED
blinks slowly. Neither a key nor the power button wakes it, the fans spin
up, and only a forced power off recovers. The log ends at
`acpi: suspend at ...`; there is no resume message and no crash dump. The
ZFS pool was healthy afterwards.

Without amdsmu the SMU gets no sleep hint, the SoC stays in a shallow idle
and any interrupt (a key press) wakes it. With the hint the SoC goes deeper
and only armed wake sources can wake it; the fans suggest the transition
itself also went wrong.

## Linux reference: what works

One `systemctl suspend` on Ubuntu (Linux 7.0.0-43), woken with the space key:

- S0i3: `Last S0i3 Status: Success`, 587776 us to enter, 32420471 us in
  S0i3, 334255 us to resume; `Hint Count: 1`.
- Wake: `/sys/power/pm_wakeup_irq` is 9, the ACPI SCI. GPE 03 is the only
  GPE that fired (850 events, enabled, unmasked): the EC's GPE. During the
  suspend Linux logged `ACPI: EC: interrupt blocked` and, on resume,
  `ACPI: EC: interrupt unblocked`.
- GPIO pins armed for S0i3 wake by `pinctrl_amd`: #18 (edge), #54 (edge),
  #58, #59, #61, #62 (level): the `_AEI` pins, see below.
- ACPI wake enabled (`/proc/acpi/wakeup`): PCIe root ports GP11, GP12,
  GP23; USB controllers XHC0, XHC1, XHC3, XHC4; USB4 NHI0, NHI1.
- NVMe resumes normally (`nvme0: 32/0/0 default/read/poll queues`).

## The GPIO wake pins

`\_SB.GPIO` (AMDI0030, `amdgpio(4)`) has an `_AEI` (ACPI event interrupts)
method in SSDT 20 that returns six GPIO interrupt descriptors as a raw
buffer. Decoded (interrupt flags word: bit 0 edge, bits 1-2 polarity, bit 4
wake capable), with what the `_EVT` handler does for each pin:

| Pin | Flags | Trigger | `_EVT` | Wakes for |
|---|---|---|---|---|
| 18 | 0x0013 | edge, active low, ExclusiveAndWake | `Notify (\_SB.PCI0.GP23, 2)` | PCIe root port GP23 (the Wi-Fi slot, `GP23.NCRD`) |
| 54 | 0x0011 | edge, active high, ExclusiveAndWake | `Notify (MP2C, 2)`, `PWRB 0x80` | the power button |
| 58 | 0x0010 | level, active high, ExclusiveAndWake | `Notify (XHC0, 2)` | USB controller XHC0 |
| 59 | 0x0010 | level, active high, ExclusiveAndWake | `Notify (XHC1, 2)` | USB controller XHC1 |
| 61 | 0x0010 | level, active high, ExclusiveAndWake | `Notify (HDEF, 2)` | HD audio |
| 62 | 0x0010 | level, active high, ExclusiveAndWake | `Notify (ACP, 2)` | audio coprocessor |

These are exactly the six pins Linux arms for S0i3 wake. (The touchpad and
touchscreen are on pins 8 and 0, not in `_AEI`.) On FreeBSD,
`kldload amdgpio` finds the same set (`gpiobus0: <unknown device> at pins
61-62,58-59,18,54`, the `gpio_aei` child), but:

- `acpi_gpiobus_enumerate_aei()` copies the pin numbers and ignores each
  descriptor's wake flag;
- `amdgpio.h` defines the per-pin wake enables (`WAKE_CNTRL_OFF_S0I3` 13,
  `_S3` 14, `_S4` 15), and nothing in the tree ever sets them;
- `amdgpio_suspend()` masks and disables the interrupt of every pin, the
  wake pins included ("In the future we should only mask non-wake
  interrupts").

So with FreeBSD no GPIO pin can wake the SoC from S0i3, the power button
included. Linux's `pinctrl_amd` sets the S0i3/S3 wake bits of each
wake-capable `_AEI` interrupt and masks only the other pins on suspend.
Also, `amdgpio` is not loaded at boot without the PnP-info patch from the
CS35L54 work, and it was not loaded in the FreeBSD suspend test.

## FreeBSD's suspend-to-idle path

`acpi_EnterSleepState()` in `sys/dev/acpica/acpi.c` suspends all devices,
then for suspend-to-idle calls `do_idle()`, which masks every interrupt
except the SCI (`intr_enable_src(AcpiGbl_FADT.SciInterrupt)`) and idles the
boot CPU once with `cpu_idle(0)`. Its own comment says it should become a
loop that checks why it woke and idles again. Compared with Linux:

- GPEs: for suspend-to-idle Linux switches to wake GPEs only and adds the
  EC GPE to that wake set. FreeBSD skips `AcpiEnterSleepStatePrep()` for
  suspend-to-idle, `acpi_ec_suspend()` only switches the EC to polling, so
  the EC GPE stays enabled as an ordinary runtime GPE (which is how a key
  woke the shallow idle), plus the `_PRW` wake GPEs from
  `acpi_wake_prep_walk()`. Whether S0i3 needs the GPE armed for wake is
  not known;
- GPIO wake: see the previous section; FreeBSD never arms the wake pins;
- devices: Linux puts NVMe and others in D3 and brings them back; FreeBSD's
  NVMe controller failed on resume from the shallow idle already.

These are leads, not verified causes.

## GPIO wake fix: not enough

Branch `olivier-s2idle-wake` (main 83c8ec72ac6a) has two commits for this:

- `acpi: let drivers add wake interrupts for suspend-to-idle`: `do_idle()`
  unmasked only the SCI; drivers can now register up to four more wake
  interrupts that stay unmasked.
- `amdgpio: arm the _AEI wake pins for suspend-to-idle`: reads the wake
  capable `_AEI` pins (trigger, polarity) at attach and registers the GPIO
  controller interrupt (IRQ 7, separate from the SCI on IRQ 9); on suspend
  arms them as Linux does (interrupt enabled and unmasked, S0i3/S3 wake
  bits, no debounce; an asserted level pin is skipped since nothing runs
  `_EVT` to clear it), masks the others; on resume restores them.

Tested with both modules loaded (DTrace showed IRQ 7 registered): the
laptop sleeps, but neither the power button nor the space key wakes it.
The power LED keeps blinking, the Caps Lock LED lights only while the key
is held (the EC, not FreeBSD, which would latch it), the fans spin up,
forced power off. The system never resumed: the wake reached the EC, but
nothing brought the SoC and the CPUs back.

## Lead: the CPUs never idle below C1

```
hw.acpi.cpu.cx_lowest: C1
dev.cpu.0.cx_supported: C1/1/1 C2/2/18 C3/3/350
dev.cpu.0.cx_method: C1/mwait C2/io C3/io
dev.cpu.0.cx_usage: 100.00% 0.00% 0.00%
```

S0i3 needs every core in its deepest idle state (CC6, reached here through
the I/O port C-states). FreeBSD keeps all cores in C1, and `do_idle()` only
calls `cpu_idle(0)` once on the boot CPU, while `amdsmu(4)` tells the SMU
the OS is ready to sleep; Linux idles every core in its deepest state
during suspend-to-idle. The sleep hint itself matches Linux (message 0x03,
argument 1).

## With Cmax: suspend and resume work, no S0i3 yet

With `hw.acpi.cpu.cx_lowest=Cmax` (cores mostly in C3; stable for minutes,
no new messages), the `olivier-s2idle-wake` kernel, amdgpio and amdsmu:
the laptop sleeps, the power button still does nothing, **the space key
wakes it, and it resumes**: network (ssh, ping 127.0.0.1) works, NVMe only
resubmits queued writes (no "Complete Failed controller"), amdgpu passes
its ring tests, USB devices detach and reattach, Bluetooth reset fails.
So the hang came from the cores never going below C1.

The SoC did not reach S0i3 (`amdsmu0: failed to enter S0i3 during last
suspend`): `hint_count` 1, 67.07 s in software DRIPS, 0 in S0i3. IP blocks
active for the whole 67.07 s, i.e. blocking S0i3:

| IP block | Probable FreeBSD cause |
|---|---|
| DISPLAY, GFX, JPEG_1 | amdgpu (drm-kmod) not taking its S0ix low-power path |
| USB3_0, USB3_1 | xhci controllers not put in D3 |
| MPM | power management firmware, likely waiting on the others |

(CPU and JPEG_0 were active 0.49 s; `USB4_1` is the known garbage value.)
`amdsmu` printed "only limited diagnostic information available for
1022:1507": its blocker diagnostics switch on the Phoenix and Krackan Point
IDs.

## Fix: deepest C-state during suspend-to-idle

Third commit on `olivier-s2idle-wake`, `acpi_cpu: use the deepest Cx state
during suspend-to-idle`: an `acpi_post_dev_suspend` handler saves each
CPU's `cpu_cx_lowest_lim` and raises it to its deepest state for
suspend-to-idle only (before amdsmu's sleep hint, which is registered
last); an `acpi_pre_dev_resume` handler restores the saved per-CPU value.

Tested with `cx_lowest` left at its C1 default: suspend, space key wakes,
full resume, `cx_lowest` reads C1 again afterwards (global and per CPU),
no NVMe failure. Still no S0i3 (50.3 s in software DRIPS), as with the
manual Cmax. Limit: the boot CPU's single `cpu_idle(0)` in `do_idle()`
still picks its state by latency from the previous sleep, so it may use C2
rather than C3; Linux enters the deepest state explicitly.

## amdsmu diagnostics for Strix Halo

Second commit on `olivier-amdsmu-strixhalo`, `amdsmu: Diagnose S0i3
blockers on Strix Halo`: adds 1022:1507 to the switch in
`amdsmu_resume_check()` that enables the blocker report, and skips blocks
reported active for longer than the sleep (a real blocker equals the sleep
time exactly; `USB4_1` always reads about 4.6e18 us here, on Linux too).
After the next resume:

```
amdsmu0: failed to enter S0i3 during last suspend; battery drain will be excessive
amdsmu0: IP blocks that blocked S0i3 entry:
amdsmu0:   DISPLAY (active for 33344564 us)
amdsmu0:   GFX (active for 33344564 us)
amdsmu0:   USB3_0 (active for 33344564 us)
amdsmu0:     hint: load tb to allow this block to suspend
amdsmu0:   USB3_1 (active for 33344564 us)
amdsmu0:   MPM (active for 33344564 us)
amdsmu0:     hint: this can happen due to other IP blocks or because the CPU didn't properly idle
amdsmu0:   JPEG_1 (active for 33344564 us)
```

The `tb` hint comes from the shared hint table and does not fit this
laptop (`thunderbolt(4)` does not know its USB4 controllers); making hints
per chip is left out.

## USB3_0/USB3_1: not the xhci controllers, not the USB4 hosts

With `debug.bootverbose=1` the suspend log shows every PCI function FreeBSD
controls going to D3cold through ACPI (`Transition from D0 to D3cold`, `set
ACPI power state D3cold on ...`): the four xhci controllers (`XHC0`,
`XHC1`, `XHC3`, `XHC4`, which have `_S0W`, `_PR0`/`_PR3` and no `_S3D`),
NVMe and its root port, HD audio, the PCIe root ports and the I2C
controllers; the LPS0 `_DSM` calls (DISPLAY_OFF, LPI_ENTRY, SLEEP_ENTRY)
all succeed. `PCI_POWERSTATE_D3` is `PCI_POWERSTATE_D3_COLD` in this tree,
so FreeBSD already asks for D3cold.

amdsmu's comment says USB3_0/USB3_1 report USB4 on Phoenix and Krackan
Point. The two USB4 host interfaces (`NHI0`/`NHI1`, 1022:158d and 158e,
class 0x0c0340) have no driver and stay in D0, since unattached functions
keep their power state over suspend (`pci_set_power_child()` skips them,
`hw.pci.do_power_nodriver` is 0). Two tests:

- `pciconf -w` PMCSR to D3hot before suspend (stays in place over the
  sleep, `pci_cfg_restore()` brings them back to D0): no change.
- Fourth commit on `olivier-s2idle-wake`, `pci: power down driverless USB4
  hosts on suspend`: `pci_set_power_child()` also handles unattached
  class/subclass/progif USB4 functions. Both now go to D3cold through ACPI
  on suspend and back to D0 on resume, but USB3_0 and USB3_1 still block.

So the remaining USB blockers are neither the xhci controllers nor the USB4
host interfaces in D0. Nor the USB-C dock: with it unplugged (Wi-Fi on a
kernel with both series, `test-wifi-s2idle`), the blockers are the same
(DISPLAY, GFX, USB3_0, USB3_1, MPM, JPEG_1, 32.5 s). Remaining candidate:
Linux's thunderbolt driver puts the USB4 routers to sleep before powering
the host interfaces down (amdsmu's hint says "load tb"); FreeBSD's
`thunderbolt(4)` has a router suspend routine (02880ddf9ed0, 2026-10-09).

`thunderbolt(4)` (module `tb`, not in GENERIC: "Disabled for now since
thunderbolt(4) breaks suspend/resume in some instances") probes USB4
hosts by class, so it attaches to these without a code change:

```
nhi0: <Generic USB4 NHI> mem 0xd4600000-0xd467ffff at device 0.5 on pci5
nhi0: Cannot find Upstream Facing Port
nhi0: Host interface is version 1.0
nhi0: Error finding LC registers: 22
nhi0: Root Router UUID: ffffffff-ffff-ffff-0438-17d6d5e64fe0
```

(same for `nhi1`). With it loaded, the laptop suspends (LED blinks), the
space key lights the keyboard backlight but the screen stays black and the
network never comes back: resume hangs, forced power off, nothing logged.
`tb`'s resume path (with its UFP and LC register errors) is the prime
suspect.

Side results of that run: mt7925 (no PM handlers) loses its firmware over
the sleep (`driver own failed`, MCU timeout), reloads it by itself, but
`wlan0` stays down; and the DHCP default route stayed on the dead `wlan0`,
so the replugged `ue0` could not reach the gateway until `wlan0` was
destroyed and a default route added.

## amdgpu: the S0ix path is taken

Linux amdgpu picks its suspend-to-idle sequence with
`amdgpu_acpi_is_s0ix_active()` (`amdgpu_acpi.c`), which sets
`adev->in_s0ix` when all of these hold: `CONFIG_SUSPEND`,
`pm_suspend_target_state == PM_SUSPEND_TO_IDLE`, an APU of Raven or later
with GFXOFF in `pp_feature`, `ACPI_FADT_LOW_POWER_S0` in the FADT, and
`CONFIG_AMD_PMC`. On FreeBSD with drm-kmod `drm_v6.12.85_3`:

- `kconfig.mk` defines `CONFIG_SUSPEND` and `CONFIG_AMD_PMC`;
- LinuxKPI sets `pm_suspend_target_state = PM_SUSPEND_TO_IDLE` from the
  `power_suspend_early` event (a25cfcab9a9d), which `acpi.c` invokes before
  `DEVICE_SUSPEND(root_bus)`, so before amdgpu's suspend method;
- the FADT has `LOW_POWER_S0`, and amdgpu never logged its "Power
  consumption will be higher" message;
- on resume amdgpu logs the same sequence as Linux (GART, "SMU is
  resuming...", "SMU is resumed successfully!").

Reading `dri/drmn0/amdgpu_gfxoff_status` through lindebugfs froze the
whole laptop (forced power off). Do not read the amdgpu GFXOFF debugfs
files on FreeBSD.

A `printf` around `amdgpu_device_suspend()` in `amdgpu_pmops_suspend()`
(drm-kmod `drm_v6.12.85_3` plus the strix-halo port patches, debug only)
confirms it:

```
amdgpu S0i3dbg: suspend in_s0ix 1 in_s3 0 gfxoff 1 req 0 pp_gfxoff 1
amdgpu S0i3dbg: after suspend r 0 gfxoff 1 req 0
```

`in_s0ix` is set, GFXOFF is enabled and engaged (`gfx_off_state` 1, no
one holds a GFXOFF-disable request), and the suspend returns 0. The same
run still reports DISPLAY, GFX, JPEG_1, USB3_0, USB3_1 and MPM active the
whole 34.7 s. So the amdgpu S0ix sequence and GFXOFF are not the missing
piece; the blockers come from something outside amdgpu's suspend method.

## GPU stays in D0: FreeBSD rejects D3hot

With `debug.bootverbose=1`, every function next to the GPU goes to D3cold
over suspend (HDAU 195:0:1, XHC1 195:0:4, HDEF 195:0:6), then the parent
bridge GPPA (0:8:1), but the GPU itself (`vgapci0`, 195:0:0) logs nothing.
The LPS0 constraint table (`ssdt27`) asks for `\_SB.PCI0.GPPA.GFX0` in D3.
DTrace cannot see this: over `zzz` it aborts with "processing aborted:
Abort due to systemic unresponsiveness". A debug `printf` in
`pci_set_power_child()` shows:

```
vgapci0: XXX suspend_child error 0 do_power 1
vgapci0: XXX set_power_child state 4 attached 1 cur 0
vgapci0: XXX dstate 3
```

Suspend asks for `PCI_POWERSTATE_D3` (D3cold, 4); GFX0's `_S3D` returns 3,
which is D3hot since 84bbfc32a3f4 ("acpi_powerres: D3cold support") split
D3 into D3hot (3) and D3cold (4). `pci_set_powerstate_method()` only has a
`case PCI_POWERSTATE_D3` (D3cold), so D3hot falls into `return (EINVAL)`;
`acpi_pci_set_powerstate_method()` then skips the ACPI transition and
nothing is logged. Every device whose `_SxD` returns 3 stays in D0. Still
in freebsd/main cf58c8667cfd and in stable/15 (releng/15.0 to 15.2).

Fix ([pci_d3hot.patch](pci_d3hot.patch), tutorial [pci_d3hot.md](pci_d3hot.md), branch `olivier-pci-d3hot`): accept D3hot and D3cold in
`pci_set_powerstate_method()` (both write D3 to the PM register), use the
10 ms delay for both, and treat D3hot/D3cold as no change since the
register cannot tell them apart. With it the GPU goes to D3hot and ACPI
switches GFX0 to D3hot; amdgpu resumes fine:

```
pci0:195:0:0: Transition from D0 to D3hot
pci3: set ACPI power state D3hot on \_SB_.PCI0.GPPA.GFX0
```

The S0i3 blockers do not change (DISPLAY, GFX, USB3_0, USB3_1, MPM, JPEG_1
for the whole 22 s). The fix is a real bug fix on its own, but not the S0i3
blocker.

## SMU sleep hint order and CPU idle: same as Linux

The hint is not sent too early. Linux 7.2
(`acpi_s2idle_prepare_late_lps0()` in `drivers/acpi/x86/s2idle.c`) runs,
after all devices suspend: AMD and Microsoft screen off, AMD LPS0 entry,
Microsoft sleep entry and LPS0 entry, then the `amd_pmc` prepare hook,
which sends `MSG_OS_HINT_RN` (3) with argument 1. FreeBSD runs the same
DSM calls (Microsoft screen off before AMD's) from `acpi_spmc_suspend`
(`acpi_post_dev_suspend`, priority ANY), then `amdsmu_suspend` (priority
LAST) sends message 0x03 with argument 1. The only other Linux step is a
reset and restart of the SMU log before the hint (statistics only).

The SMU never starts S0i3 at all: time entering S0i3 is 0 (Linux 587776
us), and every blocker reports exactly the whole software DRIPS time. The
idle mask after resume is 0x5c37b9ac (Linux 0x5f73398c, bits undocumented).

CPU idle during the sleep, from a debug `printf` of each CPU's
`cpu_cx_stats` in `acpi_cpu_s2idle_resume()` before the limit is restored
(C1 C2 C3 entries over one 21.4 s sleep):

```
XXX cpu0 cx_stats 1 4 4 prev_sleep 712355
XXX cpu1 cx_stats 0 2 2 prev_sleep 3959130
XXX cpu7 cx_stats 0 6 12 prev_sleep 124261
XXX cpu23 cx_stats 0 1 23 prev_sleep 2871787
XXX cpu31 cx_stats 0 0 3 prev_sleep 5333120
```

All 32 CPUs idle only 3 to 24 times in 21 s, mostly in C3 (the deepest
`_CST` state, 350 us latency), with idle periods of seconds. Some C2
entries remain (bus master activity or the minutes before `do_idle()`),
so the last state of each CPU is not proven, but the cores do sleep deep.

## Without amdgpu: only USB3_0/USB3_1 left

Same kernel, `amdgpu` removed from `kld_list` (console on the EFI
framebuffer), one 29.2 s sleep:

```
amdsmu0: IP blocks that blocked S0i3 entry:
amdsmu0:   GFX (active for 29226337 us)
amdsmu0:   USB3_0 (active for 29226337 us)
amdsmu0:   USB3_1 (active for 29226337 us)
amdsmu0:   JPEG_1 (active for 29226337 us)
```

DISPLAY and MPM no longer block: with amdgpu loaded, its suspend leaves
the display controller active (and MPM with it). GFX and JPEG_1 block with
or without amdgpu, so they need something no FreeBSD code does today
(Linux gets there with amdgpu loaded). USB3_0/1 are unchanged. Still no
S0i3 attempt (time entering 0).

The per-CPU counts show the boot CPU never reached C3 in this run
(`cpu0 cx_stats 10 7 0 prev_sleep 98533`) while the 31 others did (3 to
15 C3 entries each). In the amdgpu run cpu0 had 4 C3 entries. `do_idle()`
calls `cpu_idle(0)` once, and `acpi_cpu_idle()` picks the state from
`cpu_prev_sleep`, so the boot CPU's sleep depth depends on its recent
history.

A second suspend in the same boot (still no amdgpu, 71.8 s) leaves only
USB3_0 and USB3_1:

```
amdsmu0: IP blocks that blocked S0i3 entry:
amdsmu0:   USB3_0 (active for 71831002 us)
amdsmu0:   USB3_1 (active for 71831002 us)
```

GFX and JPEG_1 cleared without any driver; on the first suspend after boot
they were still active (cpu0 had 1 C3 entry this time). With amdgpu not
loaded the panel stays lit during the sleep (nothing turns it off), so the
sleep is easy to mistake for a failed suspend; the first run's "early wake"
was a key press. USB3_0/USB3_1 are now the only blockers, and still no S0i3
attempt.

## thunderbolt(4) resume: no code upstream, but one router resumes fine

`nhi_resume()` is a stub on freebsd/main (`TODO(Bug 299199)`), and
`tb_router_suspend()` only sets `ROUTER_CS_5.SLP` and polls
`ROUTER_CS_6.SLPR`. Bug 299199 (filed by the driver and amdsmu author)
lists the missing suspend steps and says they should not block S0i3; it
does not cover resume. `sc->suspended` is never cleared, so after one
cycle the next suspend returns early without putting the router to sleep.

Single-device tests with `tb` loaded (no full suspend) all come back:
`devctl suspend`/`resume` of nhi0 and nhi1 ("Ready to enter sleep",
D3cold, D0); both NHIs asleep while xhci1 (XHC0) and xhci2 (XHC3) cycle,
then the NHIs resumed. Network and system stay up.

Full suspend with `tb` loaded, `nhi1` detached, no amdgpu (52.9 s):

```
nhi0: Ready to enter sleep
pci0:197:0:5: Transition from D0 to D3cold
...
amdsmu0:   GFX (active for 52899460 us)
amdsmu0:   USB3_1 (active for 52899460 us)
```

Resume works, and USB3_0 no longer blocks: nhi0 is the USB3_0 block, and
putting its router to sleep clears it, as amdsmu's "load tb" hint says.
USB3_1 is then nhi1's router. The earlier hang had amdgpu loaded, whose
DISPLAY and GFX blockers keep S0i3 from starting, so that hang was not an
S0i3 exit; it needs either both routers or the amdgpu plus tb combination.

Same with both NHIs attached (52.9 s): both routers report "Ready to enter
sleep", resume works, and GFX is the only blocker left (still no S0i3
attempt). So `tb` with both routers is fine without amdgpu; the earlier
hang comes from `tb` together with amdgpu (untested which part).

Without amdgpu the panel stays lit during the sleep: suspend-to-idle does
not cut power to the display controller, which keeps scanning out the EFI
framebuffer until a driver (amdgpu) turns the pipe and backlight off. The
LPS0 "display off" call only notifies the firmware.

With amdgpu loaded again, `tb` with both NHIs, and the `pci` D3hot fix
(GPU in D3hot), resume works too (18.5 s sleep):

```
nhi1: Ready to enter sleep
nhi0: Ready to enter sleep
pci0:195:0:0: Transition from D0 to D3hot
amdsmu0:   GFX (active for 18471693 us)
amdsmu0:   JPEG_1 (active for 18471693 us)
```

DISPLAY and MPM clear together with USB3_0/1: with amdgpu loaded, the
display controller blocks until the USB4 routers sleep (they carry the
USB-C DisplayPort outputs; inferred, not measured). The earlier
`tb` + amdgpu hang ran on a kernel without the D3hot fix, where the GPU
stayed in D0 under a bridge in D3cold; it did not come back here. Left:
GFX and JPEG_1, still no S0i3 attempt.

## Next steps

1. `do_idle()`: make the boot CPU enter its deepest C-state explicitly.
2. USB3_0/USB3_1: `thunderbolt(4)` attaches but its resume hangs; find
   where (its suspend/resume with the UFP and LC register errors) before
   trying again.
3. amdgpu (DISPLAY, GFX, JPEG): `in_s0ix` and GFXOFF are confirmed, and
   LinuxKPI also calls `suspend_noirq` (only sets `suspend_complete` in
   S0ix). The GPU now reaches D3hot with the `pci` D3hot fix, blockers
   unchanged. Next: the order of the SMU sleep hint relative to device
   suspend, and whether these blocker times mean anything (every blocker
   reports exactly the whole software DRIPS time).
4. Power button (pin 54) still does not wake: check the `amdgpio` arming
   (register values after suspend) and the MP2 (`MP2C`) path.
5. Turn `do_idle()` into the loop its comment describes (the key wake
   through the EC GPE works, no extra arming needed).
6. Retry one suspend per change, with the disks synced first: a hang needs
   a forced power off.
7. Send the amdsmu patch: it is correct on its own (attaches, reads the SMU
   version, IP blocks and metrics; matches Linux), whatever suspend does.
   The NVMe "Complete Failed controller" seen on the C1 resumes did not
   come back with Cmax.

## Test log

| Date | Setup | Result |
|---|---|---|
| 2026-11-12 | FreeBSD main 83c8ec72ac6a, no amdsmu | sleeps, wakes on a key; NVMe controller fails, no network even on lo0, shutdown hangs |
| 2026-11-12 | stock `amdsmu.ko` | loads, does not attach (1022:1507 not in its table) |
| 2026-11-12 | patched amdsmu | attaches; SMU 100.7.0, 19 active IP blocks, metrics table version 3 |
| 2026-11-12 | patched amdsmu, `zzz` | sleeps, does not wake (key, power button), fans spin up; forced power off |
| 2026-11-13 | Ubuntu, Linux 7.0.0-43 | S0i3 success, 32.4 s; woken by space key via EC GPE 03; resume clean |
| 2026-11-13 | FreeBSD, `kldload amdgpio`, `_AEI` decode | the six `_AEI` pins are all wake capable; `amdgpio_suspend()` disables them and no code sets their wake bits |
| 2026-11-13 | `olivier-s2idle-wake` kernel + amdgpio + amdsmu, `zzz` | IRQ 7 registered; no wake by power button or key, power LED keeps blinking, fans spin up; forced power off |
| 2026-11-15 | same + `hw.acpi.cpu.cx_lowest=Cmax` | space key wakes it, full resume (network, NVMe, amdgpu); no S0i3: DISPLAY, GFX, JPEG_1, USB3_0/1, MPM active the whole 67 s |
| 2026-11-15 | + `acpi_cpu` deepest-Cx fix, `cx_lowest` C1 | space key wakes it, full resume, `cx_lowest` restored to C1; no S0i3 (50.3 s software DRIPS) |
| 2026-11-15 | + amdsmu diagnostics commit | blocker report: DISPLAY, GFX, USB3_0, USB3_1, MPM, JPEG_1; USB4_1 garbage filtered |
| 2026-11-15 | `debug.bootverbose=1` | every xhci, NVMe, root port, I2C function goes to D3cold; LPS0 calls succeed |
| 2026-11-15 | NHI0/NHI1 D3hot via pciconf | still DISPLAY, GFX, USB3_0, USB3_1 |
| 2026-11-15 | + `pci` USB4 power-down commit | NHI0/NHI1 D3cold over suspend; USB3_0, USB3_1 still block |
| 2026-11-15 | Wi-Fi + s2idle kernel, dock unplugged | same blockers; mt7925 reloads firmware after resume but `wlan0` stays down |
| 2026-11-15 | + `kldload tb` (nhi0/nhi1 attach) | resume hangs: keyboard backlight on, screen black, no network; forced power off, nothing logged |
| 2026-11-15 | read `dri/drmn0/amdgpu_gfxoff_status` (lindebugfs) | whole system froze; forced power off |
| 2026-11-15 | instrumented `amdgpu.ko` (printf in `amdgpu_pmops_suspend`) | `in_s0ix 1`, GFXOFF engaged before and after, suspend returns 0; same blockers over 34.7 s |
| 2026-11-15 | DTrace on `pci_suspend_child` over `zzz` | aborted: "Abort due to systemic unresponsiveness", no data |
| 2026-11-15 | debug `printf` in `pci_set_power_child` | GPU gets `_S3D` D3hot (3), `pci_set_powerstate_method` returns EINVAL, GPU stays D0 |
| 2026-11-15 | + `pci` D3hot fix | GPU D3hot, GFX0 ACPI D3hot, resume fine; same blockers over 22 s |
| 2026-11-15 | SMU hint order vs Linux 7.2 | same order (DSM screen off, LPS0 entry, MS entry, then hint 0x03 arg 1) |
| 2026-11-15 | debug `printf` of per-CPU Cx counts at resume | 3 to 24 idle entries per CPU in 21.4 s, mostly C3; same blockers |
| 2026-11-15 | no amdgpu loaded | blockers GFX, USB3_0, USB3_1, JPEG_1 (DISPLAY and MPM gone); cpu0 no C3 entry |
| 2026-11-15 | no amdgpu, second suspend of the boot | only USB3_0, USB3_1 block; GFX, JPEG_1, DISPLAY, MPM clear; no S0i3 attempt |
| 2026-11-15 | `tb` loaded, `devctl` suspend/resume of nhi0, nhi1, xhci1, xhci2 | all resume, system stays up |
| 2026-11-15 | `tb` loaded, `nhi1` detached, no amdgpu, `zzz` | resume works; USB3_0 cleared, GFX and USB3_1 block |
| 2026-11-15 | `tb` loaded, both NHIs, no amdgpu, `zzz` | resume works; USB3_0 and USB3_1 cleared, only GFX blocks |
| 2026-11-15 | amdgpu + `tb` (both NHIs) + `pci` D3hot fix, `zzz` | resume works (no hang); blockers GFX, JPEG_1 only |
