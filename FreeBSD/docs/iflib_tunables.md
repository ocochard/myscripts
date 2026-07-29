# iflib driver parameters

Reference for the `dev.<driver>.<unit>.iflib.*` and `net.iflib.*` sysctl trees
exposed by the FreeBSD **iflib** network-driver framework. iflib is the common
infrastructure shared by `igb`, `em`, `ix`, `ixl`, `ice`, `vmx`, `bnxt`, `iavf`
and others, so every iflib-based NIC gets the identical set of knobs and
counters described here.

Definitions, CTL flags and defaults are taken from `sys/net/iflib.c` and
`sys/net/mp_ring.c` (FreeBSD 16.0-CURRENT, `main-n287204`). Verify against your
own tree; the tree evolves.

Examples use `igb0`; substitute your interface (`dev.ix.1.iflib...`, etc.).

## How to read the CTL flags

| Flag       | Meaning                                                                 |
|------------|------------------------------------------------------------------------|
| `RD`       | read-only (a live counter or state; cannot be set)                     |
| `RWTUN`    | read-write **and** a boot-time tunable (`/boot/loader.conf`) — writable at runtime |
| `RDTUN`    | read-only at runtime; settable **only** as a loader tunable, applied at attach |

`RDTUN` knobs must be set in `/boot/loader.conf` (or the device hint) **before**
the driver attaches. Writing them via `sysctl` after boot fails or is ignored.
`RWTUN` knobs can be changed live with `sysctl`, but for a NIC that is already
up most of the queue-count / MSI-X ones only take effect on the next
attach/reinit, so treat them as loader tunables too unless noted.

---

## Per-interface tunables — `dev.<driver>.<unit>.iflib.*`

These are the knobs you actually turn. All are per-interface.

### Transmit path

#### `tx_abdicate` — `RWTUN`, default `0`
> "cause TX to abdicate instead of running to completion"

Controls who drives the TX ring after a packet is enqueued.

- `0` (source default): the enqueueing thread runs the mp_ring consumer
  **inline**, pushing the doorbell/DMA-start in its own context. Lowest latency
  for a single sender.
- `1`: the sender only enqueues; the actual ring drain is **abdicated** to the
  TX taskqueue (gtaskqueue) thread. This batches transmits from many senders and
  moves the doorbell work off the caller's CPU, which can help under heavy
  multi-producer contention but adds a context switch on the TX path.

