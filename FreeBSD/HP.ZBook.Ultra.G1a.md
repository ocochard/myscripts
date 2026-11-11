# HP ZBook Ultra G1a 14 on FreeBSD

Machine: HP ZBook Ultra G1a 14 inch Mobile Workstation (board 8D01, BIOS X89 01.06.02 of 2026-08-26),
AMD Ryzen AI Max+ PRO 395 (Strix Halo, 16 cores / 32 threads), Radeon 8060S.
Memory: 96 GB visible to FreeBSD (`hw.physmem`), plus 32 GB reserved as VRAM by the BIOS (amdgpu: `32768M of VRAM`).
Same SoC as the Framework Desktop: see [Framework-desktop.md](Framework-desktop.md).
Tested: FreeBSD 16.0-CURRENT main-n290939-a7163bd76986 (2026-11-10), GENERIC-NODEBUG.

Sources, collected on 2026-11-11: `pciconf -lv`, `devinfo -v`, `usbconfig`, `/var/run/dmesg.boot`, `kldstat`.

## What works

| Function | Device | FreeBSD driver |
|---|---|---|
| GPU, display | 1002:1586 Radeon 8060S | `amdgpu` from `graphics/drm-latest-kmod` + `gpu-firmware-amd-kmod` |
| HDMI/DP audio | 1002:1640 | `hdac0`, 4 `pcm` outputs |
| Speakers, headphone jack | 1022:15e3 + Realtek ALC245 codec | `hdac1`, `pcm4` (default), `pcm5` (headphones) |
| NVMe | Samsung PM9A1 2 TB (144d:a80a) | `nvme`/`nda` |
| USB 3 | four xHCI (1022:1587, 1588, 1589, 158b) | `xhci` |
| Touchpad | Synaptics SYNA3133 (I2C HID) | `iichid0`, polling mode (see below) |
| Touchscreen | ELAN2513 (I2C HID) | `iichid1`, polling mode (see below) |
| I2C controllers | AMDI0010 DesignWare | `ig4iic0-3` |
| SMBus | FCH 1022:790b | `intsmb` |
| CPU temperature | Family 1Ah data fabric | `amdtemp`, `amdsmn` |
| TPM 2.0 | NTC0702 | `tpmtis` (FIFO) |
| Battery, AC, lid, sleep button | ACPI | `battery`, `acpi_acad`, `acpi_lid`, `acpi_button` |
| Low-power idle | AMDI000B | `acpi_spmc` |
| Keyboard | HPQ8002 | `atkbdc` |
| Ethernet | none built in; tested with a USB-C dock (RTL8153) | `ure` |

Audio outputs attach, but I did not listen to them.
The `/boot/loader.conf` hint `hint.pcib.7.disabled="1"` from older kernels is no longer needed:
without it, `pcib7` attaches the xHCI at 197:0:0 and the boot does not hang (2026-11-11).

## PCI devices without driver

Source: `pciconf -lv | grep -A4 '^none'`.

| pciconf | Address | ID | Device |
|---|---|---|---|
| none0 | 0:0:2 | 1022:1508 | IOMMU |
| none1 | 193:0:0 | 14c3:7925 | MediaTek MT7925 Wi-Fi 7 (Filogic 360) |
| none2 | 195:0:2 | 1022:17e0 | CCP/ASP: crypto coprocessor and AMD Secure Processor (PSP) |
| none3 | 195:0:5 | 1022:15e2 | Audio Coprocessor (ACP) |
| none4 | 195:0:7 | 1022:164a | Sensor Fusion Hub (SFH) |
| none5 | 196:0:0 | 1022:150d | PCIe dummy function |
| none6 | 196:0:1 | 1022:17f0 | Neural Processing Unit (XDNA 2) |
| none7 | 197:0:5 | 1022:158d | USB4 host router 0 |
| none8 | 197:0:6 | 1022:158e | USB4 host router 1 |

## USB devices without a working driver

| ugen | ID | Device | State |
|---|---|---|---|
| ugen1.2 | 06cb:0106 | Synaptics fingerprint reader | no kernel driver; a userspace job (libfprint), support for this ID not checked |
| ugen1.3 | MediaTek (USB part of the MT7925) | Bluetooth | `ubt0` attaches, but HCI commands fail: `HCI command failed, OGF=0x3, OCF=0x3, status=0xc` |

The failing command is HCI Reset.
MediaTek controllers need firmware loaded by the host before they answer;
FreeBSD has firmware loaders only for Intel (`iwmbtfw`) and Realtek (`rtlbtfw`).

