# Review: pr/pci-d3hot

e96f095feb2f6c9f4ae460f215b403738b86845c ("pci: Accept D3hot in pci_set_powerstate_method()")

No serious bugs found.

## Comments

- Verified the claim: `PCI_POWERSTATE_D3` is `PCI_POWERSTATE_D3_COLD` (4)
  since 84bbfc32a3f4 (pcivar.h:518-520), so a request for 3 hit
  `default: return (EINVAL)`. `acpi_pci_set_powerstate_method()` then takes
  `goto out` and skips `acpi_pwr_switch_consumer()`. `ACPI_STATE_D3_HOT` is 3
  in actypes.h:744, so an `_SxD` of 3 from `acpi_device_pwr_for_sleep()`
  reaches this path. LinuxKPI `PCI_D3hot` maps to `PCI_POWERSTATE_D3_HOT`
  (linux/pci.h:225) and `pci_set_power_state()` ignores the error.
  `Fixes:` tag is correct.
- No-change test: `pci_get_powerstate_method()` returns
  `PCI_POWERSTATE_D3` (4) for any PM D3, so without the new `>= D3_HOT`
  clause a D3hot request on a D3 device would rewrite D3. Correct.
  `PCI_POWERSTATE_UNKNOWN` is -1, so it never matches the new clause.
- acpi_pci interplay checked: device in D3 (read back as 4), request D3hot
  (3): `old_state > state` branch calls `pci_set_powerstate_method(3)`,
  which now returns 0 early; ACPI switches to D3hot. Request D3cold from
  D3hot: PCI write skipped, ACPI switches to D3cold. Both fine.
- Other in-tree D3 users (`pci_cfg_save` powerdown, `pci_power_reset`,
  `vga_pci_reset`, `pci_suspend_child`) all use `PCI_POWERSTATE_D3` and
  compare against the read-back value; unaffected.
- Behaviour change worth knowing: drm-kmod/LinuxKPI callers of
  `pci_set_power_state(PCI_D3hot)` now actually put the device in D3, where
  before the call was a silent no-op. Intended, but those paths were never
  exercised on FreeBSD; the tutorial lists the LinuxKPI case as untested.

## Checks

- style(9): clang-format22 with upstream .clang-format on lines 2880-2955
  only proposes re-wrapping the new `if` condition and reindenting the
  pre-existing 4-space `delay =` lines; the added code already follows
  style(9) (4-space continuation). No real deviation.
- Non-ASCII in added lines: none.
- GPL: native FreeBSD code, no Linux origin. Nothing to compare.
- Datasheet: not a driver. The PM register single-D3 encoding is from the
  PCI PM spec; a citation is optional.
- Commit message: subject 49 chars, body under 72 columns, `Fixes:` and
  `MFC after:` tab-aligned, no PR:. OK. Author olivier@FreeBSD.org.
- Tutorial: ~/myscripts/FreeBSD/docs/pci_d3hot.md present; the patch hunks
  are identical to the commit. Stale header: says based on cf58c8667cfd,
  branch is now on 6dc19a71f70c; line numbers are approximate.

VERDICT: ready

kbowling 2026-11-22: out-of-range state on a D3 device returned 0; fixed with state <= PCI_POWERSTATE_MAX (9bb5b48fd98f). zbook d3t module: state 5 returns EINVAL, D3hot/D3cold no-ops.
