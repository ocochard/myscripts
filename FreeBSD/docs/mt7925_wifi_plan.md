# MT7925 Wi-Fi on FreeBSD (HP ZBook Ultra G1a)

Status, test log and plan for the MediaTek MT7925 (Filogic 360, PCI `14c3:7925`)
on FreeBSD 16.0-CURRENT.
Hardware context: [HP.ZBook.Ultra.G1a.md](../HP.ZBook.Ultra.G1a.md).
Patch: [mt7925_page_pool.patch](mt7925_page_pool.patch).

## Status (2026-11-12)

| Step | Stock tree | With the patch + `compat.linuxkpi.skb.mem_limit=1` |
|---|---|---|
| PCI attach, firmware files read | yes | yes |
| MCU replies (patch semaphore, HW/SW version) | no, every message times out | yes |
| ROM patch download | no | yes |
| WM (RAM code) firmware start | no | yes, `WM Firmware Version: ____000000, Build Time: 20260106153120` |
| Registers with net80211 (`net.wlan.devices: mt79250`) | no | yes |
| `ifconfig wlan0 create`, scan | no | yes, 2.4 GHz and 5 GHz APs seen |
| WPA2 association, DHCP | no | yes, 2.4 GHz 11ng HT20 and 5 GHz 11ac VHT80 |
| Throughput (iperf3, TCP, 10 s) | no | TX 232 to 254, RX 79 Mbit/s (5 GHz ch 100, Linux 577/426), see [Throughput](#throughput) |
| Disconnect, reconnect, BSS switch, `kldunload` | no | yes (needs the idr fix below) |
| Failure handling | `kldload` hangs forever, reboot needed | attach fails with ENXIO, `kldunload` works |

The scan reports rates up to 54M; that is net80211's scan list column, not a measured link rate.
Throughput is far below the PHY rate (130M on 2.4 GHz, 360M on 5 GHz), see
[Throughput](#throughput).

## Why the stock driver does not work

FreeBSD has the mt76 sources (`sys/contrib/dev/mediatek/mt76`) and module
Makefiles (`sys/modules/mt76/core`, `sys/modules/mt76/mt7925`), but
`sys/modules/Makefile` does not list `mt76`, so nothing is built.
Building the modules by hand and loading them shows separate problems,
each hiding the next one (a fourth one shows up once traffic flows).

### 1. No page pool: the driver gets no receive buffers

Linux network drivers get their receive (RX) buffers from a *page pool*:
a per-queue allocator that hands out whole pages, already mapped for DMA,
and takes them back when the network stack is done with the packet.
mt76 uses it for every RX ring, including the ring that carries replies from
the chip's microcontroller (MCU).

LinuxKPI (FreeBSD's Linux compatibility layer for drivers) has a page pool
since July 2026 (bz@, e4795d3dbee7 and e591a7662143), but all of it sits under
`#ifdef PAGE_IS_LKPI_PAGE`.
That macro is never defined: it waits for a rework where LinuxKPI gets its own
`struct page` instead of aliasing FreeBSD's `vm_page`.
Without it `linuxkpi_page_pool_alloc_frag()` returns NULL, the driver prints
`!!! LinuxKPI page pool not supported yet!!!`, the RX rings stay empty, and
every MCU command times out:

```
mt79250: Message 00000010 (seq 1) timeout
mt79250: Failed to get patch semaphore
mt79250: hardware init failed
```

Why the page itself cannot hold the data: the LKPI branch stores the pool
pointer and the DMA address *inside* `struct page` (`p->pp`, `p->dma_addr`).
A `vm_page` has no such fields.

The patch keeps that information in a side table instead: a hash table keyed
by the page pointer, with one small record per page handed out
(device, DMA address, direction, mapped or not), protected by one mutex.

| Operation | What the side table does |
|---|---|
| `page_pool_alloc_frag()` | `alloc_page()`, DMA-map it if the pool asked for it (`PP_FLAG_DMA_MAP`), sync for the device (`PP_FLAG_DMA_SYNC_DEV`), insert the record |
| `page_pool_get_dma_addr()` | look the page up, return the stored DMA address |
| `page_pool_put_full_page()` | remove the record, unmap, free the record, free the page |

Two details matter:

- mt76 finds the pool of a page with `pp_page_to_nmdesc(page)->pp`, a cast
  that only makes sense on Linux. On FreeBSD that pointer is garbage, so
  `put_full_page` ignores its `pp` argument and uses the table.
- The skb free path must give pool pages back to the pool, or the record and
  its DMA mapping leak. mt76 builds RX skbs two ways: page fragments
  (`skb_add_rx_frag`) and a head built directly on a pool page
  (`napi_build_skb`). Both now go through `page_pool_put_full_page()` when the
  skb is marked for recycling (`skb_mark_for_recycle`).

Side note: the existing LKPI branch never unmaps the DMA mapping when a page
is returned; the side-table branch does.

### 2. Init failure hangs `kldload` forever

FreeBSD added a `wait_for_completion(&dev->mt76.drv_start_complete)` to
`mt7925_register_device()` so that `kldload` returns only after the init work
finished.
The matching `complete()` is only reached on success (`mac80211.c`, after
`MT76_STATE_REGISTERED` is set).
When init fails, the work returns early, nobody calls `complete()`, and
`kldload` sleeps forever in state D while holding the linker lock: every later
`kldload` or `kldunload` blocks too, and only a reboot recovers.

The patch adds `mt7925_init_done()`, called on each early-return path of the
init work, and makes `mt7925_register_device()` return `-ENXIO` when the
device did not reach `MT76_STATE_REGISTERED`.
mt7915, mt7921 and mt7996 have the same wait and the same bug; the patch only
fixes mt7925.

### 3. Firmware chunks fail to DMA-map above 4 GB

With the page pool in place, the MCU answers, but the ROM patch download fails:

```
mt79250: Failed to send patch: -12
```

Instrumenting `mt76_dma_tx_queue_skb_raw()` showed `dma_map_single()` failing on
every 4096-byte firmware chunk, each starting at page offset 0x40, and
`compat.linuxkpi.lkpi_pci_nseg1_fail` counted 20 failures (10 retries, 2 per
retry).

The chain:

1. mt7925 declares a 32-bit DMA mask.
2. The skb data comes from `__kmalloc()`, which can return memory above 4 GB.
3. The bus_dma layer must then copy the buffer through bounce pages below 4 GB.
4. A 4096-byte buffer at offset 0x40 spans two pages, so it bounces into two
   separate pages: two DMA segments.
5. LinuxKPI's `dma_map_single()` only accepts one segment and fails.

LinuxKPI already has a knob for this case: the loader tunable
`compat.linuxkpi.skb.mem_limit=1` makes skb data come from `contigmalloc()`
below 4 GB (physically contiguous, no bounce).
With it, `lkpi_pci_nseg1_fail` stays at 0 and the firmware loads.

A related latent bug: `dma_map_single()` maps `vtophys()` of the buffer start
for the whole length, which is only correct if the buffer is physically
contiguous. `__kmalloc()` of more than a page does not guarantee that.

### 4. Station teardown panics in idr_remove()

Forcing a switch from one BSS to another (`wpa_cli bssid` + `reassociate`)
made LinuxKPI refuse the transition
(`lkpi_iv_newstate: error 95 during state transition 2 (AUTH) -> 2 (AUTH)`)
and tear the station down, which panicked:

```
__mtx_lock_sleep
idr_remove (id=-1)          linux_idr.c:276
mt76_tx_status_skb_get
mt76_wcid_cleanup
__mt76_sta_remove
mt76_sta_state
lkpi_80211_mo_sta_state
lkpi_sta_auth_to_scan
```

mt76 cleans the same station entry (`wcid`) twice, which is fine on Linux:
there an idr has no lock and `idr_destroy()` only frees the tree, leaving an
empty idr that can still be searched.
LinuxKPI's `idr_destroy()` also destroys the idr's mutex, so the second
cleanup locks a destroyed mutex and faults.
LinuxKPI already guards a second `idr_destroy()` with
`IDR_LOCK_INITALIZED()`; the patch adds the same guard to `idr_remove()`,
`idr_find()` and `idr_get_next()`, which then return NULL like on an empty
idr. With it, the same BSS switch logs error 95 and reconnects, no panic.
`idr_for_each()` needs nothing: it does not lock and a destroyed idr has no
tree.

## Throughput

iperf3 to a wired host, 10 s, TCP unless noted, Mbit/s:

| Link | `hw_crypto=0` TX / RX | `hw_crypto=1` TX / RX |
|---|---|---|
| 2.4 GHz ch 11, HT20, PHY 130M, -49 dBm | 27.8 / 26.2 | 23.1 / 35.3 |
| 5 GHz ch 36, VHT80, PHY 360M, about -73 dBm | 22.4 / 35.4 | 26.0 / 51.7 |
| 2.4 GHz, UDP TX at 300M offered | | 66.7 delivered |

- With `compat.linuxkpi.80211.hw_crypto=0` (the default) CCMP runs in
  software and `linux_80211.c` disables RX A-MPDU
  (`ifconfig -v wlan0` shows `-ampdurx`), because modern firmware cannot
  aggregate frames it cannot decrypt.
  The loader tunable `compat.linuxkpi.80211.hw_crypto=1` turns `ampdu` on in
  both directions and lifts RX by 35 to 45%.
- TX stays at 23 to 26 Mbit/s with TCP whatever the link, but UDP pushes 67
  Mbit/s on the 2.4 GHz HT20 link: the radio path is not the limit, the TCP
  TX path is. Not found yet.
- `lkpi_ic_addba_request: mo_ampdu_action returned AMPDU_TX_START_IMMEDIATE`
  is informational: LinuxKPI logs it and continues with net80211's ADDBA
  request.
- The 5 GHz AP FreeBSD used is the middle-distance unit of the mesh (about
  -73 dBm). The unit in the same room has its 5 GHz radio on channel 100,
  which FreeBSD never listed in a scan; FreeBSD defaulted to
  `regdomain FCC country US` while Linux runs `country FR: DFS-ETSI`.

### Linux comparison (same laptop, Ubuntu, Linux 7.0.0-43, `mt7925e`)

Same mesh of three AP units: one in the same room (`6b:85` 2.4 GHz,
`6b:86` 5 GHz), one at middle distance (`6b:a3`, `6b:a4`), one far
(`6b:a6`, `6b:a7`). Linux pinned to each BSSID with
`nmcli con modify cocacola 802-11-wireless.bssid`.

| AP | Linux link | Linux TCP TX / RX | Linux UDP TX | FreeBSD link | FreeBSD TCP TX / RX | FreeBSD UDP TX |
|---|---|---|---|---|---|---|
| `6b:85` 2.4 GHz, near, -48 dBm | HE, 287M | 152 / 139 | 143 | HT20, 130M | 23 / 35 | 67 |
| `6b:a4` 5 GHz ch 36, far, -67 dBm | HE80, 324M | 199 / 195 | 174 | VHT80, 360M | 26 / 52 | not run |
| `6b:86` 5 GHz ch 100, near, -49 dBm | HE80, 961M | 577 / 426 | not run | VHT80, 360M (`country FR`) | 41.5 / 74.9 | not measured |

- net80211 has no 802.11ax (HE), so FreeBSD links at HT/VHT rates.
- UDP TX efficiency is similar on both (about half the PHY rate), so the
  radio path works; TCP TX at a third of UDP is FreeBSD-specific (Linux TCP
  matches its UDP).
- Channel 100 shows up on FreeBSD after `ifconfig wlan0 country FR`
  (default was `regdomain FCC country US`, which hid it).

### Where the TCP TX time goes (2.4 GHz near AP, `hw_crypto=1`)

| Check | Result | Meaning |
|---|---|---|
| mt76 debugfs `tx_stats`, before and after a 10 s TCP TX run | `BA miss count: 0`, A-MPDU length histogram +45000 in a large bin | firmware builds aggregates and gets block acks; no sign of a sequence number / BA window mismatch |
| iperf3 sender `Retr` | 0 | TCP sees no loss |
| iperf3 `-P 4` | 34 Mbit/s total, same as 1 stream | not a per-connection window limit |
| ping during the run | 390 ms average (5 ms idle) | a deep queue fills: the link drains TCP at about 33 Mbit/s while it drained UDP at 67 |

UDP offered at 60 Mbit/s on the 5 GHz channel 100 link also stalls at
42 to 47 Mbit/s without loss, so the limit is not TCP-specific.

### TX path trace: the hardware starves (5 GHz channel 100, `hw_crypto=1`)

DTrace over a 10 s TCP run, then a 10 s UDP run:

| Function (thread) | TCP | UDP |
|---|---|---|
| `lkpi_80211_txq_task` (`thread taskq`) | 508 runs, 126 ms total, max 1.8 ms | 51345 runs (1 frame each), 194 ms |
| `lkpi_80211_txq_tx_one` | 38710 frames, 81 ms total | 51387 frames, 114 ms |
| `mt76_txq_schedule` (`mt76-tx` worker) | 251916 calls | 315980 calls |
| `mt76_dma_rx_poll` (`ndev napi taskq`) | 66681 | 69316 (TX completions come back through the RX ring) |

The CPU is idle and LinuxKPI hands frames to mt76 quickly. But sampling
`mt76/xmit-queues` during the TCP run shows the data DMA ring (`WFDMA0`)
holding only 0 to 3 frames, and `mt76/acq` shows the firmware AC queues
empty, while the ping RTT shows a 390 ms backlog upstream.

The cause is in how mt76 meters frames without an airtime estimate:
`mt76_txq_send_burst()` stops when `wcid->non_aql_packets >=
MT_MAX_NON_AQL_PKT` (16), and a frame counts as non-AQL when
`info->tx_time_est == 0` (`tx.c:309`). On Linux, mac80211's Airtime Queue
Limits fill `tx_time_est` for every frame, so this cap only applies to
special frames. LinuxKPI never sets `tx_time_est`, so on FreeBSD every frame
counts and a station never has more than 16 frames in flight.

Test with `MT_MAX_NON_AQL_PKT` raised to 256 (test only):

| Cap | TCP TX | TCP RX |
|---|---|---|
| 16 (stock) | 41.5 | 74.9 |
| 256 | 69.4 | 77.9 |

TX gains 67%, still far from Linux (577): there is a further limit.

### Second TX limit: `skb.mem_limit=1` makes every skb a `contigmalloc()`

With the cap at 4096 (effectively off), one TCP TX run right after a module
reload reached 230 Mbit/s, then later runs fell back to 35 to 42 Mbit/s and
the kernel logged `lkpi_80211_txq_tx_one: skb alloc failed 0 + 162`.
DTrace on `contigmalloc()` during an 8 s TCP TX run at 41.8 Mbit/s:

| | |
|---|---|
| calls | 29352 (one per skb) |
| calls taking 2 to 4 ms | 2844 |
| total time | 7.4 s of the 8 s run |
| failures | 3 |

`compat.linuxkpi.skb.mem_limit=1` (the workaround for blocker 3) allocates
every skb data buffer with `contigmalloc()` below 4 GB, rounded up to a power
of two. Once low memory fragments, each allocation scans for free pages and
takes milliseconds, on the single `taskqueue_thread` that carries all TX
frames (and all RX frames into net80211). That explains the 230 Mbit/s on
fresh memory and the decay afterwards.

Fix direction: drop the global tunable; keep data buffers below 4 GB only
for devices whose DMA mask needs it, from a cached allocator (a UMA zone of
DMA32 pages for skbs up to a page, `contigmalloc()` only for the rare larger
ones such as firmware chunks), or make the DMA mapping of a page-crossing
buffer work without `contigmalloc()`.

### The allocator fix

`linuxkpi_alloc_skb()` with `compat.linuxkpi.skb.mem_limit` set now takes
the skb data buffer from one of five UMA zones (256, 512, 1024, 2048 and
4096 bytes on amd64) instead of calling `contigmalloc()` every time:

- UMA keeps freed buffers in per-CPU caches, so a typical TX skb (about
  1.6 KB, the 2048 zone) is reused without touching the page allocator.
- Each zone gets its slabs from `kmem_alloc_contig_domainset()` limited to
  the same physical range as before (below 4 GB for `mem_limit=1`), so the
  device's 32-bit DMA mask still holds without bouncing.
- Each zone is created with an alignment equal to its item size, the trick
  busdma's own `busdma_bufalloc` uses on arm/arm64 (not built on amd64), so
  an item never crosses a page boundary and maps as one DMA segment.
- Larger buffers (firmware chunks of 4096 bytes plus a header) still use
  `contigmalloc()`; there are a few per firmware load.
- The free side finds the zone again from `skb->end - skb->head`, the size
  the buffer was allocated with (both are only set at allocation, and copied
  together in `__skb_linearize`).

Measured (5 GHz channel 100, `hw_crypto=1`, 10 s TCP runs):

| mt76 non-AQL cap | TCP TX | TCP RX | `contigmalloc()` calls in an 8 s TX run |
|---|---|---|---|
| 16 (stock) | 36.2 | 66.8 | 0 (zones served 56k + 30k requests, no failure) |
| 4096 (test) | 227, 160, 237 (three runs) | 78.2 | not measured |

Throughput no longer decays with time. With the stock cap TX is now held
by the 16-frame non-AQL limit alone.

### TX skb leak: `napi_consume_skb()` is a stub

With the cap at 4096 the `skbuff` and `lkpiskb 2048` zones showed 490000
items in use after a few runs, about 1 GB, and the count did not drop when
idle. mt7925 completes TX frames from its TX-free event: mt76 passes a
`free_list` in the TX status, LinuxKPI appends the skb to it, and
`mt7925_mac_tx_free()` frees the list with `napi_consume_skb(skb, 1)`.
LinuxKPI's `napi_consume_skb()` (also on current main) is
`SKB_TRACE(); SKB_TODO();`: it frees nothing. The patch makes it call
`consume_skb()` (after a NULL check), which is what it does on Linux minus
the NAPI skb cache. After the fix, 556000 more allocations left the in-use
counts unchanged; TCP TX 165, 276, 195 Mbit/s.

### Airtime estimate for dequeued frames

`linuxkpi_ieee80211_tx_dequeue()` now sets `info->tx_time_est` on every
frame it hands to the driver, as mac80211 does in `ieee80211_tx_dequeue()`:
frame length divided by the node's net80211 TX rate
(`ieee80211_node_get_txrate_kbit()`, 6 Mbit/s if unknown), stored in the
10-bit field in 4 µs units. mt76 only tests the field for non-zero, so this
alone lifts the 16-frame non-AQL cap.

Two limits of this version:

- The rate is net80211's view of the link; LinuxKPI does not update
  `ni_txrate` from the firmware's rate control, so the estimate is rough.
- LinuxKPI has no Airtime Queue Limits. On Linux, mac80211 stops dequeuing
  once a station has about 5 to 12 ms of estimated airtime in flight. Here,
  frames flow until mt76 stops the queue because the DMA ring is nearly
  full, so the queue (and latency) moves into the hardware ring: ping under
  load was 30 to 60 ms with the cap raised, against 4 ms idle. Real AQL in
  LinuxKPI (pending airtime per station and AC, decremented on TX status,
  dequeue refused above the limit) is the follow-up.

Measured with the stock mt76 (cap 16, no driver edit), 5 GHz channel 100:

| Run | TCP TX | ping under load avg / max |
|---|---|---|
| 1 | 244 Mbit/s | 75 / 152 ms |
| 2 | 254 Mbit/s | 59 / 105 ms |
| 3 | 232 Mbit/s | 40 / 77 ms |
| TCP RX | 78.8 Mbit/s | 24 / 42 ms |

Same modules without the estimate: 36 Mbit/s TX. Skb zones back to 0 in use
after 636747 allocations: no leak.

### RX: TCP capped, UDP is not

| Test (5 GHz ch 100, cap 4096) | Result |
|---|---|
| TCP RX, 1 stream / 4 streams | 79 / 84 Mbit/s total, sender `Retr 0` |
| UDP RX at 400 Mbit/s offered | 274 Mbit/s received (28% loss) |
| ping during TCP RX | 22 ms average (4 ms idle) |
| `mt76_dma_rx_poll` | 0 or 1 frames per poll, 110k polls for 70k frames |
| `ieee80211_input_mimo` | runs on `thread taskq`, the same thread as TX |

The radio and RX path carry 274 Mbit/s; TCP RX is held by its ACK stream,
which goes out through the same TX path and the same `taskqueue_thread`
that spends its time in `contigmalloc()`.
The proper fix belongs in LinuxKPI: an airtime estimate per frame (what
mac80211's `ieee80211_calc_expected_tx_airtime()` does) plus AQL-style
limits, rather than a bigger driver constant.

Background on sequence numbers: `mt7925_mac_write_txwi()` hands the host's
802.11 sequence number to the firmware (`MT_TXD3_SN_VALID`) only for frames
marked `IEEE80211_TX_CTL_INJECTED`; the firmware numbers all others itself,
while LinuxKPI assigns net80211's sequence number
(`ieee80211_output_seqno_assign()`) and takes the ADDBA start sequence from
net80211 (`params.ssn = tap->txa_start`). Linux avoids the question with
802.3 encapsulation offload (`SUPPORTS_TX_ENCAP_OFFLOAD`), where the
firmware owns the whole header. The counters above show no BA trouble, but
this is worth keeping in mind.

### Reading the mt76 debugfs on FreeBSD

The modules build without debugfs by default; `MT76_DEBUGFS=1` and
`MT7925_DEBUGFS=1` turn it on, and two upstream bugs then stop
`if_mt7925.ko` from loading:

1. `sys/modules/lindebugfs/Makefile` does not list
   `debugfs_create_devm_seqfile` (added in 3521cce445d4) in `EXPORT_SYMS`,
   so the symbol stays local (`nm` shows `t`) and is undefined for callers.
2. `mt7925/debugfs.c` has no `MODULE_DEPEND(mt7925_pci, lindebugfs, ...)`
   (only mt76_core declares one), and the kernel linker resolves symbols only
   through a module's own dependencies: `debugfs_create_file undefined`.

Since lindebugfs could not be swapped while amdgpu used it, the test carried
a renamed private copy of the helper in mt76_core instead of fixing 1.
Then:

```sh
sudo kldload lindebugfs
mkdir -p /tmp/debug && sudo mount -t lindebugfs lindebugfs /tmp/debug
sudo dd if=/tmp/debug/mt76/tx_stats bs=65536 2>/dev/null
```

`cat` fails on these files with EOPNOTSUPP, `dd` with a large block works.

3. The `mt76` debugfs directory survives `kldunload`: mt76 creates it under
   `wiphy->debugfsdir` (the debugfs root on FreeBSD), and nothing removes it
   the way cfg80211 does on Linux. After a reload, reading an old entry
   panics (page fault in `seq_read()` calling a show function from the
   unloaded module). Reboot, or never read the old entries after a reload.


## How to reproduce

Tested on the old-base worktree `~/freebsd-mt76` (6e87733f73ff), because a full
`buildkernel` on newer main failed in the ZFS module for an unrelated reason.
The page pool code is compiled into the kernel (`options COMPAT_LINUXKPI`), so
the test needs a kernel, not just modules.

```sh
cd ~/freebsd-mt76
git apply -p0 ~/myscripts/FreeBSD/docs/mt7925_page_pool.patch
env MAKEOBJDIRPREFIX=$HOME/obj-mt76 make -j32 buildkernel \
    KERNCONF=GENERIC-NODEBUG WITHOUT_CCACHE_BUILD=yes
sudo env MAKEOBJDIRPREFIX=$HOME/obj-mt76 make installkernel \
    KERNCONF=GENERIC-NODEBUG INSTKERNNAME=kernel.mt76

# mt76 is not in sys/modules/Makefile: build it against that kernel
K=$HOME/obj-mt76$HOME/freebsd-mt76/amd64.amd64/sys/GENERIC-NODEBUG
for d in core mt7925; do
  (cd sys/modules/mt76/$d && env CCACHE_DISABLE=1 \
     MAKEOBJDIRPREFIX=$HOME/obj-mt76-mod make WITHOUT_CCACHE_BUILD=yes \
     SYSDIR=$HOME/freebsd-mt76/sys KERNBUILDDIR=$K)
done
sudo install -m 555 $HOME/obj-mt76-mod$HOME/freebsd-mt76/amd64.amd64/sys/modules/mt76/core/mt76_core.ko \
    $HOME/obj-mt76-mod$HOME/freebsd-mt76/amd64.amd64/sys/modules/mt76/mt7925/if_mt7925.ko \
    /boot/kernel.mt76/

sudo pkg install wifi-firmware-mt76-kmod-mt7925
sudo nextboot -k kernel.mt76 -e compat.linuxkpi.skb.mem_limit=1 \
    -e compat.linuxkpi.80211.hw_crypto=1
# WPA2 config: ctrl_interface=/var/run/wpa_supplicant + network={ssid psk}
sudo shutdown -r now

# after the reboot
sudo kldload mt76_core if_mt7925
sudo ifconfig wlan0 create wlandev mt79250 up
sudo ifconfig wlan0 scan
sudo wpa_supplicant -B -i wlan0 -c /etc/wpa_supplicant.conf
sudo dhclient wlan0
```

## Alternative: OpenBSD mwx(4)

OpenBSD's native `mwx(4)` (claudio@, `if_mwx.c` rev 1.49, ISC licence)
supports MT7921 and MT7925, but 11n, 11ac and 6 GHz are under `#if NOTYET`:
it is 11a/b/g only, 54 Mbit/s at best.
Its firmware is the linux-firmware files renamed.
A port would follow the iwx(4) precedent (2ad0f7e91582, 2025), but it would
start slower than what the LinuxKPI driver already scans with.

## Plan

1. Throughput: find why TCP RX stays at 70 to 80 Mbit/s while UDP RX
   reaches 274, add AQL limits in LinuxKPI for latency under load (40 to
   75 ms now), then suspend/resume.
2. Regdomain: set the country automatically (`wlan_regdomain`/`country` in
   rc.conf) and document it; `country FR` was enough for channel 100.
3. The wiki's "LinuxKPI IDR updates" was at least the teardown panic fixed
   above; audit the other idr entry points (`idr_replace`, `idr_alloc*`) for
   the same use-after-destroy.
4. Fix the DMA mapping properly instead of relying on the loader tunable:
   either set `mem_limit` from the device's DMA mask, or let
   `dma_map_single()` handle multi-segment and non-contiguous buffers.
5. Rebase on current main, retest, and send to bz@ (owner of LinuxKPI 802.11
   and the page pool work) as input for his `struct page` rework: the side
   table is a stopgap until `PAGE_IS_LKPI_PAGE` exists, not a replacement.
6. The init-failure hang fix and the idr fix stand on their own: extend the
   hang fix to mt7915, mt7921 and mt7996, and submit both separately.
7. Report results on PR 273623 (mt76 meta-bug).

## Test log

| Date | Kernel | Result |
|---|---|---|
| 2026-11-12 | stock, modules built by hand | page pool warning, MCU timeouts, `hardware init failed`, kldload hung, reboot |
| 2026-11-12 | kernel.mt76: page pool side table + init fix | MCU replies, `Failed to send patch: -12` x10, attach returns ENXIO, kldload returns |
| 2026-11-12 | kernel.mt76 + `compat.linuxkpi.skb.mem_limit=1` | firmware up, `mt79250` registered, wlan0 scan lists 2.4 and 5 GHz APs |
| 2026-11-12 | same | WPA2 on 2.4 GHz HT20: 27.8/26.2 Mbit/s; forced BSS switch: error 95 then panic in `idr_remove()` |
| 2026-11-12 | same + idr fix | WPA2 on 5 GHz VHT80: 22.4/35.4 Mbit/s; disconnect, reconnect, BSS switch and `kldunload` clean |
| 2026-11-12 | same + `compat.linuxkpi.80211.hw_crypto=1` | `ampdu` on; 5 GHz 26.0/51.7, 2.4 GHz 23.1/35.3 Mbit/s; UDP TX 66.7 Mbit/s |
| 2026-11-12 | Ubuntu, Linux 7.0.0-43 | same APs: 152/139 (2.4 GHz), 199/195 (5 GHz far), 577/426 Mbit/s (5 GHz ch 100 near) |
| 2026-11-12 | kernel.mt76, debugfs modules, `country FR` | mt76 `tx_stats`: BA miss 0; TCP Retr 0, `-P 4` 34 total, 390 ms ping under load; ch 100 VHT80: 41.5/74.9 Mbit/s |
| 2026-11-12 | same, DTrace + `xmit-queues` sampling | DMA ring holds 0 to 3 frames under load: mt76 non-AQL cap of 16 frames |
| 2026-11-12 | same + `MT_MAX_NON_AQL_PKT` 256 | 69.4/77.9 Mbit/s; then panic reading a stale debugfs entry after module reload |
| 2026-11-12 | same + cap 4096 | TCP TX 230 once on fresh memory, then 35 to 42; `contigmalloc()` 7.4 s of 8 s; UDP RX 274, TCP RX 84 |
| 2026-11-12 | + cached DMA32 skb zones | no `contigmalloc()`; cap 16: 36/67; cap 4096: 227/160/237 TX, 78 RX; 490000 skbs leaked |
| 2026-11-12 | + `napi_consume_skb()` fix | no leak; cap 4096: TX 165/276/195, RX 72 Mbit/s |
| 2026-11-12 | + `tx_time_est` estimate, stock cap 16 | TX 244/254/232, RX 79 Mbit/s; ping under load 40 to 75 ms; no leak |
