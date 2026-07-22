---
name: enet-range-coder-required-for-sunshine-protocol
description: "Sunshine's control-stream ENet host enables the built-in adaptive order-2 PPM range coder via `enet_host_compress_with_range_coder()`. Moonlight clients assume this and send range-coded packets. A Sunshine-compatible server MUST register a compatible compressor or drop those packets."
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
Any Sunshine-compatible server that doesn't register a matching
compressor will drop those packets and log something like
`received compressed packet but no compressor configured`.

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

Not fatal by itself if audio/video packet paths are otherwise
working — moonshine still delivered audio through the 42%-loss
tunnel with this warning firing every ~500ms. But it IS a real
protocol conformance gap and eventually causes ControlStreamStopped
under load.

Related: [[moonshine-freebsd-port]],
[[moonshine-udp-pmtu-diagnosis-pattern]].
