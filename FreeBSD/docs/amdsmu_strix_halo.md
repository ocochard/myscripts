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
  #58, #59, #61, #62 (level). #61 and #62 match the touchpad and
  touchscreen GpioInt pins in the hardware doc.
- ACPI wake enabled (`/proc/acpi/wakeup`): PCIe root ports GP11, GP12,
  GP23; USB controllers XHC0, XHC1, XHC3, XHC4; USB4 NHI0, NHI1.
- NVMe resumes normally (`nvme0: 32/0/0 default/read/poll queues`).

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
- GPIO wake: Linux's `pinctrl_amd` sets the S0i3 wake bits of the pins
  above; FreeBSD's `amdgpio(4)` has no wake support, and it was not even
  loaded during the test (it has no PnP info yet, see the CS35L54 work);
- devices: Linux puts NVMe and others in D3 and brings them back; FreeBSD's
  NVMe controller failed on resume from the shallow idle already.

These are leads, not verified causes.

## Next steps

1. Load `amdgpio` and check, without suspending, which pins `_AEI` and
   GpioInt resources declare as wake capable.
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
