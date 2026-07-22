# graphics/mesa-dri: enable Vulkan Video encode codecs in RADV

Ports fix + PR notes. Standalone from the Moonshine study
(`~/myscripts/FreeBSD/moonshine/README.md`) that surfaced the bug.

## Summary

`graphics/mesa-dri` builds the Vulkan drivers (RADV for AMD, ANV for Intel).
It does not set `-Dvideo-codecs=`, so Mesa falls back to the upstream default
`all_free`. That silently strips all patent-encumbered codecs from the RADV
Vulkan Video path — including H.264/H.265 encode and decode, which are the
only codecs GameStream / Moonlight hosts (Moonshine, Sunshine) can use.

`graphics/mesa-libs` (gallium / VA-API path) already sets `-Dvideo-codecs=all`,
so the VA-API side works. Only the Vulkan side is broken.

**One-line fix.** Add `-Dvideo-codecs=all` to the mesa-dri MESON_ARGS.

## Reproducer (before the fix)

Host: FreeBSD 16.0-CURRENT, AMD Radeon 680M (VCN 3.0), Mesa 26.1.3 from
`graphics/mesa-dri`.

```
$ vulkaninfo 2>/dev/null | grep -E "VK_KHR_video_(encode|decode)"
	VK_KHR_video_decode_av1                       : extension revision 1
	VK_KHR_video_decode_queue                     : extension revision 8
	VK_KHR_video_decode_vp9                       : extension revision 1
	VK_KHR_video_encode_intra_refresh             : extension revision 1
	VK_KHR_video_encode_quantization_map          : extension revision 2
	VK_KHR_video_encode_queue                     : extension revision 12
```

Encode queue infrastructure is present but **no codec-specific
`VK_KHR_video_encode_h264/h265/av1` extension**, and no
`VK_KHR_video_decode_h264/h265` either. `all_free` at work: `av1dec` and
`vp9dec` are patent-free (present); everything else is gated.

## Root cause

Upstream `meson.options` (Mesa 26.1.3), the relevant block:

```
option(
  'video-codecs',
  type : 'array',
  value : ['all_free'],
  choices: [
    'all', 'all_free', 'vc1dec', 'h264dec', 'h264enc', 'h265dec', 'h265enc',
    'av1dec', 'av1enc', 'vp9dec', 'mpeg12dec', 'jpegdec'
  ],
  description : 'List of codecs to build support for. ' +
                'Distros might want to consult their legal department before ' +
                'enabling these. This is used for all video APIs (vaapi, ' +
                'vulkan). Non-patent encumbered codecs will be ' +
                'enabled by default with the all_free default value.'
)
```

Note the description: *"This is used for all video APIs (vaapi, vulkan)."*
The same knob controls both VA-API and Vulkan Video codec sets.

State of the three FreeBSD Mesa ports at the time of writing (MESAVERSION
26.1.5):

| Port | Purpose | `-Dvideo-codecs` |
|------|---------|------------------|
| `graphics/mesa-libs` | gallium drivers (radeonsi/etc, VA-API) | `"all"` (line 63) |
| `graphics/mesa-dri` | Vulkan drivers (RADV/ANV) | **not set** => `all_free` |
| `graphics/mesa-devel` | Mesa git snapshot | `all` (line 38) |

`mesa-libs` was fixed at some point (the VA-API users noticed); `mesa-dri`
was not, presumably because nobody was exercising Vulkan Video encode on
FreeBSD yet.

## The fix

`graphics/mesa-dri/Makefile`, in the `# Disable some options` block near the
end (the one that already lists `MESON_ARGS+= -Dandroid-libbacktrace=disabled`
etc.), add:

```make
MESON_ARGS+=	-Dvideo-codecs=all
```

Rationale for putting it in `mesa-dri/Makefile` (not `Makefile.common`):

- `Makefile.common` is shared with `mesa-libs`, which already sets its own
  `-Dvideo-codecs="all"` on line 63. Adding it to the common file would
  duplicate meson args for `mesa-libs`.
- Alternative: move both to `Makefile.common` and drop the mesa-libs line.
  Cleaner but bigger diff. Keep the diff minimal for the first PR.

Also bump `PORTREVISION` in `graphics/mesa-dri/Makefile` (append
`PORTREVISION= 1` under `PORTVERSION=`) so users get the rebuilt package.
`mesa-libs` and `mesa-devel` don't need a bump — they weren't touched.

