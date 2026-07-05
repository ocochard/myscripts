# Truncated mod assets: `ShapeLOD.cpp:1525 Assertion failed '_nLods >= 1'`

Symptom seen 2026-07-03 on `ser6` while starting the LIBMOD mod through the
in-game Mods menu. The mod downloaded and extracted, but the game crashed
shortly after loading it. Root cause turned out to be a **disk-full event
during download** that produced header-valid but body-truncated `.p3d`
files. The engine parsed the header, saw zero LODs, and tripped the assert.

Written up here so the same shape can be recognized next time — the crash
looks like an engine bug and isn't.

## Signature in the log

```
[ERRR] FileCache: Cache failure loading 'libmod\lib_models\shg24.p3d'
       (file not found or stream fail)
[ERRR] FileCache: Cache failure loading 'libmod\lib_models\mod98.p3d'
       (file not found or stream fail)
...  (multiple similar lines for k98_sight, pz4f1, drvrsght, pz4comsight,
      pz4gunnersight)
[ERRR] engine/Poseidon/Graphics/Rendering/Shape/ShapeLOD.cpp(1525) :
       Assertion failed '_nLods >= 1'
```

The `FileCache: Cache failure` message is misleading — the files *are*
present on disk. What actually fails is the LOD-parse step further down
the pipeline. `_nLods == 0` means the shape header (`MLOD`/`ODOL` magic +
version) parsed OK but no LOD chunk followed.

## Diagnosis steps

Assets live under
`~/.local/share/Cold War Assault/Workshop/<MODNAME>/` — the game unpacks
the distributed `<MODNAME>.pbo.zst` into that directory and a sibling
`<MODNAME>.pbo.zst` file is kept.

Loose `.p3d` files sit in `<MODNAME>/lib_models/`, `.pbo` archives in
`<MODNAME>/addons/`.

### 1. Check disk space

Look for evidence that a fill event happened during install. Free space
now doesn't rule out a past fill.

```
df -h ~/.local/share/
```

### 2. Check the loose `.p3d` file sizes

```
cd "~/.local/share/Cold War Assault/Workshop/LIBMOD/lib_models"
ls -la *.p3d | sort -n -k5
```

Weapon-sight models are usually 20-80 KB. Anything under ~2 KB is
suspicious. On the failing install, drvrsght.p3d was **505 bytes**,
pz4comsight/pz4gunnersight both **~991 bytes**, k98_sight **1836 bytes** —
all below the header + one-LOD floor.

### 3. Confirm the `.p3d` header still parses

```
head -c 8 shg24.p3d | od -c | head -1
```

Expected first four bytes: either `MLOD` (editable) or `ODOL` (optimized),
followed by a 4-byte little-endian version. A file with a valid header
and a tiny total size is header-only — the shape has zero LODs on disk,
which is exactly what `ShapeLOD.cpp:1525` asserts against.

### 4. Cross-check `.pbo` archive sizes

```
ls -la "~/.local/share/Cold War Assault/Workshop/LIBMOD/addons/" \
    | awk '{print $5, $9}' | sort -n | head -20
```

Suspiciously small `.pbo` files (a few KB where similar mods hold hundreds
of KB) are the same tell: the archive was closed early when the write
buffer failed. The `.pbo.zst` sitting alongside the extracted tree is
usually intact — it's the extraction step that ran out of space.

## Fix

Delete the corrupt tree, free space if needed, re-download via the
in-game Mods menu:

```
rm -rf ~/.local/share/Cold\ War\ Assault/Workshop/LIBMOD*
```

Then launch the game and let it re-fetch. If disk was already tight,
free at least 2x the mod's uncompressed size (mod dir + the `.pbo.zst`
kept alongside) before retrying.

## Engine-side gap

The extractor produced an incomplete tree, then the game happily loaded
it and asserted at first use. Two reasonable engine fixes:

1. **Validate at extract time** — check each `.pbo`'s TOC against actual
   bytes written; refuse the mod if any file is short.
2. **Degrade at load time** — in `ShapeLOD` parse, log and skip shapes
   with `_nLods == 0` instead of asserting. Cosmetic — the models will
   render as invisible, which is at least a playable failure mode.

Neither is filed as a PR yet. Recognizing the pattern from the log is
the immediate goal of this doc.
