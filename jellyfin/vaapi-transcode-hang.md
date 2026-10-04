# VA-API transcode hang: `-hwaccel vaapi` + `h264_vaapi` deadlocks

**Host:** nas (FreeBSD 16.0-CURRENT, Ryzen 7 PRO 8845HS / Radeon 780M, gfx1103, VCN 4.0.2)
**Found:** 2026-08-24, after two ffmpeg processes had been spinning since 2026-08-23 18:41
**Status:** root cause isolated, workaround verified, upstream cause not yet identified

---

## Symptom

`dev.amdtemp.0.core0.sensor0` reported 97°C on an otherwise idle NAS.

Two jellyfin ffmpeg processes were each pinning a core:

```
28946 jellyfin  99.07% ffmpeg  ELAPSED 13:22:37  TIME 802:31
28989 jellyfin  99.02% ffmpeg  ELAPSED 13:20:23  TIME 800:17
load averages: 2.00, 2.01, 2.01
```

Both transcoding the same 81-minute file for 13.4 hours. Neither had encoded a single frame:

```
frame=    0 fps=0.0 q=0.0 size=N/A time=N/A bitrate=N/A speed=N/A elapsed=13:24:07.92
```

Output segments existed but were 0 bytes:

```
-rw-r--r--  1 jellyfin jellyfin 0 Aug 23 18:41 ef0726e70634c603ed1bf8c1591020eb-1.mp4
-rw-r--r--  1 jellyfin jellyfin 0 Aug 23 18:43 52802ace2ef28d779a3f7d09c64d5d7c-1.mp4
```

Killing both dropped the die temperature from 97°C to 50.2°C in under 5 seconds.

### Hang signature

Consistent across every reproduction:

