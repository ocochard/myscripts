# HDR transcodes are not tone mapped: washed out SDR output

**Host:** nas (FreeBSD 16.0-CURRENT, Ryzen 7 PRO 8845HS / Radeon 780M, gfx1103)
**Found:** 2026-09-24, reported by alicia on Fire TV Stick
**Status:** SOLVED 2026-09-25. Working recipe below. Everything after the
recipe is the diagnosis that led there, kept because several parts are
non-obvious and two of the bugs are upstream issues worth reporting.

## Root cause, in one paragraph

Jellyfin does AMD VAAPI HDR tone mapping with **libplacebo**, not OpenCL. But
`EncodingHelper.GetVaapiVidFilterChain()` has an early-exit guard *before* it
ever selects the AMD branch:

    if ((isSwDecoder && isSwEncoder)
        || !isVaapiOclSupported                        // needs a FULL OpenCL stack
        || !_mediaEncoder.SupportsFilter("alphasrc"))  // a jellyfin-ffmpeg-only filter
    {
        ... return the software chain + hwupload=derive_device=vaapi
    }

Stock FreeBSD ffmpeg has neither OpenCL nor `alphasrc`, so the guard always
fired and the untone mapped software chain was emitted. OpenCL is required
only as a *gate*; the actual tone mapping is still done by libplacebo.

## Working recipe

Steps 2 to 6 are required; miss one and it silently falls back to washed out
output, which is exactly the failure mode that makes this hard to debug.
Step 1 is listed first for historical reasons but is almost certainly optional
— read it before spending time on it.

### 1. libplacebo from git master — NOT mandatory

**This step is probably unnecessary. Skip it unless something below fails.**

The libplacebo API 365 bug documented later in this note
("libplacebo filter broken on all AMD GPUs") applies to **stock ffmpeg 9.0.1**,
whose `vf_libplacebo.c` carries a `#if PL_API_VER >= 365` guard that returns
EINVAL when `queue_flags != 0`. jellyfin-ffmpeg is based on an older ffmpeg:
its `vf_libplacebo.c` has **no `queue_flags` handling and no 365 guard** (its
highest check is `PL_API_VER >= 351`), and its configure only requires
`libplacebo >= 5.229.0`. So the released `graphics/libplacebo` 7.360.1 should
be sufficient for the Jellyfin path.

Not verified directly: both hosts here run the 7.372 snapshot, and testing the
claim would mean downgrading libplacebo and rebuilding everything that links
it. The conclusion comes from reading jellyfin-ffmpeg's source, not from a
test.

If you do want the snapshot anyway (it is what nas and ser6 actually run):
`graphics/libplacebo` with `DISTVERSION=7.372.0.s20260923` plus `GL_TAGNAME`,
and mind the soname bump warning near the end of this note.

The API 365 bug is still a real upstream issue worth reporting for anyone
using stock ffmpeg with libplacebo on AMD.

### 2. multimedia/jellyfin-ffmpeg, not multimedia/ffmpeg

`multimedia/jellyfin-ffmpeg` (added to ports 2026-09-17) applies the 98
upstream jellyfin-ffmpeg patches, including
`0023-add-alphasrc-source-video-filter.patch`. `alphasrc` does not exist in
upstream ffmpeg at any version, so no build option can provide it.

The FreeBSD `multimedia/jellyfin` port depends on plain `multimedia/ffmpeg`,
so jellyfin-ffmpeg is NOT installed by default and nothing points Jellyfin at
it. Both steps are manual.

It installs isolated under `${PREFIX}/lib/jellyfin-ffmpeg8`, so it does not
disturb the system ffmpeg.

### 3. jellyfin-ffmpeg needs two local changes

The port as shipped is still not sufficient:

- add `--enable-opencl` to `CONFIGURE_ARGS`, plus
  `${LOCALBASE}/include/CL/cl.h:devel/opencl` (BUILD_DEPENDS) and
  `libOpenCL.so:devel/ocl-icd` (LIB_DEPENDS)
- apply the `overlay_vulkan` framesync patch (see below). It must run
  **after** quilt, because the upstream series' patch 0082 also edits
  `vf_overlay_vulkan.c`; a normal `files/patch-*` runs first and conflicts.

