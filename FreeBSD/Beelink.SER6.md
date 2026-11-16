# Beelink SER6 mini PC on FreeBSD

Machine: Beelink SER6 mini PC (SMBIOS maker "AZW", product "SER", AMI BIOS 113 of 2023-02-22),
AMD Ryzen 7 7735HS (Rembrandt-R, Zen 3+, 8 cores / 16 threads), Radeon 680M.
Memory: 64 GB (`hw.physmem` 64102391808), minus the BIOS VRAM carve-out (amdgpu: `4096M of VRAM`).
Tested: FreeBSD 16.0-CURRENT main-n290674-7806832f23fb (2026-11-05, with local changes), GENERIC-NODEBUG.

Sources, collected on 2026-11-16: `pciconf -lv`, `devinfo -v`, `usbconfig`, `/var/run/dmesg.boot`, `kldstat`, `/var/log/messages*`.
Device IDs checked against FreeBSD main 70cf7c62ee14 (2026-11-15) and Linux 3b5f4b83c4ab (2026-07-28).
No Linux boot on this machine: the "Linux driver" columns come from the Linux source, not from a running system.

## What works

| Function | Device | FreeBSD driver |
|---|---|---|
| GPU, display | 1002:1681 Radeon 680M | `amdgpu` from `graphics/drm-latest-kmod` + `gpu-firmware-amd-kmod-yellow-carp`, not in `kld_list` (see below) |
| HDMI/DP audio | 1002:1640 | `hdac0`, 3 `pcm` outputs |
| Analog audio | 1022:15e3 + Conexant 0x1f87 codec | `hdac1`, `pcm3` (jack, play/rec), `pcm4` (analog microphone) |
| NVMe | Kingston NV2 (2646:5017) | `nvme`/`nda` (see [NVMe event flood](#nvme-event-flood)) |
| 2.5G Ethernet | Realtek RTL8125B (10ec:8125) | `rge` |
| Wi-Fi | Intel AX200 (8086:2723) | `iwlwifi`, loaded by devmatch; `wlan0` created, association not tested |
| USB 3 | five xHCI (1022:161d, 161e, 161f, 15d6, 15d7) | `xhci` |
| I2C controllers | AMDI0010 DesignWare | `ig4iic0-1`, no child device on either `iicbus` |
| SMBus | FCH 1022:790b | `intsmb` |
| CPU frequency | CPPC | `hwpstate_amd` |
| CPU temperature | Family 19h data fabric | `amdtemp`, `amdsmn` |
| CPU idle | ACPI C-states | `cx_lowest` C8, 97.7% of time in C3 on CPU 0 |
| TPM 2.0 | MSFT0101, firmware TPM | `tpmcrb` (CRB, ACPI start method 2) |
| Power button, EC | ACPI | `acpi_button`, `acpi_ec` |
| WMI | PNP0C14 | `acpi_wmi` |
| Sleep | S3 (`hw.acpi.supported_sleep_state: S3 S4 S5`) | one resume logged on 2026-11-04 by `acpi[3149]: resumed`; not tested again |

amdgpu works when loaded by hand (`kldload amdgpu`):
`/var/log/messages` of 2026-11-10 shows `Initialized amdgpu 3.61.0 for drmn0` with 4096M VRAM and 30567M GTT.
Two warnings come with it: `Unable to set WC memtype for the aperture base` (2026-11-10)
and `REG_WAIT timeout 1us * 100000 tries - optc31_disable_crtc` (2026-10-13).
GPU resets with a successful recovery (`GPU reset succeeded`, `SMU is resumed successfully!`) are logged on 2026-11-05 and 2026-11-08.
The cause of these resets is not checked.

TPM: on 2026-11-16 `\_SB_.TPM_` shows as `unknown` in `devinfo`, because it was detached with `devctl` for a test.
`tpmcrb0` attaches at boot.
The boot also prints `Module acpi/tpmcrb failed to register: 17` (and the same for `tpm`, `tpmtis`, `isa/tpm`):
a `tpm.ko` was preloaded on top of the copy built into GENERIC. Harmless.

## PCI devices without driver

Source: `pciconf -l | grep ^none`.

| pciconf | Address | ID | Device | Purpose | Missing on FreeBSD | Linux driver |
|---|---|---|---|---|---|---|
| none0 | 0:0:2 | 1022:14b6 | IOMMU | DMA protection, PCI passthrough | nothing: `amdiommu` exists, off by default | IOMMU core |
| none1 | 116:0:2 | 1022:1649 | PSP/CCP | security processor and crypto offload | crypto offload, nothing visible | `ccp` (`sp-pci.c` lists 0x1649) |
| none2 | 116:0:5 | 1022:15e2 rev 0x60 | Audio Coprocessor (ACP 6.x) | DSP for digital microphones | nothing seen on this machine | `snd_pci_acp6x` (Yellow Carp, rev 0x60) |
| none3 | 117:0:5 | 1022:162e | USB4/Thunderbolt NHI | USB4 fabric, PCIe tunneling | eGPU, PCIe docks | `thunderbolt` |

## USB devices without a working driver

| ugen | ID | Device | State |
|---|---|---|---|
| ugen1.3 | 8087:0029 (bcdDevice 0x0001) | Intel AX200 Bluetooth | no driver attached: firmware not loaded (fixed 2026-11-16, see below) |

The AX200 Bluetooth part starts in bootloader mode and needs host-loaded firmware.
FreeBSD has the loader: `/etc/devd/iwmbtfw.conf` runs `iwmbtfw -f /usr/local/share/iwmbt-firmware`.
The firmware package (`comms/iwmbt-firmware`) is not installed, so the directory does not exist.
`ubt0` attached in October (`/var/log/messages` of 2026-10-13); the firmware state then is not known.
Fix, tested 2026-11-16: `pkg install iwmbt-firmware`, then `iwmbtfw -d ugen1.3 -f /usr/local/share/iwmbt-firmware` (or reboot).
`iwmbtfw` prints `Firmware download is successful!`, `ubt0` attaches, and `hccontrol -n ubt0hci read_bd_addr` answers.

Nothing tells the user that this package is missing:

- `fwget(8)` handles only one USB vendor, Ralink (`usr.sbin/fwget/usb/usb_ralink`).
  `fwget -n -v` lists the Wi-Fi and GPU packages for this machine, but no Bluetooth package.
- `iwmbtfw` reports the missing file on stderr only (`warn()` in `iwmbt_fw_read()`).
  devd starts it, so the message does not reach syslog: `/var/log/messages` has no `iwmbtfw` line.
- In bootloader mode, `ng_ubt_intel` rejects the device without a message (`ENXIO` in probe).
  The only trace is a `ugen1.3` with no driver.

Fix in FreeBSD: a `usb_intel` script for `fwget`, see [docs/fwget_usb_intel_bluetooth.md](docs/fwget_usb_intel_bluetooth.md).

## ACPI devices without driver

Source: `devinfo -v | grep 'unknown pnpinfo'`, without the `PWRS` power resources and the disabled devices
(UARTs, PS/2, extra I2C/I3C, FUR0-4, HID0/HID2, HFP1, APAD).

| HID | Path | Purpose | Linux driver |
|---|---|---|---|
| AMDI0030 | `\_SB_.GPIO` | GPIO controller | `pinctrl-amd`; FreeBSD `amdgpio(4)` exists, not loaded by default |
| AMDI0052 | `\_SB_.PPKG` | DSDT: `_HID` and `_STA` (always 0x0F) only | none bound; Linux uses the ID only as an ASoC machine match (`acp63-acp`) |
| ACPI000E | `\_SB_.ACDC` | Time and Alarm Device: wake timer, RTC | `acpi_tad` |
| MSFT0101 | `\_SB_.TPM_` | TPM 2.0 | detached for a test, see above |
| PNP0800, PNP0000 | `SBRG.SPKR`, `SBRG.PIC_` | legacy PC speaker and 8259 PIC: nothing to do | n/a |

`amdgpio` loads and attaches (2026-11-16):

```
gpio0: <AMD GPIO Controller> iomem 0xfed81500-0xfed818ff irq 7 on acpi0
gpioc0: <GPIO controller> at pins 0-255 on gpiobus0
```

Nothing on this machine needs it: no I2C HID device uses a GpioInt.
Unloaded after the test.

## Firmware errors at boot

```
Firmware Error (ACPI): Could not resolve symbol [\_SB.PCI0.GPP8.RTL8], AE_NOT_FOUND
Firmware Error (ACPI): Could not resolve symbol [\_SB.PCI0.SBRG.EC0._REG.AMW0], AE_NOT_FOUND
ACPI Error: Aborting method \_SB.PCI0.SBRG.EC0._REG due to previous error (AE_NOT_FOUND)
ivhd0: Unknown dev entry:0xf0
```

The first two are BIOS bugs: the tables reference objects that do not exist.
`EC0._REG` aborts, so firmware code that runs when the EC region opens does not complete.
No visible effect found: the EC attaches (`acpi_ec0: <Embedded Controller: GPE 0xb>`).
IVHD entry type 0xf0 is an ACPI HID device entry; FreeBSD skips it, and the IOMMU is off anyway.

## NVMe event flood

The Kingston NV2 (KINGSTON SNV2S500G, firmware SBJ00101) sends bursts of SMART/health asynchronous events:

```
nvme0: async event occurred (type 0x1, info 0x01, page 0x02)
```

Type 0x1 is SMART/health status, info 0x01 is "temperature above threshold".

### Thresholds

Read on 2026-11-16 with `nvmecontrol admin-passthru`:

| Value | Source | Result |
|---|---|---|
| WCTEMP (warning composite temperature) | Identify Controller, bytes 266-267 | 356 K, 82.85 C |
| CCTEMP (critical composite temperature) | Identify Controller, bytes 268-269 | 363 K, 89.85 C |
| Over-temperature threshold, composite | Get Features 0x04, `--cdw11 0` | 0x164 = 356 K, 82.85 C (same as WCTEMP) |
| Under-temperature threshold, composite | Get Features 0x04, THSEL=1 | 0x111 = 273 K, -0.15 C |
| Thresholds, sensor 1 | Get Features 0x04, TMPSEL=1 | 0: no extra sensor |
| Async event config | Get Features 0x0b | 0x21f: all critical warnings + firmware activation enabled |

The threshold is the drive default, 83 C. It is not set low.

### When events fire

Counted in `/var/log/messages` and `messages.0.bz2`, with `syslogd: last message repeated N times` added:

- bursts of 10 to 35 per minute during heavy I/O, for example 09:07 to 09:57 on 2026-11-16 (probably the kernel build for a TPM test);
- bursts of 3 to 26 around each reboot;
- single bursts at night (2026-11-11 01:13 and 02:15, 2026-11-14 04:15);
- none at idle: no event from 12:16 to 13:30 on 2026-11-16.

The first event in these logs is on 2026-11-08 08:29.
Earlier text in this document gave "364 in about 50 minutes after boot": wrong.
The kernel message buffer survives warm reboots, so `dmesg` and `/var/run/dmesg.boot` (379 lines) also hold events from earlier boots.

### Load test

90 s of `dd if=/dev/nda0 of=/dev/null bs=1m` (read only), health log every 10 s:

| Time | Composite temperature | Critical warning | Warning temp time (min) | Critical temp time (min) |
|---|---|---|---|---|
| 13:30:16, before | 44.85 C | 0x00 | 17621 | 14383 |
| 13:31:18 | 46.85 C | 0x00 | 17621 | 14383 |
| 13:31:38 | 46.85 C | 0x00 | 17621 | 14384 |

`/var/log/messages` got one event at 13:30:26, 10 s into the load.
The composite temperature never passed 47 C, but the drive added one minute of "Error Temp Composite Time" (time above CCTEMP, 90 C).
Lifetime totals: 17621 min (294 h) above 83 C and 14383 min (240 h) above 90 C, out of 7445 power-on hours.

So the drive sees a temperature far above its reported composite value, probably on an internal sensor it does not expose.
Another possible cause is a firmware bug in these counters.
Measurements cannot separate the two without a thermocouple on the controller.
Not checked: whether the drive has a heatsink or thermal pad.

### Why FreeBSD repeats the message

`sys/dev/nvme/nvme_ctrlr.c`: after a SMART/health event, the driver reads the health log page and masks the reported critical warning bits in the async event config, so a persistent warning fires once.
On this drive the critical warning byte is already 0x00 when the driver reads it.
Nothing gets masked, no `SMART WARNING: temperature above threshold` line is printed (0 in `dmesg`), and the next event comes.

Impact: log spam, and a drive that runs above its critical temperature under load.
Throttling was not measured: the 90 s read test was too short to show it.
First step: open the case and check the drive cooling.
`nvmecontrol` does not read the controller temperature, so heavy writes cannot be monitored from the composite value.

## Device purpose and impact

### IOMMU (0:0:2)

`amdiommu` (`sys/x86/iommu/amd_drv.c`) probes only with `hw.amdiommu.enable=1`.
`vmm.ko` has its own `amdviiommu` driver for bhyve passthrough.
`amdviiommu0 at device 0.2` in the message buffer comes from an earlier `vmm.ko` load; `vmm.ko` is not loaded now.
Impact: none for desktop use.
With `hw.amdiommu.enable=1` alone the stock kernel loops on USB attach; see [docs/amdiommu_ser6.md](docs/amdiommu_ser6.md) for the cause, two patches and measurements.

### PSP/CCP (116:0:2)

AMD Secure Processor: firmware TPM, platform security, crypto offload.
FreeBSD `ccp(4)` lists only 1456, 1468 and 15df.
The firmware TPM works through `tpmcrb` without this driver.
Impact: no crypto offload; AES-NI on the CPU is faster for most loads anyway.

### Audio Coprocessor (116:0:5)

ACP 6.x, the DSP for PDM digital microphones.
On this mini PC the microphone input goes through the HDA codec (`pcm4`, "Internal Analog Mic").
Whether any digital microphone is wired to the ACP is not checked.
Impact: probably none.

### USB4 NHI (117:0:5)

USB4/Thunderbolt host interface for the USB4 port.
FreeBSD `thunderbolt(4)` is not in GENERIC (comment: "breaks suspend/resume in some instances") and lists only AMD Pink Sardine IDs (1668, 1669).
On the HP ZBook its `nhi` driver attaches to unlisted AMD USB4 hosts too (see [HP.ZBook.Ultra.G1a.md](HP.ZBook.Ultra.G1a.md#usb4-host-routers-19705-19706)); not tested here.
USB 3 on the USB-C ports works through xHCI.
Impact: no PCIe tunneling (eGPU, NVMe enclosure, PCIe docks).

## Driver work in progress

None of this is needed to run the machine. Patches 1 and 2 fix detection and error reporting for the Bluetooth firmware;
patches 5 and 6 make the AMD IOMMU usable ([docs/amdiommu_ser6.md](docs/amdiommu_ser6.md)).
Each patch is one commit, also pushed to the fork as the branch of the same name.

### Applying the work, in order

The four freebsd-src patches apply on FreeBSD main 563c2f27e0ff (2026-11-16) in this order, without conflict
(checked with `git cherry-pick` of all four on a scratch branch).
Patches 1 and 2 are userland; 5 and 6 are kernel.

| # | Apply | Commits | Depends on | Then | Document |
|---|---|---|---|---|---|
| 1 | freebsd-src [`fwget_usb_intel_bluetooth.patch`](docs/fwget_usb_intel_bluetooth.patch) (branch `olivier-fwget-intel-bt`) | 1 | | `fwget` lists `iwmbt-firmware` | [docs/fwget_usb_intel_bluetooth.md](docs/fwget_usb_intel_bluetooth.md), [bug report](docs/bugreport_fwget_usb_intel_bluetooth.md) |
| 2 | freebsd-src [`iwmbtfw_syslog.patch`](docs/iwmbtfw_syslog.patch) (branch `olivier-iwmbtfw-syslog`) | 1 | | iwmbtfw errors reach syslog, or `dmesg -a` at boot | [docs/iwmbtfw_syslog.md](docs/iwmbtfw_syslog.md), [bug report](docs/bugreport_iwmbtfw_syslog.md) |
| 3 | build and install world, or only `usr.sbin/fwget` and `usr.sbin/bluetooth/iwmbtfw` | | 1, 2 | | |
| 4 | `fwget` (or `pkg install iwmbt-firmware`) | | 3 for `fwget` | reboot, or `iwmbtfw -d ugen1.3 -f /usr/local/share/iwmbt-firmware`; `ubt0` attaches | |
| 5 | freebsd-src [`iommu_idmap_when_dma_disabled.patch`](docs/iommu_idmap_when_dma_disabled.patch) (branch `olivier-amdiommu`) | 1 | | `hw.amdiommu.enable=1` alone no longer loops | [docs/amdiommu_ser6.md](docs/amdiommu_ser6.md) |
| 6 | freebsd-src [`amdiommu_skip_map_invalidation.patch`](docs/amdiommu_skip_map_invalidation.patch) (branch `olivier-amdiommu`) | 1 | | fewer IOMMU interrupts with `hw.iommu.dma=1` | [docs/amdiommu_ser6.md](docs/amdiommu_ser6.md) |
| 7 | build and install the kernel | | 5, 6 | `hw.amdiommu.enable=1`, plus `hw.iommu.dma=1` for DMA protection, in `/boot/loader.conf`; test with `nextboot -e` first | |

Not for this machine: [`rtlbtfw_syslog.patch`](docs/rtlbtfw_syslog.patch) (branch `olivier-rtlbtfw-syslog`, [docs/rtlbtfw_syslog.md](docs/rtlbtfw_syslog.md)) fixes the same bug in the Realtek loader; the SER6 has no Realtek Bluetooth.

## Which drivers are worth the work

Nothing important is missing on this machine.
Three setup items give more than any new driver:

1. Bluetooth: install `iwmbt-firmware` (done 2026-11-16). `fwget` patch for detection: see above.
2. GPU: add `amdgpu` to `kld_list` if the machine runs a desktop. Today it is loaded by hand.
3. NVMe: the threshold is the 83 C default; the drive heats under load, see [NVMe event flood](#nvme-event-flood). Fix the cooling, not the threshold.

Skip:

- PSP/CCP, IOMMU, ACP: no user-visible gain.
- USB4 NHI: only for PCIe tunneling devices.
- GPIO: `amdgpio` works, but no device needs it.
- ACPI000E: wake timers only; `atrtc` and `efirtc` already provide the clock.
