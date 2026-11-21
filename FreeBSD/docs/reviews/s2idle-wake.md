# Review: pr/s2idle-wake

83793bea27ec1520281867015b4e60d2511e962b ("acpi: let drivers add wake interrupts for suspend-to-idle")
d03000abdae3e3700917ee7a9717d2066a277dc4 ("amdgpio: arm the _AEI wake pins for suspend-to-idle")
59844de21b970550977333d24a9e7a69a7d5d0f1 ("acpi_cpu: use the deepest Cx state during suspend-to-idle")

POSTCR-d03000abdae3e3700917ee7a9717d2066a277dc4-1: an armed level-triggered wake pin that asserts during suspend-to-idle makes IRQ 7 fire continuously after do_idle() until amdgpio_resume(), as the filter clears the status but the level re-latches it
POSTCR-d03000abdae3e3700917ee7a9717d2066a277dc4-2: pre-existing: amdgpio_intr_filter() services register indices 0..116 instead of kernzp_pins[].pin_num, so an armed wake pin above 116 is never cleared (since a4d738d78305)

## Bug 1: level wake pin storm on wake

`amdgpio_suspend()` arms level pins (on the ZBook 58, 59, 61, 62: XHC0,
XHC1, HDEF, ACP wake) with `INTERRUPT_ENABLE` and `INTERRUPT_MASK` (=
delivered). It already refuses to arm a level pin asserted at suspend
time because "it would interrupt continuously as nothing runs _EVT to
clear its source". The same holds for a level pin that asserts during
the idle, which is the wake event itself:

1. pin asserts, IRQ 7 wakes the CPU from `cpu_idle(0)`;
2. `do_idle()` calls `intr_resume(false)` and `intr_restore()`;
3. `amdgpio_intr_filter()` writes the register back (W1C) and EOIs, but
   the pin is still at its active level, so `INTERRUPT_STS` sets again
   and the controller raises IRQ 7 again; the filter never masks the pin;
4. this repeats until `DEVICE_RESUME(root_bus)` reaches
   `amdgpio_resume()`, which disarms the pin. If IRQ 7 is bound to CPU 0,
   where `acpi_EnterSleepState()` is pinned, that point is never reached.

The source stays active because nothing runs `_EVT`
(`Notify (XHC0, 2)` etc.) and the device is still suspended. Not observed
in the tutorial's tests because those wakes came from the EC GPE (SCI),
not from a GPIO. Fix: in the filter, mask (`INTERRUPT_MASK` = 0) an armed
level wake pin once it fires, or disarm all wake pins from the filter
while suspended; `amdgpio_resume()` restores them anyway.

## Bug 2: pre-existing filter range

`for (pin = 0; pin < AMD_GPIO_PINS_EXPOSED; pin++)` uses the table size
(117) as a register index bound; `kernzp_pins` goes to pin 177 with gaps.
Introduced in a4d738d78305 ("amdgpio: Mask and service interrupts").
Harmless until now since all pins were disabled. With this commit any
`_AEI` wake pin above 116 that fires leaves its status set, so IRQ 7
stays asserted as in bug 1. ZBook wake pins (18, 54, 58-62) are in range;
other AMD boards may not be. Loop over `kernzp_pins[i].pin_num`.

## Comments

- What the series proves: per the tutorial, with 83793bea27ec and
  d03000abdae3 alone nothing wakes; the wake that works (space key) is
  the EC GPE through the SCI and needs only 59844de21b97. The power
  button (pin 54) still does not wake. So 83793bea27ec and d03000abdae3
  have no measured effect yet; the commit messages imply a fix. Consider
  sending 59844de21b97 alone and holding the GPIO pair until a GPIO wake
  is observed, or say "untested wake path" in the messages.
- 83793bea27ec: the comment says the array is used "with the bus
  topology lock held". True: register/unregister run from attach/detach,
  `do_idle()` runs inside `bus_topo_lock()` in `acpi_EnterSleepState()`.
  Fine. Registering an IRQ shared with other devices also lets those wake
  the idle; acceptable, worth one word in the comment.
- d03000abdae3 comment "no debounce (as Linux does)": from memory,
  Linux `amd_gpio_irq_set_type()` sets a glitch filter
  (`DB_TYPE_PRESERVE_LOW/HIGH_GLITCH`) for level types and acpi gpiolib
  applies the descriptor's debounce; verify against pinctrl-amd.c before
  claiming parity.
- d03000abdae3: `amdgpio_find_wake_pins()` `break`s on a pin >=
  AMD_GPIO_PINS_MAX, dropping the descriptor's later pins; `continue`
  would be safer. A full `sc_wake` table is silently truncated.
- 59844de21b97: ordering vs amdsmu's hint is fine: amdsmu registers at
  `EVENTHANDLER_PRI_LAST` for suspend and `PRI_FIRST` for resume, so the
  cx change runs before the hint and is undone after amdsmu resumes.
  `acpi_cpu_set_cx_lowest()` clamps to `cpu_cx_count - 1`, so a `_CST`
  change while suspended cannot overflow on restore. As the tutorial
  notes, the boot CPU's single `cpu_idle(0)` still selects by
  `cpu_prev_sleep` latency, so it may not use the deepest state.
- Semantic overlap with pr/acpi-prop-child: none. Different acpi.c
  functions, `git merge-tree` clean, no property use here.

## Checks

- style(9): clang-format21 on added lines. acpi.c/acpi_cpu.c additions
  follow those files' 4-space legacy indent (clang-format wants tabs;
  matching the file is right). amdgpio.c: blank line after `{` in
  `amdgpio_is_wake_pin()` (no locals; current style(9) drops it); the
  `acpi_s2idle_wake_irq_register(` wrap would read better as
  `sc->sc_nwake > 0 &&` / `acpi_s2idle_wake_irq_register(...) == 0`.
  Struct field alignment diffs are clang-format's, not style(9). Nits only.
- Non-ASCII in added lines: none.
- GPL: amdgpio arming mirrors pinctrl-amd behaviour (wake bits 13/14,
  mask non-wake pins), but the code is structured differently and uses
  the BSD-licensed amdgpio.h register names already in the tree; no
  copied text. acpi/acpi_cpu parts are original.
- Datasheet: d03000abdae3 sets PPR-defined wake control bits with no
  citation; cite the AMD PPR/BKDG GPIO register section (or Linux as the
  behavioural reference) in the commit message.
- Commit messages: subjects are lowercase after the prefix ("let",
  "arm", "use"); the skill's form is `subsystem: Imperative summary`
  (pr/acpi-prop-child capitalizes). 57/51/57 chars, over 50. 59844de21b97
  body line 1 is 73 columns (> 72). No tags; fine.
- Tutorial: amdsmu_strix_halo.md covers all three commits (sections "GPIO
  wake fix: not enough", "Fix: deepest C-state") with tests, and states
  the power button still fails. Matches the code; its hashes are the
  pre-rebase GitHub ones (bcebee137c71, 3b8b97303b3d, a413caa2444c).

VERDICT: fix needed (level wake pin storm in amdgpio filter, filter pin range, unproven GPIO wake claimed by commit messages, subject capitalization, 73-col body line)
