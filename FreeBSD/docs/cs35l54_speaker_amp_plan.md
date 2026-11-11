# Plan: a FreeBSD driver for the Cirrus Logic CS35L54 speaker amplifiers

Machine: HP ZBook Ultra G1a 14 (subsystem 103C:8D01), see [../HP.ZBook.Ultra.G1a.md](../HP.ZBook.Ultra.G1a.md).
Status: plan only, no driver code yet. Facts below were measured on 2026-11-11
(FreeBSD main-n290939) or read in Linux (tree of 2026-07-28) and linux-firmware (69e51bb, 2026-11-09).

## 1. The problem

The internal speakers are silent on FreeBSD.
The audio path works up to the codec: Chromium plays through PulseAudio into `pcm4`
(Realtek ALC245, pin nid23 "Speaker, Fixed, Internal"), and the hardware channel takes data with 0 underruns.

The ALC245 does not drive the speakers.
It sends digital audio to four Cirrus Logic CS35L54 "smart amplifiers".
Each amplifier has a small DSP (Cirrus "Halo" core) and an I2C control port.
The amplifier outputs nothing until the OS wakes it, configures its audio port,
and sends it a "play" command.
FreeBSD has no driver for it, so nobody sends that command.

## 2. What the hardware looks like

### ACPI description

`\_SB_.I2CB.SPKR`, `_HID` "CSC3554", `_SUB` "103C8D01", `_UID` 1.
`iasl` cannot decompile this DSDT (`Failure resolving symbol [\_SB._]`),
so the resources below come from the raw AML bytes of `SPKR._CRS` and `SPKR._DSD`:

| Resource | Value | Use |
|---|---|---|
| I2cSerialBusV2 x4 | `\_SB.I2CB`, addresses 0x30, 0x31, 0x32, 0x33, 1 MHz | the four amplifiers |
| I2cSerialBusV2 | `\_SB.I2CB`, address 0x3C | alias address, not a real device (Linux skips it, see below) |
| GpioIo | `\_SB.GPIO` pin 139 | shared reset line |
| GpioIo + GpioInt | `\_SB.GPIO` pin 130 | interrupt line |
| `_DSD` `cirrus,dev-index` | {0x30, 0x31, 0x32, 0x33} | amplifier index per I2C address |
| `_DSD` `reset-gpios` | 4 references to `SPKR` resource 0 | one reset GPIO shared by all four |

The I2C controller is `ig4iic1` (`\_SB_.I2CB`, AMDI0010), so the bus is `iicbus1` and the generic node is `/dev/iic1`.

### What FreeBSD does with it today

`acpi_iicbus` creates one child per ACPI device and keeps only the first I2cSerialBus resource
(`acpi_iicbus_get_i2cres_cb()` returns `AE_CTRL_TERMINATE`, `sys/dev/iicbus/acpi_iicbus.c:378`).
So `devinfo` shows one device, `unknown pnpinfo _HID=CSC3554 ... at addr=0x30`.
A driver attaches to that single child and talks to 0x31-0x33 itself:
`iicbus_transfer()` takes the slave address in each `struct iic_msg`, so any address on the bus is reachable.

### First contact (read-only)

[cs35l54_probe.c](cs35l54_probe.c) reads registers 0x0 (DEVID) and 0x4 (REVID) through `/dev/iic1`.
Registers have 32-bit addresses and 32-bit big-endian values (Linux `cs35l56_regmap_i2c`: `reg_bits = 32`, `val_bits = 32`, both big-endian).

```
0x30: DEVID 0x00000000 REVID 0x000000b0
0x31: DEVID 0x00000000 REVID 0x000000b0
0x32: DEVID 0x00000000 REVID 0x000000b0
0x33: DEVID 0x00000000 REVID 0x000000b0
```

