# Review: pr/devmatch-hostb

e17a19cd8d225302792719cf28c9f8d248cb2a38 ("devmatch: Match host bridges owned by hostb(4)")
1ae06ab4700035042f044aadeed61d517a885542 ("devmatch: Match hostb and vgapci children on their own bus")
b87e9d190928a8a514239f772877cfa3f9858347 ("acpi_video: Let devmatch load the module")

POSTCR-1ae06ab4700035042f044aadeed61d517a885542-1: devmatch -a now searches hostb/vgapci devices only in the hostb/vgapci hints, so it stops reporting pci-bus matches for them (e.g. amdgpu/i915kms for the GPU)

## Comments

- POSTCR-...-1: `busdrv` is also true under `-a` (`all_flag`). Upstream,
  `devmatch -a` searched an attached vgapci0 in the `pci` hints, where
  drm-kmod tables live (LinuxKPI `MODULE_DEVICE_TABLE_BUS_pci` ->
  `MODULE_PNP_INFO(..., pci, ...)`, linux/pci.h:87). With the patch the bus
  becomes `vgapci`, so `devmatch -a` loses those lines. Either keep the
  parent bus under `-a`, or search both buses there.
- Wrong-module risk, checked:
  - In-tree, the only `MODULE_PNP_INFO` tables on bus `hostb` are the three
    moved here (amdtemp, amdsmn, amdsmu), all AMD/Hygon vendor IDs. Every
    other hostb/vgapci child (agp_*, vga_isa, powermac atibl/nvbl) has no
    PNP table. Intel host bridges match nothing.
  - Other AMD families: amdtemp/amdsmn now autoload wherever their table
    lists the device; probe filters by CPU family, so an unsupported one
    loads and stays unattached. amdsmu matches 1022:1630/14B5/14E8/1122 (and
    1507 with pr/amdsmu-strixhalo); its identify filters by CPU model.
  - Behaviour change worth a line in the commit message: amdsmu now
    autoloads on every Cezanne/Rembrandt/Phoenix/Krackan laptop, which
    changes s2idle (SMU sleep hint) for users who never loaded it.
  - drm stays out: LinuxKPI tables are on `pci`, never consulted for a
    vgapci-owned device.
  - acpi_video now loads on every x86 machine with a display controller
    (servers with BMC VGA, VMs). Probe needs `_DOD`/`_DOS`, so it stays
    unattached there; on laptops it attaches where before it needed a
    manual load, which changes brightness-key handling by default
    (intended, but say so).
- `T:class=0x03` matches pci pnpinfo `class=0x%02x%02x%02x`
  (pci.c:6717) by substring after a space: 0x0300xx, 0x0302xx, 0x0380xx.
  Fine; the table is only consulted for vgapci-owned devices anyway.
- Bypassing `DF_ATTACHED_ONCE` only affects the full scan (boot
  `rc.d/devmatch`); the `-p` nomatch path keeps its kldunload guard.
  `load_kld` skips loaded modules, so repeated output is harmless.
- Commit 2 rewrites everything commit 1 added; squash them. Commit 2's
  first sentence is misleading: commit 1 never matched display
  controllers; the vgapci case is new in commit 2.

## Checks

- style(9): clang-format22 with upstream .clang-format on the changed
  ranges: only differences are KNF-valid continuation of the `busdrv`
  expression and tab in the struct member (both match style(9)); the
  82-column `printf` line is pre-existing. No real deviation.
- Non-ASCII in added lines: none.
- GPL: devmatch logic and acpi_video table are original FreeBSD
  constructs (same `D:#;T:` idiom as iwx/rtsx). No Linux code involved.
- Datasheet: n/a (no new driver). acpi_video relies on the existing
  ACPI `_DOD`/`_DOS` probe.
- Commit messages: format OK, bodies within 72 columns, no tags.
  Subject of 1ae06ab47000 is 58 chars (over 50); "children" is wrong,
  it matches the hostb/vgapci devices themselves.
- Tutorial: ~/myscripts/FreeBSD/docs/devmatch_hostb.md present; code
  and tests match the final commits, but its commit table lists the
  pre-rebase hashes (96aeddeb3a89, 0198596f053b, 7d6d31baace6), and
  it does not mention the `-a` change.

VERDICT: ready

Resolved 2026-11-21: -a searches the parent bus and the hostb/vgapci bus (search_bus() helper); commits 1+2 squashed as e96cd28f5336 'devmatch: Match hostb(4) and vgapci(4) devices', message says amdsmu now autoloads; acpi_video message says where it loads and attaches; now e96cd28f5336 8a651c2184de. Tested with devmatch -a -v on the zbook.
