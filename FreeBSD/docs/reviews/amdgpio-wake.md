# Review: pr/amdgpio-wake

0ea5d0d335abc093c03d6353abe80186d042b13b ("amdgpio: Service interrupts on the real pin numbers")
37472a9a46efc0dde295fd4c63119856e754814c ("acpi: Let drivers add wake interrupts for s2idle")
dae130e2e358696cc5295cbe8e515b540bb0616e ("amdgpio: Arm the _AEI wake pins for s2idle")

POSTCR-0ea5d0d335abc093c03d6353abe80186d042b13b-1: the filter no longer services registers of pins missing from kernzp_pins below 116 (21, 22, 27-38, 41, 42, 44, 45, 67, 73, 77-83, 94, 103-112), which attach never disables, so a firmware-enabled interrupt on one of them now stays asserted
POSTCR-dae130e2e358696cc5295cbe8e515b540bb0616e-1: amdgpio_find_wake_pins() accepts any _AEI pin below 256 but the filter only walks kernzp_pins, so an armed wake pin absent from the table is never cleared or masked and IRQ 7 stays asserted after the wake

## Bug 1: 0ea5d0d335ab narrows the serviced set

Before: registers 0..115 (index bound, gaps included). After: the 116
table pins only. The table has gaps (above), and attach disables
interrupts only on table pins, so a gap pin keeps whatever the firmware
programmed. On main a gap pin below 116 that fires is cleared; with this
commit it is not, and the controller keeps IRQ 7 asserted. Conversely the
pins this commit adds (116 and up) are all table pins that attach has
disabled, so on main nothing the commit newly services can fire: it fixes
no reachable case on its own and needs the `Fixes:`/`MFC after:` claim
rethought. Fix: walk every physical pin register (0..183 per the pin
numbering, skipping register 63, offset 0xfc, which is
`WAKE_INT_MASTER_REG`), or use `WAKE_INT_STATUS_REG0/1` as the existing
TODO says. Commit message off by one: 0..115 were serviced, so "a pin
above 116" should read "pin 116 and above" (116 is in the table).

## Bug 2: dae130e2e358 arms pins the filter never sees

`amdgpio_find_wake_pins()` bounds pins by `AMD_GPIO_PINS_MAX` (256).
An `_AEI` wake pin in a table gap (e.g. 44, 45) is armed by
`amdgpio_suspend()` but `amdgpio_intr_filter()` never reads it: status is
not cleared, the level mask is not applied, IRQ 7 storms after
`intr_resume()` in `do_idle()` until `amdgpio_resume()` (never, if IRQ 7
lands on CPU 0). The ZBook pins (18, 54, 58, 59, 61, 62) are table pins;
other AMD boards may not be. Fixed by the same full-register walk as bug
1. The 256 bound also admits register 63 (master register) and offsets
past the pin area (0x2f8/0x2fc status registers at 190/191); bound by the
real pin range and skip 63.

## Checked and correct

- Level mask in the filter: `reg &= ~(1 << INTERRUPT_MASK_OFF)` then one
  write of `reg` with bits 28/29 still set from the read: W1C clears the
  status and masks delivery in the same write. Correct given the
  in-tree register semantics (bit 12 = delivery enable, as attach and
  suspend use it).
- `amdgpio_resume()` writes `saved | UNSERVICED_INTERRUPT_MASK` for every
  pin with `armed` set; the filter leaves `armed` true, so a masked pin is
  restored. `saved` is the post-attach value (enable and mask clear), so
  the pin ends disarmed with status cleared. Correct.
- Locking: filter, suspend and resume take the `MTX_SPIN` lock around all
  `armed`/register access. `sc_wake`/`sc_nwake` are written in attach
  without the lock after `bus_setup_intr()`, but only read by the filter
  and `armed` is zero then; benign. acpi.c array: attach/detach and
  `do_idle()` all run under the bus topology lock, as the comment says.
