# NETINT Quadra live demo

Web page that starts a hardware transcode on the Quadra card and shows card,
CPU, RAM and network load. Python standard library only (plus `hls.min.js`
1.7.4 from jsdelivr, vendored in `static/`).

Pipeline per visitor (everything but packaging runs on the card):

    ffmpeg-netint -re -stream_loop -1 -c:v <h264|h265|vp9>_ni_quadra_dec -xcoder-params out=hw -i video
        -vf ni_quadra_scale=WxH[,ni_quadra_hvsplus | ni_quadra_flip] -c:v h264_ni_quadra_enc -b:v N
        -f hls (6 s segments, keyframe every 2 s)

HDR10 sources (HEVC Main 10, PQ) use their own chain, see "HDR to SDR".

## Platform

FreeBSD only for now. The encoding and streaming core is portable, but the
CPU, RAM, network and host-info readers use `sysctl`, `netstat -ibn` and
`kenv` (Linux would need `/proc/stat`, `/proc/meminfo`, `/proc/net/dev` and
`/sys/class/dmi/id`). Never run on Linux. `-readrate_initial_burst` needs
FFmpeg 7.1 or later.

## Run

    mkdir videos        # freely licensed H.264/HEVC/VP9 8-bit 4:2:0 files,
                        # and HEVC Main 10 HDR10 (PQ) files for the tonemaps
    sudo python3 -I server.py

Files the card cannot decode (AV1, ProRes, other codecs, 10-bit that is not
HDR10 HEVC) are skipped at startup, with a log line. Restart to rescan.

Environment: `DEMO_VIDEOS`, `DEMO_HLS` (use a tmpfs), `DEMO_PORT` (8080), `DEMO_BIND` (`::`),
`DEMO_MAX_SESSIONS` (20), `DEMO_MAX_AI` (6), `DEMO_MAX_TONEMAP` (2), `DEMO_MAX_4K` (6), `DEMO_MAX_4K_OUT` (2), `DEMO_MAX_MBPS` (400, total bitrate of live sessions), `DEMO_PER_IP` (1), `DEMO_SESSION_SECONDS` (180),
`DEMO_IDLE_SECONDS` (30), `DEMO_IFACE` (re0), `DEMO_TRUST_PROXY=1` (use
`X-Forwarded-For` when the peer is the local reverse proxy).

## Limits (the page has no password)

- Global session cap, one session per IP (a new start replaces the old one),
  hard time limit, and a kill when the client stops fetching segments.
- Visitors choose only from fixed presets; nothing they send reaches the
  command line.
- The stats endpoint exposes aggregate numbers only (no serial or model).
- Listens on `::` (IPv6 and IPv4) by default, no TLS, no reverse proxy:
  socket timeout of 10 s, at most `DEMO_MAX_CONNECTIONS` (200) connections,
  and sessions are counted per IPv4 address or per IPv6 /64.

## Load test (FreeBSD 16.0-CURRENT, 4-core A12, 8 GB, Quadra T1U)

Sources: Big Buck Bunny 1080p and 2160p (H.264, 30 fps), output H.264.
Columns: card decoder / encoder / scaler / AI load, then host CPU.

| Source -> output | Streams | min fps | Dec | Enc | Scl | AI | CPU |
|---|---|---|---|---|---|---|---|
| 1080p -> 720p | 8 / 16 / 24 | 30.1 | 12 / 26 / 44 % | 9 / 19 / 30 % | 3 / 7 / 18 % | 0 | 3 / 7 / 14 % |
| 1080p -> 1080p | 8 / 16 | 30.1 | 12 / 28 % | 21 / 44 % | 7 / 19 % | 0 | 4 / 7 % |
| 1080p -> 1080p | 24 | 29.8 | 85 % | 99 % | 86 % | 0 | 26 % |
| 2160p -> 1080p | 4 / 8 | 30.1 | 25 / 57 % | 11 / 24 % | 4 / 16 % | 0 | 2 / 4 % |
| 2160p -> 1080p | 16 | 18.3 | 97 % | 49 % | 67 % | 0 | 17 % |
| 2160p -> 1080p | 24 | 0 (3 of 24 not running) | 101 % | 50 % | 64 % | 0 | 20 % |
| 2160p -> 720p `hvsplus` | 4 / 6 | 30.1 | 25 / 44 % | 5 / 8 % | 2 / 8 % | 24 / 41 % | 3 / 4 % |

