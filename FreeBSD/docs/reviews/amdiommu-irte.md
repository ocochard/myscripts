11ae91fe9ff3928488256e1662afd8a0dad3cba8 ("amd_iommu: Free and align interrupt remapping entries")

POSTCR-0f5116d7efe33c81f0b24b56eec78af37898f500-1: pre-existing: amdiommu_get_ctx_for_dev() lost-race path frees ctx1 without amdiommu_ctx_fini_irte(), leaking its IRT and (now) irtids bitmap
POSTCR-0a110d5b172e20b84652aa92d5e0a7f0cd4fa323-1: pre-existing: dmar_ir_free_irte() vmem_free()s one cookie of a multi-message MSI block, msi_release() of a group panics (MPASS or NULL bt in vmem_xfree)

No bug found in the reviewed commit.

Checked:
- Callers: msi_alloc() passes count = power of 2 (pci.c powerof2(actual)), msix_alloc() passes 1; both call with msi_lock dropped, so taking AMDIOMMU_LOCK is fine.
- Alignment: stepping idx by count gives an index aligned on count; device ORs log2(MME) low bits into MSI data = IRTE index (amdiommu_map_msi_intr() sets *data = cookie). count > irte_nentries returns ENOMEM.
- Free: bit_clear() after the IR invalidation, under the unit lock; per-cookie free now matches msi_release().
- bit_alloc(M_WAITOK) in amdiommu_ctx_init_irte(): caller drops the unit lock before it, and the same function already does contigmalloc(M_WAITOK). Also removes the old unchecked vmem_create(M_NOWAIT) NULL.
- sys/bitstring.h in amd_iommu.h: pulls libkern.h/malloc.h under _KERNEL, all users of the header compile the same types.
- Interaction with pr/amdiommu: both touch sys/x86/iommu/amd_iommu.h; patches apply in either order (verified with patch(1) on upstream copy). Different structs (amdiommu_ctx vs amdiommu_domain/amdiommu_unit), different locks (unit lock vs domain pglock). No semantic conflict. With e38153bb186c the IR-only ctx keeps one ref and persists across detach, which is exactly why reclaiming IRTEs matters.

Comments:
- POSTCR-0f5116...-1: amd_ctx.c:572 "Nothing needs to be done to destroy ctx1" is wrong since amdiommu_ctx_init_irte(ctx1) ran. Needs amdiommu_ctx_fini_irte(ctx1) before free(). Rare race (two first-time get_ctx for the same RID).
- POSTCR-0a110d...-1: Intel only; msi_release() frees cookies idx+1.. first, vmem_xfree() finds no busy segment at idx+1. The tutorial already notes it as not fixed. Same bitmap approach would fix it; not a blocker for this commit.
- amdiommu_ir_find() calls iommu_instantiate_ctx() on each alloc/map/unmap and never drops the reference when DMA remapping is on (pre-existing). Contexts are not freed on detach anyway (only by the tag destroy path), so no visible effect today; no ID.

## Checks

- style(9): clang-format21 with upstream .clang-format on changed lines: only diffs are comment alignment in the struct (matches neighbours) and a blank line between sys/ and dev/ includes in amd_iommu.h (file has none elsewhere). No real deviation.
- Non-ASCII: none in diff or commit message.
- GPL: bitmap allocator written with FreeBSD bitstring(3). Linux alloc_irq_index() also aligns multi-MSI blocks, but nothing is copied (different data structure and code). OK.
- Spec: relies on AMD IOMMU spec #48882 (MSI data[10:0] is the IRTE index). Not cited; optional for a fix to an existing driver.
- Commit message: subject 53 chars (prefix "amd_iommu:" matches 4a2494d76ad0/9f4df9fc1ba8; pr/amdiommu uses "amdiommu:", pick one for the series), body <= 72 cols, Fixes:/MFC after: with tabs, no PR:. OK.
- Tutorial: ~/myscripts/FreeBSD/docs/amdiommu_irte_free.md present, code snippet and tested table match the commit.

VERDICT: ready
