# amd_iommu: MSI interrupt remap entries are never freed, nor aligned

Patch: [amdiommu_irte_free.patch](amdiommu_irte_free.patch), branch
[`olivier-amdiommu-irte`](https://github.com/ocochard/freebsd-src/compare/main...olivier-amdiommu-irte).
Found while porting the AMD XDNA NPU driver ([amdxdna_npu.md](amdxdna_npu.md)).
Line numbers are `sys/x86/iommu/amd_intrmap.c` on main 611046b15dbb.

## 1. Background

**MSI-X.** A PCI device signals an interrupt by writing a small message
(address + data) to a special address range. Each vector has its own
message. A driver asks for N vectors with `pci_alloc_msix()`.

**Interrupt remapping (IR).** With an IOMMU, the message does not go to
the CPU directly. Its data is an index into an *interrupt remapping
table* (IRT) owned by the IOMMU; the IRT entry (IRTE) holds the real
destination CPU and vector. The AMD IOMMU has one IRT per device
(requester ID).

**Who allocates what.** `msi_alloc()` / `msix_alloc()` in
`sys/x86/x86/msi.c` (lines 488, 734) ask the IOMMU for one *cookie* per
vector with `iommu_alloc_msi_intr()`; the cookie is the IRTE index. On
release they call `iommu_unmap_msi_intr()` (lines 571, 583, 790).

**The per-device allocator.** `amdiommu_ctx_init_irte()` creates a vmem
arena `ctx->irtids` covering `[0, irte_nentries)` (line 343).
`irte_nentries` defaults to 32 (line 383, tunable `hw.iommu.amd.ir_num`).
`amdiommu_alloc_msi_intr()` (line 82) takes `count` indexes from it with
`vmem_alloc()`.

## 2. The problem

`amdiommu_unmap_msi_intr()` (line 195) calls `amdiommu_ir_free_irte()`
(line 269). That function zeroes the IRTE and invalidates the IOMMU
cache, but never gives the index back to `ctx->irtids`. The Intel driver
does (`dmar_ir_free_irte()`, `vmem_free()` at intel_intrmap.c line 319).

So every MSI or MSI-X vector a device ever releases is lost for that
device. The AMD XDNA NPU uses exactly 32 MSI-X vectors, the whole
default table, so its second attach finds the arena empty:

```
# kenv hw.amdiommu.enable=1 (IR-only); kldload amdxdna.ko; kldunload amdxdna; kldload amdxdna.ko
amdxdna0: [drm] *ERROR* aie2_init: failed to alloc irq vectors, ret -22
device_attach: amdxdna0 attach returned 22
```

The -22 hides the real error. DTrace on the return values during the
second load:

```
dtrace -n 'fbt::pci_alloc_msix_method:return,fbt::pci_msix_count_method:return
    { printf("%s rv=%d", probefunc, (int)arg1); }'
pci_msix_count_method rv=32
pci_alloc_msix_method rv=12        <- ENOMEM from vmem_alloc()
```

LinuxKPI `pci_alloc_irq_vectors()` then falls through to `-EINVAL`
because only `PCI_IRQ_MSIX` was requested.

A device with fewer vectors hits it later: one with 4 vectors runs out
after 8 attach cycles.

Two more defects show up when reading the same allocator, both on the
multiple-message MSI path (`msi_alloc()`, `count` > 1, never MSI-X,
which takes one cookie per vector at line 734):

1. **Freeing one cookie at a time.** `msi_alloc()` gets the whole group
   with one `vmem_alloc(count)`, but `msi_release()` unmaps each cookie
   separately. `vmem_xfree()` (`sys/kern/subr_vmem.c`) looks the
   segment up by its start address, so the cookie `idx + 1` finds no
   segment: an `MPASS` panic with INVARIANTS, a NULL dereference
   without. The simple fix, `vmem_free(ctx->irtids, cookie, 1)`, would
   turn today's leak into that crash. The Intel driver has this pattern
   (`dmar_ir_free_irte()`); not changed here.
2. **No alignment.** `amdiommu_map_msi_intr()` writes the IRTE index as
   the MSI data (`*data = cookie`). A device with 2^n messages ORs the
   message number into the low n bits of the data, so the group's first
   index must be a multiple of `count`. `M_FIRSTFIT` without alignment
   does not guarantee that: message 1 of a group at index 3 would land
   on IRTE 3 | 1 = 3, the entry of message 0.

## 3. The fix

Replace the vmem arena with a bitmap of IRTE indexes, one bit per
entry, protected by the unit lock:

```c
	AMDIOMMU_LOCK(unit);
	for (idx = 0; idx + count <= unit->irte_nentries; idx += count) {
		if (bit_ntest(ctx->irtids, idx, idx + count - 1, 0))
			break;
	}
	if (idx + count > unit->irte_nentries) {
		AMDIOMMU_UNLOCK(unit);
		return (ENOMEM);
	}
	bit_nset(ctx->irtids, idx, idx + count - 1);
	AMDIOMMU_UNLOCK(unit);
```

and in `amdiommu_ir_free_irte()`, after the IOMMU invalidation, under
the lock it already holds:

```c
	bit_clear(ctx->irtids, cookie);
```

Why a bitmap: freeing one index is one bit, whatever the group size,
which is the interface `msi.c` uses. Stepping `idx` by `count` gives the
alignment; `count` is a power of 2 for MSI (`pci_alloc_msi_method()`
refuses others, `sys/dev/pci/pci.c` line 2704) and 1 for MSI-X. The
table has at most 2048 entries (line 387), so the linear search is
short. Clearing after the invalidation means a new owner never sees a
stale cached IRTE.

Alternatives:

- Keep vmem and `vmem_xalloc()` with `align = count`. Fixes the
  alignment, not the per-cookie free.
- Raise `hw.iommu.amd.ir_num`. Delays the failure, costs IRT memory on
  every device.

Not fixed: the Intel driver (`intel_intrmap.c`) has the same
per-cookie free of a vmem block; `amdiommu_unmap_ioapic_intr()` is
still a stub.

## 4. Tested

frwk-bsd (Framework Desktop, Strix Halo), kernel main 6871285f194d plus
the SRCU, amdiommu and LinuxKPI pcim_iomap patches,
`hw.amdiommu.enable=1` (IR-only; the only multiple-message MSI device
here is the IOMMU itself, which does not use the IRT), amdxdna from drm-kmod `olivier-amdxdna`.

| Test | Before | After |
|---|---|---|
| amdxdna second kldload | `failed to alloc irq vectors, ret -22` | attaches |
| kldload/kldunload cycles | 1 of 4 | 6 of 6, `/dev/accel/accel0` each time |
| `xrt-smi validate` after the cycles | | gemm 51.0 TOPS, latency 56 us, PASSED |
| `hw.iommu.dma=1` (DMA remapping too) | untested with this patch | untested |
| multiple-message MSI device under IR | untested (none on this machine) | untested |
| other devices, other AMD machines | untested | untested |
