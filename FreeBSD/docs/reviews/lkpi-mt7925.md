# Review: pr/lkpi-mt7925 (7 commits on upstream/main 6dc19a71f70c)

41b3115f0963b6bd49c68f2e39c7597d2a277ce1 ("LinuxKPI: idr: allow lookups after idr_destroy()")
14dff05aacbe276b1e26454188185fff2d44dea2 ("lindebugfs: export debugfs_create_devm_seqfile()")
7a33f51ee9fab5c4041e06e0932b26f55c61bb9d ("LinuxKPI: skbuff: make napi_consume_skb() free the skb")
a3716ed1cecb4afaef0c38279706ff164d306c2b ("LinuxKPI: page pool: work without PAGE_IS_LKPI_PAGE")
f10864237827ed394110352dd3de4a8be20ebedd ("LinuxKPI: skbuff: cache skb data allocations below mem_limit")
e656e32dcec51a9818cccc68e74e3f090a842acb ("LinuxKPI: 802.11: set an airtime estimate on dequeued frames")
aea19cb07db668eb5ea78f19bf08d056ae550df2 ("LinuxKPI: 802.11: request TX status only when needed")

## Bugs

POSTCR-a3716ed1cecb4afaef0c38279706ff164d306c2b-1: lkpi___skb_linearize() frees page-pool frags and head with __free_page()/skb_free_frag(), leaking the side-table entry and its DMA mapping

a3716ed1cecb converts linuxkpi_kfree_skb() to return `_SKB_PP_RECYCLE`
frags and heads through page_pool_put_full_page(), but
lkpi___skb_linearize() (linux_skbuff.c, same file) still frees every frag
with __free_page() and an external head with skb_free_frag(), regardless
of `_SKB_PP_RECYCLE`. The page goes back to the VM while its
`lkpi_pp_page` stays in `lkpi_pp_hash[]` and its dma_map_page_attrs()
mapping is never unmapped. Reachable with in-tree code alone:
mt76_dma_rx_process() builds a multi-buffer RX skb from pool pages
(napi_build_skb() + skb_mark_for_recycle() + mt76_add_fragment()), and
mt7925_mcu_rx_event() / mt7921 mcu.c:365 call skb_linearize() on it for
any MCU event larger than one RX buffer. Each such event leaks one
record per page plus a busdma map (a bounce page for the 32-bit DMA mask
of mt792x on hosts with memory above 4 GB, or an IOMMU mapping). Before
this commit page pool allocation returned NULL in the only compiled
configuration (PAGE_IS_LKPI_PAGE is defined nowhere), so no such skb
existed. Fix: apply the same `_SKB_PP_RECYCLE` test in
lkpi___skb_linearize(), ideally via one helper shared with
linuxkpi_kfree_skb().

No other runtime bugs found.

## Comments

- Standalone: each of the 7 builds on upstream/main without the mt76
  commits (headers checked: `net/page_pool/helpers.h` already included by
  linux_skbuff.c, `virt_to_head_page()` reached via dma-mapping.h ->
  mm.h; kmem_alloc_contig_domainset()/DOMAINSET_FIXED from the added
  vm_extern.h / domainset.h). No commit references an mt76 change.
- 14dff05aacbe still needed: upstream sys/modules/lindebugfs/Makefile has
  no `debugfs_create_devm_seqfile` in EXPORT_SYMS. d5cbb6229f53 and
  c343c445e2c9 only touch lindebugfs.c; no conflict. With the patch every
  non-static function in lindebugfs.c is exported (checked by diffing the
  function list against EXPORT_SYMS). Also unblocks brcmfmac and other
  mt76 chips that call it.
- 41b3115f0963: only find/remove/get_next are guarded; idr_alloc(),
  idr_replace(), idr_for_each() after idr_destroy() still hit a destroyed
  mutex. Fine for the mt76 case; the subject says "lookups" but it also
  covers idr_remove(). The unlocked mtx_initialized() check is only safe
  without a concurrent idr_destroy(), same contract as Linux.
- 7a33f51ee9fa: also fixes an existing leak in in-tree mt7921
  (mt7921_mac_tx_free(), mt7921_queue_rx_skb() PKT_TYPE_TXRX_NOTIFY):
  every TX skb freed through the stub was leaked. Worth saying in the
  message. The NULL check is redundant (kfree_skb() handles NULL).
