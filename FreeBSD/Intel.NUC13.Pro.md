# Intel NUC 13 Pro on FreeBSD

Machine: Intel NUC 13 Pro mini PC (SMBIOS product NUC13ANHi7, board NUC13ANBi7, BIOS ANRPL357.0027.2023.0607.1754 of 2023-06-07),
Intel Core i7-1360P (Raptor Lake-P, 4 P-cores + 8 E-cores, 16 threads), Iris Xe Graphics.
Memory: 64 GB (`hw.physmem` 68132372480).
Disks: Kingston KC3000 500 GB NVMe (`nda0`: EFI, a Linux partition, FreeBSD swap and ZFS pool `zroot`),
SanDisk 1 TB SATA SSD (`ada0`: Windows partitions).
Tested: FreeBSD 16.0-CURRENT main-n291498-6dc19a71f70c (2026-11-21), GENERIC-NODEBUG, booted with UEFI.
Host name `nucfbsd` (`ssh nucfbsd`).

Sources, collected on 2026-11-23: `pciconf -lv`, `devinfo -v`, `usbconfig`, `/var/run/dmesg.boot`, `kldstat`, `pkg info`.
Device IDs checked against the FreeBSD source of the running kernel (6dc19a71f70c).
No Linux boot on this machine: the "Linux driver" columns come from driver names, not from a running system.

The message buffer survived the reboot: `/var/run/dmesg.boot` starts with the end of a
FreeBSD 15.0-CURRENT boot of 2024-11-14 (main-n273622-9d4428ad0239), and the current boot starts at line 333.
In that 2024 boot, i915 and Wi-Fi worked; do not take those lines for the current state.

## What works

