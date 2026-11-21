c868422318177f042062c087f273d81507a50f6f ("LinuxKPI: sysfs: Return binary attributes whole")

No runtime bugs found.

## Comments

- Heuristic: a NUL inside `len` means binary. A text `show()` that
  counts its terminating NUL in the return value (`sprintf(...) + 1`)
  now goes out raw, with its newline and NUL, and becomes read-only.
  Not seen in drm or iwlwifi; worth one sentence in the commit message.
- Binary data that happens to contain no NUL still goes through the
  string path and loses its last byte. Not the case for gpu_metrics,
  whose header already holds a 0x00 byte.
- Read with a new value on a binary attribute returns EPERM without the
  old value; fine.
- The node stays type "A", so plain `sysctl` prints the first bytes as
  a string; users need `sysctl -b`. Acceptable.
- ABI: `sysctl_handle_attr()` is static in the header, so only modules
  that create attributes (drm-kmod amdgpu) need a rebuild to get the
  fix. No struct change, no `__FreeBSD_version` bump required.

## Checks

- style(9): one added line is 82 columns:
  `error = SYSCTL_OUT(req, buf, MIN(len, PAGE_SIZE));` (4 tabs), wrap it.
  `memchr(...)` used as a truth value: style(9) wants `!= NULL` for
  pointers.
- Non-ASCII in added lines: none.
- GPL: FreeBSD sysctl handler, no Linux code. In Linux gpu_metrics is a
  plain DEVICE_ATTR_RO whose show() memcpy()s the table, which is why a
  bin_attribute flag cannot be used; the commit's reasoning holds.
- Drivers datasheet: n/a.
- Commit message: subject `LinuxKPI: sysfs: Return binary attributes
  whole` 47 chars, body <= 72 columns, `MFC after:` tab aligned. OK.
- Tutorial: ~/myscripts/FreeBSD/docs/linuxkpi_sysfs_binary_attr.md
  present and matches the commit.

VERDICT: ready

Resolved 2026-11-21: line wrapped, memchr() compared with NULL, commit message notes the counted-NUL case (no in-tree show() returns a count including its NUL); now 0226cef54879, kernel builds.
