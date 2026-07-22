---
name: moonshine-udp-pmtu-diagnosis-pattern
description: "When a game-streaming session dies with \"no video received\" but control/audio work, compare audio-size vs video-size UDP packet delivery in dual-side tcpdumps. Massive size-correlated loss = tunnel/PMTU issue, not a server bug."
metadata: 
  node_type: memory
  type: feedback
  originSessionId: f3e4c030-b385-40b6-994b-1c49dba1ffa4
  modified: 2026-07-22T15:49:09.173Z
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

Diagnostic pattern from the moonshine ser6→Mac utun4 run (2026-07):
- Control: 138/137 both sides — perfect parity.
- Audio (76-88 byte): 11383 sent, **4773 arrived (42% delivery)**.
- Video (1040 byte): 4097 sent, **0 arrived (100% loss)**.

Small packets get through with heavy loss; large packets 100% lost →
PMTU / burst-overrun on the tunnel. Reproducing without the tunnel
(same LAN test) confirms.

**Fix is client-side**: reduce Moonlight's `packetSize` config below
the tunnel's effective inner MTU. Sunshine servers don't get a say —
they just packetize to whatever the client requested in the RTSP
ANNOUNCE (`x-nv-video[0].packetSize`). WireGuard adds ~32-60 bytes
outer overhead, so a 1280-MTU tunnel typically wants packetSize ≤ 950.

**How to apply:** any streaming/telemetry protocol with size-asymmetric
UDP flows benefits from this diagnostic — it separates "server broken"
from "path broken" in one packet-capture pair. The signature is
size-correlated loss with control-flow parity intact.

Related: [[moonshine-freebsd-port]].