- 0ea5d0d335ab builds on its own: `kernzp_pins` is the `static const`
  table from amdgpio.h already used in attach; the renamed index is not
  used elsewhere in the loop.
- `find_wake_pins()` now `continue`s on a bad pin and stops only when
  `sc_wake` is full. Polarity encodings (ACPI 0/1/2 vs controller
  `ACTIVE_HIGH`/`ACTIVE_LOW`/`BOTH_EDGE`) match; asserted-level check is
  right for both polarities.
- The "as Linux does" debounce claim is gone from the code and message.

## Comments

- Wake status vs mask: masking bit 12 stops interrupt delivery, but the
  pin keeps bit 13 (S0i3 wake) set with the level still held, so
  `WAKE_STS` re-latches. Whether `WAKE_STS` alone drives the controller
  interrupt is not documented in-tree. Clearing bits 11, 13 and 14 too
  (full disarm, which resume undoes anyway) removes the question; from
  memory, Linux pinctrl-amd disables both enable and mask when it must
  stop a storm.
- Lost wake: a wake pin firing between `amdgpio_suspend()` and
  `cpu_idle(0)` is cleared (edge) or masked (level) by the filter, and the
  system then idles with nothing left to wake it. Same class as the
  existing SCI path (no abort on pending wake); worth one line in the
  comment.
- An `_AEI` pin listed twice gets two `sc_wake` entries; the second
  saves the already armed register and resume restores it, leaving the
  pin armed. Unlikely in firmware; dedupe with `amdgpio_is_wake_pin()` in
  `find_wake_pins()`.
- 37472a9a46ef: registering a shared IRQ lets its other users end the
  idle too; one word in the comment.
- Tested state: dae130e2e358's message says no GPIO wake was seen and the
  power button still fails: honest. "the pins are armed and restored" was
  measured on the pre-rework commit (tutorial: 3b8b97303b3d); the new
  filter-mask path cannot have run, since no GPIO interrupt fired during a
  suspend. Say so ("the level mask is untested"). 37472a9a46ef has no
  test claim; its effect is unmeasured for the same reason.
  0ea5d0d335ab states "kept the interrupt asserted" as fact; on main it
  is latent (see bug 1). Holding the topic until a GPIO wake is observed
  is right.

## Checks

- style(9): clang-format21 with main's .clang-format on amdgpio.c. Added
  lines: the `acpi_s2idle_wake_irq_register(` wrap in attach should be
  `sc->sc_nwake > 0 &&` / `acpi_s2idle_wake_irq_register(...) == 0`; the
  arm comment in suspend has a short reflowed line ("no debounce.  Skip an
  asserted level pin, it would"). acpi.c additions follow the file's
  4-space legacy indent. Rest of the diff is pre-existing code.
- Non-ASCII in added lines: none.
- GPL: arming logic resembles pinctrl-amd behaviour (wake bits 13/14,
  mask non-wake pins) but is structured differently and uses the
  BSD-licensed amdgpio.h names already in the tree; no copied text.
  acpi.c part is original.
- Datasheet: dae130e2e358 programs wake control bits with no citation;
  cite the AMD BKDG/PPR GPIO register section (the filter comment already
  cites the BKDG).
- Commit messages: subjects capitalized now; 51/48/42 chars (first one 1
  over 50). Bodies within 72 columns, tags tab-aligned, no PR:. See bug 1
  for the off-by-one and the `Fixes:`/`MFC after:` on a latent bug.
- Tutorial: amdsmu_strix_halo.md "GPIO wake fix: not enough" still
  describes the old two-commit series (lowercase subjects, old hashes
  bcebee137c71/3b8b97303b3d, "arms them as Linux does"), and does not
  cover 0ea5d0d335ab or the filter's level mask. Does not match the final
  commits.

VERDICT: fix needed (filter must walk all pin registers: gap pins lost by 0ea5d0d335ab and armed but unserviced in dae130e2e358; 0ea5d0d335ab message off by one and Fixes/MFC on a latent bug; say the level mask is untested; tutorial out of date)