Both are in the `hdrfix` overlay copy of the port.

### 4. An OpenCL ICD: graphics/mesa-devel with rusticl

`devel/ocl-icd` is only the loader. Without a driver behind it ffmpeg reports

    Failed to get number of OpenCL platforms: -1001

`graphics/mesa-devel` has `OPENCL` in `OPTIONS_DEFAULT` (rusticl, via
`gallium-rusticl`) and installs `/usr/local/etc/OpenCL/vendors/rusticl.icd`.

It **co-installs** with `mesa-dri` rather than replacing it: the `COINST`
option is auto-enabled when mesa-devel is not the default GL provider, and it
keeps mesa-dri as a runtime dependency. The existing graphics stack is
untouched.

### 5. RUSTICL_ENABLE=radeonsi in Jellyfin's environment

Rusticl enables **no drivers at all** by default. Without this the ICD loads
but reports `No matching devices found`.

Jellyfin spawns ffmpeg as a child, so the variable has to be in the service
environment. On nas that is `/etc/rc.conf`:

    jellyfin_env="LIBVA_DRIVERS_PATH=/usr/local/lib/dri LIBVA_DRIVER_NAME=radeonsi RUSTICL_ENABLE=radeonsi FC_DEBUG=1024 HOME=/var/db/jellyfin"

Verify it reached the process with `procstat -e <jellyfin pid>`.

### 6. Point Jellyfin at the new encoder

In `/var/db/jellyfin/config/encoding.xml` (or Dashboard > Playback):

    <EncoderAppPath>/usr/local/lib/jellyfin-ffmpeg8/bin/ffmpeg</EncoderAppPath>

Restart Jellyfin. The log should then say

    Found ffmpeg version "8.1.2"
    FFmpeg: "/usr/local/lib/jellyfin-ffmpeg8/bin/ffmpeg"

### Verifying it worked

The generated filter chain is the proof. Working:

    setparams=color_primaries=bt2020:color_trc=smpte2084:colorspace=bt2020nc,
    hwmap=derive_device=drm,format=drm_prime,
    libplacebo=...tonemapping=bt.2390:...color_trc=bt709...,
    format=vulkan,hwmap=derive_device=vaapi,format=vaapi,scale_vaapi=format=nv12

Broken:

    setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709,scale=...,format=nv12,hwupload=derive_device=vaapi

The decisive tell is the **first** `setparams`: `bt2020/smpte2084` means
Jellyfin decided tone mapping is available, `bt709` means it did not. A useful
startup check is that no `[WRN] Filter: "..._opencl"` or `..._vulkan` lines
appear in the Jellyfin log; only the CUDA ones should remain on an AMD host.

Measured on nas (Radeon 780M) with `h264_vaapi` encoding: **101 fps, 4.22x
realtime** for 4K HDR10, no errors.

### Known risks of this stack

- rusticl prints `Patched Mesa libclc not detected. Upstream libclc may
  contain known bugs ... isn't guaranteed to work reliably`. It worked here
  but sustained multi-hour transcoding is unproven.
- libplacebo git master, mesa-devel snapshot and rusticl-on-FreeBSD are all
  bleeding edge.
- Every package is hand-installed. **A `pkg upgrade` reverts the lot.**
- Backups taken before the change: `/etc/rc.conf.bak-20260925-183155`,
  `/var/db/jellyfin/config/encoding.xml.bak-predeploy-*`.

## Symptom

HDR films transcode to a washed out, grey, low contrast picture. Skin tones go
grey-brown, shadows crush, colour separation disappears.

Client independent. Reproduced on Jellyfin Android TV (Fire TV Stick), Jellyfin
Web (Chromium on two different machines) and Jellyfin for Android (Pixel 7)
once a bitrate cap forces transcoding.

## Mechanism

Jellyfin emits this video filter chain:

    -vf "setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709,scale=...,format=nv12,hwupload=derive_device=vaapi"

`setparams` only rewrites metadata. It does not convert anything. The pixels
stay BT.2020 primaries with the SMPTE 2084 (PQ) transfer function, so the
client receives HDR data labelled as SDR and applies an SDR curve to it.

