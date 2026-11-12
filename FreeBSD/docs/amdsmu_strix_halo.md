# amdsmu(4) and suspend-to-idle on Strix Halo (HP ZBook Ultra G1a)

Status, analysis and patch for suspend-to-idle on the AMD Ryzen AI Max+ PRO
395 (Strix Halo, family 1Ah model 70h) on FreeBSD 16.0-CURRENT.
Hardware context: [HP.ZBook.Ultra.G1a.md](../HP.ZBook.Ultra.G1a.md#suspend).
Patch: [amdsmu/0001-amdsmu-Add-Strix-Halo-support.patch](amdsmu/0001-amdsmu-Add-Strix-Halo-support.patch)
(branch `olivier-amdsmu-strixhalo`, ef5cf02d0c68 on main 83c8ec72ac6a). Linux reference data:
[amdsmu/linux_s2idle_reference.txt](amdsmu/linux_s2idle_reference.txt),
[amdsmu/linux_gpio_debug.txt](amdsmu/linux_gpio_debug.txt).

## Status (2026-11-13)

| | FreeBSD, no amdsmu | FreeBSD + Strix Halo amdsmu | Linux 7.0 (Ubuntu) |
|---|---|---|---|
| Sleep entered | yes, shallow | yes | yes |
| S0i3 reached | no ("unlikely the system entered a deep sleep state") | unknown (never resumed) | yes, `Last S0i3 Status: Success`, 32.4 s in S0i3 |
| Wakes on a key | yes | no (key and power button do nothing; fans spin up) | yes (space key) |
| After resume | NVMe controller fails, no network at all | forced power off needed | NVMe, USB, Wi-Fi fine |

`amdsmu(4)` now attaches on this laptop; making suspend work needs more.

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

Branch `olivier-s2idle-wake` (main 83c8ec72ac6a, not pushed) has two commits:

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

## Next steps

1. Set `hw.acpi.cpu.cx_lowest=Cmax`, check that the cores reach C2/C3 and
   stay stable, then retry one suspend with the `olivier-s2idle-wake`
   kernel, amdgpio and amdsmu.
2. Arm the EC GPE for wake during suspend-to-idle, as Linux does, and turn
   `do_idle()` into the loop its comment describes.
3. Look at nvme(4) suspend/resume on this controller (it failed even
   without S0i3).
4. Retry one suspend per change, with the disks synced first: a hang needs
   a forced power off.
5. Send the amdsmu patch: it is correct on its own (attaches, reads the SMU
   version, IP blocks and metrics; matches Linux), whatever suspend does.

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