2160p output (preset `2160p`, 15 Mbit/s, upscaling allowed on purpose):

| 2160p source -> 2160p | Streams | min fps | Dec | Enc | Scl |
|---|---|---|---|---|---|
| | 2 / 4 / 6 / 8 | 30.1 / 30.1 / 26.7 / 21.7 | 12 / 33 / 86 / 79 % | 21 / 48 / 91 / 100 % | 7 / 26 / 100 / 100 % |

4K encode costs about 12 % of the encoder per stream, so 2160p output is
capped separately (`DEMO_MAX_4K_OUT`, 2).

Per stream: 4K decode about 7 % of the card, 1080p decode about 1.75 %,
1080p encode about 2.75 %, AI filter about 6 %. RAM about 70 MB per ffmpeg
process. Caps: 20 sessions, at most 6 with a 4K source, at most 2 with 2160p
output, at most 6 with the AI filter: worst case about 67 % decoder and 55 % encoder. Not measured: clients
fetching segments (network, HTTP serving).

## HDR to SDR: AI tonemap filters

Three filters convert an HDR10 picture to SDR with our own neural network on
the card's AI engine. How they were built, trained and measured:
[netint/ai/README.md](../../netint/ai/README.md). Copy the network binaries
from [netint/ai/models/](../../netint/ai/models/) into `models/`:

| Filter | Model file | fps per stream (1080p, card) |
|---|---|---|
| `tm48` quality | `tonemap_w48_int16_1920x1080.nb` | 27 |
| `tm32` faster | `tonemap_w32_int16_1920x1080.nb` | 37 |
| `tm48u8` uint8 inside | `tonemap_w48_uint8_1920x1080.nb` | 40 (deep reds turn orange) |

Chain for an HDR10 source (all on the card):

    -c:v h265_ni_quadra_dec -xcoder-params out=hw -i video
    -vf sidedata=mode=delete:type=... (mastering display, light level, Dolby Vision),
        [ni_quadra_scale + ni_quadra_pad to 1920x1080 when the source is another size,]
        ni_quadra_ai_pre=nb=models/tonemap_....nb,
        ni_quadra_scale=WxH:format=yuv420p,
        setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709
    -c:v <encoder> -xcoder-params "<rate control>:colorPri=1:colorTrc=1:colorSpc=1"

- Without the `sidedata` filters the encoder copies the HDR metadata into
  the SDR stream as SEI 137/144, and players treat it as HDR.
- On an HDR10 source, "No filter" cuts the 10-bit PQ samples to 8 bits
  without tonemapping and tags them BT.709: the washed-out picture the
  tonemaps fix. Without the tags the encoder keeps the source's BT.2020/PQ
  tags, and an HDR-capable browser shows the picture correctly. The other
  filters (hvsplus, GentleAIEnhance, ROI, flip) expect 8-bit SDR and are not
  offered; the page greys them out and the server refuses them.
- Output 1080p or lower only. The network works at 1080p, and an upscaled
  2160p output ran at 23.6 fps (H.264 and AV1), below the 24 fps source.
- Measured through the demo (1080p H.264, one stream): `tm48` 25.6 fps and
  47% AI load, `tm32` about 34 fps, `tm48u8` about 35 fps; output tagged
  BT.709, no SEI. With two tonemap streams the AI load is 94% and `tm48`
  runs at 25.7 fps: real time, with little margin (one short producer lag
  logged in testing).