This is the "tone mapping disabled" branch of Jellyfin's own code. From
`EncodingHelper.GetOverwriteColorPropertiesParam()`:

    isTonemapAvailable == true  -> setparams=color_primaries=bt2020:color_trc=smpte2084:colorspace=bt2020nc
    isTonemapAvailable == false -> setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709

So the emitted `bt709` variant is proof that Jellyfin decided tone mapping was
unavailable. It is not merely a missing filter, it is the documented negative
branch.

## Affected media (test case)

    /NAS/films/Fantastique.SF/The.lord.of.the.rings.The.fellowship.of.the.ring.2001.2160p.mkv

    hevc, 3840x1608, yuv420p10le, bt2020nc / smpte2084 / bt2020
    Dolby Vision Profile 8.1, DvBlSignalCompatibilityId 1, RPU present, BL present, EL absent

## Which tone map path Jellyfin uses here

Jellyfin 10.11.11 has several tone map implementations. For an AMD VAAPI device
it uses the **Vulkan / libplacebo** path, not OpenCL. This was verified by
reading `EncodingHelper.cs` from the v10.11.11 tag:

    GetAmdVaapiFullVidFiltersPrefered()
      -> var doVkTonemap = IsVulkanHwTonemapAvailable(state, options);
      -> GetLibplaceboFilter(...)

An earlier working theory that OpenCL was the required path was wrong and is
retracted. `tonemap_opencl` is used by the Intel/other branch, not this one.

## Two real bugs found and fixed (neither was sufficient)

Scope note, with hindsight: only the second of these is load-bearing for the
Jellyfin fix. The libplacebo one affects **stock ffmpeg**, which Jellyfin no
longer uses once `EncoderAppPath` points at jellyfin-ffmpeg. Both remain
genuine upstream bugs.

### 1. libplacebo filter broken on all AMD GPUs (fixed)

`ffmpeg -vf 'hwupload,libplacebo,hwdownload'` failed with
`Error initializing filters` on every AMD GPU tested, while working on
llvmpipe.

Cause, in ffmpeg `libavfilter/vf_libplacebo.c`:

    #if PL_API_VER >= 365
        pl_qf->flags = hwctx->queue_flags;
    #else
        if (hwctx->queue_flags != 0)
            return AVERROR(EINVAL); // prevent undefined behavior
    #endif

`pl_vulkan_queue.flags` was added in libplacebo API 365. The newest libplacebo
*release* is v7.360.1 (API 360), so the `#else` branch compiles in. ffmpeg's
Vulkan device sets `queue_flags = 0x4`
(`VK_DEVICE_QUEUE_CREATE_INTERNALLY_SYNCHRONIZED_BIT_KHR`) on RADV because the
driver supports `VK_KHR_internally_synchronized_queues`. Non-zero flags
therefore returned EINVAL and aborted `init_vulkan()` **before**
`pl_vulkan_import()` was ever called, which is why libplacebo itself never
logged an error.

llvmpipe works because it reports `queue_flags = 0`.

Measured with a small probe replicating ffmpeg's `copy_pl_queue()`:

    libplacebo 360:  queue_flags=0x4  copy_pl_queue() -> EINVAL
    libplacebo 372:  queue_flags=0x4  copy_pl_queue() OK, pl_vulkan_import() OK

Fix: `graphics/libplacebo` built from a git master snapshot (API 372).

### 2. overlay_vulkan missing framesync options (fixed)

Jellyfin gates the whole Vulkan filter chain on `IsVulkanFullSupported()`,
which requires, among others:

    _mediaEncoder.SupportsFilterWithOption(FilterOptionType.OverlayVulkanFrameSync)

That probes `overlay_vulkan` for the option described
`"Action to take when encountering EOF from secondary input "` (trailing space
is in the ffmpeg source). Stock ffmpeg 9.0.1 `overlay_vulkan` advertises only
`x` and `y`, so the check failed, `isVaapiVkSupported` was false, and Jellyfin
fell through to `GetVaapiLimitedVidFiltersPrefered()` (scale and deinterlace
only) which cannot tone map.

