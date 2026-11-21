# Review: pr/amdsmu-strixhalo

2bd785fd3709edd1ccd83dd750e570b7a7ad98d1 ("amdsmu: Add Strix Halo support")
370e9f318485af743668706a0be84273ff18cda8 ("amdsmu: Diagnose S0i3 blockers on Strix Halo")
3edbb6ef3e4d5dcca50b1236300a172ecbacd5eb ("amdsmu: Only report IP blocks the SMU tracks")
837d301b93fe25895f0179e7da7b6fc1356ebad7 ("amdsmu: Restart the SMU log before each suspend")

No serious bugs found.

## Comments

- 370e9f318485: the new `>` filter plus the existing `<` filter means a
  block is reported only when its last active time equals
  `time_last_in_sw_drips` exactly. Measured exact on Strix Halo
  (tutorial), but the filter applies to Phoenix and Krackan too, untested
  there. Narrower option: an `ignore` row for USB4_1, or a per-product
  check. Not filed as a bug: no evidence it hides a blocker elsewhere.
- Bisect order: with 370e9f318485 alone, a second suspend in one boot
  accumulates last-active times (tutorial: JPEG_1 43088401 = sum of two
  sleeps), so the `>` filter hides real blockers until 837d301b93fe.
  Put 837d301b93fe before 370e9f318485.
- 837d301b93fe: `LOG_RESET` before each suspend likely also resets the
  `total_*` counters, making the `total_time_in_s0i3`/`..._sw_drips`/
  `..._resuming` sysctls per-suspend despite their descriptions. Same as
  Linux amd_pmc; worth checking one value after two suspends and fixing
  the descriptions if so.
- Diagnostics table: USB4_0 is `ignore = true` by name ("garbage on
  Phoenix and Krackan Point"); with the v2 name table that now also hides
  Strix Halo USB4_0 (index 17), which may be a real blocker.
- Naming: 1022:1507 is the family 1Ah model 20h root complex in Linux
  amd_pmc, shared by Strix Point (model 20h, 22-entry table) and Strix
  Halo (70h). `PCI_DEVICEID_AMD_STRIX_HALO_ROOT` and the existing
  "Strix Point (0x14A4)" XXX comment read inconsistent; consider a
  family/model name.
- Cross-topic with pr/devmatch-hostb: no textual conflict (MODULE_PNP_INFO
  line ~595 vs suspend/resume_check ~295-365, table in amdsmu.h). Semantic:
  the PNP table is `amdsmu_products`, so the new 1507 row is exported to
  linker.hints and devmatch will autoload amdsmu on Strix Halo (and
  load-but-not-attach on 1Ah model 20h). The tutorial measured
  "patched amdsmu, zzz: sleeps, does not wake ... forced power off" on
  main without the s2idle-wake series. Landing both topics makes that the
  default for every Strix Halo user doing s2idle. Land the wake fixes
  first, or note it.
- pre-existing (not filed, cosmetic): `amdsmu_get_ip_blocks()` prints the
  trailing "\n" only when the last block is supported, so the "Active IP
  blocks" line is unterminated otherwise (since 69124109c5a0 or earlier).

## Checks

- style(9): clang-format22 on the changed ranges: the two added
  comments in `amdsmu_resume_check()` (lines 361 and 370 of the branch
  file) are 81 columns; shorten them. Table row and #define match the
  surrounding hand-aligned style; other diffs are pre-existing.
- Non-ASCII in added lines: none.
- GPL: added code is a table row, two `continue` filters and two calls
  to the existing `amdsmu_cmd()`; behaviour follows Linux amd_pmc
  (`amd_pmc_setup_smu_logging()`, supported-constraints mask) without
  copied code.
- Datasheet: no public AMD SMU spec; commit messages cite Linux amd_pmc
  as the reference, consistent with the existing driver.
- Commit messages: subjects <= 50 chars, `amdsmu:` prefix, imperative,
  bodies within 72 columns, no tags.
- Tutorial: ~/myscripts/FreeBSD/docs/amdsmu_strix_halo.md present; rows
  1, 2, 2b, 2c match the four commits (hashes are pre-rebase:
  eb3bffacdf28, fd35f91cc43e, 1bc9633f8370, 20cb2e99be81).

VERDICT: ready

Resolved 2026-11-21: log-reset commit moved before the > filter (order now 31cad82a9b5a, f522735ca04d, 669b77e23c4e, f56cea26e82c), the two 81-column comments shortened; final tree differs from 837d301b93fe only in those comments. The 82-column table row matches the existing Krackan 70h row. Land after s2idle-wake (see the devmatch-hostb comment above).