## ACPI devices without driver

Source: `devinfo -v | grep 'unknown pnpinfo'`, without the `PWRS` power resources and the disabled devices.

| HID | Path | Purpose |
|---|---|---|
| AMDI0030 | `\_SB_.GPIO` | GPIO controller. `amdgpio(4)` exists as a module but is not loaded by default |
| AMDI0105 | `\_SB_.PMF_` | Platform Management Framework: power and fan policy from firmware tables |
| AMDI0201 | `\_SB_.ISP1` | Image Signal Processor 4.1 for the cameras |
| OMNI5C10 | `\_SB_.CAMF` | front camera sensor, probably OmniVision OV05C10, behind the ISP |
| HIMX1092 | `\_SB_.CAMI` | second camera sensor (Himax), probably the IR camera for face login |
| USBC000 (_CID PNP0CA0) | `\_SB_.UBTC` | UCSI: USB Type-C connector state and power-delivery roles |
| ACPI0011 | `\_SB_.BTNS` | Generic Buttons Device (buttons wired to GPIO) |
| AMDI0081 (_CID PNP0C60) | `\_SB_.CIND` | convertible/slate mode indicator (from the _CID; not checked) |
| AMDI0080 | `\_SB_.VGBI` | unknown; name suggests virtual GPIO buttons |
| AMDI0051, AMDI0052 | `\_SB_.HDWB`, `\_SB_.PPKG` | unknown AMD platform devices |
| MSFT0201 | `\_SB_.MHSP` | Microsoft hardware security processor (Pluton), from the name; not checked |
| DRTM0001 | `\_SB_.DRTM` | Dynamic Root of Trust for Measurement |
| HPIC000C | `\_SB_.E180` | unknown HP device |
| PS8835xx, PS8836xx, PX88xxxx | `\_SB_.I2CD.*` | 32 entries at I2C addresses 0x08-0x17 and 0x30-0x4f. The prefix suggests Parade PS883x USB4 retimers, but 32 is far more than the ports need; not checked |
| PNP0800, PNP0000 | `LPCB.SPKR`, `LPCB.PIC_` | legacy PC speaker and 8259 PIC: nothing to do |

HP WMI (`acpi_wmi0`, `acpi_wmi1`) attaches; `acpi_hp(4)` exists as a module and might handle hotkeys. Not tested.

## Device purpose and impact

### Wi-Fi: MediaTek MT7925 (193:0:0)

The only wireless network device.
Linux driver: `mt7925e`.
FreeBSD has the LinuxKPI `mt76` port in the tree (`sys/contrib/dev/mediatek/mt76`, `sys/modules/mt76/mt7925`),
but `sys/modules/Makefile` does not list `mt76`, so no `if_mt7925.ko` is built or installed.
The firmware exists as a package: `wifi-firmware-mt76-kmod-mt7925`.
Status from the FreeBSD wiki (WiFi/Mt76, edited 2026-10-02):
mt7921 is in a call for testing since July 2026, with mixed results;
mt7925 comes next and "needs LinuxKPI IDR updates";
all mt76 chips wait on a LinuxKPI rework for Linux page pools.
Impact: no Wi-Fi; use USB or dock Ethernet. Track PR 273623 (mt76 meta-bug).

### IOMMU (0:0:2)

Not a missing driver: `amdiommu` is in GENERIC but off by default.
It attaches only with `hw.amdiommu.enable=1` in `/boot/loader.conf` (`sys/x86/iommu/amd_drv.c:448`).
Use: DMA protection, bhyve PCI passthrough.
Not tested on this machine.

### CCP/ASP (195:0:2)

AMD Secure Processor (PSP) plus the Cryptographic Coprocessor.
The PSP boots the SoC and runs firmware TPM, memory encryption and HSTI security checks.
Linux driver: `ccp` (with `psp`).
FreeBSD `ccp(4)` knows 1022:1456, 1468 and 15df only.
Impact: no crypto offload; nothing visible for laptop use.

### Audio Coprocessor (195:0:5)

DSP for the internal digital microphones (DMIC) and audio offload.
On AMD laptops the internal microphones go through the ACP, not through the HDA codec.
Linux: ASoC drivers in `sound/soc/amd` (ACP 7.x on Strix).
Impact: probably no internal microphone; the headset jack goes through the ALC245 codec (`pcm4` record).
Not tested.

### Sensor Fusion Hub (195:0:7)

Microcontroller that reads the accelerometer, lid angle and ambient light sensors.
Linux driver: `amd_sfh`.
Impact: no screen rotation, no auto-brightness, no tablet mode detection.

