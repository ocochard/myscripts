e38153bb186c42e650df0922e42d8fd03ec86748 ("iommu: Identity-map contexts when DMA remapping is disabled")
56481221379bf97f6d1f2506cf2a10fbb9ab4aea ("amdiommu: Skip the invalidation after PTE-only maps")

POSTCR-56481221379bf97f6d1f2506cf2a10fbb9ab4aea-1: a map that reuses a PDE just written by a concurrent map skips the flush, so its DMA can walk the stale cached PDE and IO_PAGE_FAULT

The branch head moved during the review: c9710d5ad454 was re-committed at 14:08 as 56481221379b, message only ("430 MB/s" -> "about 410 MB/s"), same tree. Read against the merge base 6dc19a71f70c.

Detail of the -1 bug. The commit's rule is that DMA through a new PDE needs a flush first, because unmap clears the PDE of a freed table before its invalidation runs (amdiommu_unmap_clear_pte() -> iommu_pgfree(entry) and amdiommu_free_pgtbl_pde(), amd_idpgtbl.c:318-333; amdiommu_domain_unload() emits INVALIDATE_IOMMU_PAGES afterwards, amd_ctx.c:131-141). But only the call that wrote the PDE flushes:
1. An unload removes the last mapping of a 2 MB region R: the leaf table P is freed (deferred) and PDE(R) cleared; the IOMMU may hold PDE(R) -> P until that invalidation executes.
2. Map X (CPU B) into R allocates P', writes PDE(R) -> P', sets pde_set, drops the pglock, then queues its flush behind the unload's commands and waits.
3. Map Y (CPU C) into R takes the pglock in that window, finds P' present and writes only its PTE: pde_set false, NpCache clear, no flush (amd_idpgtbl.c:290-293). amdiommu_map_buf() returns and the driver starts the DMA.
4. Y's DMA uses the cached PDE(R) -> P and reads a cleared PTE: IO_PAGE_FAULT, the signature of the 1303 faults measured for the NpCache-only version.
Maps of one domain do run concurrently: iommu_gas_map() calls domain->ops->map() after dropping the domain lock (iommu_gas.c:837), and nvme(4) loads from one I/O queue per CPU. The unload emits one INVALIDATE_IOMMU_PAGES per 4 KB page (amd_cmd.c:216-219), so under load the window is the one that produced the measured faults. The single-stream dd tests never have two maps in flight. The earlier per-domain field had the same hole: the problem is the skip condition, not kib's plumbing.
Fix options: keep the obligation until the flush completes, e.g. a per-domain count of PDE flushes in flight, raised under the pglock where pde_set is set, dropped after iommu_qi_invalidate_sync() returns, and flush whenever it is non-zero (Y's own pde = 1 flush then drops the stale PDE and completes after the earlier commands); or keep empty page table pages on unmap, as Linux v1 does, so that no map needs a flush with NpCache clear. Test with several parallel dd readers on nda0 at different offsets, then read the event log.

kib's PR #113 design, implemented:
- pde_set is gone from struct amdiommu_domain; amd_iommu.h only gains cap_hdr in struct amdiommu_unit.
- bool *pde_set goes through amdiommu_pgtbl_map_pte() and amdiommu_map_buf_locked(), set only where the PDE of a new table page is written (amd_idpgtbl.c:177-178); the recursion passes it down, so upper-level PDEs count.
- Callers (git grep; all static in amd_idpgtbl.c): the recursion and map_buf_locked() pass it; amdiommu_free_pgtbl_pde() and amdiommu_unmap_buf_locked() pass NULL and never allocate (tables exist, KASSERT(pte != NULL)); the store is guarded anyway.
- map_buf_locked() sets *pde_set = false before the loop (amd_idpgtbl.c:207), so amdiommu_map_buf() reads an initialized value on the 0 and ENOMEM returns. On ENOMEM without a new PDE the unwind only clears PTEs of this call, never handed to a device: no flush needed.
- Out-parameter rather than return value: the returns already carry the errno and the PTE pointer. Say so in the reply to kib.
- Flush condition: pde_set || NpCache (capability header bit 26, read in amdiommu_attach(), amd_drv.c:487); the flush is INVALIDATE_IOMMU_PAGES with pde = 1 per 4 KB page of the mapped range.

e38153bb186c, unchanged since the previous review:
- Only the AMD IR path reaches iommu_instantiate_ctx() with dma_enabled clear. iommu_get_dev_ctx() (also the entry point for arm64 gicv3_its and riscv, which share busdma_iommu.c) returns before it when DMA is off; Intel's RMRR caller runs from iommu_unit_pre_instantiate_ctx() behind the same check.
- The identity domain gets DTE pgmode 0 (pass-through) with iv and intctl still set, so IR keeps working; later references on the disabled context are dropped in iommu_instantiate_ctx().

Comments:
- Throughput: the message now says "about 410 MB/s"; the tutorial ZBook row says 433/430/433 MB/s (earlier revision) and the retest of this code reported 374 MB/s. Quote a figure the tutorial table shows, with its runs.
- e38153bb186c is committed as olivier@cochard.me (personal identity, non-ASCII name); the other three commits, and every committer in the last 500 freebsd/main commits, use @FreeBSD.org. Re-stamp the committer before pushing.

## Checks

- style(9): clang-format21 with freebsd/main .clang-format on the changed lines. Flags only reflows that match the neighbours: the pci_read_config() split (same as the BASE_LOW read below it), the map_buf_locked() and map_pte() call wraps, the 4-column continuation in busdma_iommu.c, the tab-aligned cap_hdr member. All added lines <= 80 columns. No deviation. busdma_iommu.c also loses a trailing blank.
- Non-ASCII: none in the diff or the messages (committer field of e38153bb186c above).
- GPL: nothing copied; the NpCache rule mirrors Linux amd_iommu_iotlb_sync_map(), as the message says, in FreeBSD's own code. e38153bb186c has no Linux counterpart.
- Spec: NpCache is AMD IOMMU spec 48882 capability header bit 26; pcireg.h already cites the document (rev 3.09). Optional in the message.
- Commit messages: subjects 59 and 51 chars, prefixes iommu: (sys/dev/iommu) and amdiommu:; bodies <= 72 columns; tags tab-aligned; Fixes: only on the bug fix; no PR:.
- Tutorials: bugreport_amdiommu_ir_only_loop.md and iommu_idmap_when_dma_disabled.patch match e38153bb186c (same +/- lines). bugreport_amdiommu_map_invalidation.md does not match: lines 55-58 put pde_set in struct amdiommu_domain, cleared and read in amdiommu_map_buf(); describe the bool * out-parameter (NULL from the unmap callers) instead, add the retest of this revision next to the 433/430/433 MB/s row, and the concurrency limit or its fix. amdiommu_skip_map_invalidation.patch is still the domain->pde_set version under the old subject; regenerate it.

VERDICT: fix needed (POSTCR-56481221379bf97f6d1f2506cf2a10fbb9ab4aea-1 flush skipped by concurrent maps; tutorial and .patch show domain->pde_set; reconcile the 410 MB/s figure; e38153bb186c committer identity)

Status 2026-11-22: POSTCR-...-1 confirmed from the code (main flushes after every map, so the hole is new; the flush has pde = 1, so the second map's own flush would clear the stale PDE). 16+16 parallel dd readers gave 0 faults on the unfixed kernel: not reproduced. Draft fix d4d285d4df8e (not on pr/amdiommu yet): per-domain pde_flushes count under the page-table lock; a map writing a PDE counts itself until its flush completes; any map seeing a nonzero count flushes. Zbook test of the draft: dd 439/442/443 MB/s, 16+16 parallel readers, msigt 64/64, hdac 64/64, 0 faults. Committer identity fixed in the draft. Throughput varies by boot (374, 407-431, 439-443 MB/s): message to say "400 to 440 MB/s". Tutorial and .patch still stale.

Resolved 2026-11-22: pr/amdiommu = 00e0dde9484b, 195da7d956f6 (pde_flushes fix, committer olivier@FreeBSD.org on both, message "400 to 440 MB/s" plus one sentence on concurrent maps). Tutorial and patches regenerated.
