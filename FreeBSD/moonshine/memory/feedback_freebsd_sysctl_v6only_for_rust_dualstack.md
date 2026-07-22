---
name: freebsd-sysctl-v6only-for-rust-dualstack
description: "FreeBSD defaults `net.inet6.ip6.v6only=1`, so a Rust `TcpListener::bind(\"[::]:port\")` on FreeBSD listens IPv6-only, not dual-stack. Set `net.inet6.ip6.v6only=0` (session or /etc/sysctl.conf) to get `tcp46` sockets."
metadata: 
  node_type: memory
  type: feedback
  originSessionId: f3e4c030-b385-40b6-994b-1c49dba1ffa4
  modified: 2026-07-22T15:48:53.734Z
---

On Linux, `bind()` on a `::` socket accepts both IPv6 and (via
IPv4-mapped `::ffff:0.0.0.0/96`) IPv4. On FreeBSD, the default
`net.inet6.ip6.v6only=1` disables that mapping — an IPv6 socket
listens ONLY on IPv6.

This bites Rust services that use `SocketAddr::new(IpAddr::V6(...), port)`
or bind literal `"[::]:port"` — they compile identically on Linux
and FreeBSD, but the FreeBSD binary won't accept IPv4 clients.
`sockstat -l` shows `tcp6` (IPv6-only) instead of `tcp46` (dual).

**Why:** hit on moonshine (2026-07): its `moonshine.toml` `address = "::"`
resulted in three IPv6-only listeners; IPv4 clients couldn't reach it.

**Fix:**
- Session-only: `sudo sysctl net.inet6.ip6.v6only=0`
- Persistent: add `net.inet6.ip6.v6only=0` to `/etc/sysctl.conf`
- Verify: `sockstat -l -P tcp -p <port>` should show `tcp46`.

**How to apply:** whenever a Rust (or C/Go/Python) service on FreeBSD
should serve both IPv4 and IPv6 from a single `[::]` socket, either
set the sysctl OR bind two sockets explicitly (`0.0.0.0` + `::` with
`IPV6_V6ONLY`). The sysctl approach is one line for the whole host;
per-socket `IPV6_V6ONLY=0` via `setsockopt` is more portable but not
always exposed by high-level APIs (Rust's `TcpListener` doesn't
expose it directly — needs socket2 or manual `libc::setsockopt`).

Global side-effect: setting the sysctl affects every new IPv6-bound
socket on the machine. Fine for a dedicated host, worth flagging on
a shared box.