The filter already drives framesync internally
(`ff_framesync_init_dualinput`, `ff_framesync_configure`,
`ff_framesync_activate`), it simply declared its class with
`AVFILTER_DEFINE_CLASS`. Every other overlay filter uses
`FRAMESYNC_DEFINE_CLASS` plus a `.preinit` callback.

Fix, in `libavfilter/vf_overlay_vulkan.c`:

    -AVFILTER_DEFINE_CLASS(overlay_vulkan);
    +FRAMESYNC_DEFINE_CLASS(overlay_vulkan, OverlayVulkanContext, fs);

    +    .preinit        = overlay_vulkan_framesync_preinit,

This one is a genuine upstream ffmpeg oversight and is worth submitting.

**Effect, confirmed:** Jellyfin now builds the full interop chain, which it
never did before:

    before: -init_hw_device vaapi=va:/dev/dri/renderD128 -filter_hw_device va
    after:  -init_hw_device drm=dr:/dev/dri/renderD128
            -init_hw_device vaapi=va@dr
            -init_hw_device vulkan=vk@dr
            -filter_hw_device vk

So `IsVulkanFullSupported()` now passes and the AMD Vulkan branch runs.

## What was still wrong (resolved, see recipe above)

Despite the above, the emitted filter is still the `bt709` variant, so
`doVkTonemap` is still false. The gate is:

    private bool IsVulkanHwTonemapAvailable(EncodingJobInfo state, EncodingOptions options)
    {
        if (state.VideoStream is null) return false;
        // libplacebo has partial Dolby Vision to SDR tonemapping support.
        return options.EnableTonemapping
               && state.VideoStream.VideoRange == VideoRange.HDR
               && GetVideoColorBitDepth(state) == 10;
    }

Status of each term:

| Term | Evidence | Verified? |
|---|---|---|
| `options.EnableTonemapping` | `EnableTonemapping=true` in `encoding.xml` | yes, directly |
| `GetVideoColorBitDepth(state) == 10` | DB `BitDepth = 10`, `PixelFormat = yuv420p10le` | yes, directly |
| `VideoRange == VideoRange.HDR` | derived, see below | **NO, inferred only** |

The third term was derived, not observed. `MediaStream.GetVideoColorRange()`
in the v10.11.11 source maps this file's database values to
`(VideoRange.HDR, VideoRangeType.DOVIWithHDR10)`:

    DvProfile = 8, DvBlSignalCompatibilityId = 1,
    RpuPresentFlag = 1, BlPresentFlag = 1, CodecTag = '' (empty)

    isDoViProfile = dvProfile is 5 or 7 or 8 or 10            -> true
    isDoViFlag    = rpu && bl && compatId is 0/1/4/2/6        -> true
    dvProfile 8, compatId 1                                   -> (HDR, DOVIWithHDR10)

and the non-DoVi fallback would also return HDR because
`ColorTransfer = smpte2084`. Both paths give `VideoRange.HDR`, so on paper the
gate should pass. It does not.

### Plain HDR10 fails identically (2026-09-25)

The Dolby Vision angle was tested directly and ruled out. A clean HDR10 file
with no Dolby Vision at all produces the same untone mapped output:

    /NAS/films/Animation/Akira.1988.2160p.mkv
    hevc, 3840x2074, yuv420p10le, bt2020nc / smpte2084 / bt2020
    DvProfile, RpuPresentFlag, BlPresentFlag all empty in the DB
    ffprobe reports zero Dolby Vision side data frames (Fellowship reports 4)

This file takes the simple fallback in `GetVideoColorRange()`:

    if (colorTransfer == "smpte2084")
        return (VideoRange.HDR, VideoRangeType.HDR10);

No DoVi branch, no compatibility id logic. Played through Chromium on ser6 it
still emitted:

    -vf "setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709,scale=...,format=nv12,hwupload=derive_device=vaapi"

with the full Vulkan chain present (`drm=dr`, `vaapi=va@dr`, `vulkan=vk@dr`,
`-filter_hw_device vk`), so the AMD Vulkan branch is running and only
`doVkTonemap` is false.

Conclusion: the gate fails for all HDR content, not just Dolby Vision.

