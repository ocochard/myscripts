a0e500d9b5239d218e3a35ee45c0aa601deb6511 ("amdgpio: Add PNP info for devmatch")

## Bugs

None found.

The code change is correct. The id table moves to file scope and
`ACPI_PNP_INFO(amdgpio_ids)` follows the same pattern as bytgpio.c and
adlngpio.c. The table is NULL-terminated, and ACPICOMPAT_PNP_INFO uses
`nitems(t) - 1`.

## Comments

- The commit message claim "This also enables ACPI GPIO event (_AEI)
  handling on those systems" is not true on upstream main:
  - `gpioaei` is a separate module with no PNP info, and `device gpio` is
    not in amd64 GENERIC, so nothing loads it.
  - Even when it is loaded, amd64 has no INTRNG: `gpio_alloc_intr_resource()`
    is the `#else` stub that returns NULL (sys/dev/gpio/gpiobus.c:117).
    amdgpio also has no interrupt-controller methods. Every AEI pin then
    logs "Cannot allocate an IRQ for pin 0x%x" (gpioaei.c:174).

  Drop the sentence, or keep it only for the olivier-amdgpio-intr series.
- Exposure: AMD0030/AMDI0030 is present on almost every Ryzen system, so
  this change attaches amdgpio, its interrupt filter (which acks all
  pins), and the suspend/resume routine (16d92e92ca12) on all of them, not
  only on systems with amdgpio in kld_list. The filter returns
  FILTER_HANDLED unconditionally. x86 intr_event still runs the other
  handlers on a shared line, so that is not a bug. Wider testing before
  MFC is worth it.

## Checks

- style(9): clang-format19 with upstream .clang-format on the changed
  lines. No deviation.
- Non-ASCII in added lines: none.
- GPL: none. ACPI ids only.
- Datasheet: n/a (no hardware logic changed).
- Commit message: subject OK (34 chars). Body wrapped, no tags. The _AEI
  sentence is inaccurate (see above).
- Tutorial: no FreeBSD/docs/ document for this patch. It is only
  mentioned in cs35l54_speaker_amp.md line 6. A short tutorial is needed
  (devmatch/PNP background, before/after `devmatch -p`/kldstat).

VERDICT: ready

Resolved 2026-11-21: _AEI sentence dropped, "amdgpio(4)" (no such man page) changed to "amdgpio" (now 4475256cf9f0, same tree); tutorial docs/amdgpio_pnp.md with the devmatch before/after and the scope note.
