# FreeBSD `options RSS` — what it does, who uses it

This note explains the `options RSS` kernel option in FreeBSD, how it
differs from "RSS in the NIC", how it changes the `cxgbe` driver in
particular, and which other drivers and kernel subsystems also have
`#ifdef RSS` code paths.

> **Status: DRAFT — NOT PEER-REVIEWED.** This document was written by
> the agent and not reviewed.
> is *plausible* but not *validated by FreeBSD kernel maintainers*. At
> least one factual error has already been found in companion material
> from the same session; analogous errors almost certainly remain
> here. Treat it as a starting point for your own reading, not a
> finished tutorial.

## 1. Two different things called "RSS"

| | Without `options RSS` | With `options RSS` |
|---|---|---|
| Hardware RSS in the NIC | yes — NIC still spreads packets across RX queues using a Toeplitz hash | yes — same |
| Kernel-wide RSS coordination | no — the kernel has no notion of which CPU "owns" a flow | yes — kernel maintains its own indirection table, hash key, hash-type set, and CPU↔bucket mapping |

The option itself is one line in `sys/conf/options:480`:

```
RSS    opt_rss.h
```

That `#define` gates a large body of code in `sys/net/rss_config.c` and
exposes an API (`rss_getnumbuckets()`, `rss_getcpu()`, `rss_getkey()`,
`rss_gethashconfig()`, `rss_get_indirection_to_bucket()`,
`rss_hash2bucket()`, `rss_hash2cpuid()`, `rss_m2cpuid()`, …) that
drivers and the netstack can consult.

### What the infrastructure provides

From `sys/net/rss_config.c:50-75, 182-185`:

- A **kernel-owned indirection table** (up to 128 entries, per the
  Microsoft RSS spec) — each entry holds a CPU id
  (`rss_table_entry.rte_cpu`). Buckets are assigned to CPUs
  round-robin at boot.
- A **kernel-owned 40-byte Toeplitz key** that drivers are expected to
  push into hardware so the NIC's hash matches the kernel's software
  hash (used when traffic must be re-hashed after decap, reassembly,
  etc.).
- A **canonical set of hash types** the system wants
  (`RSS_HASHTYPE_RSS_IPV4`, `…_TCP_IPV4`, `…_UDP_IPV4`, IPv6 variants).
- The promise that **TCP/UDP PCB groups are aligned 1-to-1 with RSS
  buckets**, so a flow lookup on the "right" CPU hits a per-CPU lock
  with no contention.

Without `options RSS`, hardware still spreads packets to multiple
queues, but the kernel does not try to make "the CPU that runs the
interrupt" equal to "the CPU where the connection state lives" —
packets can land on any CPU and chase the PCB across cores.

### Known limitations (from the code itself)

- **Key is not randomized** — `sys/net/rss_config.c:163` and
  `271-275` have `XXXRW: not yet` TODO comments. Every host uses the
  same Microsoft default key (which is also Chelsio T5's firmware
  default).
