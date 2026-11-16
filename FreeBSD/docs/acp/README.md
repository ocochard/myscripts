# AMD ACP 7.0 (built-in microphones): data captured on Linux

HP ZBook Ultra G1a, Ubuntu with Linux 7.0.0-43, 2026-11-16. Context and
results: [../../HP.ZBook.Ultra.G1a.md](../../HP.ZBook.Ultra.G1a.md#audio-coprocessor-19505).

| File | Content |
|---|---|
| `lspci-vvv.txt`, `lspci-config.txt`, `sysfs-pci.txt` | PCI 1022:15e2 rev 0x70 at c3:00.5: BARs, capabilities, full configuration space |
| `lsmod.txt`, `modules.txt` | ACP-related modules, aliases, dependencies, parameters |
| `dmesg-acp.txt` | kernel log lines matching ACP, PDM, DMIC, sound and ASoC (broad filter) |
| `asound-cards.txt`, `asound-card2-pcm.txt`, `amixer-card2.txt` | ALSA card 2 `acp-pdm-mach`, its capture PCM; no mixer controls |
| `asoc-debugfs.txt`, `platform-devices.txt` | ASoC components and DAIs, platform devices and their drivers |
| `acpi-node.txt` | ACPI path of the ACP: `\_SB_.PCI0.GPPA.ACP_` |
| `acp-ssdt7.dsl` | SSDT "OEMACP": `_WOV`, `_DSD` properties of `ACP_` and its child `HDA0` |
| `acp-ssdt2-scope.dsl`, `acp-ssdt5-scope.dsl` | other ACP scopes: power methods (`RPRM`, `DSTA`, `PW3S`) |
| `interrupts-idle.txt` | `/proc/interrupts` lines at idle |
| `mmiotrace-probe-capture.txt.xz` | mmiotrace of BAR 0 from the first load of `snd_acp_pci` through one 3 s capture (1083 accesses, markers `modprobe`, `capture start`, `capture end`) |
| `mmiotrace-summary.txt` | the trace per phase: offset, read or write, count, first and last value, register name |

How the trace was taken: `snd_acp_pci` blacklisted for one boot, then
mmiotrace on, `modprobe snd_acp_pci`, `arecord -D hw:2,0 -f S32_LE -c 2
-r 48000 -d 3 /dev/null`, mmiotrace off (it fails with an I/O error while a
`trace_pipe` reader runs; stop the reader first, or the CPUs stay offline).
Do not unload `snd_acp_pci` under mmiotrace: the unload stops half way and
leaves BAR 0 reserved with a stale name, and every `/proc/iomem` read oopses.

The register names in `mmiotrace-summary.txt` come from Linux
`include/sound/acp7x_chip_offset_byte.h`, which is GPL-2.0+: they label the
offsets here and are not to be copied into code. The driver files of this
path (`sound/soc/amd/acp/acp-pci.c`, `acp70.c`, `acp-pdm.c`,
`acp-platform.c`, `acp-legacy-common.c`, `acp-mach-common.c`, `amd.h`) are
`(GPL-2.0-only OR BSD-3-Clause)`.
