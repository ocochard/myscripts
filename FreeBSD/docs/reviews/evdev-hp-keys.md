337974cdd64cc0d670c8b42df81ef31402f22aff ("evdev: Map the HP mic mute and programmable keys")

## Bugs

POSTCR-337974cdd64cc0d670c8b42df81ef31402f22aff-1: global e0 01 -> KEY_MICMUTE turns Fn+Esc into mic mute on HP models that systemd hwdb maps to fn_esc

systemd `hwdb.d/60-keyboard.hwdb` (main) maps 0x81 (e0 01) for all HP
(`svnHP*:pn*` and `svnHewlett-Packard*`) to `fn_esc`. Only the
EliteBook/Elite x360/Dragonfly/ProBook/ZBook block, plus a few named
models, overrides it to `micmute`. `evdev_at_set1_scancodes[]` is not
DMI-gated. On other HP laptops, pressing Fn+Esc now sends KEY_MICMUTE,
and desktops that bind it toggle the microphone. Before the patch, the
key sent nothing. The tutorial lists this tradeoff, but the commit
message does not. KEY_FN_ESC would be harmless for those machines but
wrong for the ZBook. Either accept the tradeoff and state it in the
commit message, or leave e0 01 unmapped until there is a per-machine
override (EVIOCSKEYCODE).

## Comments

- 0x68 -> KEY_PROG1: hwdb maps it to `prog1` on the Elite Dragonfly G2 and
  to `unknown` (ignored) on the EliteBook 845 G7. Both are an HP
  programmable key, so KEY_PROG1 is benign there. Non-HP keyboards that
  send set-1 0x68 were not checked. The tutorial says so.
- KEY_MICMUTE (248) is above the X11 keycode limit. The tutorial shows
  that xf86-input-libinput remaps it (keycode 198), so it works under X.
- The commit message says "Use the mapping of systemd's hwdb for HP
  ZBooks". It should mention the generic HP fn_esc mapping that this
  overrides.

## Checks

- style(9): both added rows are 86 columns with tabs expanded. They are
  also the only trailing comments in the table. Put the note on its own
  line, as the Vivaldi block does (`/* 0x68: HP programmable key */`
  above the row), and keep the row at four entries within 80 columns.
  clang-format is not useful on this hand-aligned table.
- Non-ASCII in added lines: none.
- GPL: the key assignments are data taken from systemd hwdb (LGPL-2.1+).
  No code is copied. Fine.
- Datasheet: n/a. The scancodes were measured with dtrace (tutorial
  section 2).
- Commit message: subject OK (48 chars). Body wrapped, no tags. It is
  missing the fn_esc tradeoff.
- Tutorial: FreeBSD/docs/evdev_hp_keys.md. The diff is identical to
  evdev_hp_keys.patch and the final commit. The doc still cites the
  pre-rebase hash 81b24a701a44 on 46ce9acd6d15; update it to
  337974cdd64c on 6dc19a71f70c.

VERDICT: ready

Resolved 2026-11-21: user chose to keep the global mapping and state it; the commit message now names the generic HP fn_esc mapping and the Fn+Esc tradeoff; the row notes moved to their own lines (rows 73 and 75 columns); now 0c54fd8da608, kernel builds.
