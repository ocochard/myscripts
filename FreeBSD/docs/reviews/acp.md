# Review: pr/acp

436573bee3b005d64b88218efd1828b243f9f1c2 ("snd_acp: Add a driver for AMD ACP 7.x digital microphones")
1a9b5416704beceaefd5d623f395abb18db6a6b6 ("snd_acp: Mute the start burst and remove the DC offset")
4e904f596bbefea8a4b2fdf17fd7ebd9e22ca9dc ("snd_acp: Declare the PCI ID for devmatch(8)")

POSTCR-436573bee3b005d64b88218efd1828b243f9f1c2-1: ACP error interrupt enabled in EXT_INTR_CNTL(1) but acp_intr never acks EXT_INTR_STAT(1) bit 29, so any ACP error leaves the shared INTx line asserted (interrupt storm)

## Bugs

POSTCR-...-1. acp_hw_init() sets ACP_EXT_INTR_ENB=1 and ORs
ACP_EXT_INTR_ERROR (0x20000000) into ACP_EXT_INTR_CNTL(1). acp_intr()
only tests and clears ACP_EXT_INTR_PDM_DMA in STAT(0) and STAT(1); the
error status bit is never written back. Once the ACP raises an error,
the level-triggered INTx line (rid 0, RF_SHAREABLE) stays asserted:
the ithread reruns continuously and every device sharing the IRQ
suffers. hw_init also enables the source before snd_setup_intr() and
without clearing STAT(1) first, so a stale error left by firmware or a
previous OS asserts the line at attach and on every resume. Linux
ps/pci-ps.c acks ACP_ERROR_IRQ in its handler; the acp/ common driver
does not, but there IRQ_NONE lets the "nobody cared" logic disable the
line. Fix: either do not enable the error source (nothing consumes it),
or ack it in acp_intr (write ACP_EXT_INTR_ERROR to STAT(1)), and clear
STAT(1) before enabling in hw_init.

## Other comments

- Detach/intr window: acp_intr reads sc->rch.running after dropping
  sc->lock, then calls chn_intr(). pcm_unregister() aborts and then
  frees the channel (chn_killall) while the handler is still installed
  (bus_teardown_intr comes later in acp_release). An ithread preempted
  between the test and chn_intr() can touch a freed pcm_channel. The
  window is tiny and hdaa has the same shape; reading `running` under
  the lock narrows it, tearing down the interrupt before
  pcm_unregister() closes it (pcm_unregister() cannot fail).
- pcm_register() failure path: goto bad_hw frees sc and destroys
  sc->dmat while the channel created by pcm_addchan() still owns a
  sndbuf on that tag (bus_dma_tag_destroy returns EBUSY, map/buffer
  leak) and the snddev lock/sx from pcm_init() are never destroyed.
  Only reachable when dsp_make_dev() fails. pcm_addchan()'s return
  value is ignored: a failed sndbuf_alloc() registers a pcm device with
  no channel.
- Resume while recording: acp_pdm_start() resets start_pos and hpos, so
  the hw pointer jumps back to ring offset 0. pcm(4) reads the backward
  step as a forward delta and delivers up to one ring (64 KB, ~170 ms)
  of already-delivered samples once. Untested per the tutorial.
- Linux stops PDM by disabling DMA first, then PDM, then writing
  ACP_WOV_PDM_FIFO_FLUSH; acp_pdm_stop() disables PDM before DMA and
  never flushes the FIFO. The 100 ms mute hides stale FIFO data at the
  next start, so no visible effect; worth matching the known sequence.
- acp_pdm_start() sets running=true even when the DMA running bit never
  appears; the reader then sleeps until pcm(4)'s timeout instead of
  getting an error from trigger.
- acp_has_dmic(): absence of _WOV counts as "microphones present";
  Linux additionally requires the "acp-audio-device-type" _DSD property
  on the PDM child. With MODULE_PNP_INFO now loading the module on every
  ACP 7.x, a SoundWire-only design whose pin config is in the list
  would attach a dead recording device. Not a bug on the tested laptop.