Whether `1` helps is workload- and hardware-dependent. See the APU2 forwarding
bench in [this repo](https://github.com/ocochard/netbenches/blob/master/AMD_GX-412TC_4Cores/Intel_i210AT/txabdicate/results/fbsd16-n311215/README.md):
on a 4-core AMD GX-412TC forwarding minimum-size frames through i210AT igb NICs,
`tx_abdicate=1` produced **no operationally meaningful change** (IPv4 no
significant difference; IPv6 ~1% inside the noise band). Measure before trusting.

#### `simple_tx` — `RDTUN`, default `0`
> "use simple tx ring"

Selects a stripped-down TX ring path (no mp_ring multi-producer machinery, fewer
per-packet branches). Intended for the common single-queue / low-overhead case.
Loader-tunable only — it changes how the TX ring is set up at attach, so it
cannot be flipped at runtime. When enabled, the mp_ring `r_*` counters and some
batching behaviour do not apply.

#### Interaction: `simple_tx` vs `tx_abdicate`

**They do not compose — `simple_tx` wins and makes `tx_abdicate` dead code.**

The two select *different* `if_transmit` handlers at attach, so only one TX path
ever runs:

- `simple_tx=0` (default): `if_transmit` is the normal iflib path
  (`iflib_if_transmit` → `iflib_encap` → `ifmp_ring_enqueue(..., abdicate)`).
  This is the **only** path that reads `tx_abdicate`: the sysctl value is passed
  into the mp_ring enqueue to choose inline drain (`0`) vs. handoff to the TX
  taskqueue (`1`).
- `simple_tx=1`: at attach the handler is swapped to `iflib_simple_transmit`,
  which locks the queue, encaps, rings the doorbell directly and reclaims inline.
  It **never touches the mp_ring (`ift_br`) and never reads `tx_abdicate`.**

| `simple_tx` | `tx_abdicate` | Effect                                              |
|-------------|---------------|-----------------------------------------------------|
| `0`         | `0`           | normal path, drain **inline** in caller context     |
| `0`         | `1`           | normal path, drain **abdicated** to TX taskqueue    |
| `1`         | `0` or `1`    | simple path; **`tx_abdicate` ignored entirely**     |

`tx_abdicate` is a property of the mp_ring consumer. `simple_tx` removes the
mp_ring from the TX path, so there is no soft-ring drain to abdicate and the knob
has nothing to act on. Consequences:

- With `simple_tx=1`, the `txq<N>.r_*` counters (`r_abdications`, `r_enqueues`,
  …) stay flat — they count mp_ring activity and the mp_ring is bypassed.
- `tx_defer_mfree` **does** still work under `simple_tx` (the simple path
  allocates its own deferred-free mbuf array and honours it). Only `tx_abdicate`
  is neutralized.

The two knobs also encode opposite bets: `tx_abdicate=1` targets *many* producers
contending on one queue (batch/offload the drain), while `simple_tx=1` is the
minimal single-producer path with no soft ring at all. Setting both is not an
error, but `tx_abdicate` has no effect.

#### `tx_defer_mfree` — `RWTUN`, default `0`
> "Free completed transmits outside of TX ring lock"

- `0`: completed TX mbufs are freed while holding the TX ring lock.
- `1`: freeing of completed mbufs is deferred to **outside** the ring lock,
  shortening the critical section. Can reduce lock contention on busy TX queues
  at the cost of holding freed mbufs slightly longer. Applied live to all TX
  queues when written.

#### `tx_reclaim_thresh` — `RWTUN`, default `0`
> "Number of TX descs outstanding before reclaim is called"

Number of in-flight (unreclaimed) TX descriptors that triggers a descriptor
reclaim. `0` uses the driver's normal reclaim timing. A non-zero value forces
earlier/more-aggressive reclaim, which can keep the ring from filling under
bursty load but costs extra reclaim passes. **Bounded: must be
`<= isc_ntxd[0] / 2`** (half the TX ring size); larger values are rejected with
`EINVAL`. Applied live to all TX queues.

#### `tx_reclaim_ticks` — `RWTUN`, default `0`
> "Number of ticks before a TX reclaim is forced"

Time-based companion to the threshold: force a TX reclaim after this many ticks
even if the descriptor threshold has not been reached. `0` disables the
time-forced reclaim. **Bounded: must be `<= hz`**; larger values are rejected
with `EINVAL`. Applied live to all TX queues.

### Queue / descriptor sizing

#### `override_ntxqs` — `RWTUN`, default `0`
> "# of txqs to use, 0 => use default #"

Force the number of TX queues. `0` = driver default (usually one per core up to
the NIC limit).

#### `override_nrxqs` — `RWTUN`, default `0`
> "# of rxqs to use, 0 => use default #"

Force the number of RX queues. `0` = driver default.

#### `override_qs_enable` — `RWTUN`, default `0`
> "permit #txq != #rxq"

By default iflib requires an equal number of TX and RX queues. Set to `1` to
allow asymmetric counts (needed when `override_ntxqs != override_nrxqs`).

#### `override_ntxds` — `RWTUN` (string), default empty (`0`)
> "list of # of TX descriptors to use, 0 = use default #"

Override the TX descriptor ring depth(s). Comma-separated list (one entry per
ring for drivers with multiple TX descriptor rings). `0` in a slot = driver
default. e.g. `dev.igb.0.iflib.override_ntxds=2048`.

#### `override_nrxds` — `RWTUN` (string), default empty (`0`)
> "list of # of RX descriptors to use, 0 = use default #"

RX descriptor ring depth(s), same format as `override_ntxds`. Note some drivers
have multiple RX rings (free-list + completion): the list gives one value per
ring.

#### `rx_budget` — `RWTUN`, default `0`
> "set the RX budget"

Maximum number of RX packets processed per RX poll before yielding. `0` = use
the built-in default budget. Raising it lets an RX queue drain more per pass
(higher throughput, potentially worse latency fairness); lowering it yields more
often.

### CPU / interrupt placement

#### `disable_msix` — `RWTUN`, default `0`
> "disable MSI-X (default 0)"

`1` forces the driver off MSI-X and onto MSI/legacy interrupts. Mostly a
debugging / broken-platform workaround; MSI-X is required for multiqueue.

#### `core_offset` — `RDTUN`, default `0` (`CORE_OFFSET_UNSPECIFIED`)
> "offset to start using cores at"

CPU index at which iflib starts binding this interface's queues. Use it to keep
two NICs from stacking all their queues on the same low-numbered cores. Loader
tunable only (queue-to-CPU binding happens at attach).

#### `separate_txrx` — `RDTUN`, default `0`
> "use separate cores for TX and RX"

`1` places TX and RX queues of the same index on **different** CPU cores instead
of sharing one core per queue pair. Can help when TX and RX both saturate a
core; costs more cores. Loader tunable only.

#### `use_logical_cores` — `RDTUN`, default `0`
> "try to make use of logical cores for TX and RX"

`1` allows queue placement onto SMT/hyperthread logical cores rather than
restricting to physical cores. Loader tunable only.

#### `use_extra_msix_vectors` — `RDTUN`, default `0`
> "attempt to reserve the given number of extra MSI-X vectors during driver load
> for the creation of additional interfaces later"

Reserve N spare MSI-X vectors at load time so additional interfaces (e.g. VFs,
dynamically created sub-interfaces) can be created later without re-allocating.
Loader tunable only.

---

## Per-interface read-only fields — `dev.<driver>.<unit>.iflib.*`

#### `driver_version` — `RD`, string
> "driver version"

The driver's version string (`isc_driver_version`).

#### `allocated_msix_vectors` — `RDTUN`, default `0`
> "total # of MSI-X vectors allocated by driver"

Number of MSI-X vectors the driver actually obtained.

---

## Per-TX-queue counters — `dev.<driver>.<unit>.iflib.txq<N>.*`

All read-only (`RD`). One node per TX queue. Useful for diagnosing TX stalls,
mbuf problems and ring pressure.

### mp_ring (soft transmit ring) counters — from `sys/net/mp_ring.c`

| Sysctl          | Meaning                                                        |
|-----------------|----------------------------------------------------------------|
| `r_enqueues`    | # of enqueues to the mp_ring for this queue                    |
| `r_drops`       | # of drops in the mp_ring (ring full — packets discarded)      |
| `r_starts`      | # of normal consumer starts in the mp_ring                     |
| `r_stalls`      | # of consumer stalls (consumer could not make progress)        |
| `r_restarts`    | # of consumer restarts                                         |
| `r_abdications` | # of consumer abdications (handoffs to the taskqueue — rises when `tx_abdicate=1` is doing its job) |
| `ring_state`    | soft ring state string (producer/consumer indices + flags)     |

`r_drops` climbing means the software TX ring is overflowing (host can't feed the
NIC fast enough or the ring is too small). `r_stalls`/`r_restarts` indicate
consumer-side contention. `r_abdications` is the direct evidence of `tx_abdicate`
handing work to the taskqueue.

### Descriptor-ring / mbuf counters

| Sysctl               | Meaning                                                   |
|----------------------|-----------------------------------------------------------|
| `txq_pidx`           | producer index (hardware ring)                            |
| `txq_cidx`           | consumer index                                            |
| `txq_cidx_processed` | consumer index seen by the credit update                 |
| `txq_in_use`         | descriptors currently in use                             |
| `txq_processed`      | descriptors processed for clean                          |
| `txq_cleaned`        | total descriptors cleaned                                |
| `mbuf_defrag`        | # of times `m_defrag()` was called                       |
| `mbuf_defrag_failed` | # of times `m_defrag()` failed                           |
| `m_pullups`          | # of times `m_pullup()` was called                       |
| `no_desc_avail`      | # of times no TX descriptors were available              |
| `tx_map_failed`      | # of times DMA map failed                                |
| `txd_encap_efbig`    | # of times `txd_encap` returned `EFBIG` (too many segs)  |
| `no_tx_dma_setup`    | # of times map failed for a reason other than `EFBIG`    |
| `cpu`                | CPU core this queue is bound to                          |

High `mbuf_defrag` / `txd_encap_efbig` points at oversized mbuf chains (often TSO
or scatter-gather issues). Persistent `no_desc_avail` means the ring is too
small or reclaim is too slow (see `tx_reclaim_thresh`/`tx_reclaim_ticks`).

---

## Per-RX-queue fields — `dev.<driver>.<unit>.iflib.rxq<N>.*`

| Sysctl                 | Meaning                          |
|------------------------|----------------------------------|
| `cpu`                  | CPU core this RX queue is bound to |
| `rxq_fl<M>.pidx`       | free-list producer index         |
| `rxq_fl<M>.cidx`       | free-list consumer index         |
| `rxq_fl<M>.credits`    | free-list credits available      |
| `rxq_fl<M>.buf_size`   | receive buffer size for this free list |

`rxq_fl<M>` is a per-RX-queue **free list** (buffer pool); a queue may have more
than one. All read-only.

---

## Global iflib tunables — `net.iflib.*`

System-wide, affect every iflib interface. All `RW` (runtime-writable; not
per-interface).

#### `net.iflib.timer_default` — `RW`, default `500`
> "number of ticks between iflib_timer calls"

Interval (in ticks) of the periodic per-queue watchdog/reclaim timer. The code
initialises it to `hz / 2` at load (hence `500` on a `hz=1000` kernel). Lowering
it makes the housekeeping timer fire more often (faster watchdog / reclaim,
more overhead).

#### `net.iflib.no_tx_batch` — `RW`, default `0`
> (disable TX batching)

`1` disables the TX doorbell batching heuristic, ringing the doorbell more
eagerly instead of accumulating descriptors. Set automatically in some netmap
paths. Normally leave at `0`.

#### `net.iflib.min_tx_latency` — `RW`, default `0`
> (favour latency over batching on TX)

`1` biases the TX path toward lower latency by ringing the hardware doorbell
sooner rather than batching for throughput. Trades a bit of CPU/PCIe efficiency
for reduced send latency.

---

## Quick recipes

Set boot-time tunables (persist across reboot) in `/boot/loader.conf`:

```
# Force 4 TX/RX queues and deeper rings on igb0, abdicate TX to taskqueue
dev.igb.0.iflib.override_ntxqs="4"
dev.igb.0.iflib.override_nrxqs="4"
dev.igb.0.iflib.override_ntxds="2048"
dev.igb.0.iflib.override_nrxds="2048"
dev.igb.0.iflib.tx_abdicate="1"
```

Change a runtime (`RWTUN`) knob live:

```
sysctl dev.igb.0.iflib.tx_abdicate=1
sysctl dev.igb.0.iflib.tx_defer_mfree=1
sysctl net.iflib.min_tx_latency=1
```

Watch for TX ring overflow across all queues of igb0:

```
sysctl dev.igb.0.iflib | grep -E 'r_drops|r_stalls|no_desc_avail'
```

## See also

- `~/netbenches/AMD_GX-412TC_4Cores/Intel_i210AT/txabdicate/results/fbsd16-n311215/README.md`
  — measured `tx_abdicate` on/off on an APU2 (no meaningful effect on that platform).
- `sys/net/iflib.c` — authoritative sysctl definitions (`iflib_add_device_sysctl_pre` / `_post`).
- `sys/net/mp_ring.c` — mp_ring `r_*` counters.
- iflib(4), iflib(9) man pages.
