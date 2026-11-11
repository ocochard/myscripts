# Plan: a FreeBSD driver for the Cirrus Logic CS35L54 speaker amplifiers

Machine: HP ZBook Ultra G1a 14 (subsystem 103C:8D01), see [../HP.ZBook.Ultra.G1a.md](../HP.ZBook.Ultra.G1a.md).
Status: phases 1 and 1b done (2026-11-11): the userland tool [cs35l54_tool.c](cs35l54_tool.c) downloads the DSP firmware and the speakers play on FreeBSD.
No kernel driver yet. Facts below were measured on 2026-11-11
(FreeBSD main-n290939, and Ubuntu with Linux 7.0.0-43 on the same laptop)
or read in Linux (tree of 2026-07-28) and linux-firmware (69e51bb, 2026-11-09).
The speakers work under Ubuntu: the hardware path is confirmed.

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

`\_SB_.I2CB.SPKR` (DSDT), `_HID` "CSC3554", `_SUB` "103C8D01", `_UID` 1.
Resources, from the raw AML bytes of `SPKR._CRS` and `SPKR._DSD`, and confirmed by the DSDT decompiled under Ubuntu:

| Resource | Value | Use |
|---|---|---|
| I2cSerialBusV2 x4 | `\_SB.I2CB`, addresses 0x30, 0x31, 0x32, 0x33, 1 MHz | the four amplifiers |
| I2cSerialBusV2 | `\_SB.I2CB`, address 0x3C | alias address, not a real device (Linux skips it, see below) |
| GpioIo | `\_SB.GPIO` pin 139 | shared reset line |
| GpioIo + GpioInt | `\_SB.GPIO` pin 130 | interrupt line |
| `_DSD` `cirrus,dev-index` | {0x30, 0x31, 0x32, 0x33} | amplifier index per I2C address |
| `_DSD` `reset-gpios` | 4 references to `SPKR` resource 0 | one reset GPIO shared by all four |

The I2C controller is `ig4iic1` (`\_SB_.I2CB`, AMDI0010).
Its `iicbus`/`iic` unit numbers are not stable: `/dev/iic1` without amdgpu, `/dev/iic18` when amdgpu loads at boot and adds its display buses first.
Find the node from the ACPI path (`dev.ig4iic.N.%location`), as the tool does.

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
- DEVID reads 0 instead of the expected 0x35A54 (Linux reads `0x00035a54`).
  The cause is a FreeBSD read problem, not the chip state, see "The ig4 read problem" below.
  REVID only looked right by chance.

### The ig4 read problem

Through FreeBSD `ig4`, the first 32-bit word of every read from these amplifiers is stale:
it is the word after the end of the previous read. The following words are correct.
Example, three reads of the reset-default ASP registers (default 0x4804 = 0x28, 0x4808 = 0x18180200):

```
0x0004804: 00000061 18180200 18180200
0x0004808: 18180200 00000002 00000002
```

- A 1 ms pause between the address write and the read changes nothing; a split transfer (STOP between) changes nothing.
- Linux reads the same chips correctly with the same protocol (write 4 address bytes, repeated start, read).
- `ig4` sets up fast mode (400 kHz) per `ig4_iic.c`, below the 1 MHz the ACPI table allows; bus speed not measured.
- Root cause not found.

Workaround used by the tool: read two words starting at reg - 4 and keep the second.
It returns the right value with or without the problem.
DEVID (reg 0) cannot be read this way.
A kernel driver must use the same workaround until `ig4` is fixed.

### Firmware and calibration data

- linux-firmware has four tuning files for this laptop, one per amplifier, about 7.5 KB each:
  `cirrus/cs35l54-b0-dsp1-misc-103c8d01-amp1.bin` to `-amp4.bin`.
  License: "Redistributable. See LICENSE.cirrus for details."
- The DSP program is `cirrus/cs35l54-b0-dsp1-misc-103c8d01.wmfw`, a link to `cirrus/cs35l56/CS35L56_Rev3.11.18.wmfw` (33308 bytes).
  The link is a `Link:` line in linux-firmware `WHENCE`, created at install time, so `git ls-tree` does not show it.
- The chip boots from on-chip ROM firmware (Linux log: `fw:3.4.4 (patched=0)`).
  Linux replaces it at every probe: shutdown, download of the wmfw and bin, reset (`DSP1: Firmware: 1a00d6 vendor: 0x2 v3.11.18, 41 algorithms`).