To find 605 more HDR10-without-DoVi candidates:

    SELECT b.Path FROM MediaStreamInfos m JOIN BaseItems b ON b.Id = m.ItemId
    WHERE m.ColorTransfer = 'smpte2084'
      AND (m.DvProfile IS NULL OR m.DvProfile = 0)
      AND (m.RpuPresentFlag IS NULL OR m.RpuPresentFlag = 0)
      AND m.BitDepth = 10;

### The installed binary matches upstream (checked)

The FreeBSD port *does* patch `EncodingHelper.cs`, but only to rewrite
`OperatingSystem.IsLinux()` as `IsLinux() || IsFreeBSD()` in 9 places (plus a
QSV kernel workaround). Extracting the port and diffing the patched tree:

- `IsVulkanHwTonemapAvailable()` is byte identical to upstream
- `MediaStream.GetVideoColorRange()` is byte identical to upstream
- the `var isLinux = ...` feeding `isVaapiVkSupported` IS patched for FreeBSD,
  and demonstrably works, since the Vulkan device chain is now built

So the gate logic that is running is the logic documented above. Reproduce with:

    cd /usr/ports/multimedia/jellyfin && make extract patch
    # then read work/jellyfin-10.11.11/MediaBrowser.Controller/MediaEncoding/EncodingHelper.cs
    # remember to `make clean` afterwards

Also checked and ruled out: `encoding.xml` is not rewritten at startup (it is
byte identical to a backup taken before the last restart), and Jellyfin does
not re-probe the file at playback time, so `state.VideoStream` comes from the
stored metadata that was queried from the DB.

### Theories already tested and disproven

Recording these so they are not re-tried:

1. **OpenCL is the required path.** No: this branch uses Vulkan/libplacebo.
   `--disable-opencl` in the ffmpeg build is irrelevant here.
2. **Kernel version check fails on FreeBSD.** No:
   `Environment.OSVersion.Version >= new Version(5, 15)` is satisfied because
   FreeBSD reports 16.0.
3. **Dolby Vision is classified as SDR / excluded.** No: the database values
   map to `VideoRange.HDR` through both code paths.
4. **The framesync option was the last blocker.** Necessary but not
   sufficient: the Vulkan chain is now built and tone mapping still does not
   engage.
5. **Client capability.** No: reproduced from Chromium (SDR-only H.264),
   Jellyfin Android TV and Jellyfin for Android. All produce the identical
   `bt709` chain.
6. **Dolby Vision specific handling.** No: a plain HDR10 file with no DoVi
   metadata fails identically. See above.
7. **The FreeBSD port patches the gate.** No: the patched source is byte
   identical to upstream for both the gate and the video range classifier.
8. **The config is not actually loaded.** No: `encoding.xml` on disk has
   `EnableTonemapping=true`, is unchanged since before the last restart, and
   nothing rewrites it.

### How it was actually found

The runtime `VideoRange` was finally observed directly (not derived) via
Jellyfin's own API, using an existing device token from the database:

    sqlite3 /var/db/jellyfin/data/jellyfin.db "SELECT AccessToken FROM Devices LIMIT 1;"
    curl -s -H "X-Emby-Token: $T" "http://127.0.0.1:8096/Items/$ID/PlaybackInfo" \
      | tr ',' '\n' | grep -E '"VideoRange"|"VideoRangeType"|"BitDepth"'

    "VideoRange":"HDR"  "VideoRangeType":"HDR10"  "BitDepth":10

All three gate terms were therefore true, which meant the gate was never
being *reached*. Reading `GetVaapiVidFilterChain()` in the extracted port
source then exposed the early-exit guard documented at the top of this note.

Lesson for next time: when a condition looks satisfied but its effect is
missing, check whether the enclosing function is even entered before
re-examining the condition.


## Visual evidence

Frames extracted at the same timestamp through both paths, on ser6. Scene is
Kaneda in the red jacket under the curved tunnel arch, roughly 20:20 into
Akira.

Broken (`setparams` only, what Jellyfin produces):
- jacket dull brick/brown, tunnel arch murky olive, building dark maroon
- grey veil over the whole frame, shadows crushed

Tone mapped (libplacebo bt.2390):
- jacket vivid red, arch saturated yellow, building bright red, tree green
- clearly more contrast and colour separation

