---
name: moonshine-udp-pmtu-diagnosis-pattern
description: "When a game-streaming session dies with \"no video received\" but control/audio work, compare audio-size vs video-size UDP packet delivery in dual-side tcpdumps. Massive size-correlated loss = tunnel/PMTU issue, not a server bug."
metadata: 
  node_type: memory
  type: feedback
  originSessionId: f3e4c030-b385-40b6-994b-1c49dba1ffa4
  modified: 2026-07-22T16:24:23.609Z
---

Sunshine/Moonlight streaming has three UDP flows:
- **Video (47998)**: shard payload up to 1024 bytes → IP frame ~1088.
  Bursty: an IDR keyframe emits ~20 shards in <10 ms.
- **Audio (48000)**: Opus 20 ms frames → 76-88 byte payloads. Steady.
- **Control (47999)**: ENet, ~40-100 byte payloads, low rate.

When the client reports "no video ever received" but pairing/RTSP
worked, do NOT chase moonshine bugs. Chase the network path:

1. **Server side**: `sudo tcpdump -i <wan-iface> -n -w server.pcap
   'udp and (port 47998 or port 47999 or port 48000)'`
2. **Client side**: same, on the client's route-to-server interface
   (may be a tunnel like `utunN` with MTU < 1500).
3. Run a repro stream (~30s).
4. Compare per-port packet counts on each side. Also count by frame
   length: `tcpdump -r ... -nn | grep -oE 'length [0-9]+' | sort -n | uniq -c`.

**Important caveat from the 2026-07 investigation**: this pattern
FALSELY implicated the tunnel on moonshine's first pcap. A second
round of six paired captures (varying packetSize, codec, bitrate)
showed the same "video 0 arriving" result was an ephemeral-port
race in that first capture; subsequent runs with 704/912/1040-byte
video packets ALL delivered 9000-56000 packets across the same
tunnel. So the pattern is a useful FIRST hypothesis but ALWAYS
verify with:
1. A second capture at a different time (ephemeral ports rotate).
2. A capture that INCLUDES the client's PING packets so you can
   confirm the ephemeral source port lined up with what the host
   was sending to.
3. A dual-side capture — one moment of "server sends, client
   doesn't see" can hide either a routing problem OR a
   port-mapping race, and only paired captures distinguish them.

**Fix (when this pattern is real)**: client-side. Reduce Moonlight's
`packetSize` config below the tunnel's effective inner MTU. Sunshine
servers don't get a say — they just packetize to whatever the client
requested in the RTSP ANNOUNCE (`x-nv-video[0].packetSize`).
WireGuard adds ~32-60 bytes outer overhead, so a 1280-MTU tunnel
typically wants packetSize ≤ 950.

**Fix (when this pattern is a false positive from ephemeral-port
race)**: don't chase network layer. The Moonlight-qt problem where
"no video traffic was ever received" WHILE utun4 shows 10K+ packets
arriving is a client-side or framing bug, not a tunnel MTU bug.

**How to apply:** any streaming/telemetry protocol with size-asymmetric
UDP flows benefits from this diagnostic — it separates "server broken"
from "path broken" in one packet-capture pair. The signature is
size-correlated loss with control-flow parity intact.

Related: [[moonshine-freebsd-port]].