- a3716ed1cecb: one global MTX_DEF and a 1024-bucket table for every pool
  page on every alloc, get_dma_addr and free; acceptable as the stated
  stopgap. A pool destroyed with pages still out leaves records holding
  `ppp->dev`; mt76 drains its rings before page_pool_destroy(), so not a
  bug today. A `_SKB_PP_RECYCLE` head that is not a pool page falls back
  to put_page(), which equals __free_page()/page_frag_free() in LinuxKPI,
  so the miss path is safe. Effect on mt7921: RX now gets buffers (it got
  none before, same as mt7925). No other in-tree driver creates a page
  pool (only mt76/mac80211.c:675).
- f10864237827: mirrors kern_mbuf.c mbuf_jumbo_alloc() (custom allocf with
  kmem_alloc_contig_domainset, UMA_SLAB_KERNEL). Size-aligned items cannot
  cross a page, so rtw88's single-segment 32-bit requirement holds. Zone
  lookup on free uses `skb->end - skb->head`, consistent with alloc
  (`end = head + size`, `len == size` on the zone path). When the head
  was external, both callers set `skb->head = NULL` before
  lkpi_skb_free_head(), so `end - NULL` is computed: works (no zone ->
  free(NULL)) but is UB pointer arithmetic; test `skb->head == NULL`
  first. Only active with compat.linuxkpi.skb.mem_limit != 0 (rtw88 users
  today).
- e656e32dcec5: only mt76 reads tx_time_est in sys/contrib/dev; iwlwifi,
  rtw88, rtw89 and athk ignore it. With no AQL in LinuxKPI, mt76 loses its
  only per-station in-flight cap; queue depth is then bounded by the
  hardware ring only. ni_txrate is read without the node lock (benign
  race); when LinuxKPI never updates ni_txrate the estimate is just a
  non-zero placeholder, which is all mt76 needs.
- aea19cb07db6: effect on other drivers matches Linux: rtw88 (pci.c:1054,
  usb.c:339, sdio.c:1213) stops waiting for a firmware TX report on plain
  data frames and reports them ACKed at DMA completion; rtw89 core.c:1270
  stops requesting a report for them; iwlwifi does not test the flag. The
  `info == NULL` change only reaches drivers that call
  ieee80211_tx_status_ext() without info (mt76
  __mt76_tx_complete_skb()); net80211 now counts those as success instead
  of failure and skips ratectl. Side effect: an EAPOL/M_TXCB frame whose
  mt76 pktid idr_alloc() fails is now reported as success to its
  callback.

## Checks

- style(9): clang-format22 with upstream .clang-format on the added line
  ranges of the 5 C files: only the known clang-format vs style(9)
  divergences (`#define<tab>`, blank line in functions without locals,
  tab-aligned struct members matching the file, vm/ include order).
  No real deviations.
- Non-ASCII: none in added lines.
- GPL: no copied Linux code. idr/napi_consume/lindebugfs are trivial; the
  page-pool side table and UMA zones are FreeBSD-native (UMA pattern from
  kern_mbuf.c); the airtime estimate is a plain len*8/rate formula, not
  mac80211's ieee80211_calc_expected_tx_airtime() tables; the TX status
  condition is a FreeBSD-side test on mbuf flags (M_EAPOL, M_TXCB), not
  mac80211 code.
- Datasheet: n/a (LinuxKPI compat, no driver written from a spec).
- Commit messages: 41b3115f0963 body line 1 is 74 columns (> 72).
  Subjects 48-60 chars; 4 exceed 50 ("if possible"). Lower-case verb after
  the prefix (`LinuxKPI: idr: allow`) differs from the SKILL.md
  `Imperative summary` capitalisation, though bz@'s LinuxKPI 802.11
  commits use the same lower case. No tags, none needed.
- Tutorial: ~/myscripts/FreeBSD/docs/mt7925_wifi.md + mt7925/0001,0002,
  0005-0009 present; the patch diffs are identical to the 7 commits, but
  the doc still describes the single 12-commit series (old base
  83c8ec72ac6a, github hashes, numbering 1-12) and does not mention the
  pr/lkpi-mt7925 / pr/mt7925 split.

VERDICT: ready

Resolved 2026-11-22: lkpi_skb_free_page()/lkpi_skb_free_extfrag() shared by kfree_skb and skb_linearize in the page pool commit (now db5cce1b6ad3), skb_linearize clears _SKB_PP_RECYCLE after freeing; idr message rewrapped; napi_consume_skb message names the in-tree mt7921 leak; tutorial notes the split. All 7 commits build. linearize path not hit at runtime (dtrace: 0 calls).
