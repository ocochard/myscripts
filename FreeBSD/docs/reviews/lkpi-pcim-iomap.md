de8991be7bf2f7aadbfd61823d20ebc451c32530 ("LinuxKPI: pci: Fix pcim_iomap() BAR release")

No new runtime bugs found.

## Comments

- Default mode fix is right: the old code called `rman_get_bushandle()`
  on a bus handle, i.e. read `r_bushandle` out of device MMIO, so
  `mmio_table[bar]` was a register value and the release matched no BAR.
- The iwlwifi claim in the commit message ("With want_iomap_res
  (iwlwifi) ... that BAR leaked too") is wrong for iwlwifi.
  iwl_pci_probe() calls `pcim_request_all_regions()` before
  `pcim_iomap()` (sys/contrib/dev/iwlwifi/pcie/drv.c:1170-1180).
  `lkpi_pci_request_region()` allocates the BAR and puts it on
  `pdev->mmio`; `_lkpi_pci_iomap()` then returns that same resource from
  its duplicate check. Before the patch the mismatched `pci_iounmap()`
  was a no-op and `lkpi_pci_devres_release()` -> `pci_release_region()`
  released the BAR: no BAR leak. After the patch the iomap devres
  (newer, released first, devres list is LIFO) releases the BAR, then
  `pci_release_region()` calls `bus_release_resource()` on it again.
  For a PCI child the entry is RLE_RESERVED, so resource_list_release()
  returns EINVAL (ignored), no panic. Same double release for any driver
  that does pci_request_region(s) + pcim_iomap() on a BAR. Under vgapci
  (drm devices) the second release hits vga_pci_release_resource() and
  can drop a reference another child holds. Root cause is pre-existing:
  `_lkpi_pci_iomap()` shares the region's resource without a reference,
  since 2f9064a5d2b5 for pcim_iomap and earlier for pci_iomap. Fix the
  commit message and tutorial (section 2 item 3); refcounting the shared
  mmio entry would be a separate change.
- Pre-existing, not touched: `pci_release_region()` compares `rle->res`
  with `rman_get_bushandle(mmio->res)` (resource pointer vs bus handle),
  so it never unlinks the mmio entry it releases.
- Pre-existing, not touched: the `linuxkpi_pcim_iomap_regions()` error
  path (96ab16ebab63) passes `mmio_table[bar]` to `pci_iounmap()`, which
  matches nothing with `want_iomap_res`, and leaves the dr tables set.
  No in-tree want_iomap_res user calls pcim_iomap_regions().
- ABI: only linux_pci.c changes, no header or struct change. No
  `__FreeBSD_version` bump and no consumer rebuild needed.

## Checks

- style(9): clang-format21 on the changed lines only rewraps the new
  ternary in `lkpi_pcim_iomap_table_release()`; the patch's wrap is
  style(9) conforming. Other diffs are pre-existing lines. No real
  deviation.
- Non-ASCII in added lines: none.
- GPL: FreeBSD-only devres/resource plumbing, no Linux code involved.
- Drivers datasheet: n/a.
- Commit message: subject `LinuxKPI: pci: Fix pcim_iomap() BAR release`
  44 chars, body <= 72 columns, `Fixes:` and `MFC after:` tab aligned.
  Fixes: 2f9064a5d2b5 subject verified. Body content: see iwlwifi above.
- Tutorial: ~/myscripts/FreeBSD/docs/linuxkpi_pcim_iomap_release.md
  present and matches the diff; section 2 item 3 repeats the wrong
  iwlwifi leak claim (it does say "found by reading, not measured").

VERDICT: ready

Resolved 2026-11-21: release skips a BAR owned by a requested region (no double release with pcim_request_all_regions()), commit message and tutorial corrected (no iwlwifi leak claim); now 0351a3945238, kernel builds. mt7925 reload test on the zbook inconclusive: the control kernel without this commit hangs the same way.
