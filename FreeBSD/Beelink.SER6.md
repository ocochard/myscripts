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
| ugen1.3 | 8087:0029 (bcdDevice 0x0001) | Intel AX200 Bluetooth | no driver attached: firmware not loaded |

The AX200 Bluetooth part starts in bootloader mode and needs host-loaded firmware.
FreeBSD has the loader: `/etc/devd/iwmbtfw.conf` runs `iwmbtfw -f /usr/local/share/iwmbt-firmware`.
The firmware package (`comms/iwmbt-firmware`) is not installed, so the directory does not exist.
`ubt0` attached in October (`/var/log/messages` of 2026-10-13); the firmware state then is not known.
Fix: `pkg install iwmbt-firmware`, then replug or reboot. Not tested.

Nothing tells the user that this package is missing:

- `fwget(8)` handles only one USB vendor, Ralink (`usr.sbin/fwget/usb/usb_ralink`).
  `fwget -n -v` lists the Wi-Fi and GPU packages for this machine, but no Bluetooth package.
- `iwmbtfw` reports the missing file on stderr only (`warn()` in `iwmbt_fw_read()`).
  devd starts it, so the message does not reach syslog: `/var/log/messages` has no `iwmbtfw` line.
- In bootloader mode, `ng_ubt_intel` rejects the device without a message (`ENXIO` in probe).
  The only trace is a `ugen1.3` with no driver.

Possible fix in FreeBSD: a `usb_intel` script for `fwget` that maps the 8087 product IDs from `iwmbtfw.conf` to `iwmbt-firmware`.

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

The Kingston NV2 sends a SMART/health asynchronous event many times per hour:

```
nvme0: async event occurred (type 0x1, info 0x01, page 0x02)
```

Type 0x1 is SMART/health status, info 0x01 is "temperature above threshold".
Count: 364 in the kernel message buffer about 50 minutes after boot.
The health log reports no critical warning and 45.85 C (`nvmecontrol logpage -p 2 nvme0`).
So the event fires below any real overheating; the drive threshold is probably low.
Not checked: the threshold value (`nvmecontrol` feature 0x04, Temperature Threshold).
Impact: log spam fills the message buffer and hides boot messages.
`/var/run/dmesg.boot` also starts with 379 of these lines; use `/var/log/messages` for the boot log.

## Device purpose and impact

### IOMMU (0:0:2)

`amdiommu` (`sys/x86/iommu/amd_drv.c`) probes only with `hw.amdiommu.enable=1`.
`vmm.ko` has its own `amdviiommu` driver for bhyve passthrough.
`amdviiommu0 at device 0.2` in the message buffer comes from an earlier `vmm.ko` load; `vmm.ko` is not loaded now.
Impact: none for desktop use.

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

## Which drivers are worth the work

Nothing important is missing on this machine.
Three setup items give more than any new driver:

1. Bluetooth: install `iwmbt-firmware`. No code needed.
2. GPU: add `amdgpu` to `kld_list` if the machine runs a desktop. Today it is loaded by hand.
3. NVMe log spam: read the temperature threshold and raise it, or replace the drive. Investigate before changing.

Skip:

- PSP/CCP, IOMMU, ACP: no user-visible gain.
- USB4 NHI: only for PCIe tunneling devices.
- GPIO: `amdgpio` works, but no device needs it.
- ACPI000E: wake timers only; `atrtc` and `efirtc` already provide the clock.
