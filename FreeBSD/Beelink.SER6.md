# Beelink SER6 mini PC on FreeBSD

Machine: Beelink SER6 mini PC (SMBIOS maker "AZW", product "SER", AMI BIOS 113 of 2023-02-22),
AMD Ryzen 7 7735HS (Rembrandt-R, Zen 3+, 8 cores / 16 threads), Radeon 680M.
Memory: 64 GB (`hw.physmem` 64102391808), minus the BIOS VRAM carve-out (amdgpu: `4096M of VRAM`).
Tested: FreeBSD 16.0-CURRENT main-n290674-7806832f23fb (2026-11-05, with local changes), GENERIC-NODEBUG.
Running since 2026-11-19: main-n291400-30e3fd1811e3 (with local changes), GENERIC-NODEBUG.

Status as of 2026-11-16 evening. Sources, collected on 2026-11-16: `pciconf -lv`, `devinfo -v`, `usbconfig`, `/var/run/dmesg.boot`, `kldstat`, `/var/log/messages*`.
Device IDs checked against FreeBSD main 70cf7c62ee14 (2026-11-15) and Linux 3b5f4b83c4ab (2026-07-28).
No Linux boot on this machine: the "Linux driver" columns come from the Linux source, not from a running system.

Work of 2026-11-16, in short:

- Bluetooth fixed by installing `iwmbt-firmware`; two patches make the missing package visible (`fwget`, `iwmbtfw` logging).
- NVMe temperature events explained: default 83 C threshold, the drive heats under load.
- AMD IOMMU: the stock kernel loops on USB attach with `hw.amdiommu.enable=1`; two patches fix it and lower the DMA cost.
- Idle interrupts explained: Bluetooth SCO transfers (patch written) and `virtual_oss` (its default configuration records the microphone all the time).
- TPM no longer attaches: the installed kernel predates ACPI start method support.