- Amplifier roles, from the tuning names in the Linux log:

  | Address | Amp | Speaker |
  |---|---|---|
  | 0x30 | AMP1 | left woofer |
  | 0x31 | AMP2 | left tweeter |
  | 0x32 | AMP3 | right tweeter |
  | 0x33 | AMP4 | right woofer |
- Per-unit calibration (speaker impedance measured at the factory) is in a UEFI variable:
  `efivar -l` lists `02f9af02-7734-4233-b43d-93fe5aa35db3-CirrusSmartAmpCalibrationData`.
  Linux reads it in `cs-amp-lib.c` (`CIRRUS_LOGIC_CALIBRATION_EFI_NAME`) and logs `Calibration applied` for all four amplifiers.

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
Linux log: `snd_hda_codec_alc269 hdaudioC1D0: Found 4 CSC3554 on i2c (-%s:00-cs35l54-hda.%d)`.

### What the I2C trace shows

Under Ubuntu, an ftrace capture of all I2C transfers (`events/i2c`) covered an unbind/bind of the four amplifiers and one tone.
Decoded per register for AMP1: [cs35l54_linux_i2c_trace_amp1.txt](cs35l54_linux_i2c_trace_amp1.txt)
(decoder: [cs35l54_i2c_trace_decode.awk](cs35l54_i2c_trace_decode.awk), collection script: [zbook_collect_linux.sh](zbook_collect_linux.sh)).
Each amplifier gets about 310 register operations; 0x31-0x33 follow the same pattern.

Mailbox commands go to `DSP_VIRTUAL1_MBOX_1` (0x11020); Linux reads it back until it returns 0 (command taken).

| Time (s) | Operation | Meaning |
|---|---|---|
| 0.000 | R 0x3400150 = 3; W 0xE01C = 2; mbox 0x02000004 | state PS3; `ALLOW_AUTO_HIBERNATE` (unbind) |
| 0.001 | R 0xE004 twice, 1 ms apart | wake sequence |
| 0.006 | R 0x28021E0 = 2; mbox 0x02000003 | firmware boot done (`HALO_STATE_BOOT_DONE`); `PREVENT_AUTO_HIBERNATE` |
| 0.013 | R 0x4 = 0xB0; R 0x0 = 0x00035A54 | REVID B0, DEVID CS35L54 |
| 0.014 | R 0x190F0 = 0; R 0x10 = 4; R 0x34000D8 = 1; R 0x2800010 = 0x30404 | not secured, OTP 4, `FIRMWARE_MISSING` set, ROM firmware 3.4.4 |
| 0.015 | mbox 0x02000007, then register patch, then ASP1 setup (0x4804-0x4840, 0x4C20-0x4C2C) | `SYSTEM_RESET`, `cs35l56_set_patch()`, `cs35l56_hda_dai_config[]` |
| 0.028 | mbox 0x02000005 | `SHUTDOWN` before the download |
| 0.031-1.366 | block writes to 0x2000000-0x2C00xxx and 0x34xxxxx (1463 words) | wmfw program, then bin tuning; no write to program memory (0x3800000), see phase 1b |
| 1.525 | mbox 0x02000007, then `AUDIO_REINIT` 0x0B000003 | reset into the new firmware, reinit |
| 6.858 | mbox 0x02000003; `AUDIO_PLAY` 0x0B000001; R 0x3400150 = 0; W 0x4800 = 0x00030001 | play: PS0 reached at once, ASP1 RX1+RX2 and TX1 enabled |
| 12.884 | `AUDIO_PAUSE` 0x0B000002; W 0x4800 = 0 | stop |

`PROTECTION_STATUS` = 1 means the ROM firmware runs unpatched,
so in Linux's logic the wmfw and bin files are mandatory on this laptop (`cs35l56_hda_fw_load()`).
Phase 1 confirmed it: the ROM firmware alone outputs no sound.

## 4. Choice: LinuxKPI port or native driver

| | LinuxKPI port (out of base, like drm-kmod) | Native FreeBSD driver |
|---|---|---|
| Code reuse | cs_dsp, cs35l56-shared, cs35l56_hda as is | none; Linux is a behaviour reference only |
| License | GPL-2.0: cannot enter base, must ship as a port | BSD-2-Clause, can go upstream |
| Missing glue | LinuxKPI has no `regmap.h`, `component.h`, `gpio/consumer.h`; no ALSA kcontrols; the HDA hook must target FreeBSD `snd_hda`, not Linux HDA | none beyond the HDA hook (section 6) |
| Size | about 8000 lines carried, plus glue | estimate 1500-2500 lines: only the subset this hardware needs |
| Maintenance | follow Linux updates | own the code |