A frame pulled from a **real Jellyfin transcode segment** (not a command line
reproduction) shows the same degradation, confirming the reproduction was
accurate:

    cat /var/cache/jellyfin/transcodes/<id>-1.mp4 \
        /var/cache/jellyfin/transcodes/<id>404.mp4 > /tmp/real_seg.mp4
    ffprobe ... -> color_space=bt709 color_transfer=bt709 color_primaries=bt709

PNG file size is a useful objective proxy: the untone mapped frames carry
high entropy PQ data spread across a range the SDR viewer cannot interpret, so
they compress far worse.

    Fellowship  broken 6.4M   tonemapped 1.5M
    Akira       broken 5.9M   tonemapped 1.4M

Reproduce a comparison pair for any file:

    T=20
    ffmpeg -ss $T -i clip.mkv -frames:v 1 \
      -vf "setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709" -y broken.png
    ffmpeg -ss $T -init_hw_device vulkan=vk:0 -filter_hw_device vk -i clip.mkv -frames:v 1 \
      -vf "format=yuv420p10le,hwupload,libplacebo=tonemapping=bt.2390:colorspace=bt709:color_primaries=bt709:color_trc=bt709:format=nv12,hwdownload,format=nv12" \
      -y tonemapped.png

## VLC on FreeBSD cannot tone map either (separate cause)

Worth knowing when comparing players: VLC is not a valid reference for
"correct" colour on these hosts. Opening the same HDR10 file directly over SMB
in VLC 3.0.23 on ser6 looks the same as Jellyfin's untone mapped transcode.

That is a different defect with the same visible result. `multimedia/vlc` has:

    OPTIONS_EXCLUDE=	LIBPLACEBO # https://code.videolan.org/videolan/vlc/-/commit/8e22c39ea3c3
    LIBPLACEBO_DESC=	HDR tonemapping support through libplacebo

So the package has no tone mapping code compiled in at all, and there is no
fallback path: PQ values are pushed through as if they were SDR.

The cited commit is VLC porting **to** the libplacebo v4 API. VLC 3.0.x
therefore targets v4 while ports ships v7. Re-enabling the option does not
work: 6 of the 32 `pl_*` symbols VLC references no longer exist in v7.

    pl_context_create  pl_context_destroy  pl_ctx   <- replaced by pl_log in v4
    pl_color_space_from_video_format
    pl_sh  pl_sh_res

Checked by extracting the port and grepping its symbols against the v7
headers. Making it build would mean porting VLC's OpenGL output module across
three major libplacebo versions, which is what VLC 4.x already did. Do not
retry this; the port's exclusion is correct.

Consequence: on ser6 the only correct rendering of this content so far is the
libplacebo PNG above. If a working HDR player is wanted there, try mpv, which
tracks libplacebo closely and would use the installed v7.372.

## Direct play avoids the whole problem

A client that can play the source as-is never transcodes, so it never hits
this. Verified on a Pixel 7 running Jellyfin for Android:

    PlayMethod=DirectPlay   TranscodeReason=0   (zero ffmpeg processes on nas)

Colours are correct because the client does its own HDR handling. Applying a
bitrate cap to the same phone immediately broke it:

    PlayMethod=Transcode    TranscodeReason=ContainerBitrateExceedsLimit

and the client then advertised `VideoCodec=h264` only, producing the same
washed out output.

Browsers can never direct play this content: the Jellyfin web client advertises
`VideoCodec=av1,h264,vp9` with `h264-rangetype=SDR`. No HEVC, so a 4K HEVC
source always transcodes regardless of how capable the GPU is.

**Practical consequence:** for a 4K HEVC Dolby Vision library, native apps at
maximum quality get correct colours today; any browser client does not.

## Command line tone mapping works

Independent of Jellyfin, the fixed ffmpeg tone maps this file correctly:

    ffmpeg -init_hw_device vulkan=vk:0 -filter_hw_device vk -i clip.mkv \
      -vf "format=yuv420p10le,hwupload,libplacebo=tonemapping=bt.2390:colorspace=bt709:color_primaries=bt709:color_trc=bt709:format=nv12,hwdownload,format=nv12" \
      -c:v libx264 -preset ultrafast -f null -

    nas  (Radeon 780M): 3.05x realtime, 73 fps
    ser6 (Radeon 680M): 2.61x realtime, 62 fps

