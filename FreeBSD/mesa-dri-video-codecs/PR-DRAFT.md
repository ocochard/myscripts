# PR draft: graphics/mesa-dri — enable Vulkan Video H.264/H.265 codecs

Ready-to-use materials for opening a PR against `freebsd/freebsd-ports`.
See `README.md` in this directory for the full background.

---

## Commit message (subject + body)

```
graphics/mesa-dri: enable H.264/H.265 Vulkan Video codecs

Mesa's -Dvideo-codecs meson option defaults to 'all_free', which strips
patent-encumbered codecs (H.264, H.265) from both VA-API and Vulkan
Video paths. graphics/mesa-libs already overrides this to 'all' for
the gallium side (radeonsi VA-API), but graphics/mesa-dri — which
builds the Vulkan drivers (RADV, ANV) — does not. RADV on FreeBSD
therefore reports VK_KHR_video_encode_queue but no codec-specific
VK_KHR_video_encode_h264/h265, making the Vulkan Video encode path
unusable for streaming hosts (Moonshine, Sunshine with Vulkan
backend), ffmpeg's vulkan_encode encoders, and any other consumer.

Mirror the mesa-libs override in mesa-dri so RADV exposes the full
set of Vulkan Video decode/encode extensions supported by the
underlying hardware.

Also declare libdisplay-info as a LIB_DEPENDS: with the extra codecs
enabled, libvulkan_intel.so now links directly against
libdisplay-info.so.3 and stage-qa flagged it as an undeclared shlib
dependency.

Tested on FreeBSD 16.0-CURRENT with AMD Radeon 680M (VCN 3.0). AV1
encode remains unavailable there as expected (VCN 3.0 hardware limit
— needs VCN 4+).
```

Suggested PR title: `graphics/mesa-dri: enable H.264/H.265 Vulkan Video codecs`

## Diff (final, verified)

```diff
diff --git graphics/mesa-dri/Makefile graphics/mesa-dri/Makefile
index a0e1c4d33261..dfc7937277c2 100644
--- graphics/mesa-dri/Makefile
+++ graphics/mesa-dri/Makefile
@@ -1,5 +1,6 @@
 PORTNAME=	mesa-dri
 PORTVERSION=	${MESAVERSION}
+PORTREVISION=	1
 CATEGORIES=	graphics
 
 COMMENT=	OpenGL hardware acceleration drivers for DRI2+
@@ -8,7 +9,8 @@ WWW=		https://www.mesa3d.org/
 BUILD_DEPENDS+=	glslangValidator:graphics/glslang \
 		${PYTHON_PKGNAMEPREFIX}ply>0:devel/py-ply@${PY_FLAVOR} \
 		libva>=0:multimedia/libva
-LIB_DEPENDS+=	libgallium-${MESAVERSION}.so:graphics/mesa-libs \
+LIB_DEPENDS+=	libdisplay-info.so:sysutils/libdisplay-info \
+		libgallium-${MESAVERSION}.so:graphics/mesa-libs \
 		libgbm.so:graphics/mesa-libs
 
 USES+=		llvm:lib,noexport
@@ -97,6 +99,12 @@ MESA_PLATFORMS+=	wayland
 
 MESON_ARGS+=	-Dplatforms="${MESA_PLATFORMS:ts,:tl}"
 
+# Enable all video codecs so RADV/ANV expose the full set of Vulkan Video
+# decode/encode extensions (H.264, H.265, AV1). Upstream default is
+# 'all_free' which strips patent-encumbered codecs from both VA-API and
+# Vulkan paths. graphics/mesa-libs already sets this for the gallium side.
+MESON_ARGS+=	-Dvideo-codecs=all
+
 # Disable some options
 MESON_ARGS+=	-Dandroid-libbacktrace=disabled \
 		-Dgles1=enabled \
```

Three changes:

1. `PORTREVISION= 1` — package rebuild triggered.
2. `LIB_DEPENDS+= libdisplay-info.so:sysutils/libdisplay-info` — fixes the
   stage-qa warning that appears once ANV pulls libdisplay-info via the
   HDR/EDID code paths gated behind the extra codecs.
3. `MESON_ARGS+= -Dvideo-codecs=all` — the actual fix. Same override that
   `graphics/mesa-libs/Makefile` line 63 already applies.

## PR body

