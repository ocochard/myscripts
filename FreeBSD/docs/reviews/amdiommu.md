e38153bb186c42e650df0922e42d8fd03ec86748 ("iommu: Identity-map contexts when DMA remapping is disabled")
ea9897aaa755e6e19fa3ff6c71409172cd8b6c2e ("amdiommu: Skip the invalidation after a map that only fills PTEs")

No runtime bug found.

e38153bb186c, checked:
- iommu_instantiate_ctx() callers on main: amdiommu_ir_find() (amd_intrmap.c), iommu_get_dev_ctx() (returns NULL earlier when !dma_enabled), dmar_inst_rmrr_iter() (reached only via dmar_instantiate_rmrr_ctxs() <- unit_pre_instantiate_ctx <- iommu_get_dev_ctx(), after the same dma_enabled check). arm64/riscv have no other caller. So the new `!unit->dma_enabled` term is reachable only from the AMD IR path. Intel DMAR: no behaviour change (dmar_ir_find() never instantiates a ctx). dma_enabled is CTLFLAG_RD, set once in iommu_init_busdma().
- Disabled path: first ref kept with IOMMU_CTX_DISABLED, later refs dropped via iommu_free_ctx_locked() -> amdiommu_free_ctx_locked() refs > 1 branch, so the IR path no longer piles refs in this mode. id_mapped domain sets IOMMU_DOMAIN_IDMAP, DTE pgmode 1T1, IRT still programmed in dte_entry_init_one().

ea9897aaa755, checked:
- PCIM_AMDIOMMU_CAP_NPCACHE (1 << 26) and PCIR_AMDIOMMU_CAP_HEADER exist in pcireg.h; bit matches spec #48882 capability header NpCache.
- IOVA reuse: unload frees GAS space only after the invalidation completes (iommu_qi_drain_tlb_flush(), or sync invalidate before iommu_domain_free_entry()), so a map never reuses an IOVA with a stale present IOTLB entry.
- Freed table pages: iommu_pgfree() with entry keeps the page on entry->pgtbl_free until the deferred flush; a new PDE in that slot always comes from the allocation branch of amdiommu_pgtbl_map_pte(), which sets pde_set, and the sync flush (INVALIDATE_IOMMU_PAGES, pde = 1) covers the walk of the new range. Upper-level PDEs created by the same map are covered the same way.
- pde_set written only under the domain pglock (map_pte from map/unmap paths, both locked); read back before unlock.
- ENOMEM path of amdiommu_map_buf_locked(): partial PTEs were never handed to the device; any new PDE still forces the flush.

Interaction with pr/amdiommu-irte: both edit amd_iommu.h; hunks apply in either order (verified with patch(1)), different structs and locks, no semantic conflict.

Comments:
- ea9897aaa755 message: "capped NVMe reads at 44 MB/s with 46 IOMMU interrupts per 128 KB read" does not match the tutorial, which measures 51 interrupts per 128 KB read and 752/760/653 MB/s for stock + DMA remapping on the SER6, and states the NV2 itself varies 44.7 to 750 MB/s between boots. 44 MB/s is drive variance, not an IOMMU cap. Use the tutorial's numbers (e.g. 51 -> 19 interrupts per 128 KB read; ZBook 200 -> 430 MB/s).
- ea9897aaa755 has no Fixes: tag; it is a performance change, so none is required.
- e38153bb186c body says "On a Ryzen 7 7735HS"; the ZBook (Strix Halo) reproduces too, optional to mention.

## Checks

- style(9): clang-format21 with upstream .clang-format on changed lines. Flags: struct comment alignment (matches neighbours), pci_read_config() split in amd_drv.c (matches the two reads right below), and 8-column continuation in busdma_iommu.c (style(9) uses 4, as written). No real deviation. The patch also drops a trailing space on the pci_get_slot() line.
- Non-ASCII: none in diffs or commit messages.
- GPL: ea9897aaa755 follows Linux behaviour (amd_iommu_iotlb_sync_map() flushes on map only with NpCache), cited in the body; the code is FreeBSD's own (flag in map_pte, test in map_buf), nothing copied. e38153bb186c has no Linux counterpart. OK.
- Spec: NpCache semantic comes from AMD IOMMU spec #48882 (capability header bit 26); citing it in ea9897aaa755 would help reviewers, optional.
- Commit messages: subjects 59 and 64 chars (over 50, acceptable); prefixes "iommu:" and "amdiommu:" (pr/amdiommu-irte uses "amd_iommu:", pick one); bodies <= 72 cols; Fixes:/MFC after: with tabs; no PR:.
- Tutorials: ~/myscripts/FreeBSD/docs/bugreport_amdiommu_ir_only_loop.md matches e38153bb186c (same hunk, caller analysis). ~/myscripts/FreeBSD/docs/bugreport_amdiommu_map_invalidation.md matches the code of ea9897aaa755, but its numbers contradict the commit message (above).

VERDICT: ready

Resolved 2026-11-21: ea9897aaa755 message amended to the tutorial numbers (now 45463d7ab4e0, same tree); subject shortened to 51 chars.
