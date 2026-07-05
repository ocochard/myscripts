# PR draft — `QIFStreamB::AutoOpen`: try mod dirs when loose-file open fails on POSIX

**Branch:** `autoopen-loose-mod-file-fallback` (single commit `18686c1`, off `main`, sibling of `ai-radio-getfrom-fix`, `soldier-killedby-brain-assert-fix`, `vehicle-supply-assert-fix`, `landscape-crater-null-shape-fix`, `scene-preloader-remount-fix`)

**Files changed:**
- `engine/Poseidon/IO/Streams/QBStream.cpp` (+126/-1)

---

## Title

```
QIFStreamB: try mod dirs when loose-file open fails on POSIX
```

## Body

```markdown
## Summary

On POSIX ports (the FreeBSD port and any Linux port with an XDG
layout) mods live under `~/.local/share/Cold War Assault/Workshop/<mod>/`
while the process `cwd` stays at the data root
(`~/.local/share/CWR/base/`). Loose (non-PBO) mod assets referenced by
config with the mod-qualified name — e.g.
`\finmod\Sounds\Vehicles\tank_gear.wss` — are unreachable through the
cwd-relative fallback in `QIFStreamB::AutoOpen`, so vehicle and weapon
sounds go silent whenever a mod ships loose files.

Log symptom (FreeBSD 16-CURRENT, `CWR-CE-3.01_2`, `finmod` pack):

```
[WARN] [CORE] FileCache: file 'finmod\sounds\vehicles\tank_gear.wss' not found
[WARN] [CORE] FileCache: file 'finmod\sounds\vehicles\car_treads.wss' not found
[WARN] [CORE] FileCache: file 'finmod\sounds\vehicles\turret_mechanic.wss' not found
[WARN] [CORE] FileCache: file 'finmod\sounds\guns\rpg_fire.wss' not found
```

The files verifiably exist under the mod directory; `procstat -f`
confirms `cwd` is the data root, not the mods parent.

## Where the miss happens

`FileServer.cpp:105-112` — `FileCache::Load` on a miss constructs a
`FileInCache(name)` which calls `QIFStreamB::AutoOpen`. If the
resulting stream fails, the "FileCache: file ... not found" WARN is
emitted. So this is NOT a cache-key mismatch — it's the underlying
`AutoOpen` failing.

`QIFStreamB::AutoOpen(name)` in `IO/Streams/QBStream.cpp:1345`:

1. Try `AutoBank(name)` → find a mounted `.pbo` whose prefix matches
   `name`. If found, open from the PBO. **Path used for finmod's
   PBO-bundled assets** (world PBOs, mission PBOs, etc.).
2. Fallback: `QIFStream::open(name0)` → plain filesystem open of the
   verbatim name relative to `cwd`.

The fallback is where loose mod files should be resolved — but there
was no mod-directory search in this path. `open("finmod/sounds/vehicles/tank_gear.wss")`
looks for `~/.local/share/CWR/base/finmod/sounds/vehicles/tank_gear.wss`
and returns `ENOENT`.

Meanwhile the codebase already has a mod-dir enumerator that other
call sites use: `EnumModDirectories(callback, ctx)` in
`Core/GameState.cpp:129`. `LoadBanks` (PBO discovery) and mission-PBO
lookup (`OptionsUI.cpp:932`, `Network.cpp:337`) both use it — the
`AutoOpen` fallback did not.

## Why it only bites POSIX

On Windows the CWR launcher makes each mod a subdirectory of the game
data folder — `<data>\finmod\`. `cwd = <data>` at runtime, so
`open("finmod\Sounds\Vehicles\tank_gear.wss")` resolves relative to
`cwd` and hits the loose file. The FreeBSD port ships the mod under
XDG `~/.local/share/Cold War Assault/Workshop/<mod>/`, separate from
`~/.local/share/CWR/base/` — same layout the vanilla Linux port
picked up years ago, and the same reason the mount-path CLI
`--mod <fullpath>` exists. But the file-open fallback still assumed
`cwd`-relative resolution.

The path-normalization stack (`platformPath` / `unixPath` /
`ci_resolve_path`) is a red herring — it correctly turns
`finmod\sounds\...` into `finmod/sounds/...` before `open()`. The
open still failed because that relative path didn't exist under
`cwd`.

## Fix

Extend `QIFStreamB::AutoOpen` — and symmetrically
`QIFStreamB::FileExist` — to retry the loose-file open against each
mounted mod's absolute path when the `cwd`-relative open fails. Take
the first path component of `name0` (e.g. `finmod` from
`finmod\sounds\...`), match it case-insensitively against each mod's
basename via `::EnumModDirectories`, rewrite to `<mod-abs-path>/<rest>`
on hit, and retry `QIFStream::open`. This mirrors the Windows
convention (mod = subdirectory of the data folder) — same fallback
semantics, just made explicit instead of piggybacking on `cwd`.

Rejected an alternative "blind prefix scan of every mod dir" — costs
an `open()` per mod per miss with no upside, since the current mod
convention always mod-qualifies loose paths.

PBO-served files are unaffected: the new code runs only after
`AutoBank` fails to find a match (or the bank open itself misses).
Case-insensitive comparison uses Poseidon's portable `strnicmp`, not
`strncasecmp`, so Windows builds continue to compile.

## Verification

FreeBSD 16-CURRENT, `CWR-CE-3.01_3` from the FreeBSD port, `finmod`
pack. Prior to the fix the disk-side workaround was a symlink from
`<data>/finmod` to `<Workshop>/finmod` — which unblocked play but
proved the resolver was the missing piece. With this engine fix
installed and the workaround symlink removed, vehicle audio (engine,
gears, treads, turret servo) works unaided across mission load and
multiple vehicle types. No new warnings; the `FileCache: file ... not
found` lines for the mod's loose `.wss` assets are gone.
```