Colour output was visually verified against the broken path. So pre-tone
mapping a file to SDR is a guaranteed fallback at roughly 3x realtime.

## Packages

(Reminder: the libplacebo snapshot listed here is what these hosts happen to
run, not a requirement of the fix. See recipe step 1.)

Both hosts (nas, ser6) currently run hand-installed packages, NOT from the
repo. A `pkg upgrade` will revert them:

    libplacebo-7.372.0.s20260923   (git master snapshot, API 372)
    ffmpeg-9.0.1_1,1               (with the overlay_vulkan framesync patch)

Port changes live in a poudriere overlay, `/usr/ports` is untouched:

    /usr/local/poudriere/overlays/hdrfix/graphics/libplacebo
    /usr/local/poudriere/overlays/hdrfix/multimedia/ffmpeg

Registered as ports tree `hdrfix`; build with:

    poudriere bulk -j builder -p default -O hdrfix graphics/libplacebo multimedia/ffmpeg

Note the libplacebo port needed two extra changes beyond the version bump: the
`version_pretty` reinplace in `post-patch` had to be dropped (upstream moved it
from `src/meson.build` to `meson.build`, and the snapshot needs no version
override), and `pkg-plist` had to stop hardcoding the soname:

    SOVERSION=	${DISTVERSION:C/^[0-9]+\.([0-9]+)\..*/\1/}
    PLIST_SUB=	SOVERSION=${SOVERSION}
    lib/libplacebo.so.%%SOVERSION%%

## Warning: the libplacebo soname bump breaks other packages

Upgrading libplacebo changes the soname (`libplacebo.so.360` ->
`libplacebo.so.372`). Anything linked against the old one fails to start with

    Shared object "libplacebo.so.360" not found

On ser6 this hit **mpv** (and `libmpv.so`), which had to be rebuilt against
the new libplacebo and reinstalled:

    poudriere bulk -j builder -p default -O hdrfix multimedia/mpv

Do not use `pkg info -d` to find what needs rebuilding. It lists *declared*
dependencies, and it missed mpv entirely. Worse, after a `pkg install -f` of
the new libplacebo, pkg reports the dependency as already satisfied by
`libplacebo-7.372.0.s20260923` while the binary still needs the old soname, so
the breakage is invisible until the program is run.

Scan with `ldd` instead, before and after:

    for d in /usr/local/bin /usr/local/lib /usr/local/libexec; do
        find $d -maxdepth 1 -type f
    done | while read f; do
        ldd "$f" 2>/dev/null | grep -q "libplacebo.so.360" && echo "BROKEN: $f"
    done

nas was checked this way and had no other consumers besides ffmpeg.

Note mpv rebuilt against v7.372 also **tone maps correctly**, confirmed by
playing the Akira clip on ser6: colours match the libplacebo reference PNG.
That makes mpv the only working HDR player on these hosts, and it is a useful
reference when judging whether some other player's output is wrong.

It is also a useful negative result for the Jellyfin hunt: the whole stack
below Jellyfin (libplacebo v7.372, RADV, the GPU, the patched ffmpeg) is
proven good by mpv playing the same file correctly in real time. The remaining
fault is entirely inside Jellyfin's own decision logic.

## Unrelated observations from the same session

- Debug logging was enabled at `/var/db/jellyfin/config/logging.json` (copy of
  `logging.default.json` with `Default: Debug`). Verbose; remove it to revert.
- carbon (MTL X1 Carbon) stutters and stalls on any transcoded stream because
  it has no working GPU video decode on FreeBSD, so Chromium software decodes
  in a single renderer thread. Pre-existing, unrelated to this issue, see
  `../FreeBSD/docs/mtl_anv_no_engines.md`. ser6 plays a 5x higher bitrate
  stream smoothly.
- `transpose_vulkan` segfaults on RADV (`ffmpeg -vf
  'hwupload,transpose_vulkan,hwdownload'`). Separate ffmpeg bug, did not block
  Jellyfin's detection, not investigated.