- All four amplifiers answer on FreeBSD today, without any driver.
- REVID 0xB0: B0 silicon, which matches the linux-firmware file names (`cs35l54-b0-...`).
- DEVID reads 0 instead of the expected 0x35A54.
  Linux reads DEVID only after a wake sequence and `cs35l56_wait_for_firmware_boot()` (`cs35l56_hw_init()`);
  the probe did neither. To confirm in phase 1.

### Firmware and calibration data

- linux-firmware has four tuning files for this laptop, one per amplifier, about 7.5 KB each:
  `cirrus/cs35l54-b0-dsp1-misc-103c8d01-amp1.bin` to `-amp4.bin`.
  License: "Redistributable. See LICENSE.cirrus for details."
- There is no `.wmfw` (DSP program) file for any CS35L54.
  The amplifier runs its firmware from on-chip ROM; the `.bin` files only patch coefficients (tuning).
- Per-unit calibration (speaker impedance measured at the factory) is in a UEFI variable:
  `efivar -l` lists `02f9af02-7734-4233-b43d-93fe5aa35db3-CirrusSmartAmpCalibrationData`.
  Linux reads it in `cs-amp-lib.c` (`CIRRUS_LOGIC_CALIBRATION_EFI_NAME`).

## 3. How Linux drives it

Files (all `GPL-2.0-only`):

| File | Lines | Role |
|---|---|---|
| `sound/hda/codecs/side-codecs/cs35l56_hda.c` | 1274 | HDA side-codec driver: probe, firmware load, play/pause hooks |
| `sound/hda/codecs/side-codecs/cs35l56_hda_i2c.c` | 85 | I2C glue, matches "CSC3554" |
| `sound/soc/codecs/cs35l56-shared.c` | 1939 | register map, wake, reset, mailbox, calibration |
| `drivers/firmware/cirrus/cs_dsp.c` | 3837 | generic Cirrus DSP loader (wmfw, bin, controls) |
| `sound/soc/codecs/cs-amp-lib.c` | 864 | calibration from UEFI variables |
| `sound/hda/codecs/side-codecs/hda_component.c` | 209 | binds side codecs to the Realtek codec |
| `drivers/platform/x86/serial-multi-instantiate.c` | | creates one I2C device per I2cSerialBus resource of CSC3554 |

Probe sequence for each amplifier (`cs35l56_hda_common_probe()`):

1. Read `_SUB` and `cirrus,dev-index`; the index gives the amp name (`AMP1`..`AMP4`).
   Addresses missing from `cirrus,dev-index` (here 0x3C) are skipped silently.
2. Toggle the shared reset GPIO, or wake the chip.
   Wake = two dummy reads of `IRQ1_STATUS` (0xE004) at least 1 ms apart (`CS35L56_WAKE_HOLD_TIME_US`),
   then wait 2.2 ms for the control port (`CS35L56_CONTROL_PORT_READY_US`).
3. `cs35l56_hw_init()`: read REVID, wait for firmware boot, read DEVID (expect 0x35A54), read secure status and OTP ID.
4. System reset, wait for boot, apply a register patch (`cs35l56_set_patch()`).
5. Mailbox command `PREVENT_AUTO_HIBERNATE` (0x02000003, written to `DSP_VIRTUAL1_MBOX_1` 0x11020).
6. Read calibration, initialize the Halo DSP view (`cs_dsp_halo_init()`).
7. Write the audio serial port setup (`cs35l56_hda_dai_config[]`: `ASP1_CONTROL1..3`, frame and data control, TX inputs).

Firmware load, from a work queue (`cs35l56_hda_fw_load()`):

- Read `PROTECTION_STATUS` (0x34000D8) to learn if firmware is missing or which ROM version runs.
- Request `cirrus/cs35l54-b0-dsp1-misc-<system>-<amp>.bin` (the `-<rom version>` variant first when firmware is preloaded).
- `cs_dsp_power_up()` writes the coefficients, `cs_dsp_run()`, apply calibration, mailbox `AUDIO_REINIT` (0x0B000003).
- Without wmfw and bin, Linux still plays if the ROM firmware runs; files are mandatory only when `FIRMWARE_MISSING` is set.

