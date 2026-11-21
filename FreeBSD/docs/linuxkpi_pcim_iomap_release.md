# LinuxKPI: pcim_iomap() leaks every BAR it maps

Patch: [linuxkpi_pcim_iomap_release.patch](linuxkpi_pcim_iomap_release.patch),
branch [`olivier-lkpi-pcim-iomap`](https://github.com/ocochard/freebsd-src/compare/main...olivier-lkpi-pcim-iomap).
Found while porting the AMD XDNA NPU driver ([amdxdna_npu.md](amdxdna_npu.md)).
Line numbers are `sys/compat/linuxkpi/common/src/linux_pci.c` on main
611046b15dbb.

## 1. Background

**BAR.** A PCI device exposes its registers through Base Address
Registers. A driver must "map" a BAR before it can read or write the
registers behind it. On FreeBSD that means `bus_alloc_resource()`, which
returns a `struct resource *`. The resource holds a *bus handle*
(`rman_get_bushandle()`), on amd64 the kernel virtual address of the
registers.

**LinuxKPI.** Linux drivers (drm, iwlwifi, amdxdna) run on FreeBSD
through LinuxKPI, a layer that implements Linux kernel functions with
FreeBSD ones. Linux `pci_iomap()` returns a `void __iomem *`, a pointer
the driver dereferences with `readl()`/`writel()`. LinuxKPI therefore
returns the bus handle cast to a pointer (`linuxkpi_pci_iomap_range()`,
line 959).

**A FreeBSD extension: want_iomap_res.** Some ported drivers (iwlwifi)
call `linuxkpi_pcim_want_to_use_bus_functions()`. After that, the
iomap functions return the `struct resource *` itself, so the driver can
use `bus_read_4()`. One `void *` type, two meanings, chosen by the
`pdev->want_iomap_res` flag.

**Managed (devres) mapping.** `pcim_iomap()` is the managed form of
`pci_iomap()`: the mapping is recorded in a per-device table and is
released automatically when the driver detaches. LinuxKPI keeps two
arrays in that table (`struct pcim_iomap_devres`): `mmio_table[]` with
the bus handles and `res_table[]` with the resources.
`lkpi_set_pcim_iomap_devres()` (line 987) fills both from a resource:

```c
dr->mmio_table[bar] = (void *)rman_get_bushandle(res);
dr->res_table[bar] = res;
```

On detach, `lkpi_pcim_iomap_table_release()` (line 1096) calls
`pci_iounmap()` for each mapped BAR. `linuxkpi_pci_iounmap()` (line 1026)
looks the BAR up in the list of allocated resources and releases it. It
matches the argument as a resource when `want_iomap_res` is set, as an
address inside the BAR otherwise.

## 2. The problem

`linuxkpi_pcim_iomap()` (line 995) got its mapping from
`linuxkpi_pci_iomap()`, which by default returns a **bus handle**, and
passed it to `lkpi_set_pcim_iomap_devres()`, which expects a
**resource**. `rman_get_bushandle()` reads the `r_bushandle` field at an
offset from that address, that is from device memory, so `mmio_table[bar]`
holds whatever the register there contains. Consequences:

1. On detach, `pci_iounmap()` gets that value, matches no BAR and returns
   silently. The BAR stays allocated.
2. A second `pcim_iomap()` of the same BAR returned `res_table[bar]`. In
   the default mode that slot holds the bus handle, so the value was right
   by accident.
3. iwlwifi, the only in-tree driver with `want_iomap_res`, did not leak:
   it calls `pcim_request_all_regions()` before `pcim_iomap()`
   (`sys/contrib/dev/iwlwifi/pcie/drv.c`), so `_lkpi_pci_iomap()` returns
   the region's own resource, the mismatched `pci_iounmap()` was a no-op,
   and the region's release freed the BAR. (The first version of this
   document claimed a leak there; review showed it wrong.)

Measured with amdxdna, which maps 5 BARs with `pcim_iomap()`, on a
Strix Halo with the AMD IOMMU in interrupt-remapping mode:

```
# kldload amdxdna.ko; kldunload amdxdna
amdxdna0: lkpi_pci_dev_release_common: driver did not clean up; leaking mmio resources
pci0:194:0:1: Device leaked memory resources
```

With this patch alone the clean unload prints nothing, but the reload
still failed (`failed to alloc irq vectors, ret -22`, then `Device leaked
memory resources` from the failed attach). That second bug is in the AMD
IOMMU driver: [amdiommu_irte_free.md](amdiommu_irte_free.md).

