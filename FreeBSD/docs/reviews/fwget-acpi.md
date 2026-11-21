# Review: pr/fwget-acpi

5aef90fcee695705144f28284bf0abf0ea7e56fe ("fwget: Add ACPI device support")

POSTCR-5aef90fcee695705144f28284bf0abf0ea7e56fe-1: CSC3554 maps to package sound-firmware-cirrus-kmod-cs35l54, which is not in the ports tree, and acpi is now searched by default, so plain fwget on an HP ZBook Ultra G1a asks pkg for a package that does not exist and the single `pkg install -qy ${packages}` fails for all packages (GPU firmware included)

## Comments

- POSTCR-...-1: the port exists only as an uncommitted directory in
  ~/freebsd-official/ports (`audio/sound-firmware-cirrus-kmod`, flavor
  cs35l54; `git log` empty, not on origin/main). fwget.sh installs all
  matches in one `pkg install -qy`, and pkg rejects the whole job when one
  name has no match in the repositories. So on a ZBook G1a, `fwget` stops
  installing gpu-firmware-amd-kmod. Commit only after the port lands (and
  is in the quarterly/latest repo), or hold the `acpi_cirrus` mapping back
  and land the subsystem alone.
- Standalone check: the diff touches only usr.sbin/fwget; no file, driver or
  header from the cs35l54 series is referenced. But the package is useful
  only with `snd_cs35l54`, which is not in main (the port's own
  `ONLY_FOR_ARCHS_REASON` names that driver). With the driver absent, fwget
  would install firmware nothing loads. Another reason to sequence this
  after the driver and port, or say so in the commit message.
- ACPI support against main, verified:
  - `acpi_pnpinfo()` (acpica/acpi.c:1077) prints `_HID=%s _UID=%lu _CID=%s`.
  - devinfo(8) `-v` prints unattached ("unknown") devices too
    (devinfo.c:187) and appends ` pnpinfo ...`, so a driverless CSC3554 is
    seen.
  - If ig4 has enumerated the device onto iicbus, acpi_iicbus deletes the
    acpi0 child (acpi_iicbus.c:501-511) but `acpi_iicbus_child_pnpinfo()`
    appends `acpi_pnpinfo()` (line 745), so `_HID=` is still there.
  - `_HID=none` and non-CSC ids fall through `acpi_get_vendor`. FDT systems
    print no `_HID=`; the loop is empty. OK.
- Script structure, `return 1` in the vendor function and Makefile layout
  match usb/usb_ralink and usb/Makefile.
- Optional: `MFC after:` missing; add it if this goes to stable/15.

## Checks

- style(9): shell and Makefile only, clang-format not applicable. Matches
  the existing fwget scripts.
- Non-ASCII in added lines: none.
- GPL: new shell code, no Linux origin. The firmware mapping is only a
  package name.
- Datasheet: not a driver. N/A.
- Commit message: subject `fwget: Add ACPI device support` OK, body under 72
  columns, no tags. OK. Author olivier@FreeBSD.org.
- Tutorial: no dedicated doc. Coverage is in
  ~/myscripts/FreeBSD/docs/cs35l54_speaker_amp.md section 3.3 and test rows
  ("`fwget` installing from a package repository: untested (package not in
  a repository)"), which matches the code but confirms POSTCR-...-1. Missing
  a standalone tutorial for this split-out commit.

VERDICT: fix needed (land after audio/sound-firmware-cirrus-kmod and snd_cs35l54, or drop the CSC3554 mapping; add a dedicated tutorial)
