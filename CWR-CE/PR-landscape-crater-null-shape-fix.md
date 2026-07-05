# PR draft — `Landscape::ExplosionDammageEffects`: guard null preloaded CraterShell

**Branch:** `landscape-crater-null-shape-fix` (single commit `5643294`, off `main`, sibling of `ai-radio-getfrom-fix`, `soldier-killedby-brain-assert-fix`, `vehicle-supply-assert-fix`, `scene-preloader-remount-fix`)

**Files changed:**
- `engine/Poseidon/World/Simulation/Collisions.cpp` (+47/-34, mostly re-indent inside a new `if (shape)` block)

---

## Title

```
Landscape::ExplosionDammageEffects: guard null preloaded CraterShell
```

## Body

```markdown
## Summary

`engine/Poseidon/World/Scene/ScenePreloader.cpp:59-69` documents an
explicit `--no-strict` fallback: when `CfgScenePreload.<slot>.model`
fails to load, `LoadShape` logs the error and returns null so the
engine can still boot. The comment ("`--no-strict` (the build players
run): a missing preload model is logged but not fatal — return a null
shape and let the engine boot rather than `exit(1)`") is explicit about
the invariant.

`Landscape::ExplosionDammageEffects` in
`engine/Poseidon/World/Simulation/Collisions.cpp` didn't honor that
contract. Both `CraterShell` branches call
`GLOB_SCENE->Preloaded(CraterShell)` and immediately dereference the
result — `shape->BoundingCenter()` at line 1015, and the shape pointer
is handed to `new Crater(...)` unchecked at both 984 and 1024.

When the preload comes back null, the first explosion crashes:

```
SIGSEGV in Vector3P::operator[](this=0x0000000000000168, i=0)
  Math3DP.hpp:137
  ← Matrix4P::Rotate(op=0x0000000000000168)  Math3DP.hpp:466
  ← Landscape::ExplosionDammageEffects        Collisions.cpp:1015
  ← Landscape::ExplosionDammage               Collisions.cpp:1176
  ← SmokeSourceVehicle::SimulateExplosion     Smokes.cpp:300
  ← Tank::Simulate                            Tank.cpp:1494
```

`op=0x168` is the field offset of `Vector3 _boundingCenter` inside a
null `LODShapeWithShadow*`. `BoundingCenter()` returns `Vector3Val`,
which is `const Vector3K&` (a reference), so a null `shape` produces
a null-reference-return that crashes on the first component access
inside `Matrix4P::Rotate`.

## Fix

Add null-shape guards at both `CraterShell` use sites:

- Line 976 branch (no `directHit`, above-ground splash crater): early
  `return` — nothing more to do in this branch when the shape is
  missing.
- Line 1021 branch (flat-ground crater case): wrap the crater
  creation and its child ground-debris FX block in `if (shape) { ...
  }`. The outer function still falls through to the `if (ownerCenter)
  Disclose(...)` call, which must always run.

Both sites include a comment pointing at the `ScenePreloader.cpp:59-69`
contract so the guard's purpose is discoverable from the crash site.

## Reproduction

Encountered on FreeBSD 16-CURRENT after activating the `finmod` mod
through the in-game Mods menu. The mod-triggered restart brought the
game up with the CraterShell preload slot null (root cause of the
null still under investigation — `bin/remaster.cpp` declares
`CraterShell.model = "data3d\krater.p3d"`, and `Data3D.pbo` in the
base pack does contain `krater.p3d`, so the load-failure is in the
resolver path after mod activation, not a missing asset).

Independent of what causes the null, the game crashed on first
explosion. With this guard, a missing `CraterShell` degrades to "no
crater visible" — cosmetic, playable — instead of taking the world
down on first tank hit.

## Verification

Built into the FreeBSD port (`CWR-CE-3.01_2`), installed on a
FreeBSD 16-CURRENT host. Activated the mod via the in-game Mods menu
(the re-mount path that previously crashed on first explosion within
seconds) and played a combat mission with multiple fuel explosions —
no crash, no assert.

## Same shape as other recent fixes

Fourth crash in this codebase where engine code contradicts a nearby
defensive-by-design invariant. First three were assertion mismatches
(`ai-radio-getfrom-fix`, `soldier-killedby-brain-assert-fix`,
`vehicle-supply-assert-fix`); this one is a preload-contract violation
in the opposite direction: `ScenePreloader` promises null-tolerance
under `--no-strict` but its consumers didn't implement it. All four
are cosmetic invariant violations; all four hide real game states
from the player.
```