Playback, hooked on the Realtek codec PCM (`cs35l56_hda_playback_hook()`):

- On PCM prepare: mailbox `AUDIO_PLAY` (0x0B000001), poll `TRANSDUCER_ACTUAL_PS` (0x3400150) until PS0, enable ASP1 RX1/RX2 in `ASP1_ENABLES1` (0x4800).
- On PCM cleanup: mailbox `AUDIO_PAUSE` (0x0B000002), disable ASP1 RX/TX.

The Realtek side finds the amplifiers in `find_cirrus_companion_amps()` (`sound/hda/codecs/realtek/alc269.c`),
called for every ALC269-family codec, and calls the hook from its PCM playback hook.
The quirk for 103C:8D01 itself is only `ALC285_FIXUP_HP_GPIO_LED` (mute LED).

## 4. Choice: LinuxKPI port or native driver

| | LinuxKPI port (out of base, like drm-kmod) | Native FreeBSD driver |
|---|---|---|
| Code reuse | cs_dsp, cs35l56-shared, cs35l56_hda as is | none; Linux is a behaviour reference only |
| License | GPL-2.0: cannot enter base, must ship as a port | BSD-2-Clause, can go upstream |
| Missing glue | LinuxKPI has no `regmap.h`, `component.h`, `gpio/consumer.h`; no ALSA kcontrols; the HDA hook must target FreeBSD `snd_hda`, not Linux HDA | none beyond the HDA hook (section 6) |
| Size | about 8000 lines carried, plus glue | estimate 1000-1500 lines: only the subset this hardware needs |
| Maintenance | follow Linux updates | own the code |

Recommendation: a native driver.
The LinuxKPI route still needs a FreeBSD-specific HDA hook and three new LinuxKPI subsystems,
and the result can never be in base.
The native driver needs only a subset: no wmfw loader (no CS35L54 wmfw exists), no SoundWire, no SPI, no ALSA controls, no factory calibration.
Write it from the register behaviour, without copying GPL code.

## 5. Phases

Each phase ends with a test that proves it on this laptop.
Keep the speaker volume low during tests: phase 2 runs the amplifiers without tuning or calibration.
Linux accepts that state (it plays with ROM firmware when files are absent), but the speaker protection limits are then the ROM defaults.

### Phase 1: userland prototype through /dev/iic1

Extend `cs35l54_probe.c` into a tool that, for each amplifier:

1. Wakes it (two reads of 0xE004, 1 ms apart, then 2.2 ms wait).
2. Waits for firmware boot, then reads DEVID (expect 0x35A54), `PROTECTION_STATUS`, `DSP_RESTRICT_STS1`.
3. Sends `PREVENT_AUTO_HIBERNATE`, writes the ASP1 setup, sends `AUDIO_PLAY`, polls for PS0, enables ASP1 RX.

Test: play a tone into `pcm4` (`cat /dev/random > /dev/dsp4` at low `mixer vol`, or a WAV file), run the tool, listen.
This answers the biggest unknown without kernel code: does the ROM firmware play with this register sequence and no tuning?
If it does not, compare with a Linux boot on the same laptop (Ubuntu is installed): dump the same registers under Linux with `i2ctransfer` while audio plays.

### Phase 2: kernel driver skeleton

- New driver `cs35l54` (or `cs35l5x`) on `iicbus`, matching ACPI HID CSC3554 (`acpi_iicbus` child at 0x30).
- Read `cirrus,dev-index` from `_DSD` (`acpi_GetProperty()` / `device_get_property()`) to get the amplifier list; ignore 0x3C.
- Reset through the shared GPIO pin 139, or fall back to the wake sequence.
  FreeBSD has no ACPI GpioIo lookup for a device that is not a gpiobus child:
  parse the GpioIo resource from `_CRS` and call `gpio_pin_get_by_bus_pinnum()` (`sys/dev/gpio/gpiobusvar.h:154`) on the `amdgpio(4)` gpiobus.
  `amdgpio` is not loaded by default.