- Attach on a machine without microphones still powers on and resets
  the ACP before deciding, then leaves it in reset. Harmless today.

## Checks

- style(9): clang-format22 with upstream .clang-format on acp.c. All
  diffs are the usual false positives of that config (tab after
  #define, struct member alignment, KOBJMETHOD/DEVMETHOD tables,
  4-space continuation, include sorting). Real deviation: several
  `case` labels on one line (`case 4: case 5: ...`, `case 0x70: ...`
  in acp_has_dmic/acp_probe); one per line is the tree norm.
- Non-ASCII: none in `git diff upstream/main pr/acp`.
- GPL: compared with ~/linux (3b5f4b83c4ab, 2026-07-28). Every value
  matches the dual-licensed (GPL-2.0-only OR BSD-3-Clause)
  sound/soc/amd/acp/ driver: PGFSM 0xffffffff/mask 3/in-progress 1
  (acp/amd.h; ps/ uses 0x1f/0xff, not used here), SOFT_RST_DONE
  0x00010001, pin config list = union of check_acp70_config(),
  PDM PTE 0x6000, ATU groups 1/2/5 with GRP2_OFFSET 0x4000
  (acp-platform.c), ring window 0x4c00000 (ACP7x_DMIC_MEM_WINDOW_START),
  MISC_CTRL |= 0x18, CLK 7, DEC_64 2, error mask in CNTL(1)
  (acp-legacy-common.c). acp_hw_init/acp_reset/power-on follow the
  order of acp_init()/acp70_init() as minimal register sequences; no
  identifiers or comments copied (driver names ACP_PDM_* where Linux
  has ACP_WOV_*), position read uses a hi/lo/hi retry Linux lacks, the
  mute and DC filter have no Linux counterpart. Nothing from the
  GPL-only ps/ or acp7x/ trees found (ps/ gain field and PME_EN not
  used). No GPL copying.
- Datasheet: none public; header comment states register trace plus
  the dual-licensed AMD driver. Acceptable.
- Commit messages: subjects in `snd_acp: Imperative` form; 436573bee3b0
  is 57 chars and 1a9b5416704b 54 (over 50, acceptable if no shorter
  wording). 436573bee3b0 body line 1 is 73 columns ("...the ACP's PDM"),
  over 72: rewrap. No tags, none needed. 4e904f596bbe body is a
  sentence fragment ("So that the module loads..."); also small enough
  to fold into the first commit.
- Build: sys/modules/sound/driver/acp/Makefile lists opt_acpi.h but not
  acpi_if.h, which dev/acpica/acpivar.h includes unconditionally. Works
  under buildkernel (-I${KERNBUILDDIR}), fails for a standalone
  `make` in the module directory. Every other acpivar.h user in
  sys/modules lists acpi_if.h. Add it.
- Man page: `mandoc -Tlint` on the extracted snd_acp.4: no output.
- Tutorial: ~/myscripts/FreeBSD/docs/snd_acp_dmic.md present. Code is
  identical to the final commits (acp.c, man page, Makefiles unchanged
  vs eac669d546ee), so line numbers hold, but it cites the pre-rebase
  hashes 6ba38c3ca4a6/e4c888c47347/eac669d546ee and base d546356523f3;
  update to 436573bee3b0/1a9b5416704b/4e904f596bbe on 6dc19a71f70c.

VERDICT: ready

Resolved 2026-11-21: the ACP error source is masked in acp_hw_init() and stale status cleared before enabling; acp_intr() reads running under the lock; acpi_if.h added to the module Makefile; one case label per line; the devmatch commit folded into the driver commit, message rewrapped; now 4a48d48141f8 228ca612790e. Recording tested on the zbook (400 interrupts per 4.27 s, 0 idle).