Recommendation: a native driver.
The LinuxKPI route still needs a FreeBSD-specific HDA hook and three new LinuxKPI subsystems,
and the result can never be in base.
The native driver needs only a subset: a wmfw and bin loader for the Halo DSP, but no SoundWire, no SPI, no ALSA controls, no factory calibration.
The wmfw loader is the largest part (format parsing, memory region mapping, algorithm table); it is still a fraction of `cs_dsp.c`, which supports several DSP generations.
The phase 1b loader in `cs35l54_tool.c` is about 360 lines of C.
Write it from the register behaviour and the documented file formats, without copying GPL code.

## 5. Phases

Each phase ends with a test that proves it on this laptop.
Keep the speaker volume low during tests until phase 4: calibration is not applied, so the speaker protection uses default values.

### Phase 1: userland prototype through the I2C node (done, no sound)

[cs35l54_tool.c](cs35l54_tool.c) replays the non-download part of the Linux trace, for each amplifier:

1. Wake: two reads of 0xE004, 1 ms apart, then 2.2 ms wait.
2. Poll `DSP1_HALO_STATE` (0x28021E0) until 2 (`BOOT_DONE`, 1 ms steps, 250 ms timeout), then read `PROTECTION_STATUS` and `DSP1_FW_VER`.
3. Mailbox `PREVENT_AUTO_HIBERNATE`, register patch, `MAIN_RENDER_USER_VOLUME`, ASP1 setup (the 0x4804-0x4840 and 0x4C20-0x4C2C writes of the trace).
4. Mailbox `AUDIO_PLAY`, poll 0x3400150 for 0 (PS0), write 0x4800 = 0x00030000 | BIT(amp index).

Commands: `reset` (pulse of GPIO 139, needs `amdgpio`), `info`, `play [-v dB]`, `stop`, `tone [Hz [s [dBFS]]]`, `read`, `write`.
`MAIN_RENDER_USER_VOLUME` (0x340002C) takes 0.25 dB steps from -100 to +12 dB in bits 6-15 (signed); the tool defaults to -20 dB.

Results on ROM firmware 3.4.4, all with a 440 Hz tone on the speaker pcm, nothing heard:

| Test | Result |
|---|---|
| Normal play (DSP path) | amps reach PS0, ROM firmware sets the routing (`DACPCM1_INPUT` = DSP1TX5, `DSP1RX1/2_INPUT` = ASP1RX1/2), silence |
| DSP bypass on the woofers (`DACPCM1_INPUT` = ASP1RX1) | silence |
| Both tests again with the codec speaker pin fed from converter 0x03 (as on Linux) instead of 0x02 | silence |

Conclusion: the ROM firmware is a boot loader; `FIRMWARE_MISSING` means what it says.

### Phase 1b: firmware download in userland (done, sound)

`cs35l54_tool load [-nsv] DIR` parses the wmfw and bin files and writes them over I2C, then `play` gives sound (2026-11-11, heard on the laptop at -30 dB amp volume).

Sequence per amplifier, as in the Linux trace:

1. Wake, wait for boot, `PREVENT_AUTO_HIBERNATE`, system reset (HALO_STATE = 0, mailbox `SYSTEM_RESET`), wait for boot, patch, ASP setup.
2. If `PROTECTION_STATUS` bit 0 (`FIRMWARE_MISSING`): mailbox `SHUTDOWN`, poll `PM_CUR_STATE` (0x2804308) for 1.
3. wmfw: 70 regions. XM/YM unpacked: base + offset * 4. XM/YM packed: (base + offset * 3) & ~3. PM packed: 0x3800000 + offset * 5.
4. Read the algorithm table at 0x2800000: a 10-word header (core, block rev, vendor, firmware id, version, XM base/size, YM base/size, count), 41 entries of 6 words, terminator 0x00BEDEAD.
   The firmware id (0x1A00D6) also owns XM/YM regions, like each algorithm: one bin block per amp targets it.
5. bin: 35 blocks per amp, each at its algorithm's XM or YM base (converted as in step 3) plus the block offset.
6. System reset, wait for boot, `PREVENT_AUTO_HIBERNATE`, patch, ASP setup, `AUDIO_REINIT`.

After step 6: `PROTECTION_STATUS` = 0, `HALO_STATE` = 2, `PM_CUR_STATE` = 2, and the mailbox answers.

Checks against the Linux trace (`-n` prints the wmfw writes without touching the amps):

