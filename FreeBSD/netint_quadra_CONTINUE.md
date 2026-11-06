# NETINT Quadra on FreeBSD: handoff

Read `netint_quadra.md` for concepts. This file = state + next actions. Updated 2026-11-06.

**Local-only data:** the raw captures (`netint_quadra_captures/`: traces, identify dumps, results logs, golden hashes) and the helper tools (`netint_quadra_tools/`) are not in git; they stay on the author's Mac. Paths to them below refer to that local tree. The libxcoder port and the firmware upgrade tool are in the `freebsd` branch of https://github.com/ocochard/netint_libxcoder.

## State: Ubuntu side done, FreeBSD attach works

Host: `ssh elitedesk-ubuntu` (HP EliteDesk, Ubuntu 26.04, kernel 7.0). Card `QuadraT1U-EP3`, PCI `0a:00.0`, `1d82:0401`, `/dev/nvme1`, serial `Q1U23AA11DC074-0108`.

- Firmware upgraded `31054rc6` (FW API 5) -> `5906tFr1` (v5.9.0_RC1, loader 4.10.06) with `quadra_auto_upgrade.sh`. Host rebooted twice (first flash, then a same-version re-flash for tracing). `ni_rsrc_list`: `F/W & S/W compatibility: yes`.
- libxcoder 5.9.0 (from the download package, `~/netint/Quadra_SW_V5.9.0_RC1/libxcoder`) installed in `/usr/local`. Public GitHub libxcoder tags all need FW API 6, so the old firmware was unusable.
- NETINT ffmpeg fork tag `v5.9.0` (FFmpeg 7.1) built in `~/netint/netint_ffmpeg` (`--enable-gpl --enable-ni_quadra --disable-ni_logan`).
- Encoding verified: H.264 501 frames (~17x realtime), H.265 300 frames, 0 errors. Decode and hw transcode traced too.
- Needs `sudo` (`/dev/nvme1` root-only, `/dev/nvme1n1` root:disk). Not fixed.
- PCIe link 8 GT/s (card supports 16): slot/board limit.
- Download package: `~/Downloads/Quadra_V5.9.0` on the Mac (firmware, libxcoder, FFmpeg patches, PDFs). Copy on host: `~/netint/Quadra_{FW,SW}_V5.9.0_RC1`.

## FreeBSD bring-up (done 2026-11-06)

Host `elitedesk-fbsd` (192.168.100.24, FreeBSD 16.0-CURRENT, dual boot with Ubuntu on the same disk).
- Stock settings: panic + corrupted video + dump failure. Cause: card BARs allocated at `0xd0000000`, inside the iGPU BAR. Fix: `hw.pci.host_mem_start="0xd0d70000"` in `/boot/loader.conf`. Details: `netint_quadra.md` 7.1b.
- Now `nvme1` (QuadraT1U-EP3, FW 5906tFr1) attaches at boot as `nda1`; `nvmecontrol identify nvme1` OK. Identify output saved in `netint_quadra_captures/freebsd_fw5906tFr1/`.
- Netdump to `bigone` (192.168.100.2) configured; debugger_on_panic=0. `~/freebsd-src` cloned on the host.
- `nvmecontrol identify` says firmware download is Not Supported (oacs=0x2), so `nvmecontrol firmware` will likely refuse: firmware upgrade needs the passthrough tool.

## Findings that shape the port

1. The card is a standard NVMe device. Linux uses the stock `nvme` driver; there is no NETINT kernel driver for video (`/dev/netint` is only for optional GPU P2P).
2. Data path = ordinary NVMe Read/Write whose **SLBA encodes the request** (`ni_nvme.h` macros). Vendor admin opcodes 0xD0-0xDD are only used to compute the SLBA. Admin queue is nearly silent (Identify only).
3. Only `ni_nvme.c` and a few helpers are OS-specific. Port the user-space layer; kernel module only if `nvme(4)` blocks something.
4. Firmware upgrade (measured) = `nvme reset`, `nvme fw-download -x 4096` (1397 x opcode 0x11), then admin vendor opcode `0xC7` (burn to NOR, 180 s timeout). **No Firmware Commit (0x10).** Cold upgrade needs a power cycle. Details in `netint_quadra.md` 6.4.
5. udev/udisks probe the fake disk (SLBA 0, 1, 3, ..., end of disk). Expect `nda(4)`/`geom(4)` to do the same on FreeBSD.
6. Variant query opcode 0xC2 is rejected by old firmware; the script then picks the plain `-Quadra.bin`.
7. Identify data changed with the firmware: `frmw` 0x5 -> 0x4 (slot 1 no longer read-only), `oncs` 0x18 -> 0x58. FreeBSD must be compared against the 5.9 baseline (`fw_5906tFr1/identify/`), not the old one.

## Artifacts (all under `FreeBSD/`)

| Path | What |
|---|---|
| `netint_quadra.md` | Student-level doc: concepts, protocol, firmware upgrade, FreeBSD plan |
| `netint_quadra_captures/fw_31054rc6/` | Old-firmware identify, logs, features, upgrade log |
| `netint_quadra_captures/fw_5906tFr1/reflash/` | Firmware upgrade traces (strace, kernel nvme trace, admin command list) |
| `netint_quadra_captures/fw_5906tFr1/scenarios/` | 02..07 encode/decode/transcode traces + `decoded.txt` |
| `netint_quadra_captures/decode_slba.py` | SLBA -> macro-name decoder, parses `ni_nvme.h` |
| `netint_quadra_captures/capture.sh` | Trace runner (ftrace nvme events + strace) |

