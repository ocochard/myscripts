# Review: pr/acp

4c9b09e986a6c67b472cb707b1f23615eb8e6bf1 ("snd_acp: Add a driver for AMD ACP 7.x digital microphones")
08cf0b4b16abe61c1fbe8b69c412ef51f888748e ("snd_acp: Mute the start burst and remove the DC offset")
c9343aaddf92e4cbc9d987aca8bd7ad02ac3d9e9 ("snd_acp: Set the microphone gain with the recording level")

POSTCR-c9343aaddf92e4cbc9d987aca8bd7ad02ac3d9e9-1: mixer rec.mute=1 (and rec level 0) leaves the microphones recording at PDM gain 0 while the mixer reports them muted

## Bugs

POSTCR-c9343aaddf92e4cbc9d987aca8bd7ad02ac3d9e9-1. `mixer rec.mute=1`
goes through libmixer `SOUND_MIXER_WRITE_MUTE` -> `mix_setmutedevs()`
-> `mixer_set(m, SOUND_MIXER_RECLEV, 0, 0)` (mixer.c:254) ->
`acpmix_set(..., 0, 0)` (acp.c:497), which sets `sc->gain = 0`. Gain 0
is 18 dB below the default, not silence: the tutorial's own table
records the 440 Hz tone at -85 dBFS at gain 0. The mixer then shows
`rec` muted while the microphones still deliver audio. The same holds
for `rec.volume=0`, which hdaa(4) turns into an amplifier mute
(hdaa.c:2580, `left == 0` -> `HDAA_AMP_MUTE_LEFT`). The man page
documents 0-24 as "the lowest" gain, but says nothing about mute, and
users and applications that mute the microphone through /dev/mixer
expect silence. Fix: treat `MAX(left, right) == 0` as mute, keep a
`sc->muted` flag under `sc->lock`, and zero the new samples in
`acp_rec_process()` while it is set (bitperfect included). Map 1-100
onto the four gain steps and update snd_acp.4.

## Other comments