- Browser test, `tm48`, H.265 1080p, Chrome on macOS, the whole 4.4 min
  video: startup 6.2 s. At 25.5 fps for a 24 fps source the initial 12 s
  burst cannot build up, so the player sits at the live edge: four 0.0 s
  "stalls" at segment boundaries in the first 30 s (not visible), producer
  lag for 78 s, then a 6 s lead. One real stall of 0.5 s at 218 s, 5 of 2022
  frames dropped. Watchable; `tm32` and `tm48u8` have more margin.
- One tonemap stream keeps one of the two NPU cores busy: two streams run at
  full speed, a third slows all of them (measured 1 to 4 sessions: 27, 53,
  53, 55 fps in total). Hence `DEMO_MAX_TONEMAP` (2). Tonemaps count in
  `DEMO_MAX_AI` too; running them next to hvsplus or ROI streams is not
  measured.
- Source used: *Sol Levante* (Netflix Open Content, CC BY 4.0), the HDR10
  ProRes master scaled to 1920x1080 and encoded with x265 (CRF 10, BT.2020
  PQ color tags, no mastering metadata: the master has none). The card
  cannot decode the ProRes `.mov` itself.

## Encoder settings (resolution, bitrate, rate control)

The page offers resolution (360p to 2160p, upscaling allowed), bitrate (Auto
or 0.5 to 25 Mbit/s; Auto is 0.8, 2.5, 5 and 15 Mbit/s per resolution) and a
rate-control mode, each mapped to NETINT encoder parameters (see "Rate
Control" in NETINT's docs, docs.netint.com/vpu/quadra/v5.9.0/llms/llms.txt):

| Mode | `-xcoder-params` | Measured, 1080p 4 Mbit/s H.264, per 6 s segment |
|---|---|---|
| CBR (steady) | `RcEnable=1:cuLevelRCEnable=1:bitrateMode=1:vbvBufferSize=500` | 3.5 to 4.5 Mbit/s |
| VBR (peaks allowed) | same with `vbvBufferSize=1000:vbvMaxRate=1.5 x bitrate` | 3.5 to 4.5 Mbit/s |
| Constant quality | `RcEnable=0:crf=23:lookAheadDepth=10:vbvBufferSize=500:bitrate=<ceiling>` | 1.5 to 3.6 Mbit/s |

All three work with H.264, H.265 and AV1, and with the ROI filter. Selections
are validated against fixed lists; the sum of the bitrates of live sessions
is limited by `DEMO_MAX_MBPS`. The caps in the load-test tables were measured
at the Auto bitrates: encoder load at 25 Mbit/s is not measured.

## Notes from testing (FreeBSD 16.0-CURRENT, firmware 5906tFr1)

- The encoder ignores `-b:v` unless `-xcoder-params RcEnable=1` is given
  (constant quality otherwise). Without it, 2160p segments were 25 to 35 MB
  per 6 s (33 to 45 Mbit/s) for a 15 Mbit/s target, which made browsers
  stall at segment boundaries. With it, segments follow the target. The load
  test tables above were measured before this was found: re-run them.
- `ffmpeg-netint` ignores SIGTERM (stock `ffmpeg` does not). The server
  stops it by writing `q` on stdin: exits in about 1 s and the card shows 0
  instances. SIGKILL leaves card instances allocated for about 10 s.
- `-progress` reports `bitrate=N/A` with HLS output, so the per-stream
  bandwidth is the bytes actually served to the client over the last 12 s.
- The server network figure is the `netstat -ibn` counters of `DEMO_IFACE`
  over about 10 s. HLS fetches segments in bursts.
- `ni_rsrc_mon -S -o json` is polled every 2 s by one thread, whatever the
  number of visitors.

## Not done yet

- Run as an unprivileged user: `/dev/nvme1*` are root-only and the
  libxcoder lock files in `/tmp` are root-owned (`NI_LCK_*`). Needs a devfs
  rule and a dedicated user, then a test that the card works without root.
- TLS reverse proxy (Caddy) on `elitedesk.cochard.me`, and a packet filter
  (`pf` is not loaded on the host at the moment).
- rc.d script, and HLS directory on tmpfs.
