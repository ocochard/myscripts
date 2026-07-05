# Bug: loose mod files not found by `QIFStreamB::AutoOpen` on POSIX

**Status:** fixed 2026-07-04 on branch `autoopen-loose-mod-file-fallback`
(commit `18686c1`, off `main`). End-to-end verified on ser6 with the
disk-side symlink workaround removed — CWR-CE-3.01_3 with the engine
fix resolves finmod vehicle audio unaided. Filename retained for
history; the "case normalization" hypothesis was wrong (see § Not the
bug).

## Symptom

Playing a vehicle in `finmod` — no engine sounds, no gear-shift
sounds, no turret servo. Log shows dozens of
`FileCache: file '...' not found` warnings for `.wss` files that
visibly exist under the mod directory:

```
[WARN] [CORE] FileCache: file 'finmod\sounds\vehicles\tank_gear.wss' not found
[WARN] [CORE] FileCache: file 'finmod\sounds\vehicles\car_treads.wss' not found
[WARN] [CORE] FileCache: file 'finmod\sounds\vehicles\turret_mechanic.wss' not found
[WARN] [CORE] FileCache: file 'finmod\sounds\guns\rpg_fire.wss' not found
...
```

## Where the log message comes from

`FileServer.cpp:105-112`: `FileCache::Load` on a miss constructs a
`FileInCache(name)` which calls `QIFStreamB::AutoOpen`. If the
resulting stream fails, the "FileCache: file ... not found" WARN is
emitted. So this is NOT a cache-key mismatch — it's the underlying
`AutoOpen` failing.

## The real bug: no mod-dir search for loose files

`QIFStreamB::AutoOpen(name)` in `IO/Streams/QBStream.cpp:1345`:

1. Try `AutoBank(name)` → find a mounted `.pbo` whose prefix matches
   `name`. If found, open from the PBO. **Path used for
   finmod's PBO-bundled assets** (world PBOs, mission PBOs, etc.).
2. Fallback: `QIFStream::open(name0)` → plain filesystem open of the
   verbatim name relative to `cwd`.

The fallback is where loose mod files should be resolved — but
there's no mod-directory search in this path. The `cwd` at runtime is
the data root (`~/.local/share/CWR/base/`), not the mod parent
(`~/.local/share/Cold War Assault/Workshop/`). So
`open("finmod/sounds/vehicles/tank_gear.wss")` looks for
`~/.local/share/CWR/base/finmod/sounds/vehicles/tank_gear.wss` and
returns ENOENT even though the file exists at
`~/.local/share/Cold War Assault/Workshop/finmod/sounds/vehicles/tank_gear.wss`.

Meanwhile the codebase already has a mod-dir enumerator that other
call sites use: `EnumModDirectories(callback, ctx)` in
`Core/GameState.cpp:129`. `LoadBanks` (PBO discovery) and mission-PBO
lookup (`OptionsUI.cpp:932`, `Network.cpp:337`) both use it — the
`AutoOpen` fallback does not.

## Why it only bites POSIX

On Windows, the CWR launcher makes the mod a subdirectory of the game
data folder — `<data>\finmod\`. `cwd = <data>` at runtime, so
`open("finmod\Sounds\Vehicles\tank_gear.wss")` resolves relative to
cwd and hits the loose file. The FreeBSD port ships the mod under XDG
`~/.local/share/Cold War Assault/Workshop/<mod>/`, separate from
`~/.local/share/CWR/base/` — same layout the vanilla Linux port
picked up years ago, and the same reason the mount-path CLI
`--mod <fullpath>` exists. But the file-open fallback still assumes
`cwd`-relative resolution.

The path-normalization stack (`platformPath` /
`unixPath` / `ci_resolve_path`) is a red herring — it correctly turns
`finmod\sounds\...` into `finmod/sounds/...` before `open()`. The
open still fails because that relative path doesn't exist under cwd.

## Fix (shipped)

Branch `autoopen-loose-mod-file-fallback` (single commit `18686c1`,
off `main`). Extends `QIFStreamB::AutoOpen` — and symmetrically
`QIFStreamB::FileExist` — to retry the loose-file open against each
mounted mod's absolute path when the cwd-relative open fails.

Splice strategy (**strategy 1** from the earlier plan): take the first
path component of `name0` (e.g. `finmod` from `finmod\sounds\...`),
match it case-insensitively against each mod's basename via
`::EnumModDirectories`, rewrite to `<mod-abs-path>/<rest>` on hit, and
retry `QIFStream::open`. This mirrors the Windows convention
(mod = subdirectory of the data folder) — the same fallback semantics,
just made explicit rather than piggybacking on `cwd`.

Rejected strategy 2 (blind prefix scan of every mod dir) — costs an
`open()` per mod per miss with no upside, since the current mod
convention always mod-qualifies loose paths.

PBO-served files are unaffected: the fix runs only after `AutoBank`
fails to find a match (or the bank open itself misses).

Files changed:
- `engine/Poseidon/IO/Streams/QBStream.cpp` (+126 / -1)

## Disk-side workaround (superseded by the engine fix)

Prior to the fix, a symlink from cwd to the mod tree unblocked play:

```sh
ln -s "/home/olivier/.local/share/Cold War Assault/Workshop/finmod" \
      "/home/olivier/.local/share/CWR/base/finmod"
```

Kept documented here as the escape hatch for anyone on an older port
(pre-`CWR-CE-3.01_3`). With the engine fix installed, the symlink can
be removed and vehicle audio still works. Verified on ser6
2026-07-04 (`CWR-CE-3.01_3`, `finmod`, symlink removed).

## Repro

1. FreeBSD 16-CURRENT host with `CWR-CE-3.01_2` from the port.
2. Install `finmod` (unpacked, not fully PBO-packed) under
   `~/.local/share/Cold War Assault/Workshop/finmod`.
3. Launch: `cwr-ce --mod ".../Workshop/finmod" --log-file /tmp/x.log`.
4. Start any mission with a tank/car; enter the vehicle.
5. `grep 'FileCache: file' /tmp/x.log` → dozens of misses for
   files that verifiably exist under the mod dir; audio subjectively
   absent for gears, treads, servos.
6. `procstat -f <pid> | head -5` → `cwd` is the data root, not the
   mods parent.

## Not the bug (things I initially suspected but ruled out)

- **Case-sensitivity vs mixed-case config strings.** The POSIX
  `OpenFileForRead` has a `ci_resolve_path` that walks each component
  case-insensitively via `readdir` + `strcasecmp`. Confirmed working
  path (used elsewhere).
- **Backslash normalization.** `LocalPath` / `unixPath` /
  `platformPath` fire before `open`; the `\` → `/` translation is
  correct.
- **FileCache key hashing asymmetry.** No hashing — `FileCache::Find`
  uses linear `strcmp`. The "not found" message is emitted from the
  underlying `AutoOpen` failure, not from a cache-lookup mismatch.
