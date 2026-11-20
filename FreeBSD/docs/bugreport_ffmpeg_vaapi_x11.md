# multimedia/ffmpeg: default build has no VA-API X11 backend (--disable-xlib)

```
Category:  Ports & Packages
Component: Individual Port(s)
Version:   Latest
Summary:   multimedia/ffmpeg: VA-API X11 backend missing since 8.0.1 (--disable-xlib with default options)
CC:        maintainer of multimedia/ffmpeg
```

Patch: [`ffmpeg_vaapi_x11.patch`](ffmpeg_vaapi_x11.patch)
(`multimedia/ffmpeg/Makefile`, against ports `cc8f989225`, 2026-11-15).

**Summary.** With its default options, the ffmpeg port passes `--disable-xlib`
to configure, so libavutil is built without the X11 backend of VA-API
(`vaapi_x11`). Any program that asks libavutil for a VA-API device by X11
display name then fails with `No VA display found for device :0` and falls back
to software decoding. The rule that adds `--disable-xlib` came with the 8.0.1
update (`c204aaf79162`, "fix XCB option", PR 290246). It is also redundant:
the XCB option already toggles xlib through `XCB_CONFIGURE_ENABLE`.
The patch removes the rule.

## How to repeat

FreeBSD 16.0-CURRENT, amd64, AMD Radeon 680M (radeonsi), ffmpeg-9.0.2_3,1 built
by poudriere with the default options (no options file, no make.conf overrides).

VA-API itself works on the X server:

```
$ DISPLAY=:0 vainfo | grep Driver
vainfo: Driver version: Mesa Gallium driver ... for AMD Radeon 680M (radeonsi, rembrandt, ...)
```

but libavutil only has the DRM backend:

```
$ ldd /usr/local/lib/libavutil.so | grep libva
	libva-drm.so.2 => /usr/local/lib/libva-drm.so.2
	libva.so.2 => /usr/local/lib/libva.so.2
```

games/moonlight-embedded is one affected consumer: on X11 it creates its device
with `av_hwdevice_ctx_create(..., AV_HWDEVICE_TYPE_VAAPI, ":0", ...)`
(`src/video/ffmpeg_vaapi.c:62`) and draws with `vaPutSurface()`, which needs an
X11 VA display:

```
$ moonlight stream -1080 -fps 60 -app ... <host>
[VAAPI @ 0x168b06e26d40] No VA display found for device :0.
```

It then decodes in software. The same failure shows with ffmpeg itself:

```
$ DISPLAY=:0 ffmpeg -init_hw_device vaapi=va::0 -f lavfi -i nullsrc -frames:v 1 -f null -
```

## Cause

`multimedia/ffmpeg/Makefile`, at the end:

```make
.if !${PORT_OPTIONS:MVDPAU} || !${PORT_OPTIONS:MXCB} || !${PORT_OPTIONS:MXVIDEO}
CONFIGURE_ARGS+=	--disable-xlib
.endif
```

xlib is disabled unless VDPAU, XCB *and* XVIDEO are all on. XVIDEO is not in
`OPTIONS_DEFAULT`, so every default build gets `--disable-xlib`. That
argument comes after the `--enable-xlib` that `XCB_CONFIGURE_ENABLE` adds,
so it wins.

In FFmpeg's configure, xlib is what the X11 backend of VA-API hangs on:

```
vaapi_x11_deps="xlib_x11"
...
    if enabled xlib_x11; then
        check_pkg_config vaapi_x11 "libva-x11" "va/va_x11.h" vaGetDisplay
    fi
```

(`xv_outdev` is the only other user of xlib.) Before `c204aaf79162` the port
did not pass any xlib switch and configure autodetected it.

## Fix

Remove the rule. The XCB option already passes `--enable-xlib` or
`--disable-xlib`, and XCB brings libX11, libXext and libXv, which configure
requires before it enables xlib. The nox11 flavor still disables xlib.

xlib switches in `CONFIGURE_ARGS` (`make -V CONFIGURE_ARGS`):

| options              | before          | after           |
|----------------------|-----------------|-----------------|
| defaults             | `--enable-xlib --disable-xlib` | `--enable-xlib` |
| XCB off              | `--disable-xlib` (twice) | `--disable-xlib` |
| VDPAU off            | `--enable-xlib --disable-xlib` | `--enable-xlib` |
| XVIDEO on            | `--enable-xlib` | `--enable-xlib` |
| FLAVOR=nox11         | `--disable-xlib` (twice) | `--disable-xlib` |

## Test

Built with poudriere (16.0-CURRENT 1600031 jail, default options) with xlib
enabled. That is the same `CONFIGURE_ARGS` the patch gives with the default
options. Installed on the client:

```
$ ldd /usr/local/lib/libavutil.so | grep libva-x11
	libva-x11.so.2 => /usr/local/lib/libva-x11.so.2
$ DISPLAY=:0 ffmpeg -init_hw_device vaapi=va::0 -f lavfi -i nullsrc -frames:v 1 -f null -
(no error)
$ moonlight stream -1080 -fps 60 -app ... <host>
Platform X Window System (VAAPI)
Starting video stream...Using FFmpeg decoder: hevc
```

The video receive thread of moonlight-embedded dropped from about 43% CPU
(software decoding) to below the busiest thread of the process (1.2%).

## Not covered

With XVIDEO on and XCB off, `XCB_CONFIGURE_ENABLE` still passes
`--disable-xlib`, so the Xv output device is not built. That is the same with
or without this patch.
