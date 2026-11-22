ede5032f6fb073e0656f58d98d92de453923e47b ("x86: Release the IOMMU entries of an MSI group at once")
27c94c177c17994cc8e12815fb2025f84a57c372 ("amdiommu: Free and align interrupt remapping entries")

No runtime bug found in the reviewed commits.

Read against the merge base 6dc19a71f70c (freebsd/main is now 02e1b1cd1fb1; no touched file changed). Since the previous review: ede5032f6fb0 unchanged; 8baaa149192b -> 27c94c177c17 changes only the AMD free path (one interrupt table invalidation per group), same message.

kib's PR #112 design, implemented completely:
- msi_release() (msi.c:564-569) calls iommu_unmap_msi_intr(first->msi_dev, first->msi_remap_cookie, count) once, under one msi_lock drop; msix_release() (msi.c:787) passes 1.
- Intel dmar_ir_free_irte() (intel_intrmap.c:306-324): clears count IRTEs, one dmar_qi_invalidate_iec(cookie, count) (splits an unaligned range into aligned descriptors, one wait), then vmem_free(count). The IOAPIC unmap passes 1 (intel_intrmap.c:230).
- AMD: vmem_xalloc(count, align count) (amd_intrmap.c:100-102); amdiommu_ir_free_irte() clears count IRTEs, then one INVALIDATE_INTERRUPT_TABLE for the requester devid, which flushes the device's whole table (amd_cmd.c:283-301); then vmem_xfree(count) (amd_intrmap.c:208).

Checked:
- vmem pairing on every path. AMD irtids: vmem_xalloc() from MSI (count) and MSI-X (1), vmem_xfree() with the same count; amdiommu_map_ioapic_intr() allocates nothing. Intel irtids: vmem_alloc() from MSI (count), MSI-X (1) and IOAPIC (1), vmem_free() with the same sizes; the count 1 paths behave as before. Both arenas have qcache_max 0 (amd_intrmap.c:352, intel_intrmap.c:365), so vmem_free() is vmem_xfree(), and the freed (addr, size) always matches the segment: the bt_start/bt_size MPASSes the old per-message free broke now hold.
- Cookies: both drivers return cookies[i] = idx + i from one segment, or all -1 on EOPNOTSUPP; msi_alloc() stores them in irqs[] order, so first->msi_remap_cookie is the segment start and one cookie == -1 test covers the group. x86_no_iommu leaves the cookies unset, but its unmap ignores them (pre-existing, harmless).
- Unwind: in msi_alloc() and msix_alloc() the IOMMU allocation is the last step that can fail; on failure no segment exists and the vectors are freed. No path frees an index it did not allocate.
- vmem_xalloc() arguments pass every MPASS in subr_vmem.c (align a power of 2 and a multiple of quantum 1, phase 0 < align, nocross 0). count is a power of 2 on every path: pci_alloc_msi_method() rejects others (pci.c:2704) and passes maxcount = count; vmd(4), hyperv pcib and the acpi/x86 pcib pass the child's request through; msix_alloc() passes 1. count > irte_nentries returns ENOMEM and pci_alloc_msi_method() retries with half.
- Alignment is required: amdiommu_map_msi_intr() sets data = cookie and the device modifies the low log2(count) data bits (MME = count). Intel needs none (index = handle + subhandle, data = 0).
- KASSERT ranges cannot wrap: cookie < n is tested first, then count <= n - cookie. count >= 1 meets dmar_qi_invalidate_iec()'s start < start + cnt.
- Order: entries cleared, invalidation completed, then index freed, so a new owner never sees a cached IRTE.
- msi_lock: dropped after the group checks and before any field is cleared, once instead of count times. msi_dev and msi_first stay set across the window, so msi_alloc() cannot reuse the sources; the unit, vmem and context locks are only taken with msi_lock dropped, as since e8fc8eb8b8f5.
- Changed signatures: git grep on the branch finds the struct x86_iommu hook, its three providers (dmar, amdiommu, x86_no_iommu), the wrapper and the two callers; all converted. i386 builds msi.c (files.i386 "optional apic pci") and the iommu files with options IOMMU (i386 LINT includes x86/conf/NOTES); no arch-dependent type is involved.
- Bisect: ede5032f6fb0 alone builds; AMD there still clears entry by entry and leaks, as its message says.
- Messages: accurate. 0a110d5b172e introduced both the block vmem_alloc(count) and the per-message vmem_free(cookie, 1); 0f5116d7efe3 the unaligned vmem_alloc() and the missing free (checked in those commits).