- Suspend reuses `running` to mean "restart on resume" (acp.c:689):
  while suspended, `acp_intr()` and `getptr` act as if the DMA were
  running against an ACP that is in reset, and on s2idle in D3. The
  INTx is allocated `RF_SHAREABLE`. Another device's interrupt on that
  line then reads `EXT_INTR_STAT(0)` as 0xffffffff (D3), takes the
  period path and calls `chn_intr()`. `acp_pdm_pos()` returns 0 or ~0,
  `pos` wraps, `acp_rec_process()` rewrites the whole 64 KB ring and
  pcm(4) gets a garbage pointer. This is not reachable on the tested
  laptop: in the Linux trace the ACP has IOAPIC pin 13 to itself.
  Keep `running` false while suspended and add a separate
  restart-on-resume flag, or use the MSI the device offers ("MSI:
  Count=1/1" in lspci-vvv.txt) and avoid the shared line.
- Idle power: Linux autosuspends the ACP 2 s after use (acp-pci.c
  `pm_runtime_set_autosuspend_delay(..., 2000)`; its suspend is reset
  plus `ZSC_DSP_CTRL=1`). snd_acp keeps the ACP powered, out of reset,
  with `ZSC_DSP_CTRL=0` (acp.c:210) from attach to detach, and devmatch
  loads it on every ACP 7.x laptop. This is not measured. Compare RAPL
  idle with and without the module, or run `acp_hw_fini()` while no
  channel is open.
- Commit 1 message: "devmatch(8) loads the module on machines with an
  ACP 7.x". 1022:15e2 is the ACP ID since Raven: Linux raven/, renoir/,
  vangogh/, yc/, ps/ and acp7x/ all bind 0x15E2. devmatch therefore
  loads snd_acp on every Ryzen machine with an ACP, and probe rejects
  it there because of the revision. Say so.
- `acp_pdm_stop()` disables PDM and DMA only when the RUNNING bit (bit
  1) is set (acp.c:302). After a start whose poll timed out ("PDM DMA
  did not start"), stop leaves `PDM_ENABLE`/`DMA_ENABLE` at 1. A DMA
  that starts late then keeps writing into the ring, and on detach
  `pcm_unregister()` frees that ring before `acp_hw_fini()` resets the
  ACP. Test the enable bit, or write 0 unconditionally. Both polls
  wait 500 us; Linux acp-pdm.c uses `PDM_TIMEOUT` 1000 us.
- Still open from the earlier round: `acp_intr()` drops `sc->lock`
  before `chn_intr()`, and `pcm_unregister()` -> `chn_kill()` frees the
  channel while the handler is still installed. `pcm_unregister()`
  always returns 0, so detach can clear the PDM source in
  `EXT_INTR_CNTL(0)` and `bus_teardown_intr()` first. Resume still
  restarts the hardware pointer at 0 while pcm(4) keeps `b->hp`, which
  re-delivers up to 64 KB of old audio once.
- Still open: `pcm_addchan()`'s return value is ignored. If
  `sndbuf_alloc()` fails (64 KB contiguous, `BUS_DMA_NOWAIT`, likely
  on a late kldload), a pcm device with no channel is registered.
  The `pcm_register()` failure path frees `sc` under a live mixer and
  channel; call `pcm_unregister()` there.
- A gain change during a recording steps the DC estimate. The 1024
  sample average needs about 21 ms to follow, which can click. Minor.
- `mix_setrecdevs(SOUND_MASK_RECLEV)` makes "rec" its own recording
  source. It works, but `SOUND_MASK_MIC` as the source with RECLEV as
  the level matches the other drivers. Cosmetic.

## Checks

- Locking: pcm(4) calls `trigger` and `getptr` under `CHN_LOCK`.
  `setblocksize` runs with the channel unlocked (chn_resizebuf drops it
  around `CHANNEL_SETBLOCKSIZE`), which is required, because
  `sndbuf_resize()` takes `CHN_LOCK` itself. `mixer_set` runs under the
  primary mixer lock `&d->lock`. Lock order: `d->lock` -> `sc->lock`
  and `CHN_LOCK` -> `sc->lock`. `acp_intr()` releases `sc->lock`
  before `chn_intr()`. No cycle and no sleep under a mutex: the only
  waits are `DELAY` polls.
- In-place processing: getptr is called only from `chn_dmaupdate()`
  (rdintr, and abort, where `CHN_STARTED` is false so the driver is not
  called). `chn_rdfeed()` consumes everything up to the pointer in the
  same `CHN_LOCK` hold. mmap maps bufsoft. pcm(4) never reads a region
  while it is being processed.
- DMA/ATU: the tag is 4 KB aligned, 1 segment, below 4 GB, 64 KB.
  `bufsize` is 64 KB for every block size (64 KB / blksz * blksz). That
  gives 16 PTEs at 0x16000-0x1607f, matching the Linux trace and
  config_acp_dma (scratch 0x10000 + DMIC 0x6000).
- Bounds: BAR0 is 256 KB (lspci-vvv.txt). The highest access is
  0x1607c + 4 = 0x16080 < 0x40000. The driver does not check
  `rman_get_size()`.
- Linux claims checked against ~/linux 3b5f4b83c4ab: the PS PDM driver
  saves the byte count at START (ps-pdm-dma.c:312), as `start_pos`
  does. The gain is `ACP_WOV_GAIN_CONTROL` GENMASK(4,3) from
  `pdm_gain` (default 3) in ps/, yc/ and renoir/. The acp/ driver ORs
  0x18. Soft reset, PGFSM, the interrupt mask and the timeouts match
  acp-legacy-common.c.
- style(9): clang-format22 diffs are the usual false positives of that
  config. Real nits: a double blank line after `#include <mixer_if.h>`
  (acp.c:51-52), and the tree mostly writes `#include "mixer_if.h"`
  (17 against 6). No line over 80 columns, no trailing whitespace.
- Non-ASCII: none in the diff.
- GPL: no copied text. Register values come from the dual-licensed
  sound/soc/amd/acp/. The gain field position is a hardware fact,
  measured in the tutorial.
- Datasheet: none public. The header cites the register trace and the
  dual-licensed driver.
- Commit messages: subjects are 57, 54 and 57 characters (over 50; no
  obvious shorter wording). Bodies are at most 72 columns. `Reviewed
  by:` and `Pull Request:` tags are present.
- Build glue: `device snd_acp` is missing from sys/amd64/conf/NOTES, so
  LINT does not build it. snd_acp.4 is installed on every arch; use
  `${_snd_acp.4}` in the amd64 block of share/man/man4/Makefile.
  `.Dd` is still November 16, although commit 3 changed the page.
  `mandoc -Tlint`: clean.
- Tutorial: ~/myscripts/FreeBSD/docs/snd_acp_dmic.md is present, and
  snd_acp_dmic.patch matches the three commits line for line. The
  header still cites two commits (4a48d48141f8, 228ca612790e) instead
  of 4c9b09e986a6, 08cf0b4b16ab and c9343aaddf92. Section 3 "What it
  does not do: no gain control (no mixer)" contradicts commit 3.

VERDICT: ready

Resolved 2026-11-24: all points fixed in the commit each belongs to (a09391de8e13, 568f24ff96b9, a7297cefc587); mute verified all-zero, suspend/resume, detach cycles, idle power unchanged (24.0 W both). Kept: rec as its own source, ACP powered while idle.