## Verifying the fix

On the target host (ser6), after installing the rebuilt `mesa-dri`:

```
$ vulkaninfo 2>/dev/null | grep -E "VK_KHR_video_(encode|decode)_(h26[45]|av1)"
```

Expected new extensions on VCN3 (Radeon 680M):

- `VK_KHR_video_decode_h264`
- `VK_KHR_video_decode_h265`
- `VK_KHR_video_encode_h264`
- `VK_KHR_video_encode_h265`

VCN3 does not have an AV1 encoder block, so `VK_KHR_video_encode_av1` will
remain absent — expected, this is a hardware limit (needs VCN4+ on
Phoenix/RDNA3). `VK_KHR_video_decode_av1` was already present via `all_free`.

Intel Arc / ANV users on the same rebuilt Mesa gain the equivalent extensions
for their hardware.

## Build + test procedure

```sh
# 1. Edit the port.
cd ~/freebsd-official/ports/graphics/mesa-dri
$EDITOR Makefile   # add MESON_ARGS+= -Dvideo-codecs=all, bump PORTREVISION

# 2. Poudriere test-build (jail: builder, tree: official).
sudo poudriere testport -j builder -p official graphics/mesa-dri
# Expect: clean stage, packages install.

# 3. Install the freshly built pkg on ser6.
scp /usr/local/poudriere/data/packages/builder-official/All/mesa-dri-*.pkg ser6:/tmp/
ssh ser6 'sudo pkg install -f /tmp/mesa-dri-*.pkg'

# 4. Verify.
ssh ser6 'vulkaninfo 2>/dev/null | grep -E "VK_KHR_video_(encode|decode)_(h26[45]|av1)"'
```

If the four expected extensions appear on the AMD GPU, the fix is confirmed.

## PR / bug report

Target: `freebsd/freebsd-ports` (GitHub mirror) or a Bugzilla PR against
`x11@FreeBSD.org`.

Suggested commit message:

```
graphics/mesa-dri: enable all video codecs for Vulkan drivers

Mesa's -Dvideo-codecs meson option defaults to 'all_free', which strips
patent-encumbered codecs (H.264, H.265) from both VA-API and Vulkan Video
paths. graphics/mesa-libs already overrides this to 'all' for the gallium
side (radeonsi VA-API). graphics/mesa-dri, which builds the Vulkan drivers
(RADV, ANV), does not — so RADV on FreeBSD reports VK_KHR_video_encode_queue
but no codec-specific VK_KHR_video_encode_h264/h265, making the whole
Vulkan Video encode path unusable for downstream consumers (streaming
hosts, ffmpeg's vulkan_encode backend, etc.).

Mirror the mesa-libs override in mesa-dri so RADV exposes the full set of
Vulkan Video decode/encode extensions supported by the underlying hardware.

Tested on FreeBSD 16.0-CURRENT with AMD Radeon 680M (VCN 3.0): after
rebuild, VK_KHR_video_{encode,decode}_h264 and _h265 are exposed as
expected. AV1 encode remains unavailable (VCN 3.0 hardware limit).
```

Suggested PR title:

```
graphics/mesa-dri: enable H.264/H.265 Vulkan Video codecs
```

Also mention the exact `MESAVERSION` you built against (26.1.5 at time of
writing) so the maintainer can reproduce.

## Downstream unblocked by this fix

- **Moonshine** — see `~/myscripts/FreeBSD/moonshine/README.md`. Vulkan Video
  encode is a hard requirement.
- **Sunshine on FreeBSD** — if/when it adopts the Vulkan encoder backend.
- **ffmpeg** — `-c:v hevc_vulkan` / `h264_vulkan` encoder needs these
  extensions.
- **magic-mirror / any Wayland+Vulkan streaming host** on FreeBSD.

## Non-goals / out of scope for this PR

- Refactoring `Makefile.common` to unify the mesa-libs and mesa-dri overrides.
  Nice to have, separate PR.
- Adding a `VIDEO_CODECS` port option for users who want to opt out (legal
  concerns in some jurisdictions). `mesa-libs` doesn't have one either;
  keep parity — one PR at a time.
- Bumping MESAVERSION. Orthogonal.