### Neural Processing Unit (196:0:1)

AMD XDNA 2 NPU, about 50 TOPS INT8 (AMD figure, from memory, not checked).
Linux driver: `amdxdna` (accel subsystem) plus AMD's XRT userspace.
Impact: none for FreeBSD use; llama.cpp and similar run on the iGPU through Vulkan.

### USB4 host routers (197:0:5, 197:0:6)

USB4/Thunderbolt controllers for the USB-C ports.
Linux driver: `thunderbolt`.
FreeBSD `thunderbolt(4)` (`sys/dev/thunderbolt`) knows AMD Pink Sardine (1022:1668, 1669), not these IDs.
USB 3 on the USB-C ports works through the xHCI functions; DisplayPort alt mode goes through amdgpu.
Impact: no PCIe tunneling (eGPU, NVMe enclosure, PCIe docks).

### Cameras: ISP 4.1 + sensors

The cameras are MIPI sensors behind the AMD ISP, not USB (UVC) cameras.
Linux needs the AMD ISP4 capture driver and the sensor driver (`ov05c10`).
The ISP firmware is already loaded on FreeBSD: `amdgpu_isp_4_1_1_bin.ko` comes with amdgpu, but nothing uses it.
Impact: no webcam. A USB webcam works through `webcamd`.

### Platform Management Framework (AMDI0105)

Applies firmware power and fan tables (power slider modes, Smart PC policies) through the SMU.
Linux driver: `amd-pmf`.
Impact: the firmware default policy applies; no OS-side power mode selection.

### UCSI (USBC000)

OS interface to the USB Type-C/PD controller: connector status, data and power roles, partner identity.
Linux driver: `ucsi_acpi`.
Impact: none for normal use; the EC handles PD negotiation.

## Touchpad and touchscreen interrupts

`dmesg` on every boot:

```
iichid0: <SYNA3133:01 06CB:CFE2 I2C HID device> at addr 0x2c on iicbus0
iichid0: Interrupt setup failed
iichid0: Using sampling mode
iichid1: <ELAN2513:02 04F3:4356 I2C HID device> at addr 0x10 on iicbus2
iichid1: Interrupt setup failed
iichid1: Using sampling mode
```

The DSDT describes these interrupts as GpioInt resources on `\_SB.GPIO` (AMDI0030):
it holds GpioInt descriptors (type 0x8C, connection type interrupt) referencing `\_SB.GPIO`.
`iasl` fails to decompile this DSDT (`Failure resolving symbol [\_SB._]`), so the mapping to TPAD/TPL0 is not checked.

Test on 2026-11-11: `kldload amdgpio` attaches `gpio0` and an `_AEI` event handler (`gpio_aei0`, pins 61-62, 58-59, 18, 54).
After `kldunload iichid.ko; kldload iichid`, both devices still report `Interrupt setup failed`.
Cause: `acpi_iicbus.c` ignores GpioInt resources (`/* Not supported by FreeBSD yet */`, `sys/dev/iicbus/acpi_iicbus.c:415`).
The same gap on Meteor Lake is described in [docs/x86_gpio_intr_mtl.md](docs/x86_gpio_intr_mtl.md); that patch targets the Intel GPIO controller, so `amdgpio` would need the same interrupt support.

## Which drivers are worth the work

1. Wi-Fi (MT7925).
   The biggest gap, but upstream work is in progress: mt7925 needs LinuxKPI IDR and page pool changes first (see the Wi-Fi section).
   Best action: follow PR 273623 and test when the mt7925 call for testing comes out.
   Building `sys/modules/mt76/mt7925` by hand today is not tested and unlikely to work.
2. Touch interrupts (amdgpio + GpioInt in acpi_iicbus).
   Gives lower latency on the first touch after idle and no dropped reports during fast movement.
   Builds on the Meteor Lake GpioInt work.
3. MediaTek Bluetooth firmware loader.
   A small `ubt` companion like `rtlbtfw`; needs the MediaTek firmware download protocol.
4. Internal microphone (ACP).
   Needed for calls without a headset; ASoC-style driver, medium to large effort.

Skip for laptop use:

- NPU, CCP/PSP, UCSI: no user-visible gain.
- Sensor Fusion Hub: only rotation and auto-brightness.
- USB4 routers: only for PCIe tunneling devices.
- Cameras: ISP and sensor drivers are a large job; a USB webcam is the practical answer.
- PMF: useful for power modes, but the firmware default works.