- 99% CPU on one core, state `uwait` (userspace wait — spinning in ffmpeg's own loop, not blocked in a kernel driver call)
- `frame=0` forever, no output ever written
- **Ignores SIGTERM.** `timeout` does not work. Requires `kill -9`
- ffmpeg initialises cleanly first — no error, no exit code, the encoder reports ready and then never produces a frame

Because SIGTERM is ignored, `timeout N` wrappers do not protect you. Every test run needs manual `pgrep -lf ffmpeg` cleanup afterwards.

---

## Root cause

**A three-thread deadlock on radeonsi's single per-screen mutex**, confirmed by gdb backtrace on a live wedged process (2026-08-24, PID 61856):

```
Thread 26  enc0:0:h264_vaa   vaRenderPicture  -> RUNNING inside radeonsi, holds the lock
Thread 27  vf#0:0            vaUnmapBuffer    -> BLOCKED on mutex 0x3e98a8c97e08
Thread 28  dec0:0:h264       vaSyncSurface    -> BLOCKED on mutex 0x3e98a8c97e08
```

Both blocked threads wait on the **same mutex address**. The encoder thread never releases it — it spins at 99% CPU beneath `vaRenderPicture()` inside `radeonsi_drv_video.so`, which is the source of the heat. The decoder needs the lock for `vaSyncSurface()`, the filter for `vaUnmapBuffer()`; neither ever acquires it.

This is why separate processes work (test 6): each process gets its own radeonsi screen and therefore its own mutex, so there is no shared lock to contend on.

`procstat -kk` shows the same picture without gdb — the three pipeline threads sit in `do_lock_umutex` (real mutex contention) while all other threads sit in `__umtx_op_wait_uint_private` (ordinary condvar idle).

### Trigger: the full filter chain, NOT `-hwaccel vaapi` alone

An earlier revision of this document claimed `-hwaccel vaapi` was the trigger. **That was wrong** — test 5 removed the flag *and* simplified the filter chain simultaneously, and the wrong variable got the credit. Re-tested 2026-08-24:

| Filter chain (all with `-hwaccel vaapi` + `h264_vaapi`) | Result |
|---|---|
| `format=nv12,hwupload` | works, 13x |
| `scale=...,format=nv12,hwupload` | works, 240 frames |
| `setparams=...,format=nv12,hwupload` | works, 240 frames |
| `setparams=...,scale=...,format=nv12,hwupload` (Jellyfin's) | **hangs** |

Each filter passes alone. Only the full `setparams` + `scale` combination deadlocks — a longer chain means more concurrent VA-API surface operations, which widens the window for the lock cycle.

Bisection, all against the same file with the same encoder:

| # | Configuration | `-hwaccel vaapi` | `h264_vaapi` | Result |
|---|---|---|---|---|
| 1 | Decode only, real file | yes | — | works, 12.2x |
| 2 | Encode only, synthetic source | — | yes | works, 18x |
| 3 | Full Jellyfin chain | yes | yes | **hangs at frame 0** |
| 4 | Chain minus `derive_device=vaapi` | yes | yes | **hangs at frame 0** |
| 5 | Software decode + hardware encode, real file | **no** | yes | works, **29.2x** |
| 6 | HW decode \| HW encode, **two piped processes** | yes | yes | works, 20.3x / 20.6x |
| 7 | HW decode + HW encode, **simple** filter chain | yes | yes | works, 13x |

Test 4 clears `hwupload=derive_device=vaapi`, which was the leading suspect — the hang is identical without it.

Test 5 changed two variables at once (dropped `-hwaccel vaapi` AND simplified the filter chain); test 7 shows the filter chain was the relevant one. See "Trigger" below.

### Cross-host control: ser6 (Radeon 680M) does NOT reproduce

Both hosts were brought to an identical software stack on 2026-08-24, then tested with the **bit-identical**
Ice Age file (md5 `93eabcca72670e84ed1cb3c97542f1cd` on both):

| | nas | ser6 |
|---|---|---|
| GPU | 780M / gfx1103 / VCN 4.0.2 (Phoenix) | 680M / gfx1035 / VCN 3.x (Rembrandt) |
| FreeBSD | 16.0-CURRENT | 16.0-CURRENT |
| ffmpeg | 8.1.2 | 8.1.2 |
| mesa | 26.2.1 | 26.2.1 |
| libva | 2.24.1 | 2.24.1 |
| Jellyfin chain, **real file** | **hangs** | **hangs** |
| Jellyfin chain, synthetic file | — | works, 10.4x |

**Both GPUs reproduce it.** ser6 shows the identical three-thread signature:

```
enc0:0:h264_vaa   <running>          99.1% CPU
vf#0:0            do_lock_umutex     BLOCKED
dec0:0:h264       do_lock_umutex     BLOCKED
```

**mesa 26.2.1 does NOT fix the hang** (verified on nas after upgrading both mesa-dri and mesa-libs). Not a version
regression, and **not GPU-generation-specific** — it affects both VCN 3.x and VCN 4.0.2.

### Correction: an earlier synthetic-file "control" was invalid

A previous revision concluded the bug was specific to Phoenix / gfx1103 / VCN 4.0.2, because ser6 passed while nas
hung. That comparison was wrong: ser6 was tested with a synthetic `libx264 -preset ultrafast` file, which is not
equivalent to the real input:

| | real (Ice Age) | synthetic (ultrafast) |
|---|---|---|
| profile | **High** | Constrained Baseline |
| level | **4.1** | 3.1 |
| has_b_frames | **2** | 0 |
| audio | ac3 5.1 | none |

The synthetic file never exercised the code path that deadlocks. Re-tested with the real file, ser6 hangs too.

### Bisection: everything structural ruled out, minimal reproducer NOT found

All tests on ser6 (680M, mesa 26.2.1), Jellyfin filter chain, `-t 10`:

**Derived from the real file — every variant hangs:**

| Input | Result |
|---|---|
| real Ice Age, 4.7 GB, video+audio | **HUNGS** |
| video-only, stream copy (ac3 dropped), 90 MB | **HANGS** |
| video-only, `-map_metadata -1 -map_chapters -1`, 90 MB | **HANGS** |
| first 120 s, video+audio, 96 MB | **HANGS** |
| first 30 s, stream copy, 42 MB | **HANGS** |
| first 5 s, stream copy, 11 MB | **HANGS** |
| **re-encoded** through libx264 (fresh bitstream), 4.6 MB | **HANGS** |

**Synthetic `testsrc` files — every variant passes:**

| Input | Result |
|---|---|
| High/4.1, B-frames=2 | works (5/5 runs — not racy) |
| High/4.1, B-frames=0 | works |
| High/4.1, B-frames=2, recurring forced IDR every 0.5 s | works |
| Constrained Baseline (original bad control) | works |

**Ruled out:** audio stream, Matroska metadata/chapters, file size (11 MB still hangs), original bitstream
quirks (re-encode still hangs), B-frames, IDR/scene-change frequency, GPU generation, mesa version, and
raciness.

**The confounder:** `synth-bframes.mkv` (passes) and `p-reencoded.mkv` (hangs) are **identical in every
property ffprobe reports** — same 1280x688, High, level 4.1, has_b_frames=2, yuv420p, progressive, all color
tags `unknown`. The only differences are the actual picture content and the framerate representation
(`2997/125` vs `13978/583`).

Since re-encoding real content through libx264 still hangs while synthetic content never does, the trigger
appears to be **content-dependent decode behaviour** rather than any container or stream-configuration
property. Framerate representation is untested and is the obvious next probe.

**A minimal, shareable reproducer has NOT been found.** Any upstream report must currently attach a clip of
real-world video; the 11 MB 5-second stream-copy clip (`p-5s.mkv`) is the smallest confirmed reproducer.

### Trap: `pkg upgrade` silently breaks VA-API on both hosts

Hit on ser6, then again on nas. A plain `pkg upgrade` moves **mesa-libs** to the FreeBSD-ports version but leaves
**mesa-dri** pinned at the older `home-default` poudriere version (that repo has higher priority). The
`radeonsi_drv_video.so` symlink then points at a `libgallium-<old>.so` that the upgrade just deleted:

```
mesa-dri-26.1.5_1                                     <-- pinned, stale
mesa-libs-26.2.1                                      <-- upgraded
radeonsi_drv_video.so -> ../libgallium-26.1.5.so      <-- DANGLING
/usr/local/lib/libgallium-26.2.1.so                   <-- the only one on disk
```

Symptom: `vainfo` reports `va_openDriver() returns -1`, and Jellyfin loses hardware transcode entirely. `ldd` on the
ICD looks clean because it does not follow the dangling symlink.

Fix — force both from the same repo:

```bash
sudo pkg install -f -r FreeBSD-ports mesa-dri mesa-libs
```

Check after every `pkg upgrade` that touches mesa:

```bash
pkg info -x '^mesa'          # versions must match
ls -la /usr/local/lib/dri/radeonsi_drv_video.so   # target must exist
```

This is the pkg-skew failure mode in the user's `project_freebsd_vulkan_pkg_skew` note, now confirmed to hit VA-API
as well as Vulkan.

Test 6 is decisive. The *same* hardware decode and hardware encode, running **concurrently on the same VCN**, both complete at full speed when split across two processes connected by a pipe:

```
decoder (HW VAAPI):  frame=240  speed=20.3x  exit 0
encoder (HW VAAPI):  frame=240  speed=20.6x  exit 0
```

### The fault is a userspace lock cycle, not hardware

| Signal | What it rules out |
|---|---|
| `dmesg` completely silent — no ring timeout, no GPU reset, across all 6 runs | hardware hang, VCN firmware fault, kernel driver |
| Process state `uwait` (userspace wait, not kernel block) | blocking in a kernel ioctl |
| Two processes decode+encode concurrently at full speed | single-VCN-instance serialization, resource exhaustion |
| One process deadlocks deterministically | anything other than process-local locking |

radeonsi shares a single `pipe_context`/screen lock per device *within a process*. Decode and encode each acquire it and deadlock. Across processes each gets its own screen, so no shared lock exists and both run fine.

This means the GPU is healthy and capable of exactly the workload Jellyfin wants — the bug is purely in per-process userspace state.

### What this is *not*

- **Not a thermal or cooling fault.** 97°C was the correct thermal response to two cores pinned at 4813 MHz boost on a 35-54W mobile APU. Tjmax on Zen 4 mobile is 100°C; the silicon is designed to ride near it under load. The heatsink is fine.
- **Not a broken VA-API install.** Both hardware blocks work in isolation. `vainfo` entrypoints are intact.
- **Not the documented `hwupload` failure** in `jellyfin.md` ("FFmpeg exits with code 234"). That one *exits*. This one hangs silently after successful init — a distinct failure requiring a different diagnostic.
- **Not file-specific.** Reproduced across Ice Age (720p SDR h264) and House of the Dragon S02E02/E03 (2160p HDR/DV x265), with both `-codec:a copy` and aac transcode.
- **Not `derive_device=vaapi`.** Ruled out by test 4.
- **Not power/thermal contention between CPU and iGPU.** No encode work ever happened; there was nothing to contend with.

---

## Workaround

Force software decode, keep hardware encode. The iGPU still does the expensive work at **29.2x realtime**; only decode moves to CPU, which is trivial for 720p h264 on 16 Zen 4 cores.

In **Dashboard → Playback → Transcoding**, uncheck every hardware *decode* codec (H264, HEVC, AV1, VP9…) while leaving:

- Hardware acceleration: **VA-API**
- VA-API device: `/dev/dri/renderD128`
- Hardware *encode* enabled

This makes Jellyfin omit `-hwaccel vaapi` from its command while keeping `-codec:v:0 h264_vaapi`.

Do **not** disable hardware acceleration entirely — encode is where the GPU earns its keep, and encode is not the broken half.

### Verify the workaround took effect

After changing settings, start a playback that requires transcoding and check the generated command:

```sh
grep 'TranscodeManager' /var/db/jellyfin/log/log_$(date +%Y%m%d).log | tail -1
```

It should contain `h264_vaapi` but **not** `-hwaccel vaapi`.

### Caveat

4K HDR/DV sources (House of the Dragon) will decode in software, which is far heavier than 720p. Expect real CPU load on those, though it will complete rather than hang. If 4K playback becomes the common case, revisit.

---

## Collateral findings

### Jellyfin's own reaper mostly works

```
[ERR] MediaBrowser.MediaEncoding.Transcoding.TranscodeManager: FFmpeg exited with code 137
```

Code 137 = SIGKILL. Jellyfin does time out and kill hung transcodes. Two escaped it and ran for 13 hours, so the reaper is not reliable — do not depend on it.

### Client retry storm amplifies the problem

When a transcode hangs, the player seeks backwards hunting for a segment that never appears, spawning a new hung ffmpeg each time. From 22:27 to 22:35 on 2026-08-23, nine sessions were spawned against one file, `-ss` walking backwards 00:24:58 → 00:21:28. Each is another pinned core.

The two survivors from 18:41 and 18:43 were the same pattern: user hit play, nothing happened, user retried.

### LibraryMonitor cannot watch any library path

Unrelated to the hang, but present:

```
[ERR] LibraryMonitor: Error watching path: "/NAS/films"
[ERR] LibraryMonitor: Error watching path: "/NAS/series"
[ERR] LibraryMonitor: Error watching path: "/NAS/audio/musiques"
[ERR] LibraryMonitor: Error watching path: "/NAS/audio/livres"
[ERR] LibraryMonitor: Error watching path: "/NAS/livres/Calibre Library"
[ERR] LibraryMonitor: Error watching path: "/NAS/SD"
```

All six libraries. New media will not be auto-detected; scans must be triggered manually. Needs separate investigation.

---

## Environment at time of diagnosis

```
FreeBSD nas 16.0-CURRENT main-n287760-b72f9bfc4513 (built 2026-07-29)
hw.model: AMD Ryzen 7 PRO 8845HS w/ Radeon 780M Graphics
hw.ncpu: 16
ffmpeg-8.1.2_1,1
mesa-dri-26.1.5_1
libva-2.24.1 / libva-utils-2.24.0
amdgpu.ko + amdgpu_vcn_4_0_2_bin.ko (VCN 4.0.2)
uptime at diagnosis: 25 days
```

---

## Upstream status

Searched 2026-08-24. **No existing report matches this.** The nearest AMD reports are all different failure modes:

- [jellyfin#14911](https://github.com/jellyfin/jellyfin/issues/14911) — Radeon 890M, `frame= 0`, but **exits** with error -22 rather than hanging.
- [jellyfin#10830](https://github.com/jellyfin/jellyfin/issues/10830) — 780M/gfx1103, but caused by LLVM too old to recognise gfx1103. Here the driver initialises fine and both blocks work standalone.
- [jellyfin#9212](https://github.com/jellyfin/jellyfin/issues/9212) — Vega 11 system hang via the Vulkan/libplacebo subtitle path, not used by this command.
- [mesa#12528](https://docs.mesa3d.org/relnotes/26.2.1.html) — "HW accelerated video playback causes VCN timeout", but that produces ring timeouts in dmesg. This produces none.

The Mesa 26.2.1 notes do list active VCN regressions (gpu-screen-recorder VAAPI H.264 corruption since 26.0.0; HEVC P-frame corruption on gfx1033), so the VCN paths are under active churn.

This looks like a genuinely unreported bug. The reproduction here — deterministic, dmesg-clean, with the two-process control proving the hardware is fine — is worth filing on Mesa GitLab against radeonsi.

## Open questions

1. **Exact lock cycle.** Attach a debugger to a wedged process for a backtrace, or run with `-loglevel trace` / `LIBVA_MESSAGING_LEVEL=2` to name the mutex.
2. **Is this FreeBSD-specific?** The same ffmpeg + mesa on **Linux with VCN 4.0.2 hardware** would separate a Mesa/radeonsi bug from a FreeBSD DRM shim bug. This is now the highest-value remaining unknown — Mesa maintainers will ask. Note the control must be VCN 4.0.2; a VCN 3.x Linux box proves nothing, since ser6 already shows VCN 3.x is unaffected on FreeBSD.
3. ~~Did this ever work? Bisect mesa versions.~~ **Answered:** mesa 26.2.1 hangs identically to 26.1.5. Not a version regression.
4. **Does it affect other codec pairs?** Only h264 decode → h264 encode was tested. HEVC decode → h264 encode may behave differently.
5. **Could Jellyfin be made to use two processes?** Test 6 shows the pipeline works split. Not currently expressible in Jellyfin's transcode config, but relevant if reporting there.

---

## Reproduction

See `vaapi-hang-repro.sh` in this directory. It runs the full bisection matrix with automatic cleanup of wedged processes.

```sh
scp jellyfin/vaapi-hang-repro.sh nas:/tmp/
ssh nas 'sudo sh /tmp/vaapi-hang-repro.sh'
```
