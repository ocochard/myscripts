# PR draft — `UnloadGameData`: reset `ScenePreloader` so re-mount repopulates `_preloaded[]`

**Branch:** `scene-preloader-remount-fix` (single commit `54f2d27`, off `main`, sibling of `ai-radio-getfrom-fix`, `soldier-killedby-brain-assert-fix`, `vehicle-supply-assert-fix`, `landscape-crater-null-shape-fix`)

**Recommended merge order:** `landscape-crater-null-shape-fix` first (defensive net), this PR second (root-cause). Either standalone is fine; both together = belt + suspenders.

**Files changed:**
- `engine/Poseidon/Foundation/Platform/Shutdown.cpp` (+6/-0)

**Relationship to `landscape-crater-null-shape-fix`:** independent, complementary. This PR fixes the **root cause** (mod re-mount leaves the preload cache empty). The sibling PR adds a **defensive guard** in `Collisions.cpp` for the null-shape symptom. Ship either standalone; both together is fine and gives defense-in-depth.

---

## Title

```
UnloadGameData: reset ScenePreloader so re-mount repopulates _preloaded[]
```

## Body

```markdown
## Summary

`ScenePreloader` is a Meyers singleton (`Instance()` returns a static
local, `ScenePreloader.cpp:74-77`) whose `Initialize(Scene&)` uses a
process-lifetime `_initialized` flag to short-circuit repeated
invocations (`ScenePreloader.cpp:95-96`):

```cpp
void ScenePreloader::Initialize(Scene& scene)
{
    if (_initialized)
        return;
    // ... populate scene._preloaded[] from CfgScenePreload ...
    _initialized = true;
}
```

The boot path (`GameApplication::InitializeSubsystems` at
`GameApplication.cpp:879-880`) calls `Initialize(*GScene)` and
`_initialized` flips true.

The mod re-mount path (`GameApplication::Remount` at
`GameApplication.cpp:1743`) tears the content layer down and rebuilds
it:

```
Remount()
  UnloadGameData(keepEngine=true)   ← old GScene deleted here
  LoadGameData()
    ReadConfiguration()
    InitializeGameContent()
    InitializeWorld()               ← new GScene created here
    InitializeSound()
    InitializeSubsystems()
      ScenePreloader::Instance().Initialize(*GScene)   ← EARLY-RETURN
```

The second `Initialize()` hits the `_initialized` guard and returns
without touching the fresh `GScene`. Its `_preloaded[]` array
(`Scene.hpp:178`) stays all-null. The first explosion after the
re-mount then segfaults in `Landscape::ExplosionDammageEffects` at
`Collisions.cpp:1015`:

```
SIGSEGV in Vector3P::operator[](this=0x0000000000000168, i=0)
  ← Matrix4P::Rotate(op=0x0000000000000168)
  ← Landscape::ExplosionDammageEffects        Collisions.cpp:1015
  ← Landscape::ExplosionDammage               Collisions.cpp:1176
  ← SmokeSourceVehicle::SimulateExplosion     Smokes.cpp:300
  ← Tank::Simulate                            Tank.cpp:1494
```

`op=0x168` is `offsetof(Shape, _boundingCenter)` inside a null
`LODShapeWithShadow*` returned by `Preloaded(CraterShell)`.

## Isolation

Booting directly with `--mod <path>` (skipping the in-game restart
flow) does **not** reproduce the crash: 6 explosions, 0 errors, 0
asserts in a 60-second session with the same finmod pack that
crashes via the Mods menu path. That narrows the bug to something
`Remount()` does that direct-boot doesn't — which is the
`_initialized` guard preventing re-population of the new Scene.

## Fix

`ScenePreloader::Shutdown()` already existed
(`ScenePreloader.cpp:185-188`) and simply resets `_initialized =
false`. Nothing was calling it — dead code, and the smoking gun that
the invariant was intended but never wired up.

The natural place to wire it in is `UnloadGameData` in
`Shutdown.cpp`, right next to the existing
`FontSystem::Instance().Shutdown()` call. `FontSystem` and
`ScenePreloader` are the two content-reflecting singletons; both
should reset when content is torn down. Adding one line means every
teardown path (`Remount`, `DDTerm`, and any future one) resets the
flag automatically — no per-call-site plumbing.

```cpp
    FontSystem::Instance().Shutdown();
    ScenePreloader::Instance().Shutdown();   // NEW
    GPreloadedTextures.Clear();
```

## Test impact

`tests/unit/engine/Poseidon/World/Scene/test_scene_preloader.cpp`
already exercises `Shutdown()` in its "IsAvailable is false before
Initialize" case, so the entry point is unit-tested. No behavior
change under `--check` or bare boot: the extra `Shutdown()` call is a
no-op the first time (nothing yet initialized), and only matters on
re-mount.

`tests/unit/engine/Poseidon/Graphics/test_shutdown_order_audit.cpp`
I-04 checks `ClearFontCache → FontSystem::Shutdown → DestroyEngine`
ordering. Unaffected — the new line sits between
`FontSystem::Shutdown` and `DestroyEngine`.

## Verification

Direct-`--mod` boot: 60s, 6 fuel explosions, 0 asserts (baseline).
Mods-menu boot (pre-fix): crashed within seconds of first explosion.
Mods-menu boot (post-fix, FreeBSD `CWR-CE-3.01_2` on 16-CURRENT):
mod activation triggers the in-game restart cleanly, mission loads,
multiple explosions in combat — no crash, no assert.
```
