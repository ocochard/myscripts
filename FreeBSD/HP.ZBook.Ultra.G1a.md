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
| GPU, display, Vulkan, video decode/encode | 1002:1586 Radeon 8060S | `amdgpu` from `graphics/drm-latest-kmod` + `gpu-firmware-amd-kmod`, Mesa (see [GPU features](#gpu-features)) |
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

## GPU features

Tested on 2026-11-15 with `mesa-dri` 26.2.2 (radeonsi and RADV), `amdgpu`
from `drm-latest-kmod` (drm 6.12), packages `libva-utils`, `vulkan-tools`,
`clinfo` and `ffmpeg` 9.0.2, no desktop session (render node
`/dev/dri/renderD128`, user in group `video`).

| Feature | Result | Evidence |
|---|---|---|
| Vulkan | works | `vulkaninfo`: `AMD Radeon 8060S Graphics (RADV STRIX_HALO)`, Vulkan 1.4.354 |
| Vulkan video | exposed | `VK_KHR_video_decode_{h264,h265,vp9,av1}`, `VK_KHR_video_encode_{h264,h265,av1}` |
| VA-API decode | works, bit-exact | H.264, HEVC (Main, Main10), VP9 (profiles 0, 2), AV1, JPEG |
| VA-API encode | works | H.264, HEVC (Main, Main10), AV1 |
| VA-API video processing | listed | `VAProfileNone: VAEntrypointVideoProc` (the VPE engine) |
| OpenCL | none | `clinfo`: 0 platforms; no FreeBSD package provides Mesa rusticl |
| OpenGL | not tested | needs a desktop session |

VA-API needs `libva` (pulled in by `libva-utils` or `ffmpeg`); the driver
itself, `radeonsi_drv_video.so`, ships in `mesa-dri`. `vainfo --display drm
--device /dev/dri/renderD128` lists the profiles.

Measured with 10 s 1920x1080 30 fps test clips (`testsrc2`, encoded in
software), decoded with `ffmpeg -hwaccel vaapi -hwaccel_device
/dev/dri/renderD128 -hwaccel_output_format vaapi -i CLIP -f null -`:

| Clip | Hardware decode, 300 frames | Output vs software decoder |
|---|---|---|
| H.264 | 0.24 s | identical (`framemd5`) |
| HEVC | 0.25 s | identical |
| VP9 | 0.27 s | identical |
| AV1 | 0.34 s | identical |
| MJPEG | 0.70 s (0.04 s CPU) | not compared (lossy decoders may round differently) |

Hardware encode (`-vf format=nv12,hwupload -c:v h264_vaapi|hevc_vaapi|av1_vaapi`)
of the same 300 frames took 0.73 s, 0.41 s and 0.44 s and produced valid
1920x1080 streams (`ffprobe`). The SMU message log of a debug amdgpu build
shows the engines powering up for the work and down when idle
(`PowerUpVcn0/1`, `PowerUpJpeg0/1`, then `PowerDown...`).

Use cases: hardware video playback (mpv, browsers with VA-API), webcam and
capture MJPEG decode, transcoding with ffmpeg or GStreamer, and Vulkan
compute (llama.cpp's Vulkan backend). The two JPEG engines (JPEG_0,
JPEG_1) serve `VAProfileJPEGBaseline`.

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
| none6 | 196:0:1 | 1022:17f0 | NPU (XDNA 2) | low-power AI inference | job submission (port in progress, see below) | `amdxdna` |
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
`compat.linuxkpi.skb.mem_limit=1` (plus `compat.linuxkpi.80211.hw_crypto=1` for A-MPDU), WPA2 works on 2.4 and 5 GHz (11ac), at 474 to 509 Mbit/s TX and 289 to 314 Mbit/s RX (Linux: 577/426);
see [docs/mt7925_wifi.md](docs/mt7925_wifi.md).

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

AMD XDNA 2 NPU: 8 columns x 6 rows of AIE2 tiles, firmware 1.1.2.65.
Linux driver: `amdxdna` (accel subsystem) plus AMD's XRT userspace; FastFlowLM runs LLMs on it.
FreeBSD: a port of `amdxdna` to drm-kmod attaches, loads the firmware, answers queries and creates hardware contexts,
in carveout mode (no IOMMU SVA on FreeBSD); measured on a Framework Desktop with the same NPU (1022:17f0 rev 0x11),
not yet on this laptop. Job submission, XRT and FastFlowLM are not done.
Details: [docs/amdxdna_npu.md](docs/amdxdna_npu.md).
Impact: none yet; llama.cpp and similar run on the iGPU through Vulkan.

### USB4 host routers (197:0:5, 197:0:6)

USB4/Thunderbolt controllers for the USB-C ports.
Linux driver: `thunderbolt`.
FreeBSD `thunderbolt(4)` (module `tb`, not in GENERIC) lists AMD Pink Sardine IDs (1022:1668, 1669) in `nhi_reg.h`,
but its `nhi` driver probes any USB4 host by class and attaches to these too
(with "Cannot find Upstream Facing Port" and "Error finding LC registers: 22");
with it loaded, resume from suspend-to-idle hangs (see [docs/amdsmu_strix_halo.md](docs/amdsmu_strix_halo.md)).
USB 3 on the USB-C ports works through the xHCI functions; DisplayPort alt mode goes through amdgpu.
Impact: no PCIe tunneling (eGPU, NVMe enclosure, PCIe docks).

### Cameras: ISP 4.1 + sensors

The cameras are MIPI sensors behind the AMD ISP, not USB (UVC) cameras:
an OmniVision OV05C RGB camera (`_DDN` "OV05C-RGB") and a Himax HM1092 IR camera (`_DDN` "HM1092-IR").
Linux binds `amd-isp4` to the RGB camera; nothing binds the IR camera.
The ISP firmware is already loaded on FreeBSD: `amdgpu_isp_4_1_1_bin.ko` comes with amdgpu, but nothing uses it.
Impact: no webcam with stock FreeBSD; a test driver (`amdisp`, see below) gives a working `/dev/video0`. A USB webcam works with the native `uvideo(4)` driver (or `webcamd`).
FreeBSD 16 has a kernel V4L2 capture framework, `video(4)` (9c9428825f4c, 2026-08): it provides
`/dev/videoN`, buffers, `mmap` and the V4L2 ioctls, so an ISP driver would only implement the
`video_if` hardware methods (formats, controls, start/stop stream), like `uvideo(4)` and `fwcam(4)`.
The Linux driver (`amd_isp4_capture`, about 4000 lines plus the amdgpu ISP power and the ISP I2C/pin
controllers) is GPL-2.0+, so a FreeBSD driver would be a rewrite against the ISP firmware interface.
The ISP firmware drives the OV05C sensor itself (no sensor driver in Linux).
On Ubuntu (Linux 7.0.0-43, 2026-11-15) the RGB camera works: `amd_isp4_capture` provides `/dev/video0`
(driver `amd_isp_capture`, media model `amd_isp41_mdev`), NV12 and YUYV from 640x360 to 2888x1808 at
30 fps; `v4l2-ctl --stream-mmap` captured 1920x1080 NV12 at 29.66 fps with a correct image (black
frames with the privacy shutter closed). Driver study: [docs/amd_isp_camera.md](docs/amd_isp_camera.md).

### Platform Management Framework (AMDI0105)

Applies firmware power and fan tables (power slider modes, Smart PC policies) through the SMU.
Linux driver: `amd-pmf`.
Impact: the firmware default policy applies; no OS-side power mode selection.

### UCSI (USBC000)

OS interface to the USB Type-C/PD controller: connector status, data and power roles, partner identity.
Linux: `ucsi_acpi` is loaded but not bound to the device on this laptop (no log line, use count 0).
Impact: none for normal use; the EC handles PD negotiation.

## Suspend

Tested 2026-11-12 on main 83c8ec72ac6a: the firmware offers only S4/S5
(`hw.acpi.supported_sleep_state: S4 S5`), so `zzz` uses suspend-to-idle
(`kern.power.suspend: suspend_to_idle`). The laptop goes to sleep (power LED
blinks slowly); the power button does not wake it, a key press does. Resume
is broken platform-wide:

- `acpi0: Resumed from suspend-to-idle on AMD processor but amdsmu(4) is not
  attached; unable to verify S0i3 entry. It is unlikely the system entered a
  deep sleep state.`
- `nvme0: Complete Failed controller`, then queued writes resubmitted (the
  ZFS pool was healthy after the next boot).
- Every USB device detaches and reattaches; Bluetooth reset fails.
- No network traffic afterwards, not even a ping to 127.0.0.1, although
  timers work; `shutdown -r` hangs on a black screen; only a forced power
  off recovers.

Do not suspend this laptop on FreeBSD until this is fixed.
Stock `amdsmu(4)` does not attach (its table lacks the Strix Halo root
complex 1022:1507); with a one-row patch it attaches, but suspend then
hangs with no wake at all. Linux reaches S0i3 and wakes on a key on the
same laptop. Patch, Linux reference data and analysis:
[docs/amdsmu_strix_halo.md](docs/amdsmu_strix_halo.md).

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

## Driver work in progress

Branches of the FreeBSD fork (github.com/ocochard/freebsd-src) and of the
drm-kmod fork (github.com/ocochard/drm-kmod) written for this laptop, with
the document that explains each one.

| Area | Branch | Commits | Status | Document |
|---|---|---|---|---|
| Wi-Fi (MT7925) | [`olivier-mt7925`](https://github.com/ocochard/freebsd-src/compare/main...olivier-mt7925) | 12 | works, TX 82-88% / RX 68-74% of Linux, survives suspend-to-idle; firmware port PR 300731 | [docs/mt7925_wifi.md](docs/mt7925_wifi.md) |
| Internal speakers (CS35L54) | [`olivier-cs35l54`](https://github.com/ocochard/freebsd-src/compare/main...olivier-cs35l54) | 10 | works, waiting for review | [docs/cs35l54_speaker_amp.md](docs/cs35l54_speaker_amp.md) |
| SMU power metrics (amdsmu) | [`olivier-amdsmu-strixhalo`](https://github.com/ocochard/freebsd-src/compare/main...olivier-amdsmu-strixhalo) | 4 | attaches, S0i3 blocker report | [docs/amdsmu_strix_halo.md](docs/amdsmu_strix_halo.md) |
| Suspend-to-idle wake and C-states | [`olivier-s2idle-wake`](https://github.com/ocochard/freebsd-src/compare/main...olivier-s2idle-wake) | 3 | key wake and clean resume; no S0i3 yet | [docs/amdsmu_strix_halo.md](docs/amdsmu_strix_halo.md) |
| PCI D3hot (GPU stayed in D0 over suspend) | [`olivier-pci-d3hot`](https://github.com/ocochard/freebsd-src/compare/main...olivier-pci-d3hot) | 1 | fix, tested | [docs/pci_d3hot.md](docs/pci_d3hot.md) |
| I2C controller clock | [`olivier-ig4-amd-clock`](https://github.com/ocochard/freebsd-src/compare/main...olivier-ig4-amd-clock) | 1 | `ig4: Use the 150 MHz input clock of AMD AMDI0010 controllers` | |
| GPIO driver autoload | [`olivier-amdgpio-pnp`](https://github.com/ocochard/freebsd-src/compare/main...olivier-amdgpio-pnp) | 1 | `amdgpio: Add PNP info for devmatch` | |
| ACPI properties | [`olivier-acpi-prop-child`](https://github.com/ocochard/freebsd-src/compare/main...olivier-acpi-prop-child) | 1 | `acpi: Refuse property requests for other buses children` | |
| LinuxKPI SRCU (needed by the NPU) | [`olivier-lkpi-srcu`](https://github.com/ocochard/freebsd-src/compare/main...olivier-lkpi-srcu) | 1 | fix, tested (test module, stress, mutant) | [docs/linuxkpi_srcu_per_struct.md](docs/linuxkpi_srcu_per_struct.md) |
| NPU (AMD XDNA 2, `amdxdna`) | drm-kmod [`olivier-amdxdna`](https://github.com/ocochard/drm-kmod/compare/drm_v6.12.85_3...olivier-amdxdna) | 3 | firmware, queries, hardware contexts work (tested on a Framework Desktop); no job submission yet | [docs/amdxdna_npu.md](docs/amdxdna_npu.md) |
| Built-in camera (AMD ISP 4.1) | drm-kmod [`olivier-amdisp`](https://github.com/ocochard/drm-kmod/compare/drm_v6.12.85_3...olivier-amdisp) | 18, on the port's Strix Halo patches | `/dev/video0` through `video(4)`, interrupt-driven, works in VLC (NV12 and YUYV, 640x360 to 2888x1808, 30 fps); needs the 2025/08 ISP firmware | [docs/amd_isp_camera.md](docs/amd_isp_camera.md) |

### Applying the work, in order

The eight freebsd-src branches apply in this order, without conflict
(checked with 32 commits; mt7925's 12th, the suspend fix, was added later
and applies on top).
Branch [`zbook`](https://github.com/ocochard/freebsd-src/compare/main...zbook)
of the fork has all 33 commits in this order on FreeBSD main 46ce9acd6d15
(2026-11-16), for testing everything at once (steps 1 to 8). It builds
(`buildkernel KERNCONF=GENERIC-NODEBUG`, plus the mt76 modules, which
`sys/modules/Makefile` does not list, and the drm-kmod `amdgpu` and
`amdisp` modules of step 10 against it). Boot test on the laptop
(2026-11-16, kernel `zbook-n291256-f7d7c068c5b5` with those modules in
the kernel directory): Wi-Fi associates and passes traffic, `amdgpio`
attaches `gpio0`, the four `ig4` controllers attach, `snd_cs35l54` attaches
the 4 amplifiers (calibration read, firmware 3.11.18; no sound played),
`amdsmu` attaches (SMU 100.7.0), and the camera streams 1920x1080 NV12 at
29.84 fps; no panic or fault in the boot log. Suspend-to-idle (`zzz`,
Xorg running, amdsmu loaded, dock attached): the space key wakes it after
84 s, Xorg, amdgpu, NVMe (queued writes resubmitted, no error), USB and
the dock come back, the camera streams at 29.81 fps and the speaker driver
stays loaded; no S0i3 (70 s software DRIPS, blockers DISPLAY, USB3_0,
USB3_1, MPM, JPEG_1). Wi-Fi after resume: without the 12th mt7925 commit
`wlan0` stays "associated" but passes no traffic (none 7 min after resume)
until `if_mt7925` is reloaded; with it, traffic passes 10 s after resume
(see [docs/mt7925_wifi.md](docs/mt7925_wifi.md#suspend-and-resume)). A
test trap: `rc.conf` gives the dock's USB Ethernet a static address as
`ue0`, but USB adapters are renumbered on resume, so a second USB
Ethernet (the KVM's) can come back as `ue0` and take the address and the
default route. Fixed on the laptop with a fixed name: a devd rule
([zbook/dock-ether.conf](zbook/dock-ether.conf), installed in
`/usr/local/etc/devd/`, `IFNET` `ATTACH` on `ue[0-9]+`) runs a script
([zbook/dock-ether-name](zbook/dock-ether-name), in `/usr/local/sbin/`) that renames the adapter with the dock's MAC address to
`dock0` and starts it with `/etc/pccard_ether`, and `rc.conf` configures
`ifconfig_dock0` instead of `ifconfig_ue0`; tested by resetting the
adapter (`usbconfig reset`): it came back as `ue1`, was renamed `dock0`
and got both addresses. Each
document gives the deeper tests of its own branch. Steps 10 and 11 are outside the kernel source.

| # | Apply | Commits | Depends on | Then | Document |
|---|---|---|---|---|---|
| 1 | freebsd-src [`olivier-acpi-prop-child`](https://github.com/ocochard/freebsd-src/compare/main...olivier-acpi-prop-child) | 1 | | | [docs/cs35l54_speaker_amp.md](docs/cs35l54_speaker_amp.md) (section 3.4) |
| 2 | freebsd-src [`olivier-amdgpio-pnp`](https://github.com/ocochard/freebsd-src/compare/main...olivier-amdgpio-pnp) | 1 | | devmatch loads `amdgpio` (otherwise add it to `kld_list`) | |
| 3 | freebsd-src [`olivier-ig4-amd-clock`](https://github.com/ocochard/freebsd-src/compare/main...olivier-ig4-amd-clock) | 1 | | | [docs/cs35l54_speaker_amp.md](docs/cs35l54_speaker_amp.md) |
| 4 | freebsd-src [`olivier-pci-d3hot`](https://github.com/ocochard/freebsd-src/compare/main...olivier-pci-d3hot) | 1 | | | [docs/pci_d3hot.md](docs/pci_d3hot.md), [patch](docs/pci_d3hot.patch) |
| 5 | freebsd-src [`olivier-s2idle-wake`](https://github.com/ocochard/freebsd-src/compare/main...olivier-s2idle-wake) | 3 | `amdgpio` loaded | | [docs/amdsmu_strix_halo.md](docs/amdsmu_strix_halo.md) |
| 6 | freebsd-src [`olivier-amdsmu-strixhalo`](https://github.com/ocochard/freebsd-src/compare/main...olivier-amdsmu-strixhalo) | 4 | | | [docs/amdsmu_strix_halo.md](docs/amdsmu_strix_halo.md) |
| 7 | freebsd-src [`olivier-cs35l54`](https://github.com/ocochard/freebsd-src/compare/main...olivier-cs35l54) | 10 | 1, 2, 3 | firmware port `audio/sound-firmware-cirrus-kmod` (not committed yet); devmatch loads `snd_cs35l54` | [docs/cs35l54_speaker_amp.md](docs/cs35l54_speaker_amp.md) |
| 8 | freebsd-src [`olivier-mt7925`](https://github.com/ocochard/freebsd-src/compare/main...olivier-mt7925) | 12 | | MT7925 firmware (port PR 300731); `if_mt7925` in `kld_list` | [docs/mt7925_wifi.md](docs/mt7925_wifi.md) |
| 9 | build and install the kernel and modules (`buildkernel`, `installkernel`) | | 1-8 | | |
| 10 | drm-kmod [`olivier-amdisp`](https://github.com/ocochard/drm-kmod/compare/drm_v6.12.85_3...olivier-amdisp): tag `drm_v6.12.85_3`, the graphics/drm-latest-kmod port's Strix Halo DCN patches (first commit), then the camera | 1 + 18 | kernel source of step 9 | build `amd/amdgpu` and `amd/amdisp` with `SYSDIR=<src>/sys`, install both in `/boot/modules` (keep the packaged `amdgpu.ko`); `amdgpu amdisp` in `kld_list` | [docs/amd_isp_camera.md](docs/amd_isp_camera.md) |
| 11 | ISP firmware of August 2025: drm-kmod-firmware [`sync-linux-firmware-20260519`](https://github.com/ocochard/drm-kmod-firmware/commit/41e5783) for graphics/gpu-firmware-amd-kmod, or linux-firmware's `amdgpu/isp_4_1_1.bin` (md5 `c872d1ba`) copied to `/boot/firmware/amdgpu/` with `/boot/modules/amdgpu_isp_4_1_1_bin.ko` moved aside | | 10 | without it the ISP boots but finds no sensor | [docs/drm_kmod_firmware_isp_report.md](docs/drm_kmod_firmware_isp_report.md) |

## Which drivers are worth the work

1. Wi-Fi (MT7925).
   The biggest gap. Built by hand with an experimental LinuxKPI patch it associates and passes traffic,
   TX reaches 82 to 88% of Linux, RX 68 to 74% (474 to 509 and 289 to 314 Mbit/s against 577/426 on the same AP).
   Status, patches and next steps: [docs/mt7925_wifi.md](docs/mt7925_wifi.md).
   Upstream: follow PR 273623 (mt76 meta-bug).
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
- Cameras: a large job (now in progress, see [docs/amd_isp_camera.md](docs/amd_isp_camera.md)); a USB webcam works today with `uvideo(4)`.
- PMF: useful for power modes, but the firmware default works.