- The wmfw and bin writes for AMP1 match the trace in address, word count and first word.
- One difference in chunking: Linux writes a 624-word region in one transfer; the tool no longer splits writes at 768 bytes.
- Program memory: the trace has no write to 0x3800000, yet the file has a 14600-byte PM region.
  Without it (the first attempt, which matched the trace exactly), the new firmware never boots: `HALO_STATE` stays 0 and the mailbox is not taken.
  With it, the firmware boots and plays.
  Probable reason: the trace covers a rebind under Linux, when the amplifiers still held the program from the boot-time load; not verified.
  The tool now writes it by default; `-s` skips it, to reproduce the failure.

Usage:

```sh
kldload amdgpio
cs35l54_tool reset
cs35l54_tool load /path/to/firmware      # cs35l54-b0-dsp1-misc-103c8d01.wmfw, -amp1..4.bin
cs35l54_tool play -v -30
cs35l54_tool tone 440 5 -20              # or any audio on pcm4
cs35l54_tool stop
```

`stop` allows auto-hibernation; a hibernating amp does not answer I2C until woken, and the firmware survives it (the next `play` works without a new `load`).

### Phase 2: kernel driver skeleton

- New driver `cs35l54` (or `cs35l5x`) on `iicbus`, matching ACPI HID CSC3554 (`acpi_iicbus` child at 0x30).
- Read `cirrus,dev-index` from `_DSD` (`acpi_GetProperty()` / `device_get_property()`) to get the amplifier list; ignore 0x3C.
- Reset through the shared GPIO pin 139, or fall back to the wake sequence.
  FreeBSD has no ACPI GpioIo lookup for a device that is not a gpiobus child:
  parse the GpioIo resource from `_CRS` and call `gpio_pin_get_by_bus_pinnum()` (`sys/dev/gpio/gpiobusvar.h:154`) on the `amdgpio(4)` gpiobus.
  `amdgpio` is not loaded by default.
- Interrupt (GPIO 130): skip. Linux works without it, and FreeBSD x86 cannot deliver GpioInt yet (see [x86_gpio_intr_mtl.md](x86_gpio_intr_mtl.md)).
- Port phases 1 and 1b into the attach routine: firmware download at attach (from a taskqueue), then `dev.cs35l54.0.play` as a sysctl for manual tests.
- Use the read workaround from "The ig4 read problem".

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

### Phase 4: calibration

The DSP program and tuning download moved to phases 1b and 2 (no sound without them).
Remaining:

- Firmware files from `/boot/firmware/` with `firmware_get()` (`try_binary_file()`, `sys/kern/subr_firmware.c:270`), instead of a path given to the tool.
- Read `CirrusSmartAmpCalibrationData` with `efi_var_get()` (`sys/sys/efi.h:370`, needs `efirt`) and write the per-amp values to the protection algorithm.
  The control offsets come from the wmfw `ALGORITHM_DATA` regions (coefficient names), which the tool skips today.
- Send `AUDIO_REINIT` after the writes.

Test: the driver logs the calibration it applied; sound quality should match Linux on the same laptop.

### Phase 5: power management and polish

- Suspend/resume: re-run wake, patch and tuning on resume.
- Let the amplifiers hibernate when idle (drop `PREVENT_AUTO_HIBERNATE`, wake before play).
- Man page `cs35l54.4`.
- Port for the firmware files (`audio/cirrus-amp-firmware` or a flavor of an existing firmware port), from linux-firmware `cirrus/` under LICENSE.cirrus.
- Other laptops: linux-firmware has `.bin` files for other HP IDs (103C8D08, 103C8D85, ...); keep system name and amp count data-driven from ACPI.

## 6. Risks and open questions

- The `ig4` stale-read problem: the workaround works, but the root cause is unknown and may affect other I2C devices on AMD laptops.
- Codec setup: FreeBSD feeds the speaker pin from converter 0x02, Linux from 0x03. With firmware loaded, sound works on 0x02, so no codec change is needed.
- Sound quality not judged yet: left/right balance and the woofer/tweeter split come from the tuning, which is loaded, but nobody compared with Linux.
- Speaker safety without calibration: limited test volume until phase 4.
- Clean-room discipline: no copied Linux code in the native driver; register names and values are hardware facts.

## 7. Next step

Phase 2: kernel driver skeleton on the `olivier-cs35l54` branch of the FreeBSD fork, porting `cs35l54_tool.c` (wake, reset, download, play/stop sysctl).