## 3. The fix

```c
	if (dr->res_table[bar] == NULL) {
		res = _lkpi_pci_iomap(pdev, bar, maxlen);
		if (res == NULL)
			return (NULL);
		lkpi_set_pcim_iomap_devres(dr, bar, res);
	}

	/* This is a FreeBSD extension so we can use bus_*(). */
	if (pdev->want_iomap_res)
		return (dr->res_table[bar]);
	return (dr->mmio_table[bar]);
```

and in the release:

```c
	pdr = lkpi_devres_find(dev, lkpi_pci_devres_release, NULL, NULL);
	...
		if (dr->res_table[bar] == NULL)
			continue;
		/* A requested region owns its BAR: its release frees it. */
		if (pdr != NULL && pdr->region_table[bar] == dr->res_table[bar])
			continue;

		/* pci_iounmap() takes what pcim_iomap() returned. */
		pci_iounmap(pdev, pdev->want_iomap_res ?
		    (void *)dr->res_table[bar] : dr->mmio_table[bar]);
```

Why here: `_lkpi_pci_iomap()` is the internal helper that always returns
the resource; `linuxkpi_pcim_iomap_regions()` (line 1050) already uses it
for the same table, so `pcim_iomap()` now fills the table the same way.
The return value follows the same rule as `linuxkpi_pcim_iomap_table()`
(line 887): resource with `want_iomap_res`, bus handle without. The
release passes `pci_iounmap()` the same kind of value the driver got.

The region check matters once the release works: with iwlwifi's
`pcim_request_all_regions()` then `pcim_iomap()`, both devres entries
hold the same resource. Releasing it from `pcim_iomap()`'s entry too would
release the BAR twice (`pci_release_region()` releases it again, and
under `vgapci` that can drop a reference another child holds). So a BAR
that a requested region owns is left to that region's release.

Alternatives:

- Convert the handle back to a resource in `lkpi_set_pcim_iomap_devres()`.
  Needs a search of `pdev->mmio` for every call; the resource is already
  available one call level down.
- Make `pci_iounmap()` accept either type. It cannot tell a resource
  pointer from a bus handle, both are kernel addresses.

Not fixed: a driver that sets `want_iomap_res` after mapping (the flag
changes meaning of values already handed out; no in-tree driver does), and
a region requested with `pci_request_region()` on an unmanaged device and
then mapped with `pcim_iomap()` (the region is not in `region_table`).
Also older and left alone: `pci_release_region()` compares `rle->res`
with a bus handle (since d4a4960c6559), so it never removes its entry
from `pdev->mmio`.

## 4. Tested

frwk-bsd (Framework Desktop, Strix Halo), kernel main 6871285f194d plus
the SRCU and amdiommu branches, `hw.amdiommu.enable=1`, amdxdna from
drm-kmod `olivier-amdxdna`.

| Test | Before | After |
|---|---|---|
| amdxdna kldunload | `leaking mmio resources`, `Device leaked memory resources` | no message |
| 4 load/unload cycles (with the IRTE fix) | second load fails | 4/4 attach, `/dev/accel/accel0` each time |
| `xrt-smi validate` after the cycles | | gemm 51.0 TOPS, latency 56 us, PASSED |
| iwlwifi (want_iomap_res, region requested first) | untested | untested (no hardware; covered by reading) |

The rows above are the first version of the patch (no region check). The
final version was built into a test kernel for the HP ZBook Ultra G1a
(its `zbook` source, 0d71515aee38, plus this commit) to exercise the
changed release function with mt7925, which maps its BAR with
`pcim_iomap_regions()`, by reloading `if_mt7925`:

| Kernel | `kldunload`/`kldload if_mt7925` cycles | Result |
|---|---|---|
| the laptop's installed kernel | 3 + 3 + 8 | all reassociate and pass traffic |
| test kernel with this commit | 2 runs | BAR released and allocated again cleanly each cycle, then the whole system hangs in cycle 2, after `lkpi_ic_addba_request` |
| control: same build, same source, without this commit | 1 run | same hang, in cycle 1 |

The control hangs the same way, so the hang belongs to how those test
kernels were built (rebuilt kernel plus four modules copied from the
installed kernel), not to this commit; it is an mt7925/LinuxKPI 802.11
problem to chase separately. A clean mt7925 reload run with this commit
is therefore still missing.
