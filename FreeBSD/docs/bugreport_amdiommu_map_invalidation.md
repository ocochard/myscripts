# amdiommu: every DMA map waits for an IOTLB invalidation

```
Category:  kern
Component: kern
Version:   16.0-CURRENT
```

Patch: [`amdiommu_skip_map_invalidation.patch`](amdiommu_skip_map_invalidation.patch)
(`sys/x86/iommu/amd_drv.c`, `amd_idpgtbl.c`, `amd_iommu.h`).
Branch: `olivier-amdiommu` on github.com/ocochard/freebsd-src, on top of the identity-mapping fix (separate report).
Background for readers new to this code: [`amdiommu_ser6.md`](amdiommu_ser6.md), sections 1, 3.2 and 4.2.

**Summary.** With `hw.amdiommu.enable=1 hw.iommu.dma=1`, `amdiommu_map_buf()` queues an invalidation and a completion wait after every map,
and waits for it. Its comment already doubts this: "XXXKIB invalidation seems to be needed even for non-valid->valid updates. Recheck."
On a Ryzen 7 7735HS each 128 KB NVMe read costs 51 IOMMU interrupts, and 128 KB reads run at about half the no-IOMMU speed.
The patch invalidates after a map only when the map wrote a new PDE, or when the IOMMU caches non-present entries (NpCache).
That cuts IOMMU interrupts about 3 times and raises 128 KB read throughput by about 38%, with no IOMMU fault.

## How to repeat

Machine: Beelink SER6, AMD Ryzen 7 7735HS, IOMMU capability header `0x190b640f` (NpCache, bit 26, clear),
Kingston NV2 NVMe, FreeBSD 16.0-CURRENT main-n290674 (7806832f23fb), GENERIC-NODEBUG.

```
# nextboot -e hw.amdiommu.enable=1 -e hw.iommu.dma=1
# shutdown -r now
...
# vmstat -i | grep cmdev
# dd if=/dev/nda0 of=/dev/null bs=128k count=8000
# vmstat -i | grep cmdev
```

dtrace on `amdiommu_cmd_event_intr()` shows the interrupts come from the map path:
`nvme_qpair_submit_request()`, `bus_dmamap_load_mem()`, `iommu_gas_map()`, `amdiommu_map_buf()`.

## Cause

`amdiommu_map_buf()` ends with `iommu_qi_invalidate_sync()`, which queues `INVALIDATE_IOMMU_PAGES` plus `COMPLETION_WAIT` and waits.
Filling a non-present PTE needs no invalidation: the AMD IOMMU caches non-present entries only when the capability header sets NpCache,
which virtual IOMMUs do. Linux flushes on map only then (`amd_iommu_iotlb_sync_map()` in `drivers/iommu/amd/iommu.c`).

One case does need the flush on FreeBSD.
`amdiommu_unmap_clear_pte()` frees a page table page as soon as its last PTE is unmapped: it clears the PDE at once,
and keeps the page until the deferred invalidation (`iommu_pgfree()` with an `entry`).
A later map in the same region writes a new PDE while the IOMMU may still hold the old one, and walks the old, cleared table.
Linux's v1 page table code keeps intermediate tables after unmap, so the case never arises there.

Measured: a first version of the patch that followed Linux exactly (flush only with NpCache) produced 1303 `IO_PAGE_FAULT` events from `nvme0` under read load,
all "page not present" (`pr 0`), all device-to-memory writes (`rw 1`), all in one 2 MB IOVA region (0x4200000-0x43fffff), the span of one leaf table.
The event log overflowed 4 times. ZFS reported no checksum error.

## Fix

- `amd_iommu.h`: `cap_hdr` in `struct amdiommu_unit`; `pde_set` in `struct amdiommu_domain`, protected by the page table lock.
- `amd_drv.c`, `amdiommu_attach()`: read the capability header.
- `amd_idpgtbl.c`, `amdiommu_pgtbl_map_pte()`: set `pde_set` when it writes the PDE of a new table page.
- `amd_idpgtbl.c`, `amdiommu_map_buf()`: clear `pde_set`, map, then call `iommu_qi_invalidate_sync()` only if `pde_set` is true or `PCIM_AMDIOMMU_CAP_NPCACHE` is set.

