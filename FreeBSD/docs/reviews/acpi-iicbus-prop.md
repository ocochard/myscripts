debb1082fb9ea2df721f2928c07d9e6fd10b89af ("acpi_iicbus: Return _DSD properties of the I2C children")

Replaces the acpi-prop-child version (direct-child check in acpi_device_get_prop(), broke DPAA2; report in acpi-prop-child.md).

POSTCR-debb1082fb9ea2df721f2928c07d9e6fd10b89af-1: pre-existing: acpi_iicbus_child_deleted() overrides iicbus_child_deleted() and never frees the ivars or their resource list, so every acpi_iicbus child deletion leaks them (now including the struct acpi_device this commit embeds)
POSTCR-debb1082fb9ea2df721f2928c07d9e6fd10b89af-2: pre-existing: acpi_iicbus_child_deleted() dereferences NULL ivars when the M_NOWAIT malloc in iicbus_add_child_common() fails and it calls device_delete_child()
POSTCR-debb1082fb9ea2df721f2928c07d9e6fd10b89af-3: pre-existing: acpi_ad_get_prop() matches property names by prefix (strncmp bounded by the _DSD key length), so a lookup of "foo-bar" returns the value of an earlier "foo" key

## Comments

New code (acpi_iicbus_get_property(), acpi_ad_get_property() split): no bug found.

- acpi.c split is behaviour-neutral: acpi_bus_get_prop() and acpi_device_get_prop()
  still pass device_get_ivars(child) to the same parser. DPAA2
  (dpaa2_mc_acpi, memac_mdio_acpi give their children a real struct
  acpi_device and forward to acpi) takes the same path as before. No other
  in-tree caller of acpi_bus_get_prop / ACPI_GET_PROPERTY / acpi_GetProperty
  (the last has no users).
- Ivars: iicbus_add_child_common() mallocs sizeof(struct acpi_iicbus_ivars)
  with M_ZERO via acpi_iicbus_add_child(); the hinted-child path goes
  through BUS_ADD_CHILD too. ad.dsd.Pointer/dsd_pkg start NULL. Only
  IICBUS_IVAR() casts to the first member; nothing else depends on the
  layout or size.
- Handle lifetime: get_property returns -1 without caching while handle is
  NULL; acpi_iicbus_write_ivar() refuses to change a non-NULL handle, so
  the cache cannot go stale. Reassigning ad_handle on every call is
  harmless.
- PACKAGE results point into devi->ad.dsd; valid until child_deleted,
  which runs after the child's driver detached. Same contract as acpi(4).
- Cache filling is unlocked (two racing first lookups would leak one
  buffer and can see dsd_pkg reset to NULL in acpi_find_dsd()). Identical
  to acpi(4), and property reads happen in probe/attach under the newbus
  topology lock, so not reported as a bug.
- Non-direct children get -1: correct, their ivars belong to another bus
  (iicmux downstream iicbus, hidbus under iichid). Also fixes
  pca954x's device_has_property() on ACPI systems, which went through the
  same garbage-ivars path.

Pre-existing details:
- -1: 9c99ba9a0677 (iicbus: Use a bus_child_deleted method to free ivars)
  added iicbus_child_deleted(), but acpi_iicbus has overridden
  bus_child_deleted since 9b7938dcf338 and never chains to it.
  iicbus_detach() -> bus_generic_detach() -> device_delete_children(), so
  each detach of acpi_iicbus (kldunload of the controller driver, devctl
  detach) leaks every child's ivars and resource list entries. This commit
  frees the _DSD buffer inside an allocation that is itself leaked. Fix:
  after the ACPI cleanup, resource_list_free(&devi->super_ivar.rl) and
  free(devi, M_DEVBUF), or export iicbus_child_deleted() and call it.
- -2: 9b7938dcf338. device_delete_child() calls BUS_CHILD_DELETED() even
  with NULL ivars; iicbus_child_deleted() checks for NULL,
  acpi_iicbus_child_deleted() does not (the new dsd line adds a second
  dereference). Only on M_NOWAIT failure.
- -3: b91fc6c43a81 (acpica: add ACPI_GET_PROPERTY). String.Length excludes
  the NUL, so strncmp(propname, key, key_len) accepts any propname that
  starts with key. This commit extends the reach of that parser to I2C
  children. Fix: compare strlen(propname) with String.Length too, or use
  strcmp() (ACPI strings are NUL-terminated).
- acpi_child_deleted() never AcpiOsFree()s ad->dsd.Pointer either (since
  b91fc6c43a81); acpi(4) children are rarely deleted after a _DSD lookup,
  so minor. Not given an ID.

## Checks

- style(9): clang-format22 with upstream .clang-format on the changed
  functions only flags the tab-aligned prototypes (acpi.c:171-172,
  acpivar.h:511-513) and the wrapped return in acpi_iicbus_get_property();
  all match the surrounding code. No real deviation.
- Non-ASCII: none in added lines.
- GPL: plain FreeBSD newbus/ACPICA plumbing reusing existing acpi.c
  parsing; nothing ported from Linux.
- Datasheet: N/A (not a driver).
- Commit message: subject 55 chars (slightly over 50, acceptable), body
  under 72 columns, no tags. Optional: `Fixes: 3f9a00e3b577 ("device: add
  device_get_property and device_has_property")` (the forwarding that
  makes acpi see foreign ivars) and `MFC after:`.
- Tutorial: FreeBSD/docs/acpi_iicbus_prop.md matches the commit
  (acpi_iicbus_prop.patch diff identical to the branch). Line references
  checked: subr_bus.c:2328 device_get_property(), subr_bus.c:3885
  bus_generic_get_property(), acpi_iicbus.c:73 struct acpi_iicbus_ivars;
  DPAA2 alternative claim verified (dpaa2_mc_acpi.c:240,
  memac_mdio_acpi.c:238 set struct acpi_device ivars). Section 3 says
  child_deleted "frees the cached buffer": true, but the ivars holding it
  are leaked (-1); worth one line under "What it does not fix".

VERDICT: ready

Update 2026-11-21: findings -1 and -2 fixed in a new first commit 57ff876fee1d ("acpi_iicbus: Free the ivars of deleted children", Fixes: 9b7938dcf338); the property commit is now 319cab72103f and frees its _DSD cache before calling iicbus_child_deleted(). Both commits build. -3 (prefix match in acpi_ad_get_prop) left for a separate PR.

2026-11-23: added commit 1 (cce18749f956) for the DEVICE_PROP_ANY reference memcpy bug (99e6980fcf5e), seen in D60063; zbook: FAIL before, PASS after (docs/acpi_prop_ref_test.c), cirrus,dev-index unchanged. Branch 95cde369275b.
