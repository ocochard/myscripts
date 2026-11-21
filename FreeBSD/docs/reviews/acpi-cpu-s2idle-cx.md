dba93fcd3ca3 ("acpi_cpu: Idle in the deepest Cx state for s2idle")

Split on 2026-11-21 from pr/s2idle-wake, where it was reviewed as
59844de21b97 (see s2idle-wake.md): same diff (patch-id checked), no bug
found. Ordering with amdsmu's suspend hint checked fine; acpi_cpu_set_cx_lowest()
clamps on restore. Message reworded: subject capitalized and 49 chars,
73-column body line fixed.

VERDICT: ready