- **UDP 4-tuple is off by default, and is new** — `sys/net/rss_config.c:153`,
  gated by tunable `net.inet.rss.udp_4tuple`. The tunable itself was
  added in FreeBSD 16-CURRENT (commit 283ef95d167, 2026-03-01,
  PR #2057) and is not present in 15.x or earlier.
  With the default (`udp_4tuple=0`), UDP falls back to the 2-tuple
  hash on (src IP, dst IP) — see `sys/netinet/in_rss.c:128-139`. That
  still distributes UDP across queues as long as your traffic spans
  many src/dst IP pairs (a DNS resolver talking to many external
  servers, a router forwarding for many subscribers, etc.). It only
  collapses to a single CPU for flows between a single IP pair —
  e.g. all UDP inside one IPsec/WireGuard/GRE/VXLAN tunnel, or one
  GTP-U PDP session. Enable `udp_4tuple=1` when those tunneled
  workloads dominate; otherwise the default is usually fine.
- **Assumes contiguous CPU ids** — `sys/net/rss_config.c:213-215`
  walks `0..mp_maxid` and has an `XXXRW` warning about "incorrect
  assumptions regarding contiguity of this set elsewhere".
- IPv6 RSS cleanup is still on the TODO list; it works but is not
  actively polished.

## 2. How `options RSS` changes `cxgbe`

Everywhere in `sys/dev/cxgbe/` that has `#ifdef RSS`, the driver stops
making its own decisions and starts asking the kernel.

### a) Queue count is forced to match the kernel's bucket count

`t4_main.c:13775-13790` (`tweak_tunables()`):

```c
if (t4_ntxq < 1) {
#ifdef RSS
    t4_ntxq = rss_getnumbuckets();
#else
    calculate_nqueues(&t4_ntxq, nc, NTXQ);
#endif
}
if (t4_nrxq < 1) {
#ifdef RSS
    t4_nrxq = rss_getnumbuckets();
#else
    calculate_nqueues(&t4_nrxq, nc, NRXQ);
#endif
}
```

So `hw.cxgbe.nrxq` / `ntxq` defaults change: instead of "function of
CPU count and a hard-coded ceiling", they become exactly
`rss_getnumbuckets()`. If you override these tunables and they end up
`!= rss_getnumbuckets()`, attach logs a loud warning
(`t4_main.c:7270-7273`):

```c
if (vi->nrxq != nbuckets) {
    CH_ALERT(vi, "nrxq (%d) != kernel RSS buckets (%d);"
        "performance will be impacted.\n", vi->nrxq, nbuckets);
}
```

### b) Hardware indirection table is programmed from the kernel table

`t4_main.c:7269-7291` (`vi_full_init()`):

```c
for (i = 0; i < vi->rss_size;) {
#ifdef RSS
    j = rss_get_indirection_to_bucket(i);
    j %= vi->nrxq;
    rxq = &sc->sge.rxq[vi->first_rxq + j];
    vi->rss[i++] = rxq->iq.abs_id;
#else
    for_each_rxq(vi, j, rxq) {
        vi->rss[i++] = rxq->iq.abs_id;
        if (i == vi->rss_size) break;
    }
#endif
}
```

Without RSS: naive round-robin fill of the NIC's indirection table.
With RSS: each NIC table slot is wired to the queue that corresponds
to the kernel's bucket for that slot — NIC and kernel agree on which
queue a given hash bucket belongs to.

### c) Hash key copied from the kernel into the NIC

`t4_main.c:7080-7092` (`write_global_rss_key()`):

```c
rss_getkey((void *)&raw_rss_key[0]);
for (i = 0; i < nitems(rss_key); i++)
    rss_key[i] = htobe32(raw_rss_key[nitems(rss_key) - 1 - i]);
t4_write_rss_key(sc, &rss_key[0], -1, 1);
```

The hardware Toeplitz hash and any software-side hash now use the
same key, so if the stack re-hashes a packet (after IPsec decap,
fragment reassembly, lagg, etc.) it lands in the same bucket the NIC
would have chosen.

### d) Hash type set is taken from the kernel and translated to firmware bits

`t4_main.c:7171-7232` — `hashconfig_to_hashen()` translates
`RSS_HASHTYPE_RSS_TCP_IPV4` / `…_UDP_IPV4` / `…_IPV6` etc. into the
Chelsio firmware's `F_FW_RSS_VI_CONFIG_CMD_*` flags. If firmware
refuses some combination, the driver forces a superset and logs which
extra hash types were enabled (`t4_main.c:7318-7334`).

Without RSS the driver uses a hard-coded baseline (TCP/UDP 4-tuple +
IP 2-tuple for v4 and v6).

### e) RX queue MSI-X vector pinned to the bucket's CPU

`t4_main.c:7032-7053` (`t4_setup_intr()`):

```c
#ifdef RSS
int nbuckets = rss_getnumbuckets();
#endif
...
#ifdef RSS
if (q < vi->nrxq)
    bus_bind_intr(sc->dev, irq->res, rss_getcpu(q % nbuckets));
#endif
```

This is the headline behaviour for a router: with `options RSS`,
every cxgbe RX MSI-X interrupt is pinned to the CPU the kernel says
owns that bucket. Without the option, `bus_bind_intr()` is never
called and the scheduler is free to move interrupt handling around.

### f) Netmap path also obeys the kernel table

`t4_netmap.c:520-581` (`cxgbe_netmap_simple_rss()`) — when toggling
into/out of netmap mode, the indirection table is reprogrammed using
the same `rss_get_indirection_to_bucket()` calls, so a netmap app
sees the same flow→queue mapping the kernel expects.

## 3. Other NIC drivers with `#ifdef RSS`

`cxgbe` is the most thorough consumer, but many others have RSS
code paths. The pattern is consistent — query
`rss_getnumbuckets()` for queue count, `rss_get_indirection_to_bucket()`
to program the hardware LUT, `rss_getkey()` to sync the Toeplitz key,
`rss_getcpu()` to bind interrupts, `rss_gethashconfig()` to align
hash types.

| Driver | Family | Key files |
|---|---|---|
| `ixl` | Intel 40G XL710 | `sys/dev/ixl/ixl.h:101`, `sys/dev/ixl/ixl_pf_iflib.c:846` (LUT), `sys/dev/ixl/ixl_txrx.c:48` |
| `iavf` | Intel virtual function | `sys/dev/iavf/iavf_lib.h:45`, `iavf_txrx_iflib.c`, `iavf_vc_common.c` |
| `ice` | Intel 100G E810 | `sys/dev/ice/ice_rss.h:45` |
| `e1000` (em / igb) | Intel 1G | `sys/dev/e1000/if_em.h:75`, `if_em.c:3376` (RETA), `em_txrx.c`, `igb_txrx.c` |
| `igc` | Intel 2.5G I225 | `sys/dev/igc/if_igc.c:35,1900`, `igc_txrx.c:33` |
| `ixgbe` | Intel 10G 82599/X550 | `sys/dev/ixgbe/ixgbe_rss.h:37,40` (stub wrappers) |
| `mlx5en` | Mellanox ConnectX-4+ | `sys/dev/mlx5/mlx5_en/mlx5_en_main.c:2820`, `mlx5_en_tx.c`, `mlx5_en_hw_tls_rx.c:98,104` (TLS RX channel pick), `mlx5_core/mlx5_eq.c:485` |
| `sfxge` | Solarflare | `sys/dev/sfxge/sfxge.c:178`, `sfxge_intr.c:199` (`rss_getcpu`), `sfxge_rx.c:1119` (LUT), `sfxge_tx.c:898` (`rss_hash2cpuid` for TX) |
| `ena` | AWS Elastic NA | `sys/dev/ena/ena_rss.h:40`, `ena_rss.c`, `ena_datapath.c` |
| `vmxnet3` | VMware | `sys/dev/vmware/vmxnet3/if_vmx.c:49,1144,1167,1535` (uses `rss_gethashalgo()` + LUT) |
| `hn` (netvsc) | Hyper-V | `sys/dev/hyperv/netvsc/if_hn.c:101,192,2170,6561,6685` (rings via `rss_getcpu`, capped by `rss_getnumbuckets`) |
| `enic` | Cisco VIC | `sys/dev/enic/if_enic.c:31-32`, `enic_txrx.c:31-32` |
| `mana` | Microsoft Azure | `sys/dev/mana/mana_en.c:52-53` |
| `aq` | Aquantia/Marvell | `sys/dev/aq/aq_main.c:68` (iflib-based) |
| `axgbe` | AMD/Broadcom | `sys/dev/axgbe/if_axgbe_pci.c` |
| `dpaa2` | NXP/ARM | `sys/dev/dpaa2/dpaa2_io.c:63-64,447` (`rss_getcpu` for DPIO placement) |
| `liquidio` | Cavium/Marvell | `sys/dev/liquidio/lio_rss.{h,c}`, `lio_core.c`, `lio_rxtx.c`, `base/cn23xx_pf_device.c` |

**iflib itself** (`sys/net/iflib.c:6553`) caps queue count to
`rss_getnumbuckets()` when RSS is configured, which means every
iflib-converted driver inherits that behaviour for free even without
extra `#ifdef RSS` blocks.

Drivers with **no** RSS-specific code paths still get hardware RSS
(packets spread across queues), they just don't coordinate CPU
affinity with the kernel — which somewhat defeats the point of
enabling `options RSS` system-wide if your NICs are in this category.

## 4. Kernel subsystems with `#ifdef RSS`

`options RSS` is not only a driver knob — it changes substantial
parts of the network stack.

### Core RSS infrastructure
- `sys/net/rss_config.{c,h}` — the API itself.
- `sys/net/toeplitz.c` — Toeplitz hash implementation, included by
  `rss_config.h`.
- `sys/net/route.h:136` — `fib4_calc_packet_hash`,
  `fib6_calc_packet_hash` become RSS-aware route lookups when
  `#ifdef RSS`.

### L2 / virtual interfaces
- `sys/net/if_ethersubr.c:76,698` — ether netisr uses
  `NETISR_POLICY_CPU` and `rss_m2cpuid()` to dispatch each frame to
  the bucket-owning CPU before L3 processing.
- `sys/net/if_epair.c:74-77,206-234,936-970` — without RSS, epair
  allocates a single taskqueue and `epair_select_queue()` always
  returns bucket 0 (serialised on one CPU). With RSS, one taskqueue
  is created per CPU and pinned, and `epair_select_queue()` selects
  the bucket via `rss_m2bucket()` / `rss_soft_m2cpuid_v4()` so
  forwarding scales across cores — a meaningful throughput win for
  VNET jails on SMP boxes.
- `sys/net/if_gre.c:74-75,83-84,883,894` — GRE flowid computed via
  `rss_hash_ip4_2tuple()` / `rss_hash_ip6_2tuple()` so encapsulated
  flows hash consistently.

### IPv4
- `sys/netinet/ip_input.c:66` — IPv4 input dispatched via RSS-aware
  netisr.
- `sys/netinet/ip_output.c:66,1278` — exposes `IP_RECVRSSBUCKETID`
  socket option so userland can read the bucket id of received
  packets.
- `sys/netinet/ip_reass.c:50` — fragment reassembly tagged for the
  right CPU on completion.
- `sys/netinet/in_pcb.c:82` — PCB group lookup uses RSS buckets so
  TCP/UDP control-block searches are per-CPU.
- `sys/netinet/in_rss.c:46,354` — `rss_soft_m2cpuid_v4()` (the
  netisr callback) plus IPv4 hash-tuple generators.
- `sys/netinet/tcp_input.c:82`, `tcp_timer.c:50`, `udp_usrreq.c:70` —
  PCB-group coordination.
- `sys/netinet/tcp_hpts.c:127-129,219,1016` — HPTS (TCP high-precision
  pacing) binds worker threads to RSS CPUs, picks the worker via
  `rss_hash2cpuid()` of the flow.
- `sys/netinet/tcp_ratelimit.c:713,1062` — rate-limited packets get
  `M_HASHTYPE_RSS_TCP_IPV4/V6` so downstream stays on the same CPU.

### IPv6
- `sys/netinet6/ip6_input.c` (many lines) — registers a dedicated
  `NETISR_IPV6_DIRECT` handler so packets that need to be re-injected
  after defragmentation/decap land on the right CPU instead of going
  through the generic ip6 handler again.
- `sys/netinet6/in6_rss.c:46,379` — `rss_soft_m2cpuid_v6()` and IPv6
  hash-tuple generators.
- `sys/netinet6/frag6.c:437,886,903` — reassembled v6 datagrams are
  tagged with an `ip6_direct_ctx` m_tag and dispatched via
  `NETISR_IPV6_DIRECT`.
- `sys/netinet6/ip6_output.c:97`, `udp6_usrreq.c:97` — RSS-aware
  output / socket option support.

### Kernel TLS
- `sys/kern/uipc_ktls.c:61-63,116,414` — KTLS worker threads are
  bound to RSS CPUs and each socket's worker is chosen via
  `rss_hash2cpuid()`. Without RSS, KTLS workers are not pinned.

### Summary of the layered effect

Enabling `options RSS` is really three things at once:

1. **Hardware level** (NIC driver `#ifdef RSS`): program the LUT and
   key, pin IRQs to CPUs.
2. **Netisr/software level** (ether / ip / ip6 / frag6): re-dispatch
   packets to the bucket-owning CPU after any step that loses the
   original RX CPU (encap, decap, reassembly, bridge).
3. **PCB/socket level** (in_pcb, tcp_hpts, ktls, ratelimit): keep
   per-connection state on the same CPU as the bucket so the lookup
   and the work all happen with warm caches and uncontended locks.

If the NIC driver in use does not have `#ifdef RSS`, only layers 2
and 3 are active and the benefit is much smaller — packets still
arrive on whichever CPU the NIC interrupt happens to fire on, then
get re-dispatched.

## 5. Trade-offs for BSDRP

**Wins**
- Real CPU affinity for flow processing — IRQ, per-queue softirq, and
  PCB live on the same core, keeping L1/L2 cache warm.
- Hardware and software hashes agree (matters for any path that
  re-hashes: IPsec, fragments, lagg, netmap, GRE).
- Deterministic queue placement — easier to reason about CPU load
  with `top -SHP`. Packets within the same stream always hit the
  same queue, so per-flow latency stays stable.
- **epair(4) becomes per-CPU.** Without RSS, `if_epair.c:936-970`
  creates a single taskqueue and `epair_select_queue()` returns
  bucket 0 for every packet — all forwarding through an epair pair
  is serialised on one CPU. With RSS, one taskqueue is created and
  pinned per CPU, and `epair_select_queue()` hashes via
  `rss_m2bucket()` / `rss_soft_m2cpuid_v4()` to spread traffic
  across them (`if_epair.c:206-234`). This is the
  big win for VNET jails wired with epair on SMP boxes.

**Costs / sharp edges**
- `nrxq` / `ntxq` defaults change to `rss_getnumbuckets()`. Anything
  that hard-codes these (tunables, tuning docs, test scripts) needs
  re-checking, or you'll trip the "nrxq != kernel RSS buckets"
  warning. For best results tune so RX/TX queue counts match the CPU
  count (which is what `rss_getnumbuckets()` will give you anyway,
  capped at 128).
- Hard-coded Toeplitz key — fine in practice but worth noting.
- UDP defaults to 2-tuple (src IP, dst IP) hashing. That distributes
  across CPUs when traffic involves many IP pairs (DNS resolver
  fan-out, a router serving many subscribers), but pins all UDP
  inside a single tunnel (IPsec, WireGuard, GRE, VXLAN underlay, a
  GTP-U PDP session) onto one CPU. On 16-CURRENT you can flip
  `net.inet.rss.udp_4tuple=1` (loader tunable, `CTLFLAG_RDTUN`) to
  hash UDP on the full 4-tuple instead — useful when tunnelled
  workloads dominate. Not available on 15.x or earlier.
- The implementation still has `XXXRW` TODOs from the original
  Juniper-funded work and assumes contiguous CPU ids — fine on a
  normal router box, watch out on weird NUMA / hotplug topologies.
- Only drivers with explicit `#ifdef RSS` blocks (table in §3) get
  the IRQ-pinning win. Other drivers ride on iflib's queue-count cap
  but won't pin interrupts.

For a Chelsio-based router specifically `options RSS` does exactly
what you'd want. The main thing to check after enabling it is that
`hw.cxgbe.nrxq` / `ntxq` aren't being overridden somewhere to a value
that fights `rss_getnumbuckets()`, and that `net.inet.rss.udp_4tuple`
is set if UDP is a meaningful share of the traffic mix.
