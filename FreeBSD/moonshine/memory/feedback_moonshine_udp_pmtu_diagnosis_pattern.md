---
name: moonshine-udp-pmtu-diagnosis-pattern
description: "\"No video received\" while control/audio work is NOT a PMTU/packet-size drop by default. In the 2026-07 moonshine investigation, large video packets crossed the tunnel intact — the real failure was the CLIENT receive path. Disprove the PMTU pattern with dual-side captures before believing it."
metadata: 
  node_type: memory
  type: feedback
  originSessionId: f3e4c030-b385-40b6-994b-1c49dba1ffa4
  modified: 2026-07-25T00:00:00.000Z
---

**Corrected lesson (the original version of this memory taught a
disproven pattern — do not re-adopt it).**

Sunshine/Moonlight streaming has three UDP flows:
- **Video (47998)**: shard payload up to ~1024 bytes → IP frame ~1088.
  Bursty: an IDR keyframe emits ~20 shards in <10 ms.
- **Audio (48000)**: Opus 20 ms frames → 76-88 byte payloads. Steady.
- **Control (47999)**: ENet, ~40-100 byte payloads, low rate.

When the client reports **"no video ever received"** but pairing/RTSP
and audio work, the tempting hypothesis is "the tunnel drops the big
video packets (PMTU/packetSize)." **In this project that hypothesis was
WRONG.** A six-run paired-capture matrix (varying packetSize 704/912/
1040, codec, bitrate) showed 1040-byte video packets crossing the
1280-MTU WireGuard tunnel in the **tens of thousands** (9000-56000 per
run). The first capture that seemed to show "video 0 arriving" was an
**ephemeral-port race**, not a size drop. See STATE.md §16/§17.

**Why:** "large-UDP-on-a-tunnel = PMTU/size drop" is a *false pattern*.
Size-correlated loss is a hypothesis to DISPROVE first, not a
conclusion. When the server demonstrably sends and packets demonstrably
arrive at the client NIC but the app still logs "no video," the bug is
in the **client receive path** (here: Moonlight-qt's `recvUdpSocket()`),
not the network MTU. Also note: same-LAN video works fine (STATE.md
§20), which further rules out any send-side/packet-size cause.

**How to apply:** diagnose with paired dual-side captures before
touching packetSize:
1. **Server**: `sudo tcpdump -i <wan-iface> -n -w server.pcap
   'udp and (port 47998 or port 47999 or port 48000)'`
2. **Client**: same, on the client's route-to-server interface (may be
   a tunnel like `utunN` with MTU < 1500).
3. Run a ~30s repro. Compare per-port counts AND per-length counts
   (`tcpdump -r ... -nn | grep -oE 'length [0-9]+' | sort -n | uniq -c`).
4. **Capture the client's PING packets too** — they reveal the client's
   real ephemeral source port, so you can confirm the host was sending
   to the port the client is actually listening on (defeats the
   ephemeral-port-race false positive).
5. Take a **second** capture at a different time — ephemeral ports
   rotate; one snapshot can hide a port-mapping race.

If big video packets DO arrive on the client interface but the app
never emerges them from its recv call, stop chasing the network layer:
it is a client-side / framing bug. Only if packets genuinely fail to
arrive (confirmed by paired captures) should you consider reducing the
client's `packetSize` below the tunnel's effective inner MTU.

Related: [[moonshine-freebsd-port]].