Comments:
- Hardware: the zbook runs (16-message MSI group x64 on USB4, hdac x64) used 8baaa149192b. 27c94c177c17 has not run; rerun the 16-message cycle on the zbook before sending. The carbon run applies (ede5032f6fb0 unchanged).
- AMD with IR only (hw.iommu.dma=0) also needs e38153bb186c (PR #113), otherwise the context gets an empty translating page table. Give the kernel composition in the tutorial table.
- Pre-existing, no ID (no realistic trigger found: two first-time instantiations of one RID must race, and contexts are created from the device's own attach): the lost-race path of amdiommu_get_ctx_for_dev() (amd_ctx.c:570-573, since 0f5116d7efe3) frees ctx1 with free() only and leaks its tag, IRT and irtids arena. Needs amdiommu_ctx_fini_irte(ctx1) and free(ctx1->context.tag); separate patch.
- Pre-existing: amdiommu_ir_find() takes a context reference on every alloc, map and unmap and never drops it when DMA remapping is on; no visible effect while contexts are not freed.

## Checks

- style(9): clang-format21 with freebsd/main .clang-format on the changed lines. Three flags, none real: amdiommu_ir_free_irte() definition rewrap (the break predates the patch), KASSERT continuation (clang-format wants 8 more columns; 4 is style(9) and matches the neighbours), dmar_ir_free_irte() prototype would fit in exactly 80 columns (the split is legal). for-loop declarations are allowed by style(9).
- Non-ASCII: none in the diff or the messages.
- GPL: no Linux code. Linux alloc_irq_index() also aligns multi-message MSI on roundup_pow_of_two(count); this uses vmem_xalloc(), nothing copied.
- Spec: fixes to existing drivers. The alignment comment could cite AMD IOMMU spec 48882 (MSI data[10:0] is the IRTE index); optional.
- Commit messages: subjects 54 and 52 chars, prefixes x86: (msi.c plus both drivers) and amdiommu: (the most used for amd_*); bodies <= 72 columns except the 101-column Fixes: line (0a110d5b172e has no short subject; acceptable for a tag); tags tab-aligned; no PR:; author and committer olivier@FreeBSD.org.
- Tutorial: ~/myscripts/FreeBSD/docs/amdiommu_irte_free.md does not match the commits. Must change:
  1. Header: two commits on pr/amdiommu-irte; line numbers from 6dc19a71f70c (now 611046b15dbb).
  2. Section 2, item 1: the Intel driver is now fixed by ede5032f6fb0; show its vmem_xfree() MPASS / NULL bt in bt_rembusy() path.
  3. Section 3: replace the bitmap with the two-commit design (count passed by msi_release(); DMAR count clear, one IEC invalidation, vmem_free(count); AMD aligned vmem_xalloc(), one INVALIDATE_INTERRUPT_TABLE, vmem_xfree(count)). List the bitmap as the rejected alternative (kib: free the block in msi.c, vmem_xalloc() for the alignment).
  4. "Not fixed": drop Intel; keep the amdiommu_unmap_ioapic_intr() stub.
  5. Section 4: add the zbook rows (16-message USB4 x64, hdac x64) and the carbon row (8-message xhci1 x64) with kernel and revision; the "multiple-message MSI device under IR: untested" row is now tested.
  6. Regenerate amdiommu_irte_free.patch from freebsd/main..pr/amdiommu-irte (it is the bitmap version).

VERDICT: ready

Status 2026-11-22: the AMD group test ran on this code (zbook test kernel with the 27c94c177c17 delta, hw.amdiommu.enable=1 hw.iommu.dma=1): msigt 64/64 cycles of 16 messages, 0 misaligned; hdac 64/64; 0 IOMMU faults. Test module: docs/amdiommu_msigt.c. Tutorial and .patch still stale.

Resolved 2026-11-22: tutorial rewritten for the two-commit design with the zbook and carbon rows; patch regenerated from freebsd/main..pr/amdiommu-irte.

Pushed 2026-11-22 as c6fdd1d8634f, 9b0aa430a96c (rebased on 02e1b1cd1fb1, tags added, code unchanged).

Local 2026-11-22: 342579ded8e0, 60acc4c686a3 (ron link tag unified to Pull Request:, code unchanged; to push).

kbowling 2026-11-22: IEC index mask not capped at MHMV (fixed in c05c25cc6728), AMD invalidated the requester ID instead of ctx->context.rid (fixed in 56a12c719059, map path too). zbook msigt/hdac 64/64; carbon 64/64 (MHMV 15, cap not hit; loop checked with docs/amdiommu_iec_mask_sim.c).
