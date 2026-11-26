# Review: pr/acp

e41bc0d68ec6 ("snd_acp70: Add a driver for AMD ACP 7.x digital microphones")
02497907dec5 ("snd_acp_pdm: Mute the start burst and remove the DC offset")
b64e7aaeeb55 ("snd_acp_pdm: Set the microphone gain with the recording level")

Serious bugs: none. No new user interface besides the pcm(4) device, so
no syzkaller ID.

Checked: register offsets and constants against Linux sound/soc/amd/ps
(acp63.h, ps-common.c, ps-pdm-dma.c); the pin configuration list, the
DMIC node and _WOV logic, the gain field and default; the page table
ends at 0x1007C, inside the 256 KB BAR (now checked with rman_get_size)
and the PDM page table area; lock order (scp->lock is a leaf under the
channel and device locks, released before chn_intr()); detach
(pcm_unregister() frees the channel before mixer_uninit(), which the
mixer callback survives); the DMA tag resolves to the ACP's PCI RID;
mixer defaults (rec 75) and mute (level 0).

Minor points from the review of the earlier hashes c5c5662ae6ce,
e2ab0ec697d2 and 903cc235641c, all changed in the commit each belongs
to:

1. The first commit's mixer callback ignored the control, so bass or
   treble changed the gain: it now answers igain only.
2. A DMA start timeout was only printed: start now stops the DMA and
   trigger returns EIO.
3. _DSD was read at its first UUID only: the device-properties UUID is
   now found at any position.
4. The reset poll waited for both bits of the done mask; Linux accepts
   either: changed to match.
5. The DC estimate was seeded only right after the mute window: it is
   now seeded from the first sample kept, also after an overrun or a
   mute.
6. A detach path that could not run (re-arming the interrupt after a
   child detach failure): removed; the teardown checks the cookie.

VERDICT: ready
