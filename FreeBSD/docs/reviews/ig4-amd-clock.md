e83caa8359c7995e6f41bd13d2c5e4e6be3e11ca ("ig4: Use the 150 MHz clock of AMDI0010 controllers")

## Bugs

No new bug found in this commit.

pre-existing: POSTCR-e83caa8359c7995e6f41bd13d2c5e4e6be3e11ca-1: AMD0010 still gets the 100 MHz Atom clock while Linux clocks it at 133 MHz (cz_i2c_desc), so without FMCN its bus runs about 33% fast

### -1 (pre-existing, not introduced here)

AMD0010 was added by 8f733dabcc35 ("ig4(4): Add device HID to match I2C
controller on ASUS X540 laptops") and falls into the same `else` branch
this commit edits. Linux `drivers/acpi/acpi_apd.c` gives AMD0010
`cz_i2c_desc` (133 MHz). Only applies when firmware has no SSCN/FMCN.
Inferred from the Linux clock table, not measured. The tutorial states
this limit.

## Comments

- The rework fixes the previous -1: `sc->version` stays `IG4_ATOM`, so
  `IG4_HAS_ADDREGS()` and every `== IG4_ATOM` test in ig4_iic.c
  (COMP_PARAM1 FIFO read, COMP_VER check, RESETS_HSW, suspend/resume,
  dump) behave exactly as before for AMDI0010.
- Override is safe for other controllers: newbus allocates the softc
  zeroed, the PCI front end never sets `ic_clock_rate`, and the field is
  read only in `ig4iic_get_config()` inside the `ig4_timings < 2` branch.
  `ig4_timings=0` still lets ACPI SSCN/FMCN win, `2` and `3` ignore it.
- Counts checked by hand: fast mode at 150 MHz gives HCNT=129, LCNT=230,
  SDA_HOLD=9; standard mode 639/740/9. All fit the 16-bit masks.
- 150 MHz matches Linux `wt_i2c_desc` (AMDI0010, AMDI0019). AMDI0019 is
  not in `ig4iic_ids[]`, so it is out of scope here.
- Struct copy of `ig4_hw` (24 bytes) on the stack is fine. Keeping
  `const struct ig4_hw *` and a local copy only when overriding would
  shrink the diff, but this form is clearer. Nit, no change needed.

## Checks

- style(9): clang-format19 with the freebsd/main .clang-format on the
  changed hunks. No deviation in added lines. The only diffs are
  pre-existing (`reg_read` wrapping in `ig4iic_get_config()`, and the
  struct field tab alignment, which clang-format cannot express; the new
  field matches its neighbours).
- Non-ASCII in added lines: none (`LC_ALL=C grep` on the diff).
- GPL: no Linux code copied. Only the 150 MHz clock (a hardware fact)
  comes from Linux acpi_apd.c. Fall/hold times are FreeBSD's existing
  `IG4_ATOM` entry. The new comment cites no GPL source.
- Datasheet: none cited. No public AMD document gives the I2C reference
  clock; Linux acpi_apd.c plus the ZBook measurement are the stated
  sources. Acceptable for a one-constant change.
- Commit message: subject 50 chars, `ig4:` prefix, imperative. Body
  wrapped under 72 columns. No tags, none needed. Content matches the
  diff.
- Tutorial: ~/myscripts/FreeBSD/docs/ig4_amd_clock.md present;
  ig4_amd_clock.patch is identical to the commit (format-patch diff,
  headers excluded). Line refs checked on the pr branch: ig4_iic.c:91
  (table), :750 (`ig4iic_clk_params`), ig4_var.h:56 (`IG4_HAS_ADDREGS`)
  correct; :895 is the FMCN call, the `ig4_timings == 0` test is :892.
  Doc nits:
  - "every `== IG4_ATOM` test (about ten)": ig4_iic.c has 7 tests
    (8 matches, one is the table initializer). ig4_pci.c matches are PCI
    ID entries, irrelevant for ACPI.
  - "the Intel register path of section 3 is the likely one" for the
    first version running at stock rate after reload is unmeasured
    inference; a stale or mismatched ig4.ko would give the same number.
    Say "not traced" only, or drop the sentence.
  - "each row ran twice" but the first-version boot row has one value.
  - Tests ran on kernel 0d71515aee38 (zbook branch, which carries the
    first version in its built-in ig4), with the patch only via
    kldunload/kldload. Attach at boot with this patch is not in the
    table; list it as untested. "builds against main 6dc19a71f70c" is a
    claim not re-checked here (no builds in this review).

VERDICT: ready

Rework 2026-11-22 (wulf, #114): aa0669aa77b0 on 02e1b1cd1fb1, IG4_AMD before IG4_SKYLAKE with its own table entry; DesignWare COMP_PARAM1/COMP_VER checks only. zbook: 348 kHz twice, 4 controllers, touchpad, amplifiers and tones OK, GENERIC builds. Tutorial and patch updated.
