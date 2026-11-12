# HP ZBook Ultra G1a 14 on FreeBSD

Machine: HP ZBook Ultra G1a 14 inch Mobile Workstation (board 8D01, BIOS X89 01.06.02 of 2026-08-26),
AMD Ryzen AI Max+ PRO 395 (Strix Halo, 16 cores / 32 threads), Radeon 8060S.
Memory: 96 GB visible to FreeBSD (`hw.physmem`), plus 32 GB reserved as VRAM by the BIOS (amdgpu: `32768M of VRAM`).
Same SoC as the Framework Desktop: see [Framework-desktop.md](Framework-desktop.md).
Tested: FreeBSD 16.0-CURRENT main-n290939-a7163bd76986 (2026-11-10), GENERIC-NODEBUG.

Sources, collected on 2026-11-11: `pciconf -lv`, `devinfo -v`, `usbconfig`, `/var/run/dmesg.boot`, `kldstat`.
Linux comparison: Ubuntu with Linux 7.0.0-43 on the same laptop, same day (`lspci -nnk`, `/sys/bus/acpi/devices/*/physical_node/driver`, ACPI tables decompiled with `iasl`).

## What works

| Function | Device | FreeBSD driver |
|---|---|---|
| GPU, display | 1002:1586 Radeon 8060S | `amdgpu` from `graphics/drm-latest-kmod` + `gpu-firmware-amd-kmod` |
| HDMI/DP audio | 1002:1640 | `hdac0`, 4 `pcm` outputs |
| Headphone jack | 1022:15e3 + Realtek ALC245 codec | `hdac1`, `pcm5` (headphones) |
| Internal speakers | `pcm4` (ALC245) + 4 Cirrus Logic CS35L54 amplifiers (CSC3554) | not in FreeBSD yet: `snd_cs35l54` from branch [`olivier-cs35l54`](https://github.com/ocochard/freebsd-src/compare/main...olivier-cs35l54) + firmware port (see below) |
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

Audio outputs attach, but I did not listen to the headphone or HDMI outputs.
Sound device nodes are `root:audio` 0660 and DRM nodes `root:video` 0660 since main of May 2026 (a6aa95eba6ee):
add desktop users to both groups, or sound and GPU acceleration fail.
The `/boot/loader.conf` hint `hint.pcib.7.disabled="1"` from older kernels is no longer needed:
without it, `pcib7` attaches the xHCI at 197:0:0 and the boot does not hang (2026-11-11).

## PCI devices without driver

Source: `pciconf -lv | grep -A4 '^none'`.

| pciconf | Address | ID | Device | Purpose | Missing on FreeBSD | Linux driver |
|---|---|---|---|---|---|---|
| none0 | 0:0:2 | 1022:1508 | IOMMU | DMA protection, PCI passthrough | nothing: `amdiommu` exists, off by default | IOMMU core (no `lspci` driver line) |
| none1 | 193:0:0 | 14c3:7925 | MediaTek MT7925 (Filogic 360) | Wi-Fi 7 | Wi-Fi | `mt7925e` |
| none2 | 195:0:2 | 1022:17e0 | CCP/ASP | security processor (PSP) and crypto offload | crypto offload, nothing visible | `ccp` |
| none3 | 195:0:5 | 1022:15e2 | Audio Coprocessor (ACP) | DSP for the internal digital microphones | internal microphone (probably) | `snd_acp_pci` |
| none4 | 195:0:7 | 1022:164a | Sensor Fusion Hub / MP2 | sensor microcontroller; Linux uses it as an I2C controller | see below | `pcie_mp2_amd` (not `amd_sfh`) |
| none5 | 196:0:0 | 1022:150d | PCIe dummy function | placeholder that carries the NPU function | nothing | none |
| none6 | 196:0:1 | 1022:17f0 | NPU (XDNA 2) | low-power AI inference | NPU offload | `amdxdna` |
| none7 | 197:0:5 | 1022:158d | USB4 host router 0 | USB4/Thunderbolt fabric, PCIe tunneling | eGPU, PCIe docks | `thunderbolt` |
| none8 | 197:0:6 | 1022:158e | USB4 host router 1 | same, second set of USB-C ports | same | `thunderbolt` |

Details for each device are in "Device purpose and impact" below.

## USB devices without a working driver

| ugen | ID | Device | State |
|---|---|---|---|
| ugen1.2 | 06cb:0106 | Synaptics fingerprint reader | no kernel driver; a userspace job (libfprint), support for this ID not checked |
| ugen1.3 | MediaTek (USB part of the MT7925) | Bluetooth | `ubt0` attaches, but HCI commands fail: `HCI command failed, OGF=0x3, OCF=0x3, status=0xc` |

The failing command is HCI Reset.
MediaTek controllers need firmware loaded by the host before they answer;
FreeBSD has firmware loaders only for Intel (`iwmbtfw`) and Realtek (`rtlbtfw`).
Linux loads it through `btmtk` and Bluetooth works there (`Bluetooth: hci0: Device setup in 310964 usecs`).
The fingerprint reader has no kernel driver on Linux either.

## ACPI devices without driver

Source: `devinfo -v | grep 'unknown pnpinfo'`, without the `PWRS` power resources and the disabled devices.

The "ACPI definition" column comes from the tables decompiled under Ubuntu;
"Linux driver" is the driver bound to the device there.

| HID | Path | Purpose | ACPI definition | Linux driver |
|---|---|---|---|---|
| CSC3554 | `\_SB_.I2CB.SPKR` | Cirrus Logic CS35L54 smart amplifiers (4) for the internal speakers: no speaker sound without them | DSDT; 4 I2C addresses + alias, see [docs/cs35l54_speaker_amp_plan.md](docs/cs35l54_speaker_amp_plan.md) | `serial-multi-instantiate`, then `cs35l56-hda` per amp |
| AMDI0030 | `\_SB_.GPIO` | GPIO controller | DSDT | `amd_gpio`; FreeBSD `amdgpio(4)` exists, not loaded by default |
| AMDI0105 | `\_SB_.PMF_` | Platform Management Framework: power and fan policy from firmware tables | DSDT | `amd-pmf` |
| AMDI0201 | `\_SB_.ISP1` | Image Signal Processor 4.1 for the cameras | SSDT | none on ISP1 itself |
| OMNI5C10 | `\_SB_.CAMF` | front RGB camera | SSDT "CAM11", `_DDN` "OV05C-RGB" | `amd-isp4` |
| HIMX1092 | `\_SB_.CAMI` | IR camera (face login) | SSDT "CAM11", `_DDN` "HM1092-IR" | none |
| USBC000 (_CID PNP0CA0) | `\_SB_.UBTC` | UCSI: USB Type-C connector state and power-delivery roles | SSDT "UcsiAcpi" | none bound (`ucsi_acpi` loaded, unused) |
| ACPI0011 | `\_SB_.BTNS` | Generic Buttons Device (buttons wired to GPIO) | DSDT, `_STA` 0x0B | `soc_button_array` |
| AMDI0081 (_CID PNP0C60) | `\_SB_.CIND` | convertible/slate mode indicator ("Display Sensor Device" per iasl) | SSDT "CPMSFAML", no methods besides `_STA` | none |
| AMDI0080 | `\_SB_.VGBI` | unknown; depends on the sensor hub (`_DEP` `\_SB.PCI0.GPPA.MP2C`) | SSDT "CPMSFAML" | none |
| AMDI0051 | `\_SB_.HDWB` | unknown | SSDT "CPMWBH": `_HID`/`_CID`/`_UID` only, no methods | none |
| AMDI0052 | `\_SB_.PPKG` | unknown | DSDT: `_HID` and `_STA` (always 0x0F) only | none |
| MSFT0201 | `\_SB_.MHSP` | Microsoft Pluton security processor | SSDT "MHSP", `_DDN` "Microsoft Pluton security processor", 2 memory ranges + 1 interrupt | none |
| DRTM0001 | `\_SB_.DRTM` | Dynamic Root of Trust for Measurement | SSDT "DRTM" | none |
| HPIC000C | `\_SB_.E180` | unknown HP device | DSDT: `_HID` and `_STA` (depends on flag `E100`) only | none |
| PS8835xx, PS8836xx, PX88xxxx | `\_SB_.I2CD.*` | 48 I2C addresses (0x08-0x17, 0x30-0x4f). Prefix suggests Parade PS883x USB4 retimers; probably a list of candidate addresses, not 48 chips | DSDT: one I2C address each at 400 kHz, `_STA` 0x0B (hidden), stub `_DSM` | none (I2C clients created, no driver) |
| PNP0800, PNP0000 | `LPCB.SPKR`, `LPCB.PIC_` | legacy PC speaker and 8259 PIC: nothing to do | DSDT | n/a |

Devices with no Linux driver either (AMDI0051, AMDI0052, AMDI0080, AMDI0081, HPIC000C, MSFT0201, DRTM0001, HIMX1092, PS88xx) are not FreeBSD gaps: nothing on Linux uses them on this laptop.

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
Experiment (2026-11-12): with a LinuxKPI page pool side table, an init-failure fix, an idr fix and
`compat.linuxkpi.skb.mem_limit=1` (plus `compat.linuxkpi.80211.hw_crypto=1` for A-MPDU), WPA2 works on 2.4 and 5 GHz (11ac), at 26 Mbit/s TX and 52 Mbit/s RX at best;
see [docs/mt7925_wifi_plan.md](docs/mt7925_wifi_plan.md).

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
Linux driver: `snd_acp_pci` (ASoC drivers in `sound/soc/amd`).
Impact: probably no internal microphone; the headset jack goes through the ALC245 codec (`pcm4` record).
Not tested.

### Internal speakers: Cirrus CS35L54 amplifiers (CSC3554)

The ALC245 codec does not drive the speakers directly: four CS35L54 smart amplifiers on I2C (`\_SB_.I2CB`, addresses 0x30-0x33) do.
Under Linux they drive the left woofer (AMP1), left tweeter (AMP2), right tweeter (AMP3) and right woofer (AMP4), per the tuning file names in the Linux log.
The OS must download a DSP program and tuning into each amplifier, then send it a "play" command.
Linux: `cs35l56-hda` side-codec driver with `cirrus/cs35l54-b0-dsp1-misc-103c8d01.wmfw` and `-amp1..4.bin`; the speakers work under Ubuntu (tested 2026-11-11).
Stock FreeBSD: Chromium plays through PulseAudio into `dsp4` (sink RUNNING, not muted, 85%), the hardware channel takes data with 0 underruns, and the speakers stay silent.

Driver (not in FreeBSD yet): `snd_cs35l54`, branch [`olivier-cs35l54`](https://github.com/ocochard/freebsd-src/compare/main...olivier-cs35l54) of the FreeBSD fork.
It downloads the firmware, applies the factory calibration from UEFI, and starts or pauses the amplifiers with the speaker stream, through a new `hdaa` event (so it needs a kernel built from the branch: `snd_hda` is in GENERIC).
Firmware: the `audio/sound-firmware-cirrus-kmod` port (not committed yet) installs the linux-firmware files under `/boot/firmware/cirrus/`.
Tested 2026-11-11 and, after the rebase onto `main` 29b24020f6fa, 2026-11-12: test tone, YouTube in Chromium, pause/resume.

- How it works, step by step: [docs/cs35l54_speaker_amp.md](docs/cs35l54_speaker_amp.md)
- Investigation log, measurements and the list of patches to land: [docs/cs35l54_speaker_amp_plan.md](docs/cs35l54_speaker_amp_plan.md)

### Sensor Fusion Hub / MP2 (195:0:7)

AMD MP2 microcontroller, which can run the sensor fusion firmware (accelerometer, lid angle, ambient light).
On this laptop Linux binds `pcie_mp2_amd`, the MP2 I2C controller driver, not `amd_sfh`:
the MP2 serves as an I2C bus here, not as a sensor hub.
`\_SB_.VGBI` (AMDI0080) depends on it (`_DEP`).
Impact: unknown until the devices behind this I2C bus are identified; Linux exposes no sensors from it.

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

The cameras are MIPI sensors behind the AMD ISP, not USB (UVC) cameras:
an OmniVision OV05C RGB camera (`_DDN` "OV05C-RGB") and a Himax HM1092 IR camera (`_DDN` "HM1092-IR").
Linux binds `amd-isp4` to the RGB camera; nothing binds the IR camera.
The ISP firmware is already loaded on FreeBSD: `amdgpu_isp_4_1_1_bin.ko` comes with amdgpu, but nothing uses it.
Impact: no webcam. A USB webcam works through `webcamd`.

### Platform Management Framework (AMDI0105)

Applies firmware power and fan tables (power slider modes, Smart PC policies) through the SMU.
Linux driver: `amd-pmf`.
Impact: the firmware default policy applies; no OS-side power mode selection.

### UCSI (USBC000)

OS interface to the USB Type-C/PD controller: connector status, data and power roles, partner identity.
Linux: `ucsi_acpi` is loaded but not bound to the device on this laptop (no log line, use count 0).
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

Both interrupts are GpioInt resources on `\_SB.GPIO` (AMDI0030), from the tables decompiled under Ubuntu:

| Device | I2C | Interrupt |
|---|---|---|
| Touchpad `\_SB_.I2CA.TPAD` (DSDT) | 0x2C on `\_SB.I2CA`, 400 kHz | GpioInt, `\_SB.GPIO` pin 8 |
| Touchscreen `\_SB_.I2CC.TPL0` (SSDT) | 0x10 on `\_SB.I2CC` | GpioInt, `\_SB.GPIO` pin 0 (static buffer `SBFG`) |

FreeBSD `iasl` fails on the DSDT image written by `acpidump -o` (`Failure resolving symbol [\_SB._]`);
the same `iasl` decompiles the DSDT extracted under Linux (`acpidump`, `acpixtract`) without error.

Test on 2026-11-11: `kldload amdgpio` attaches `gpio0` and an `_AEI` event handler (`gpio_aei0`, pins 61-62, 58-59, 18, 54).
After `kldunload iichid.ko; kldload iichid`, both devices still report `Interrupt setup failed`.
Cause: `acpi_iicbus.c` ignores GpioInt resources (`/* Not supported by FreeBSD yet */`, `sys/dev/iicbus/acpi_iicbus.c:415`).
The same gap on Meteor Lake is described in [docs/x86_gpio_intr_mtl.md](docs/x86_gpio_intr_mtl.md); that patch targets the Intel GPIO controller, so `amdgpio` would need the same interrupt support.

## Which drivers are worth the work

1. Wi-Fi (MT7925).
   The biggest gap, but upstream work is in progress: mt7925 needs LinuxKPI IDR and page pool changes first (see the Wi-Fi section).
   Best action: follow PR 273623 and test when the mt7925 call for testing comes out.
   Building `sys/modules/mt76/mt7925` by hand today is not tested and unlikely to work.
2. Speaker amplifier (CS35L54).
   Done, waiting for review: branch [`olivier-cs35l54`](https://github.com/ocochard/freebsd-src/compare/main...olivier-cs35l54), see the speaker section.
3. Touch interrupts (amdgpio + GpioInt in acpi_iicbus).
   Gives lower latency on the first touch after idle and no dropped reports during fast movement.
   Builds on the Meteor Lake GpioInt work.
4. MediaTek Bluetooth firmware loader.
   A small `ubt` companion like `rtlbtfw`; needs the MediaTek firmware download protocol.
5. Internal microphone (ACP).
   Needed for calls without a headset; ASoC-style driver, medium to large effort.

Skip for laptop use:

- NPU, CCP/PSP, UCSI: no user-visible gain.
- Sensor Fusion Hub / MP2: Linux uses it only as an I2C controller here, with no visible function.
- USB4 routers: only for PCIe tunneling devices.
- Cameras: ISP and sensor drivers are a large job; a USB webcam is the practical answer.
- PMF: useful for power modes, but the firmware default works.
