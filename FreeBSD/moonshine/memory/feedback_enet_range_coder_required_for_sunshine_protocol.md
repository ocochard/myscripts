---
name: enet-range-coder-required-for-sunshine-protocol
description: "Sunshine's control-stream ENet host enables the built-in adaptive order-2 PPM range coder via `enet_host_compress_with_range_coder()`. Moonlight clients send range-coded packets; a server without a matching compressor drops them. LOW-PRIORITY conformance gap in the moonshine port — never blocked streaming (audio still decoded)."
metadata: 
  node_type: memory
  type: feedback
  originSessionId: f3e4c030-b385-40b6-994b-1c49dba1ffa4
  modified: 2026-07-22T15:49:20.416Z
---

The Moonlight/Sunshine control channel (UDP 47999) runs on **ENet**,
and Sunshine hosts unconditionally enable ENet's built-in adaptive
order-2 PPM range coder on the control host:

```c
enet_host_compress_with_range_coder(host);
```

Moonlight clients (Moonlight-qt, Moonlight iOS, etc.) assume this
and send **range-coded** compressed packets on the control channel.
A Sunshine-compatible server that doesn't register a matching
compressor drops those packets and logs
`received compressed packet but no compressor configured`. This is a
conformance gap, not a hard requirement — in the moonshine port it
never blocked streaming (see severity note below).

**Why:** moonshine (Rust port of Sunshine) uses `tokio-enet 0.1.0`,
which has a `Compressor` trait but ships **no implementation**. Its
`HostConfig::default()` gives you `compressor: None`. The result
looks like a broken control channel from the client side — even
though the raw UDP path works.

**Rust fix:** pull in [`rusty_enet::RangeCoder`](https://docs.rs/rusty_enet/latest/rusty_enet/struct.RangeCoder.html)
(byte-compatible transpile of ENet's C range coder, `impl
Compressor` after a small trait adapter if API shapes differ) and
call `host.set_compressor(Some(Box::new(RangeCoder::new())))`
right after `Host::new(config)`.

**How to apply:** any Rust port of a Sunshine/GameStream-shaped
protocol needs to register this compressor. Also applies to any
ENet-based server whose clients enable range-coder compression
(the C API side does it in one line).

**Severity: LOW-PRIORITY backlog — this was never "the wall."** Not
fatal by itself: moonshine still delivered audio through the tunnel
with this warning firing every ~500ms. It IS a real protocol
conformance gap and should be fixed for correctness, but it did not
block streaming. (Any claim that it "eventually causes
ControlStreamStopped under load" is unverified speculation, not
observed behavior.)

Related: [[moonshine-freebsd-port]],
[[moonshine-udp-pmtu-diagnosis-pattern]].