Not committed to git. Large: ~4 MB of traces.

## Known gaps

- No real error-case capture (scenario 07 just scaled to 64x64).
- No scaler/AI/two-session captures; no output MD5 per scenario (only two full clips in `outputs.md5`).
- Several FreeBSD API names in the doc are marked "to verify" (`NVME_PASSTHROUGH_CMD`, `struct nvme_pt_command`, `nvmecontrol firmware` flags).
- Libxcoder/NETINT license not checked for redistribution of a port.

## Plan

1. **Keep Ubuntu on this host** (dual boot). It is the recovery path for a failed FreeBSD flash and the source of golden traces.
2. Install FreeBSD in a second partition. Check `pciconf -lv`, `nvmecontrol devlist`, `nvmecontrol identify nvme1`; diff `id-ctrl` against `fw_5906tFr1/` data (baseline: `fw_5906tFr1/identify/id-ctrl.bin`).
3. Verify the passthrough API in `/usr/include/dev/nvme/nvme.h`; write a tiny C tool: Identify, then a raw Read/Write at a given SLBA.
4. Port `ni_rsrc_*` shared memory (`shm_open`), then `ni_nvme.c` (passthrough + AIO replacement, table in `netint_quadra.md` 7.2). `ni_rsrc_list` must match Ubuntu output.
5. Replay: open/close session, then 1-frame encode. Decode FreeBSD's kernel trace (DTrace `nvme` provider or driver debug) with `decode_slba.py` and compare with scenario 02. Then 100-frame encode: output MD5 must equal Ubuntu.
6. Firmware upgrade on FreeBSD (required, `netint_quadra.md` 6.4): `nvmecontrol firmware` for the download steps (check it does not send Commit), small tool for vendor `0xC7`, POSIX `sh` wrapper. Test first with a same-version image, then power cycle.
7. Build NETINT ffmpeg on FreeBSD (`gmake`), run regression clips.
8. Decide upstreaming (libxcoder PR) or a ports entry.

## Command trace comparison (done 2026-11-06)

FreeBSD `ni_xcoder_encode` 1-frame trace decodes fully and matches the Ubuntu session lifecycle; only poll counts, session id and the upload chunk size differ. Details: `netint_quadra.md` 7.9. Tool: `netint_quadra_tools/kdump2cmds.py`.

## FFmpeg on FreeBSD (done 2026-11-06)

NETINT FFmpeg v5.9.0 builds and runs on `elitedesk-fbsd`; H.264 and H.265 encodes are byte-identical to Ubuntu (same md5), hw decode and parallel sessions work. Details: `netint_quadra.md` 7.10.

## AI engine / POSIX AIO (done and pushed 2026-11-06)

Linux AIO ported to POSIX `aio(4)` (`lio_listio`). The `freebsd` branch of the fork (`~/netint_libxcoder` on `elitedesk-fbsd`, remote `ocochard/netint_libxcoder`) now has two commits on top of v5.9.0: `c8ab10b` (the port, message reworded) and `bc060d3` (AIO), force-pushed with `--force-with-lease`. Self test passes; AI filter `ni_quadra_hvsplus` works. Details and limits: `netint_quadra.md` 7.11.

## Firmware upgrade tool (done 2026-11-06)

`freebsd/tools/nvmefw.c` and `quadra_fw_upgrade.sh` in the `freebsd` branch of the fork (commit `34db737`, pushed); details in `netint_quadra.md` 7.13. A same-version flash was run on the card from FreeBSD: all statuses OK, burn 70 s, card healthy after reboot, regression hashes unchanged. Limit: a real version change was not tested (only 5.9.0 images here), and the tool does not read the flash back.

## AI filters and GStreamer (done 2026-11-06)

FFmpeg `ni_quadra_ai_pre` (3 models), `roi` and `bg` work (`bg` needs `bg_img=` or `use_default_bg=1`, otherwise segfault; it logs `ni_decoder_session_copy_internal(): passed parameters are null`): `netint_quadra_captures/freebsd_fw5906tFr1/ai-filter-results.txt`, `netint_quadra.md` 7.11. The NETINT GStreamer plugin builds unmodified against pkg GStreamer 1.28.8 and its pipelines and demos work: `gstreamer-results.txt` in the same directory, `netint_quadra.md` 7.14. The NETINT GStreamer framework patch (tiled `NI_QUAD_*` video formats) is not needed for these and not tested.

## Next action

1. Boot Ubuntu: compare outputs/hashes for the decode and scaler tests; check the scaler demo's duplicate last frame, the `ni_quadra_bg` error message and the `demo_ni_ppu` 2-frame loss on parameter change.
2. Untested: `ni_quadra_bgr`, GStreamer `bg`/`bgr`/`overlay`, ROI output vs plain encode quality, patched GStreamer, a real firmware version change (brick risk, needs explicit go).