| Function | Device | FreeBSD driver |
|---|---|---|
| Ethernet | Intel I226-V 2.5 GbE (8086:125c) | `igc0`, 2500Base-T full duplex, 4 RX/TX queues, MSI-X |
| NVMe | Kingston KC3000 (2646:5013) | `nvme`/`nda` |
| SATA | Alder Lake-P AHCI (8086:51d3) | `ahci`, SanDisk SSD at 6 Gbit/s |
| USB 3 | Thunderbolt 4 xHCI (8086:a71e), PCH xHCI (8086:51ed) | `xhci` |
| Audio | Raptor Lake-P cAVS (8086:51ca) + Realtek ALC256 | `hdac0`, `pcm0` (playback not tested) |
| CPU frequency | Intel Speed Shift | `hwpstate_intel0-15`, EPP 128 |
| TPM 2.0 | firmware TPM, CRB interface | `tpmcrb0`, `/dev/tpm0`, also a `random(4)` source |
| I2C controllers | Alder Lake-P Serial IO (8086:51e8, 51e9) | `ig4iic0-1` (nothing attached behind them) |
| SMBus | Alder Lake PCH-P (8086:51a3) | `ichsmb` |
| Low-power idle | ACPI PEP device | `acpi_spmc0`, Intel DSM (see [acpi_spmc warnings](#acpi_spmc-warnings)) |
| Thermal zone | ACPI `tz0` | `hw.acpi.thermal.tz0.temperature` (47.1 C at idle) |
| Real-time clock | UEFI | `efirtc0` |
| Crypto | AES-NI, SHA | `aesni0` |
| Logitech Unifying receiver | 046d:c52b | `hkbd0`, `hms0`, `hcons0`, `hsctrl0` |
| GPU | Iris Xe (8086:a7a0) | `i915kms` from `drm-612-kmod-6.12.110.1600031_3`, DMC firmware `i915/adlp_dmc.bin` v2.20; `/dev/dri/card0`, `renderD128`, console on `drmfb` |
| Wi-Fi | Intel AX211 CNVi (8086:51f1) | `iwlwifi0` with `wifi-firmware-iwlwifi-kmod-ax210` (firmware 89.735b75a4.0); scan tested, no association yet. `iwx0` scans too |
| Bluetooth | Intel AX211 Bluetooth (USB, ugen1.3) | `ubt0` after `iwmbtfw` loads `iwmbt-firmware`; `hccontrol -n ubt0hci read_bd_addr` answers |

GPU, Wi-Fi and Bluetooth were broken until 2026-11-23, with no code change needed to fix them:

- GPU: `KLD i915kms.ko: depends on kernel - not available or version mismatch`, so `kld_list="i915kms"` failed at every boot.
  All 127 kmod packages (`drm-61-kmod-6.1.92_2` and 126 `gpu-firmware-*`) were built on 2024-10-30 for FreeBSD 1500026.
  Fix: `pkg delete drm-61-kmod 'gpu-firmware-*'`, then `pkg install -r bigone drm-kmod gpu-firmware-kmod`.
  The `bigone` repository already had 1600031 builds (`builder-default`, 2026-11-20); the machine had not been upgraded.
- Wi-Fi: `iwlwifi0: no suitable firmware found!`, `iwlwifi-so-a0-gf-a0-89 is required`.
  `fwget` lists the missing package: `wifi-firmware-iwlwifi-kmod-ax210`.
- Bluetooth: no `ubt0`, because no firmware was loaded.
  Fix: `pkg install iwmbt-firmware` (`fwget` does not list it, see [Beelink.SER6.md](Beelink.SER6.md)), then `iwmbtfw -d ugen1.3 -f /usr/local/share/iwmbt-firmware` or a reboot.

Both `if_iwlwifi` and `if_iwx` load at boot, and `iwlwifi` claims the device.
After `kldunload if_iwlwifi`, the already loaded `if_iwx` takes the card.
The unload logs `iwlwifi0: lkpi_pci_dev_release_common: driver did not clean up; leaking mmio resources`; `iwlwifi` still attached again afterwards.
After a reboot (2026-11-23), i915 (from `kld_list`), `iwlwifi0` and `ubt0` attach at boot.
Not tested: display output, audio playback, S3 suspend, Thunderbolt devices.

## PCI devices without driver

Source: `pciconf -lv | grep -A4 '^none'`.

| pciconf | Address | ID | Device | Purpose | Missing on FreeBSD | Linux driver |
|---|---|---|---|---|---|---|
| none0 | 0:8:0 | 8086:a74f | GNA Scoring Accelerator | low-power neural inference (noise suppression) | nothing usable | none in mainline (out-of-tree `intel_gna`) |
| none1 | 0:10:0 | 8086:a77d | Crashlog and Telemetry | Platform Monitoring Technology counters, crash records | nothing for normal use | `intel_vsec` with `pmt_telemetry`/`pmt_crashlog` (ID not checked) |
| none2, none3 | 0:13:2, 0:13:3 | 8086:a73e, a76d | Thunderbolt 4 NHI | USB4/Thunderbolt fabric, PCIe tunneling | eGPU, PCIe docks | `thunderbolt` |
| none4 | 0:20:2 | 8086:51ef | PCH Shared SRAM | firmware scratch memory | nothing | none |
| none5 | 0:22:0 | 8086:51e0 | HECI (Management Engine) | host interface to the Intel ME | nothing for normal use; `hfsts(4)` decodes the ME firmware status | `mei_me` |
| none6 | 0:31:5 | 8086:51a4 | PCH SPI controller | BIOS flash | nothing (flash updates only) | `spi-intel-pci` |

Notes:

- Thunderbolt: FreeBSD `thunderbolt(4)` probes any USB4 NHI by class (`Generic USB4 NHI`, `sys/dev/thunderbolt/nhi_pci.c`),
  but it is commented out in GENERIC ("breaks suspend/resume in some instances") and has no module loaded here.
  USB 3 on the Thunderbolt ports works through `xhci0`; DisplayPort alt mode needs i915.
- HECI: `hfsts.ko` exists in `/boot/kernel` (added 8e5e2c391059, 2026-09-15) and lists 0x51e0 ("Alder Lake Point P MEI"),
  but nothing loads it automatically. `kldload hfsts` exposes the HFSTS1-6 registers; not tried.

## USB devices without a working driver

| ugen | Device | State |
|---|---|---|
| ugen1.3 | Intel AX211 Bluetooth | no driver attached: the controller needs firmware from `iwmbtfw`, which needs the `iwmbt-firmware` package (not installed) |

The Logitech receiver's vendor HID pages (`page=0xff00`, `0xffbc`) stay unclaimed: they carry Logitech's HID++ pairing and configuration protocol, not input.

## ACPI devices without driver

Source: `devinfo -v | grep 'unknown pnpinfo'`, without the disabled devices and the processor objects.
Most entries are disabled (`_STA` 0): the BIOS keeps the reference-design devices (touchpads, cameras, USB-C PD controllers, power meters, fingerprint)
that a NUC does not have.

| HID | Path | Purpose | Note |
|---|---|---|---|
| INTC1055 | `\_SB_.GPI0` | Alder Lake-P GPIO controller | FreeBSD `adlngpio` knows only INTC1056/1057/1085 (Alder Lake-N); nothing on this machine uses a GpioInt |
| OVTID858, OVTI01AF, TXNW3643 | `\_SB_.PC00.LNK0/LNK1`, `FLM0/FLM1` | OmniVision camera sensors and TI flash drivers on I2C | leftovers: no IPU function in `pciconf`, so no camera path exists |
| USBC000 (_CID PNP0CA0) | `\_SB_.UBTC` | UCSI: USB Type-C connector state | nothing attaches; the PD controller works without the OS |
| ACPI000E | `\_SB_.AWAC` | ACPI wake alarm timer | nothing attaches; only needed for timed wake |
| PNP0C0B | `\_TZ_.FAN0-4` | ACPI fans | nothing attaches; the EC controls the fan |
| PNP0000 | `LPCB.IPIC` | legacy 8259 PIC | nothing to do |

`acpi_wmi0` and `acpi_wmi1` attach with embedded MOF and no consumer.

## acpi_spmc warnings

Every boot logs 84 lines like:

```
acpi_spmc0: Intel: Wrong package length for constraint 0's constraint package.
```

The Intel DSM reports `DEVICE_CONSTRAINTS,CRASH_DUMP_DEVICE,DISPLAY_OFF,DISPLAY_ON,LPI_ENTRY,LPI_EXIT`;
`acpi_spmc` rejects most entries of its device constraint list.
Impact: unknown, since this machine uses S3 (`hw.acpi.supported_sleep_state: S3 S4 S5`, `kern.power.suspend: fw_suspend`),
not suspend-to-idle. Not investigated.

## Next steps

1. VA-API H.264 encode (`low_power 0`): LinuxKPI cannot map one buffer object WB and WC at once, see [Tracing the hang](#tracing-the-hang-2026-11-23); use `-low_power 1`.
2. Associate Wi-Fi with an access point and measure throughput.
3. Test S3 suspend and resume, and power-off with `enable_guc=3`.

## GPU acceleration

State on 2026-11-23, with i915 from `drm-612-kmod` loaded:

| Feature | State | Evidence |
|---|---|---|
| Vulkan | works | `vulkaninfo --summary`: `Intel(R) Graphics (RPL-P)`, Mesa 24.1.7, Vulkan 1.3.278 |
| VA-API decode/encode | none at first: no Intel VA-API driver installed | `ffmpeg -init_hw_device vaapi=va:/dev/dri/renderD128`: `Failed to initialise VAAPI connection`; see [VA-API with the iHD driver](#va-api-with-the-ihd-driver) for the state after installing it |
| GuC and HuC firmware | loaded with `hw.i915kms.enable_guc=3` (2026-11-23) | before: `enable_guc: 0`, no GuC or HuC line in `dmesg`; after: `adlp_guc_70.bin` 70.49.4, `tgl_huc.bin` 7.9.3, `HuC: authenticated for all workloads`, `GUC: submission enabled`, `SLPC enabled` |
| OpenGL, OpenCL | not tested | |

GuC and HuC: drm-kmod changes the `enable_guc` default from -1 (auto) to 0 (`i915_params.h`, under `#ifdef __FreeBSD__`:
"there is a great chance that the computer freezes when it reboots or is powered off").
Upstream auto mode on Raptor Lake-P would select 3: HuC authentication plus GuC submission (`uc_expand_default_options()` in `intel_uc.c`,
under `#ifndef __FreeBSD__` in drm-kmod).
Without HuC, the media driver cannot use the low-power encoder's bitrate control.
Without GuC, i915 submits work with execlists and the host controls the GPU frequency, not GuC SLPC.
`hw.i915kms.enable_guc=3` in `/boot/loader.conf` matches upstream; that is the value that fixed the Meteor Lake panic
in [docs/i915kms_panic.md](docs/i915kms_panic.md). Not tested on this machine; check that reboot and power-off still work.

The Meteor Lake video fix ([docs/mtl_media_gt.md](docs/mtl_media_gt.md), LinuxKPI `vmap()` honoring `pgprot`) should not be needed here.
Raptor Lake has a single GT, with the video engines and the HuC on it, and it has an LLC:
`intel_gt_coherent_map_type()` returns WB, not WC, for its firmware buffers.
WC is returned only for local memory or for the Meteor Lake media GT (Wa_22016122933).
Not tested: no kernel with that fix has run on this machine.

Userland: `mesa-dri` 24.1.7 is a 2024 build for FreeBSD 1500026; the `bigone` repository has 26.2.2.
`/dev/drm/*` is `root:video` 0660; user `olivier` was added to group `video` on 2026-11-23.

### VA-API with the iHD driver

Tested 2026-11-23, after `pkg upgrade` (mesa-dri 26.2.2, ffmpeg 9.0.2) and `libva-intel-media-driver` 26.3.5, still with `enable_guc=0`.
`vainfo` lists `Intel iHD driver ... 26.3.5`, with decode (`VLD`) for H.264, HEVC up to 4:4:4 12-bit, VP9, AV1, MPEG-2, VC-1, VP8 and JPEG,
and encode (`EncSlice`, `EncSliceLP`) for H.264, HEVC and JPEG.

Decode of 300-frame 1920x1080 clips (`-hwaccel vaapi -hwaccel_output_format vaapi -f null -`): H.264 0.42 s, HEVC 0.27 s.
The `framemd5` comparison with the software decoder differed for both clips; the hardware output was not converted to the
software decoder's pixel format first, so this does not prove a decode error. Not re-checked.

Encode hangs the process in the kernel (`h264_vaapi`, `-low_power 0 -rc_mode CQP`, the first encode tried):
the output stays at 48 bytes, `kill -9` does not end the process, and the console prints, without end:

```
lkpi_vmf_insert_pfn_prot_locked: page rename failed: page is mapped
```

`procstat -kk` on the encoder thread:

```
printf lkpi_vmf_insert_pfn_prot_locked remap_io_sg vm_fault_cpu linux_cdev_pager_populate
vm_fault_allocate vm_fault vm_fault_trap trap_pfault
```

i915 `vm_fault_cpu()` (CPU fault on a GEM object mapping) inserts the object's shmem pages with `remap_io_sg()`.
LinuxKPI `lkpi_vmf_insert_pfn_prot_locked()` (`linux_page.c`) moves each page from its shmem object into the device pager object;
when the page is still mapped elsewhere it prints the message and returns `VM_FAULT_NOPAGE` with no page inserted.
`linux_cdev_pager_populate()` (`linux_compat.c`) retries that case forever:
`while (vmap->vm_pfn_count == 0 && err == VM_FAULT_NOPAGE) { kern_yield(PRI_USER); ... }`.
The loop never checks for a pending signal, so the thread spins at 100% of one CPU and the process cannot exit; only a reboot frees it.
What holds the page: see [Tracing the hang](#tracing-the-hang-2026-11-23).
The path does not depend on `enable_guc`.

Reproduced after a reboot with `hw.i915kms.enable_guc=3` (GuC 70.49.4: submission, SLPC and RC enabled; HuC 7.9.3 authenticated for all workloads):
the same `h264_vaapi` CQP encode hangs with the same stack, and `timeout 60` cannot end it.
`shutdown -r now` still rebooted the machine with such a process stuck, in about 40 s.

#### Tracing the hang (2026-11-23)

Three more reproductions under DTrace (scripts read the i915 ioctl structures by their uapi offsets; `i915kms.ko` has no CTF),
then kgdb on the live kernel (`kgdb /usr/lib/debug/boot/kernel/kernel.debug /dev/mem`) with the stuck processes still looping:

1. The faulting mapping is always GEM handle 38, `I915_MMAP_TYPE_WB` (`__assign_mmap_offset_handle` type 2), length 0x380000 (3.5 MB),
   created early in the run and first touched by the encoder thread.
2. Handle 38 gets only one mmap offset (WB); a second mapping of the same object can still come through another handle (see below). It is not a userptr object: drm-kmod refuses mmap offsets on userptr BOs
   (`I915_GEM_OBJECT_NO_MMAP`, `__assign_mmap_offset()` returns `-ENODEV`), and handle 38's assignment succeeded.
3. `procstat -v`: the mapping (`0x890c00000-0x890f80000`, type `md`, flag `S`) is 2 MB-aligned, superpage-mapped, all 896 pages resident.
   Its page-table entry is a writable 2 MB superpage: PDE `0x8040000324a004e7` (PS=1), physical 0x324a00000.
4. While the loop runs, the pages the rename check rejects (pa 0x324a00000 to 0x324a05000) sit in an `OBJT_SWAP` object with no handle
   (a LinuxKPI shmem object) and are mapped with no 4 KB pv entry, that is through a 2 MB mapping.
   In an earlier run, a rejected page (pa 0x293d3e000) was pindex 0 of another BO's device pager object (handle 116, a 4 KB WB mapping).
5. kgdb afterwards: pa 0x324a00000 is pindex 0 of the mapping's own device pager object, with `psind 1`; pa 0x324a01000 is pindex 1, `psind 0`.

A first hypothesis, a stale `psind` letting `vm_fault_populate()` build a superpage over pages the device pager object does not own,
is refuted: booted with `vm.pmap.pg_ps_enabled=0` (superpages off), the same encode hangs the same way.

Root cause, found with superpages off (every mapping then has a 4 KB pv entry):
the rejected page (pa 0x1807e6000, `ref=0x80000001`) is pindex 0 of another device pager object, mapped in the same process at `0x89dd36000`.
kgdb dump of the two `struct i915_mmap_offset` (the vmas' `vm_private_data`), compared field by field:

| Offset | Existing mapping | Faulting mapping | Field |
|---|---|---|---|
| +0x28 | 0x101284 | 0x101bd7 | `vma_node.vm_node.start`: the fake mmap offset, in pages |
| +0xd8 | 0xfffff801775ae000 | 0xfffff801775ae000 | `obj`: the same GEM object |
| +0xe0 | 2 | 1 | `mmap_type`: `I915_MMAP_TYPE_WB` against `I915_MMAP_TYPE_WC` |
| +0xe8/+0xf0 | | | the two nodes link to each other in that object's mmap offset tree |

So the user-space media stack maps one buffer object twice, write-back and write-combined.
The first fault (WB) moves the object's shmem page into the WB mapping's device pager object.
A FreeBSD page belongs to one VM object only, so the WC fault cannot take the page while the WB mapping maps it,
and `linux_cdev_pager_populate()` retries forever. Linux allows one page in many VMAs, so the same sequence works there.

Known limitation: [freebsd/drm-kmod#481](https://github.com/freebsd/drm-kmod/issues/481) (Xorg startup with drm-612-kmod,
"linuxkpi can't [have] two live mappings of the same page") and [PR 296195](https://bugs.freebsd.org/bugzilla/show_bug.cgi?id=296195)
("Xorg hangs in lkpi_vmf_insert_pfn_prot_locked").

Encoders on a kernel with the containment patch below (2026-11-23): only `h264_vaapi` with `low_power 0`
(the default, `EncSlice`) hits the double mapping; `h264_vaapi -low_power 1` and `hevc_vaapi` (both modes) encode 300 frames,
CQP and VBR. Workaround for H.264: `-low_power 1`.

Containment patch: [docs/linuxkpi_rename_sigbus.md](docs/linuxkpi_rename_sigbus.md) (the process gets SIGSEGV within a second
instead of hanging; tested on this machine).

Fix directions:

- Containment: done in the patch above.
- Real fix: let a second mapping of the same page exist, for example with a fictitious page (`vm_page_getfake()`) for the same physical address,
  as the `OBJT_DEVICE` pager does; the WB and WC aliases of one page also need a decision on the page's memory attribute.
- Why Meteor Lake encodes fine ([docs/mtl_media_gt.md](docs/mtl_media_gt.md)): not checked; maybe the media driver maps buffers there in one mode only.