```markdown
## Summary

`graphics/mesa-dri` builds the Vulkan drivers (RADV for AMD, ANV for Intel)
but does not set `-Dvideo-codecs=`, so Mesa falls back to the upstream
default `all_free`. That silently strips all patent-encumbered codecs from
the RADV/ANV Vulkan Video path — including H.264 and H.265 encode+decode,
which are the codecs every GameStream/Moonlight host (Moonshine, Sunshine
with Vulkan backend) and ffmpeg's `hevc_vulkan`/`h264_vulkan` encoders
depend on.

`graphics/mesa-libs` already sets `-Dvideo-codecs=all` for the gallium /
VA-API side, so the VA-API path works. Only the Vulkan side is broken.

## Upstream option (Mesa 26.1.x `meson.options`)

```
option(
  'video-codecs',
  type : 'array',
  value : ['all_free'],
  choices: ['all', 'all_free', 'vc1dec', 'h264dec', 'h264enc', 'h265dec',
            'h265enc', 'av1dec', 'av1enc', 'vp9dec', 'mpeg12dec', 'jpegdec'],
  description : '... This is used for all video APIs (vaapi, vulkan). ...',
)
```

The description confirms the knob controls **both** APIs. `all_free` keeps
only patent-free codecs (av1dec, vp9dec, jpegdec, etc.), which is why on
current FreeBSD RADV `VK_KHR_video_decode_av1` and `_vp9` show up but the
whole H.264/H.265 pair is missing.

## Reproducer

Host: FreeBSD 16.0-CURRENT, AMD Radeon 680M (VCN 3.0), Mesa 26.1.5 from
`graphics/mesa-dri`.

**Before this PR** — with stock `mesa-dri`:

```console
$ vulkaninfo 2>/dev/null | grep -E "VK_KHR_video_(encode|decode)_(h26[45]|av1)" | sort -u
	VK_KHR_video_decode_av1                       : extension revision 1
```

Only av1dec (patent-free) survives. No H.264/H.265 anywhere. The generic
`VK_KHR_video_encode_queue` is present but useless without a codec.

**After this PR** — with the patched `mesa-dri`:

```console
$ vulkaninfo 2>/dev/null | grep -E "VK_KHR_video_(encode|decode)_(h26[45]|av1)" | sort -u
	VK_KHR_video_decode_av1                       : extension revision 1
	VK_KHR_video_decode_h264                      : extension revision 9
	VK_KHR_video_decode_h265                      : extension revision 8
	VK_KHR_video_encode_h264                      : extension revision 14
	VK_KHR_video_encode_h265                      : extension revision 14
```

Four new codec-specific extensions appear, matching what VCN 3.0 hardware
actually supports:

- `VK_KHR_video_decode_h264`
- `VK_KHR_video_decode_h265`
- `VK_KHR_video_encode_h264`  ← enables streaming/encode workloads
- `VK_KHR_video_encode_h265`  ← enables streaming/encode workloads

`VK_KHR_video_encode_av1` is *not* exposed — expected, VCN 3.0 has no AV1
encoder block. That's a hardware limit (needs VCN 4+ on Phoenix/RDNA 3),
not a driver issue.

## Test plan

- [x] `poudriere bulk -j 16.0-CURRENT -p main graphics/mesa-dri` — builds
      cleanly.
- [x] Install rebuilt `mesa-dri` + `mesa-libs` on FreeBSD 16.0-CURRENT
      with AMD Radeon 680M.
- [x] `vulkaninfo` exposes the four expected codec extensions (see
      before/after above).
- [x] stage-qa no longer flags `libvulkan_intel.so` missing dependency
      on `libdisplay-info` (fixed by the `LIB_DEPENDS` addition).
- [x] `pkg info -d mesa-dri` shows `libdisplay-info-0.3.0` as a
      declared runtime dep.

## Downstream unblocked

- **Moonshine** — Vulkan Video encode is required, port work blocked
  without this fix.
- **Sunshine** (Vulkan encoder backend) — same requirement.
- **ffmpeg** — `-c:v hevc_vulkan` / `-c:v h264_vulkan` encoders need
  these extensions.
- **magic-mirror** / any Wayland+Vulkan streaming host on FreeBSD.

## Notes

- Applied to `graphics/mesa-dri/Makefile`, not `Makefile.common`, because
  the latter is shared with `graphics/mesa-libs` which already sets its
  own `-Dvideo-codecs="all"` on line 63. Doing this in the common file
  would duplicate the meson argument on the mesa-libs build. A future
  refactor could unify both; keeping this PR minimal.
- `PORTREVISION` bump on `mesa-dri` only. `mesa-libs` and `mesa-devel`
  are untouched — they already had the override.
```

## Where to open the PR

Target: `freebsd/freebsd-ports` on GitHub.

Base branch: `main`. Head branch: whatever fork branch you push from
(the diff currently lives uncommitted on `~/freebsd-official/ports`
`main` — commit and push to a fork branch such as `mesa-dri-video-codecs`
before invoking `gh pr create`).

Alternative: FreeBSD Bugzilla against `x11@FreeBSD.org` if the
maintainer prefers the traditional PR path. Same commit message + body
work there.

## Reviewer to CC

`x11@FreeBSD.org` is the port MAINTAINER (from `Makefile.common` line
16). Loop them in.

## What NOT to include in this PR (deferred)

- Refactoring `Makefile.common` to unify the `mesa-libs` / `mesa-dri`
  video-codecs overrides. Nice-to-have, separate PR.
- Adding a `VIDEO_CODECS` port option for users who want to opt out for
  legal reasons. `mesa-libs` doesn't have one either — keep parity.
- Bumping `MESAVERSION`. Orthogonal to this change.
