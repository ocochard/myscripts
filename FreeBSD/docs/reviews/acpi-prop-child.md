# Review: pr/acpi-prop-child

5e0fcbf6774ca899a387daa26117bb7c7a1c143c ("acpi: Refuse property requests for other buses children")

POSTCR-5e0fcbf6774ca899a387daa26117bb7c7a1c143c-1: dpaa2_mac_dev and memacphy_acpi lose their _DSD properties, so they no longer attach on ACPI-booted DPAA2 (LX2160A) systems
POSTCR-5e0fcbf6774ca899a387daa26117bb7c7a1c143c-2: pre-existing: acpi_device_get_prop() casts the ivars of any descendant to struct acpi_device and follows garbage pointers (since 3f9a00e3b577)

## Bug 1: regression on DPAA2

Two acpi(4) children build grandchildren that carry a real `struct
acpi_device` as ivars and depend on acpi answering property requests for
them:

- `dpaa2_mc_acpi_probe_child()` (sys/dev/dpaa2/dpaa2_mc_acpi.c:204) adds
  `dpaa2_mac_dev` children of `dpaa2_mc` with a malloc'ed `struct
  acpi_device` (ad_handle set). `dpaa2_mc_acpi_get_property()` forwards
  with `bus_generic_get_property()`, so the request arrives at acpi with
  `device_get_parent(child) == dpaa2_mc`, not acpi.
- `memac_mdio_acpi_probe_child()` (sys/dev/dpaa2/memac_mdio_acpi.c:213)
  does the same for `memacphy_acpi`; `memac_mdio_get_property()` forwards
  too.

With the patch:

- `dpaa2_mac_dev_probe()` reads "reg" with `device_get_property()`, gets
  -1 and returns ENXIO: no dpaa2_mac_dev attaches, so
  `dpaa2_mc_acpi_get_phy_dev()` fails for every DPMAC.
- `memacphy_acpi_attach()` reads "phy-channel", gets -1, sets
  `scc.phy = -1` and returns ENXIO: no PHY, no miibus.

Net effect: no Ethernet PHY on ACPI DPAA2 boards (SolidRun HoneyComb
LX2K, the platform these drivers were written for). Not tested here (no
hardware); the call chain is direct.

A fix needs those buses to keep working, e.g. an exported acpi helper
that the two forwarders call for their own children (they know the
ivars are `struct acpi_device`), or an opt-in on the intermediate bus.
The direct-child check stays right for everything else.

## Bug 2 (pre-existing, what this commit fixes)

Since 3f9a00e3b577 ("device: add device_get_property and
device_has_property"), acpi(4) implements `bus_get_property` with
`acpi_device_get_prop()` taking `device_get_ivars(dev)` unchecked.
`device_get_property()` on any deeper ACPI-enumerated device (acpi_iicbus
children, e.g. pca954x via `device_has_property()`; dp83867phy under
miibus; acpi_gpiobus children) reaches it through
`bus_generic_get_property()` with foreign ivars. Reproduced on the ZBook
(tutorial: freeze at kldload). The patch fixes this but too broadly (bug
1).

## Comments

- Commit message: "acpi(4) is the only bus implementing bus_get_property"
  is wrong: simplebus(4) implements it, and dpaa2_mc_acpi /
  memac_mdio_{acpi,fdt} implement forwarders. True only for x86. Reword
  once bug 1 is addressed.
- No conflict with pr/s2idle-wake: different functions in acpi.c,
  `git merge-tree` of both branches is clean, and s2idle-wake does not
  use device properties.
- Grammar: "other buses children" / "that child ivars": missing
  possessives ("other buses' children", "that child's ivars").

## Checks

- style(9): clang-format21 with upstream .clang-format on the added lines:
  no change.
- Non-ASCII in added lines: none.
- GPL: 3-line check, no ported code.
- Datasheet: not a driver; n/a.
- Commit message: subject 55 chars (over 50, acceptable), body under 72
  columns, no tags. The factual error above must be fixed.
- Tutorial: cs35l54_speaker_amp.md section 3.4 describes the hang and the
  driver workaround (evaluate `_DSD` directly) but not this acpi fix, its
  alternatives, or any test of it. Does not match the commit.

VERDICT: fix needed (DPAA2 regression, commit message claim, tutorial lacks the fix and its test)
