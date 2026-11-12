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
| WPA association, traffic | no | not tested yet (no credentials on the test host) |
| Failure handling | `kldload` hangs forever, reboot needed | attach fails with ENXIO, `kldunload` works |

The scan reports rates up to 54M; that is net80211's scan list column, not a measured link rate.

## Why the stock driver does not work

FreeBSD has the mt76 sources (`sys/contrib/dev/mediatek/mt76`) and module
Makefiles (`sys/modules/mt76/core`, `sys/modules/mt76/mt7925`), but
`sys/modules/Makefile` does not list `mt76`, so nothing is built.
Building the modules by hand and loading them shows three separate problems,
each hiding the next one.

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

## How to reproduce

Tested on the old-base worktree `~/freebsd-mt76` (6e87733f73ff), because a full
`buildkernel` on newer main failed in the ZFS module for an unrelated reason.
The page pool code is compiled into the kernel (`options COMPAT_LINUXKPI`), so
the test needs a kernel, not just modules.

```sh
cd ~/freebsd-mt76
git apply ~/myscripts/FreeBSD/docs/mt7925_page_pool.patch
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
sudo nextboot -k kernel.mt76 -e compat.linuxkpi.skb.mem_limit=1
sudo shutdown -r now

# after the reboot
sudo kldload mt76_core if_mt7925
sudo ifconfig wlan0 create wlandev mt79250 up
sudo ifconfig wlan0 scan
```

## Alternative: OpenBSD mwx(4)

OpenBSD's native `mwx(4)` (claudio@, `if_mwx.c` rev 1.49, ISC licence)
supports MT7921 and MT7925, but 11n, 11ac and 6 GHz are under `#if NOTYET`:
it is 11a/b/g only, 54 Mbit/s at best.
Its firmware is the linux-firmware files renamed.
A port would follow the iwx(4) precedent (2ad0f7e91582, 2025), but it would
start slower than what the LinuxKPI driver already scans with.

## Plan

1. Association test with WPA2 on the test host (wpa_supplicant), then
   throughput with iperf3, then suspend/resume and `kldunload`.
2. Check what the FreeBSD wiki said was still missing (LinuxKPI IDR updates)
   once traffic flows: the scan and firmware start did not hit it.
3. Fix the DMA mapping properly instead of relying on the loader tunable:
   either set `mem_limit` from the device's DMA mask, or let
   `dma_map_single()` handle multi-segment and non-contiguous buffers.
4. Rebase on current main, retest, and send to bz@ (owner of LinuxKPI 802.11
   and the page pool work) as input for his `struct page` rework: the side
   table is a stopgap until `PAGE_IS_LKPI_PAGE` exists, not a replacement.
5. The init-failure hang fix stands on its own: extend it to mt7915, mt7921
   and mt7996 and submit it separately.
6. Report results on PR 273623 (mt76 meta-bug).

## Test log

| Date | Kernel | Result |
|---|---|---|
| 2026-11-12 | stock, modules built by hand | page pool warning, MCU timeouts, `hardware init failed`, kldload hung, reboot |
| 2026-11-12 | kernel.mt76: page pool side table + init fix | MCU replies, `Failed to send patch: -12` x10, attach returns ENXIO, kldload returns |
| 2026-11-12 | kernel.mt76 + `compat.linuxkpi.skb.mem_limit=1` | firmware up, `mt79250` registered, wlan0 scan lists 2.4 and 5 GHz APs |