Unmap invalidation is unchanged.

Alternative: keep empty page table pages after unmap, as Linux does. No map would then need a flush,
at the cost of table memory held for the life of the domain. A larger change.

## Tested

Beelink SER6, 2026-11-16. Boots back to back in one session; `dd if=/dev/nda0 of=/dev/null`,
1000 MB in 128 KB blocks three times, then 3000 MB in 1 MB blocks, same offsets every time.
The NV2's own speed varies a lot between boots (44.7 to 750 MB/s for the same read with the stock IOMMU on the same day),
so only runs from one session compare; interrupt counts per read do not depend on the drive.

| Kernel, tunables | 128 KB reads | 1 MB reads | IOMMU interrupts per read (128 KB / 1 MB) | Idle IOMMU interrupts | IOMMU events |
|---|---|---|---|---|---|
| stock, no IOMMU | 1205, 1568, 1276 MB/s | 877 MB/s | n/a | n/a | n/a |
| stock, `hw.iommu.dma=1` | 752, 760, 653 MB/s | 952 MB/s | 51 / 409 | 118/s | 0 |
| patched, `hw.iommu.dma=1` | 904, 1032, 1062 MB/s | 1119 MB/s | 19 / 138 | 62/s | 0 |
| first version (NpCache only), `hw.iommu.dma=1` | 447, 964, 805 MB/s | 847 MB/s | 18.7 / 136 | 54/s | 1303 page faults |

Patched kernel with `hw.iommu.dma=1`, other checks:
0 IOMMU events after 6 GB of reads and 2 GB over ssh; `rge0` 117 MB/s in, 115 MB/s out over ssh;
`zpool status -x`: all pools are healthy.

HP ZBook Ultra G1a, 2026-11-16: AMD Ryzen AI Max+ PRO 395 (Strix Halo), IOMMU 1022:1508,
capability header `0x190b640f` (NpCache clear, as on the SER6), Samsung MZVL22T0HBLB NVMe;
kernels from FreeBSD main 46ce9acd6d15 plus the laptop's branch `zbook`, the patched one with both amdiommu commits.
Same reads as above (`dd if=/dev/nda0`, 1000 MB in 128 KB blocks three times at fixed offsets, then 3000 MB in 1 MB blocks), one boot each, all on the same day:

| Kernel, tunables | 128 KB reads | 1 MB reads | IOMMU interrupts per read (128 KB / 1 MB) | Idle IOMMU interrupts | IOMMU events |
|---|---|---|---|---|---|
| no IOMMU | 960, 794, 913 MB/s | 1743 MB/s | n/a | n/a | n/a |
| stock, `hw.amdiommu.enable=1 hw.iommu.dma=1` | 198, 200, 200 MB/s | 219 MB/s | 66 / 516 | 168/s | 0 |
| patched, `hw.amdiommu.enable=1 hw.iommu.dma=1` | 433, 430, 433 MB/s | 441 MB/s | 33 / 260 | 52/s | 0 |

The patch doubles read throughput and halves the IOMMU interrupts here too, but DMA remapping still costs half of the
no-IOMMU speed on this machine (the SER6 came close to it). In both IOMMU boots Wi-Fi associated and amdgpu logged no display error; USB enumerated in the patched one (not checked in the stock one); `zpool status -x`: all pools are healthy.

Not tested:

- Disk writes under DMA remapping (avoided, to protect the pool).
- An IOMMU with NpCache set (virtual IOMMU): the patch keeps the flush there.
- Suspend and resume; bhyve passthrough; other AMD generations.
- Where the remaining 19 interrupts per 128 KB read come from (unmap invalidations, maps that write a PDE): not broken down.
