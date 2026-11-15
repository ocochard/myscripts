Subject: Strix Halo suspend-to-idle: amdsmu, s2idle and tb findings

Hi Aymeric,

I have been working on suspend-to-idle on an HP ZBook Ultra G1a (Ryzen AI
Max+ PRO 395, Strix Halo, family 1Ah model 70h, root complex 1022:1507)
on main. Since you wrote amdsmu, the s2idle path and the tb suspend code,
I would like your opinion before going further. Full notes, logs and the
Linux reference data:
https://github.com/ocochard/myscripts/blob/master/FreeBSD/docs/amdsmu_strix_halo.md

Where it stands: with the patches below, `zzz` sleeps, a key wakes it and
resume is clean (NVMe, network, amdgpu, tb). The SMU never even starts
S0i3: time entering S0i3 is always 0, where Ubuntu (7.0) on the same
laptop reaches S0i3 (595 ms to enter, 29 s in S0i3).

Patches (branches on github.com/ocochard/freebsd-src):

1. olivier-amdsmu-strixhalo
   - amdsmu: Add Strix Halo support (1022:1507, Krackan registers, same as
     Linux amd_1ah_m70_cpu_info).
   - amdsmu: Diagnose S0i3 blockers on Strix Halo (USB4_1 value is always
     garbage there, as in Linux).
   - amdsmu: Only report IP blocks the SMU tracks. The blocker loop walked
     every name; GFX is not in the constraint mask (0x1ff9dd9 on this
     part) and was reported on every suspend. Affects all models.
   - amdsmu: Restart the SMU log before each suspend, as Linux
     amd_pmc_setup_smu_logging() does. Without it the "last active" times
     accumulate across suspends (a second suspend reported exactly the
     sum of both sleeps).
2. olivier-s2idle-wake
   - acpi: let drivers register extra wake IRQs for do_idle().
   - amdgpio: arm the _AEI wake pins (WAKE_CNTRL_OFF_S0I3) for s2idle.
   - acpi_cpu: use the deepest Cx during s2idle. hw.acpi.cpu.cx_lowest
     defaults to C1; with C1 the laptop never woke.
3. olivier-pci-d3hot
   - pci: Accept D3hot in pci_set_powerstate_method(). Since 84bbfc32a3f4
     PCI_POWERSTATE_D3 is D3cold, so an _SxD of 3 (D3hot) hits
     `default: return (EINVAL)` and the device silently stays in D0; the
     GPU (GFX0 _S3D = 3) stayed in D0 under a bridge in D3cold. Also hits
     LinuxKPI pci_set_power_state(PCI_D3hot). Still in main and stable/15.

What I measured (all with amdgpu, amdgpio, amdsmu and tb loaded):

- tb clears USB3_0/USB3_1 (nhi0 = USB3_0), and also DISPLAY and MPM,
  which come and go with the USB4 routers. tb resume worked in my run once the
  GPU goes to D3hot. Two tb notes: nhi_resume() is empty, and
  sc->suspended is never cleared, so the second suspend of a boot skips
  putting the routers to sleep.
- amdgpu: same SMU messages as Linux from boot to resume (I logged
  smu_cmn on both). in_s0ix is set, GFXOFF engaged, VCN/JPEG gated. The
  only boot difference was Linux's ISP up/down (PowerDownIspByTile 0x7ff);
  adding it on FreeBSD changed nothing.
- Hint order matches Linux: LPS0 screen off and entry DSMs, then the hint
  (0x03 arg 1).
- The last blockers are "JPEG_0"/"JPEG_1", and they seem to follow the
  CPUs, not the JPEG engines (amdgpu has them powered down on both OSes).
  With the default 1 s hw.acpi.sleep_delay, JPEG_0 is active for exactly
  that second and JPEG_1 the whole sleep. With sleep_delay=0, both are
  active the whole sleep, and cpu0, cpu1, cpu2 and cpu31 never reach C3
  (per-CPU cx_stats printed at resume) while the others do. My guess is
  one bit per CCD (cpu0-15, cpu16-31), but I have no documentation.
- Forcing every CPU into C3 for the sleep (prev_sleep hack, no bus-master
  demotion) gives a sleep that never wakes, and the battery shows it is
  not S0i3 (about 5-6 W for 30 min, close to awake idle), so a hang.

Questions:

1. Is a real s2idle loop planned or in progress? I mean all CPUs entering
   their deepest state with the tick stopped and a wake-reason check,
   as the XXX comment in do_idle() describes. That looks like the missing
   piece here, and I would rather not duplicate your work.
2. On your Framework (Phoenix), what does it take to reach S0i3 with
   main today? Does the single cpu_idle(0) on the BSP and the stock
   acpi_cpu C-state choice get there, or do you carry local changes?
3. Do you know what the JPEG_0/JPEG_1 constraint bits mean on 1Ah parts,
   and whether they can track core idle state?
4. Are you interested in the patches above, and how would you like them:
   reviews, or pull requests on GitHub?

I can test anything on this laptop.

Thanks,
Olivier
