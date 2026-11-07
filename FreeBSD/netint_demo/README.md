# NETINT Quadra live demo

Web page that starts a hardware transcode on the Quadra card and shows card,
CPU, RAM and network load. Python standard library only (plus `hls.min.js`
1.7.4 from jsdelivr, vendored in `static/`).

Pipeline per visitor (everything but packaging runs on the card):

    ffmpeg-netint -re -stream_loop -1 -c:v <h264|h265|vp9>_ni_quadra_dec -xcoder-params out=hw -i video
        -vf ni_quadra_scale=WxH[,ni_quadra_hvsplus | ni_quadra_flip] -c:v h264_ni_quadra_enc -b:v N
        -f hls (6 s segments, keyframe every 2 s)

## Run

    mkdir videos        # put freely licensed H.264/HEVC/VP9 8-bit 4:2:0 files here
    sudo python3 -I server.py

Files the card cannot decode (10-bit, AV1, other codecs) are skipped at
startup, with a log line. Restart to rescan.

Environment: `DEMO_VIDEOS`, `DEMO_HLS` (use a tmpfs), `DEMO_PORT` (8080), `DEMO_BIND` (`::`),
`DEMO_MAX_SESSIONS` (20), `DEMO_MAX_AI` (6), `DEMO_MAX_4K` (6), `DEMO_MAX_4K_OUT` (2), `DEMO_PER_IP` (1), `DEMO_SESSION_SECONDS` (180),
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

## Notes from testing (FreeBSD 16.0-CURRENT, firmware 5906tFr1)

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
