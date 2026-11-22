# IOMMU: MSI interrupt remap entries are never freed (AMD), freed piecewise (Intel), not aligned (AMD)

Patch: [amdiommu_irte_free.patch](amdiommu_irte_free.patch), two commits
on FreeBSD main 02e1b1cd1fb1, in review as
[#112](https://ron-dev.freebsd.org/FreeBSD/src/pulls/112) (waiting for
kib's answer to the rework he asked for):

1. `x86: Release the IOMMU entries of an MSI group at once`
   (`msi.c`, the IOMMU interface, the Intel driver);
2. `amdiommu: Free and align interrupt remapping entries`.

Found while porting the AMD XDNA NPU driver ([amdxdna_npu.md](amdxdna_npu.md)).
Line numbers are from main 02e1b1cd1fb1 unless the patched file is named.

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
`sys/x86/x86/msi.c` ask the IOMMU for one *cookie* per
vector with `iommu_alloc_msi_intr()`; the cookie is the IRTE index. On
release they call `iommu_unmap_msi_intr()` (lines 571, 583, 790), one
cookie at a time.

**The per-device allocator.** `amdiommu_ctx_init_irte()`
(`amd_intrmap.c`) creates a vmem arena `ctx->irtids` covering
`[0, irte_nentries)`. `irte_nentries` defaults to 32 (tunable
`hw.iommu.amd.ir_num`). `amdiommu_alloc_msi_intr()` takes `count`
indexes from it with one `vmem_alloc()`. The Intel driver does the same
with one arena per IOMMU unit (`intel_intrmap.c` line 84).

## 2. The problem

`amdiommu_unmap_msi_intr()` (`amd_intrmap.c` line 195) calls
`amdiommu_ir_free_irte()` (line 269). That function zeroes the IRTE and invalidates the IOMMU
cache, but never gives the index back to `ctx->irtids`. The Intel driver
calls `vmem_free()` (`dmar_ir_free_irte()`), but see item 1 below.

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
   without (found by reading the code, not reproduced). The simple AMD
   fix, `vmem_free(ctx->irtids, cookie, 1)`, would turn today's leak
   into that crash. The Intel driver already has it:
   `dmar_ir_free_irte()` calls `vmem_free(unit->irtids, cookie, 1)` for
   each message of a block allocated with `vmem_alloc(count)`.
2. **No alignment.** `amdiommu_map_msi_intr()` writes the IRTE index as
   the MSI data (`*data = cookie`). A device with 2^n messages ORs the
   message number into the low n bits of the data, so the group's first
   index must be a multiple of `count`. `M_FIRSTFIT` without alignment
   does not guarantee that: message 1 of a group at index 3 would land
   on IRTE 3 | 1 = 3, the entry of message 0.

## 3. The fix

The group is allocated as one block, so it is freed as one block, by
the code that knows it is a group. kib suggested this design in review:
fix `msi.c` to free the whole block, and use `vmem_xalloc()` for the
alignment.

**Commit 1, `msi.c` and the interface.** `iommu_unmap_msi_intr(dev,
cookie, count)` gains a `count`. `msi_release()` calls it once for the
whole group, with the cookie of the first message, before clearing the
messages; it drops `msi_lock` around the call as the old per-message
calls did. `msix_release()` passes 1. Intel `dmar_ir_free_irte(unit,
cookie, count)` clears the `count` entries, invalidates the interrupt
entry cache once for the range (`dmar_qi_invalidate_iec(unit, cookie,
count)`), then gives the block back with `vmem_free(unit->irtids, cookie,
count)`. The IOAPIC path passes 1.

**Commit 2, AMD.** Allocation keeps vmem but aligns the block:

```c
	KASSERT(powerof2(count), ("bad count %u", count));
	error = vmem_xalloc(ctx->irtids, count, count, 0, 0, VMEM_ADDR_MIN,
	    VMEM_ADDR_MAX, M_FIRSTFIT | M_NOWAIT, &vmem_res);
```

`count` is a power of 2 for MSI (`pci_alloc_msi_method()` refuses
others) and 1 for MSI-X. Release clears the `count` entries, issues one
INVALIDATE_INTERRUPT_TABLE for the device (the AMD command invalidates
the whole table of a requester ID, so one is enough), then frees:

```c
	amdiommu_ir_free_irte(ctx, src, cookie, count);
	vmem_xfree(ctx->irtids, cookie, count);
```

Memory allocated with `vmem_xalloc()` must go back with `vmem_xfree()`.
The index is freed after the invalidation, so a new owner never sees a
stale cached IRTE.

Alternatives:

- A bitmap of IRTE indexes in the AMD driver, freed one bit per
  message. It keeps the per-message interface of `msi.c`, but hides that
  the group is one block, and leaves the Intel driver broken.
- Raise `hw.iommu.amd.ir_num`. Delays the failure, costs IRT memory on
  every device.

Not fixed: `amdiommu_unmap_ioapic_intr()` is still a stub. The lost-race
path of `amdiommu_get_ctx_for_dev()` leaks the losing context's IRT and
arena (separate patch).

## 4. Tested

Test module: [amdiommu_msigt.c](amdiommu_msigt.c)
([Makefile](amdiommu_msigt.Makefile)). On load it takes an idle device
with multiple-message MSI, then 64 times: allocates a group, sets up a
handler on each message (which programs the remapping entries), checks
that the MSI data of the first message is aligned on the group size,
and releases the group.

| Machine, kernel, tunables | Test | Result |
|---|---|---|
| HP ZBook Ultra G1a (Strix Halo), laptop kernel 0d71515aee38 plus #112 and #113, `hw.amdiommu.enable=1 hw.iommu.dma=1` | msigt, 16-message group on the idle USB4 router (1022:158d) | 64/64 cycles, data aligned on 16 each time |
| same | `devctl detach`/`attach` of `hdac0` (1 MSI vector), 64 times; stock main falls back to INTx from cycle 32 | 64/64 with MSI |
| same | IOMMU events after the tests | 0 |
| ThinkPad X1 Carbon (Meteor Lake, Intel), `hw.dmar.enable=1 hw.iommu.dma=0` | msigt, 8-message group on xhci1 (8086:7e7d) | 64/64 cycles |
| both commits on main | `buildkernel` GENERIC (INVARIANTS) and GENERIC-NODEBUG | no warning |

Untested: amdxdna attach cycles with these commits (the failure in
section 2 is from stock main), IOAPIC remapping changes, other AMD and
Intel machines.

## 5. Review

- [#112](https://ron-dev.freebsd.org/FreeBSD/src/pulls/112): reviewers
  asked: imp, kbowling, kib. kib's comment led to the design in section
  3; the rework was posted 2026-11-22, no approval yet.
- Local review (Opus): no bug found. Every `vmem_alloc()`/`vmem_free()`
  and `vmem_xalloc()`/`vmem_xfree()` pairs up on the MSI, MSI-X, IOAPIC
  and error paths; the range checks cannot overflow; all callers are
  converted, i386 included.