Update of 2026-11-21 (kernel main-n291400): TPM works (`tpmcrb0`, `/dev/tpm0`);
the IOMMU shows as `amdviiommu0` because `vmm.ko` is loaded;
the ACP driver written for the HP ZBook (`snd_acp`) does not cover this ACP, see [Audio Coprocessor](#audio-coprocessor-11605).

All patches and their order: [Applying the work, in order](#applying-the-work-in-order).

## What works

| Function | Device | FreeBSD driver |
|---|---|---|
| GPU, display | 1002:1681 Radeon 680M | `amdgpu` from `graphics/drm-latest-kmod` + `gpu-firmware-amd-kmod-yellow-carp`, not in `kld_list` (see below) |
| HDMI/DP audio | 1002:1640 | `hdac0`, 3 `pcm` outputs |
| Analog audio | 1022:15e3 + Conexant 0x1f87 codec | `hdac1`, `pcm3` (jack, play/rec), `pcm4` (analog microphone) |
| NVMe | Kingston NV2 (2646:5017) | `nvme`/`nda` (see [NVMe event flood](#nvme-event-flood)) |
| 2.5G Ethernet | Realtek RTL8125B (10ec:8125) | `rge` |
| Wi-Fi | Intel AX200 (8086:2723) | `iwlwifi`, loaded by devmatch; `wlan0` associates with WPA and gets a DHCP lease (tested 2026-11-16, not enabled in `rc.conf`) |
| Bluetooth | Intel AX200 (8087:0029 on USB) | `ng_ubt` after `iwmbtfw` loads the firmware; needs `iwmbt-firmware` (installed 2026-11-16), see [below](#usb-devices-without-a-working-driver); costs about 1100 interrupts/s at idle, see [Interrupt rates at idle](#interrupt-rates-at-idle) |
| USB 3 | five xHCI (1022:161d, 161e, 161f, 15d6, 15d7) | `xhci` |
| I2C controllers | AMDI0010 DesignWare | `ig4iic0-1`, no child device on either `iicbus` |
| SMBus | FCH 1022:790b | `intsmb` |
| CPU frequency | CPPC | `hwpstate_amd` |
| CPU temperature | Family 19h data fabric | `amdtemp`, `amdsmn` |
| CPU idle | ACPI C-states | `cx_lowest` C8, 97.7% of time in C3 on CPU 0 |
| TPM 2.0 | MSFT0101, firmware TPM | `tpmcrb` (CRB, ACPI start method 2), needs a kernel from main of 2026-11-12 or later; attached since the 2026-11-19 kernel |
| Power button, EC | ACPI | `acpi_button`, `acpi_ec` |
| WMI | PNP0C14 | `acpi_wmi` |
| Sleep | S3 (`hw.acpi.supported_sleep_state: S3 S4 S5`) | one resume logged on 2026-11-04 by `acpi[3149]: resumed`; not tested again |

amdgpu works when loaded by hand (`kldload amdgpu`):
`/var/log/messages` of 2026-11-10 shows `Initialized amdgpu 3.61.0 for drmn0` with 4096M VRAM and 30567M GTT.
Two warnings come with it: `Unable to set WC memtype for the aperture base` (2026-11-10)
and `REG_WAIT timeout 1us * 100000 tries - optc31_disable_crtc` (2026-10-13).
GPU resets with a successful recovery (`GPU reset succeeded`, `SMU is resumed successfully!`) are logged on 2026-11-05 and 2026-11-08.
The cause of these resets is not checked.

TPM: this firmware TPM uses the ACPI start method (TPM2 table StartMethod 2).
`tpm_crb` supports it since 6af18560a124 ("tpm: crb: Support the ACPI start method", main of 2026-11-12).
The kernel installed until 2026-11-19 (main-n290674, 2026-11-05) was older: `\_SB_.TPM_` stayed `unknown` in `devinfo` and there was no `/dev/tpm0`.
Earlier on 2026-11-16, a boot with a preloaded test `tpm.ko` attached `tpmcrb0: <Trusted Platform Module 2.0, CRB mode (ACPI start)>`,
with `Module acpi/tpmcrb failed to register: 17` (and the same for `tpm`, `tpmtis`, `isa/tpm`) because GENERIC also has `device tpm`.
That test kernel is removed.
Fixed by the kernel of 2026-11-19 (main-n291400): `devinfo` shows `tpmcrb0`, and `/dev/tpm0` exists.

## PCI devices without driver

Source: `pciconf -l | grep ^none` (2026-11-16; rechecked 2026-11-21: same list, except the IOMMU, now held by `amdviiommu` from `vmm.ko`).

| pciconf | Address | ID | Device | Purpose | Missing on FreeBSD | Linux driver |
|---|---|---|---|---|---|---|
| none0 | 0:0:2 | 1022:14b6 | IOMMU | DMA protection, PCI passthrough | nothing: `amdiommu` exists, off by default; with two patches it works, see [docs/amdiommu_ser6.md](docs/amdiommu_ser6.md) | IOMMU core |
| none1 | 116:0:2 | 1022:1649 | PSP | security processor (no crypto engine exposed, see below) | nothing visible | `ccp` module, PSP part only (`sp-pci.c`: `dev_vdata[6]`, `pspv3`) |
| none2 | 116:0:5 | 1022:15e2 rev 0x60 | Audio Coprocessor (ACP 6.x) | DSP for digital microphones | nothing seen on this machine | `snd_pci_acp6x` (Yellow Carp, rev 0x60) |
| none3 | 117:0:5 | 1022:162e | USB4/Thunderbolt NHI | USB4 fabric, PCIe tunneling | eGPU, PCIe docks | `thunderbolt` |

## USB devices without a working driver

| ugen | ID | Device | State |
|---|---|---|---|
| ugen1.3 | 8087:0029 (bcdDevice 0x0001) | Intel AX200 Bluetooth | fixed 2026-11-16: `iwmbt-firmware` installed, `ubt0` attaches at every boot |

The AX200 Bluetooth part starts in bootloader mode and needs host-loaded firmware.
FreeBSD has the loader: `/etc/devd/iwmbtfw.conf` runs `iwmbtfw -f /usr/local/share/iwmbt-firmware`.
Before 2026-11-16 the firmware package (`comms/iwmbt-firmware`) was not installed, so the directory did not exist and no driver attached.
`ubt0` attached in October (`/var/log/messages` of 2026-10-13); the firmware state then is not known.
Fix, tested 2026-11-16: `pkg install iwmbt-firmware`, then `iwmbtfw -d ugen1.3 -f /usr/local/share/iwmbt-firmware` (or reboot).
`iwmbtfw` prints `Firmware download is successful!`, `ubt0` attaches, and `hccontrol -n ubt0hci read_bd_addr` answers.

Nothing tells the user that this package is missing:

- `fwget(8)` handles only one USB vendor, Ralink (`usr.sbin/fwget/usb/usb_ralink`).
  `fwget -n -v` lists the Wi-Fi and GPU packages for this machine, but no Bluetooth package.
- `iwmbtfw` reports the missing file on stderr only (`warn()` in `iwmbt_fw_read()`).
  devd starts it with stderr on `/dev/null`, and at boot before syslogd: `/var/log/messages` has no `iwmbtfw` line.
- In bootloader mode, `ng_ubt_intel` rejects the device without a message (`ENXIO` in probe).
  The only trace is a `ugen1.3` with no driver.

Fixes in FreeBSD: a `usb_intel` script for `fwget` ([docs/fwget_usb_intel_bluetooth.md](docs/fwget_usb_intel_bluetooth.md))
and syslog plus console logging in `iwmbtfw` ([docs/iwmbtfw_syslog.md](docs/iwmbtfw_syslog.md)); both tested on this machine.

## ACPI devices without driver

Source: `devinfo -v | grep 'unknown pnpinfo'`, without the `PWRS` power resources and the disabled devices
(UARTs, PS/2, extra I2C/I3C, FUR0-4, HID0/HID2, HFP1, APAD).

| HID | Path | Purpose | Linux driver |
|---|---|---|---|
| AMDI0030 | `\_SB_.GPIO` | GPIO controller | `pinctrl-amd`; FreeBSD `amdgpio(4)` exists, not loaded by default |
| AMDI0052 | `\_SB_.PPKG` | DSDT: `_HID` and `_STA` (always 0x0F) only | none bound; Linux uses the ID only as an ASoC machine match (`acp63-acp`) |
| ACPI000E | `\_SB_.ACDC` | Time and Alarm Device: wake timer, RTC | `acpi_tad` |
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
Tested 2026-11-16 ([docs/amdiommu_ser6.md](docs/amdiommu_ser6.md)):

- stock kernel, `hw.amdiommu.enable=1` alone: USB devices attach in an endless loop, power cycle needed;
- stock kernel, plus `hw.iommu.dma=1`: works, but 128 KB NVMe reads lose about 45%;
- with the two patches: both settings work; the read loss drops to about 25%, with 0 IOMMU events.

The same loop and the same fix were confirmed on an HP ZBook Ultra G1a (Strix Halo) by a separate test,
which also found an amdgpu display stall with interrupt remapping alone (see [docs/bugreport_amdiommu_ir_only_loop.md](docs/bugreport_amdiommu_ir_only_loop.md)).

On this machine the protection buys little (no PCIe tunneling over USB4 on FreeBSD yet), so the IOMMU stays off.

### PSP (116:0:2)

AMD Secure Processor: boots the SoC, runs the firmware TPM and platform security.
On this ID it exposes no crypto engine: Linux `sp-pci.c` (master, read 2026-11-21) maps 0x1649 to `dev_vdata[6]`,
which has only `psp_vdata = &pspv3` and no `ccp_vdata`.
So Linux does no crypto offload or hardware RNG here either; earlier text in this document said "crypto offload": wrong.

What `pspv3` gives Linux:

- TEE interface (`teev1`): loads trusted applications into the PSP; used by `amdtee` for AMD-specific TAs, nothing a FreeBSD desktop uses.
- Platform access (`pa_v1`): firmware mailbox for the other PSP features below.
- DBC (Dynamic Boost Control): lets a privileged tool change the SoC power limits at run time (`/dev/dbc`); OEM tuning tools use it.
- HSTI: reads the security state (fused firmware signing, debug lock, rollback protection) for `fwupd` host security reports.

FreeBSD `ccp(4)` (`sys/crypto/ccp/ccp.c`) lists only 1456, 1468 and 15df, and covers the other part:
AES/SHA offload through `crypto(9)` and a TRNG `random(4)` source. Adding 0x1649 to its table would give nothing, since that hardware is absent.
The firmware TPM works through `tpmcrb` without this driver, and the kernel already has a hardware seed (`kern.random.random_sources`: `Intel Secure Key Seed`, RDSEED).
Impact: none. A new driver would add only DBC power tuning and an HSTI security report.

### Audio Coprocessor (116:0:5)

ACP 6.x, the DSP for PDM digital microphones.
On this mini PC the microphone input goes through the HDA codec (`pcm4`, "Internal Analog Mic").
The firmware does not declare a digital microphone on the ACP (checked on 2026-11-16 with `acpidump -b` and `iasl -d`):
`Device (ACP)` in the DSDT has only `_ADR` and no `_DSD`, so no `AcpDmicConnected` property.
`_WOV` (SSDT) returns `F5WV`, a static `Name (F5WV, 0x01)`.
Linux `acp6x-mach.c` registers a card only when `AcpDmicConnected` is 1 or the DMI matches its quirk table,
and the table has no entry for this machine (DMI `AZW` / `SER`).
So Linux also binds no ACP card here, and a FreeBSD driver would have no microphone to drive.
Not confirmed on hardware: no Linux boot checked `arecord -l`.

The `snd_acp` driver written for the HP ZBook (branch `olivier-acp`, [HP.ZBook.Ultra.G1a.md](HP.ZBook.Ultra.G1a.md#audio-coprocessor-19505))
does not apply: it probes only revisions 0x70 to 0x72 (ACP 7.x), and this ACP is revision 0x60 (ACP 6.x, Rembrandt).
Porting it would gain nothing here: the ACP only adds the PDM digital microphone input, and no microphone is wired to it.
The one possible effect of an unbound ACP is power: with `hw.pci.do_power_nodriver=0` (the default) FreeBSD leaves it in D0.
Not measured; the ACP also has its own power gating (`ACP_PGFSM_CONTROL`), and its state at boot is not known.
Impact: none expected.

### USB4 NHI (117:0:5)

USB4/Thunderbolt host interface for the USB4 port.
FreeBSD `thunderbolt(4)` is not in GENERIC (comment: "breaks suspend/resume in some instances") and lists only AMD Pink Sardine IDs (1668, 1669).
On the HP ZBook its `nhi` driver attaches to unlisted AMD USB4 hosts too (see [HP.ZBook.Ultra.G1a.md](HP.ZBook.Ultra.G1a.md#usb4-host-routers-19705-19706)); not tested here.
USB 3 on the USB-C ports works through xHCI.
Impact: no PCIe tunneling (eGPU, NVMe enclosure, PCIe docks).

## Driver work in progress

None of this is needed to run the machine. Patches 1 and 2 fix detection and error reporting for the Bluetooth firmware;
patches 5 and 6 make the AMD IOMMU usable ([docs/amdiommu_ser6.md](docs/amdiommu_ser6.md));
patch 7 stops the idle Bluetooth interrupts ([docs/ng_ubt_sco_on_demand.md](docs/ng_ubt_sco_on_demand.md)).
Each patch is one commit, also pushed to the fork as the branch of the same name.

### Applying the work, in order

The five freebsd-src patches apply on FreeBSD main 563c2f27e0ff (2026-11-16) in this order, without conflict
(checked with `git cherry-pick` of all five on a scratch branch).
Patches 1 and 2 are userland; 5, 6 and 7 are kernel.

| # | Apply | Commits | Depends on | Then | Document |
|---|---|---|---|---|---|
| 1 | freebsd-src [`fwget_usb_intel_bluetooth.patch`](docs/fwget_usb_intel_bluetooth.patch) (branch `olivier-fwget-intel-bt`) | 1 | | `fwget` lists `iwmbt-firmware` | [docs/fwget_usb_intel_bluetooth.md](docs/fwget_usb_intel_bluetooth.md), [bug report](docs/bugreport_fwget_usb_intel_bluetooth.md) |
| 2 | freebsd-src [`iwmbtfw_syslog.patch`](docs/iwmbtfw_syslog.patch) (branch `olivier-iwmbtfw-syslog`) | 1 | | iwmbtfw errors reach syslog, or `dmesg -a` at boot | [docs/iwmbtfw_syslog.md](docs/iwmbtfw_syslog.md), [bug report](docs/bugreport_iwmbtfw_syslog.md) |
| 3 | build and install world, or only `usr.sbin/fwget` and `usr.sbin/bluetooth/iwmbtfw` | | 1, 2 | | |
| 4 | `fwget` (or `pkg install iwmbt-firmware`) | | 3 for `fwget` | reboot, or `iwmbtfw -d ugen1.3 -f /usr/local/share/iwmbt-firmware`; `ubt0` attaches | |
| 5 | freebsd-src [`iommu_idmap_when_dma_disabled.patch`](docs/iommu_idmap_when_dma_disabled.patch) (branch `olivier-amdiommu`) | 1 | | `hw.amdiommu.enable=1` alone no longer loops | [docs/amdiommu_ser6.md](docs/amdiommu_ser6.md) |
| 6 | freebsd-src [`amdiommu_skip_map_invalidation.patch`](docs/amdiommu_skip_map_invalidation.patch) (branch `olivier-amdiommu`) | 1 | | fewer IOMMU interrupts with `hw.iommu.dma=1` | [docs/amdiommu_ser6.md](docs/amdiommu_ser6.md) |
| 7 | freebsd-src [`ng_ubt_sco_on_demand.patch`](docs/ng_ubt_sco_on_demand.patch) (branch `olivier-ubt-sco`) | 1 | | idle `xhci1` interrupts go from about 1100/s to 0; SCO calls untested | [docs/ng_ubt_sco_on_demand.md](docs/ng_ubt_sco_on_demand.md), [bug report](docs/bugreport_ng_ubt_idle_isoc.md) |
| 8 | build and install the kernel and modules | | 5, 6, 7 | for the IOMMU: `hw.amdiommu.enable=1`, plus `hw.iommu.dma=1` for DMA protection, in `/boot/loader.conf`; test with `nextboot -e` first | |

Not for this machine: [`rtlbtfw_syslog.patch`](docs/rtlbtfw_syslog.patch) (branch `olivier-rtlbtfw-syslog`, [docs/rtlbtfw_syslog.md](docs/rtlbtfw_syslog.md)) fixes the same bug in the Realtek loader; the SER6 has no Realtek Bluetooth.

## Interrupt rates at idle

Measured on 2026-11-16 with `vmstat -i` over 10 s, machine idle, nobody using audio or Bluetooth:
`xhci1` takes about 1085 interrupts per second and `hdac1` about 937 per second.
Both have one cause each, found by switching the suspect off and on again:

| Source | Change | `xhci1`/s | `hdac1`/s |
|---|---|---|---|
| baseline | | 1083 | 938 |
| Bluetooth | `usbconfig -d ugen1.3 set_config 255` (unconfigure the AX200 Bluetooth) | 0 | |
| Bluetooth | `set_config 0` again | 1084 | |
| Bluetooth | `net.bluetooth.usb_isoc_enable=0`, then re-attach | 0 | |
| Bluetooth | back to `usb_isoc_enable=1`, re-attach | 1083 | |
| audio | `service virtual_oss stop` | | 0 |
| audio | `service virtual_oss start` | | 937 |

### Bluetooth: SCO transfers run all the time

`usbdump -i usbus1` shows only the Bluetooth adapter (`usbus1.3`) talking: isochronous transfers on endpoints 0x83 (in) and 0x03 (out),
32 frames each, without pause.
These endpoints carry SCO, the voice channel of headsets (HSP/HFP calls).

`sys/netgraph/bluetooth/drivers/ubt/ng_ubt.c`, `ubt_attach()`: it selects the alternate setting of interface 1 with the largest packet size
and sets up the isochronous transfers at attach, so they run whether or not a SCO link exists.
Linux `btusb` keeps the zero-bandwidth alternate setting until a SCO connection is opened.

Workaround: `net.bluetooth.usb_isoc_enable=0` (a tunable, read when `ubt` attaches, so it belongs in `/boot/loader.conf`).
With it, HCI still works (`hccontrol read_local_version_information`: HCI 5.2; `inquiry` found 2 devices) and `xhci1` drops to 0 interrupts per second.
Cost: no SCO, so no headset voice. Data links (ACL) are unaffected: keyboards, mice, file transfer, A2DP music.
Left at the default (1) on this machine.

Fix: start the SCO transfers only while a SCO link is open, as Linux does; patch 7 in [Applying the work](#applying-the-work-in-order),
see [docs/ng_ubt_sco_on_demand.md](docs/ng_ubt_sco_on_demand.md). Tested at idle (0 interrupts per second); a real SCO call is not tested.

### Audio: virtual_oss keeps the codec busy

`virtual_oss` (`virtual_oss_enable="YES"`) holds `/dev/dsp3` (`hdac1`, Conexant codec) open all the time,
with an 8 ms buffer (`-s 8ms`), playback and recording, so the codec never idles.
The recording is what costs: about 750 of the 937 interrupts a second; a larger buffer (`-s`) does not lower the rate.
To lower it: play only (`-R /dev/null -P /dev/dsp3` instead of `-f /dev/dsp3`), or stop the service when the machine needs no audio.
Details and measurements: [docs/virtual_oss.md](docs/virtual_oss.md).

Not measured: the power or C-state cost of these 2000 interrupts per second.

## Which drivers are worth the work

Nothing important is missing on this machine.
Five setup items give more than any new driver:

1. Bluetooth: install `iwmbt-firmware` (done 2026-11-16). `fwget` and `iwmbtfw` patches: see above.
2. GPU: add `amdgpu` to `kld_list` if the machine runs a desktop. Today it is loaded by hand.
3. NVMe: the threshold is the 83 C default; the drive heats under load, see [NVMe event flood](#nvme-event-flood). Fix the cooling, not the threshold.
4. TPM: update the kernel to main of 2026-11-12 or later (done 2026-11-19).
5. Idle interrupts: apply patch 7 (`ng_ubt`), or set `net.bluetooth.usb_isoc_enable=0` in `/boot/loader.conf` if headset voice is not needed;
   see [Interrupt rates at idle](#interrupt-rates-at-idle).

Skip:

- PSP, IOMMU, ACP: no user-visible gain. This PSP has no crypto engine; a driver would add only DBC and HSTI. The ZBook `snd_acp` driver is ACP 7.x only, and this ACP has no microphone wired.
- USB4 NHI: only for PCIe tunneling devices.
- GPIO: `amdgpio` works, but no device needs it.
- ACPI000E: wake timers only; `atrtc` and `efirtc` already provide the clock.