- Interrupt (GPIO 130): skip. Linux works without it, and FreeBSD x86 cannot deliver GpioInt yet (see [x86_gpio_intr_mtl.md](x86_gpio_intr_mtl.md)).
- Port phase 1 into the attach routine; expose `dev.cs35l54.0.play` as a sysctl for manual tests.

Test: `kldload`, `sysctl dev.cs35l54.0.play=1` while `pcm4` plays: sound. `=0`: silence.
Model the iicbus usage on `ipmi_ssif` ([IPMI_SSIF.md](IPMI_SSIF.md)).

### Phase 3: hook into snd_hda

The amplifiers must follow the speaker stream: play when `pcm4` starts, pause when it stops.
`hdaa_channel_trigger()` (`sys/dev/sound/pci/hda/hdaa.c:2223`) sees `PCMTRIG_START` and `PCMTRIG_STOP`.
Options, to discuss with the sound maintainers before coding:

1. An `EVENTHANDLER` fired by hdaa on trigger, carrying the codec, the pin association and start/stop.
   Simple, loosely coupled; the amp driver filters on its codec.
2. A kobj interface ("hda side codec") that hdaa calls for registered side codecs.
   Closer to Linux `hda_component`; more code in hdaa.

Either way the link between amp and codec comes from ACPI: CSC3554 exists and the codec subsystem ID matches `_SUB`.

Test: play and stop audio in Chromium; sound starts and stops without the sysctl.

### Phase 4: tuning and calibration

- Load `cirrus/cs35l54-b0-dsp1-misc-103c8d01-ampN.bin` with `firmware_get()`; FreeBSD loads raw files from `/boot/firmware/` (`try_binary_file()`, `sys/kern/subr_firmware.c:270`).
- Write a minimal `.bin` (WMDR) parser: blocks address coefficients by DSP algorithm ID and offset,
  so the driver must first read the algorithm list from the DSP memory (the Halo part of `cs_dsp.c`).
- Read `CirrusSmartAmpCalibrationData` with `efi_var_get()` (`sys/sys/efi.h:370`, needs `efirt`) and write the per-amp values to the protection algorithm.
- Send `AUDIO_REINIT` after the writes.

Test: the driver logs the tuning file and calibration it applied; sound quality should match Linux on the same laptop.

### Phase 5: power management and polish

- Suspend/resume: re-run wake, patch and tuning on resume.
- Let the amplifiers hibernate when idle (drop `PREVENT_AUTO_HIBERNATE`, wake before play).
- Man page `cs35l54.4`.
- Port for the firmware files (`audio/cirrus-amp-firmware` or a flavor of an existing firmware port), from linux-firmware `cirrus/` under LICENSE.cirrus.
- Other laptops: linux-firmware has `.bin` files for other HP IDs (103C8D08, 103C8D85, ...); keep system name and amp count data-driven from ACPI.

## 6. Risks and open questions

- DEVID read 0 in the first probe: wake/boot sequence not yet confirmed.
- The ALC245 may need extra codec setup to send audio to the amplifiers; Linux applies no 8D01-specific codec fixup besides the mute LED, so probably not.
- Amplifier channel mapping: Linux enables one ASP TX slot per amp (`asp_tx_mask = BIT(index)`); left/right/woofer assignment comes from the `.bin` tuning, so phase 2 may sound wrong (mono or odd balance) until phase 4.
- Speaker safety without calibration: limited test volume until phase 4.
- Clean-room discipline: no copied Linux code in the native driver; register names and values are hardware facts.

## 7. Next step

Phase 1: extend `cs35l54_probe.c` with the wake sequence and confirm DEVID 0x35A54 on all four amplifiers.
