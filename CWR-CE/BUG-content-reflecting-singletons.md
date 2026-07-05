# Bug pattern: content-reflecting singletons and mod re-mount

**Status:** one instance confirmed and fixed (`ScenePreloader`,
2026-07-03). Documented as a *class* because the same shape almost
certainly exists in other Poseidon singletons — this doc is a checklist
to sweep them.

**First victim:** `ScenePreloader`. Symptom was a `SIGSEGV` in
`Landscape::ExplosionDammageEffects` on the first explosion after a
mod-menu activation. Fix in `scene-preloader-remount-fix` branch.

---

## The pattern

Poseidon uses **Meyers singletons** for content-reflecting caches:

```cpp
ScenePreloader& ScenePreloader::Instance()
{
    static ScenePreloader s;
    return s;
}
```

The instance lives for the entire process. Many of these singletons
have an `_initialized` flag to short-circuit repeat `Initialize()`
calls:

```cpp
void ScenePreloader::Initialize(Scene& scene)
{
    if (_initialized)
        return;                     // <-- the trap
    // ... populate scene._preloaded[] from CfgScenePreload ...
    _initialized = true;
}
```

That guard is correct for boot (`GameApplication::InitializeSubsystems`
calls `Initialize(*GScene)` once). It is **catastrophic** across
`GameApplication::Remount()`:

```
Remount()
  UnloadGameData(keepEngine=true)   ← old GScene deleted
  LoadGameData()
    InitializeWorld()               ← new GScene created
    InitializeSubsystems()
      ScenePreloader::Instance().Initialize(*GScene)   ← EARLY-RETURN
                                                          new GScene never
                                                          populated
```

Result: the fresh `Scene`'s cache stays in its default-constructed
(all-null) state. The next consumer that dereferences an entry crashes
with a null-shape SIGSEGV, and the crash appears far from the actual
cause (in engine code that assumed the preload contract holds).

## The fix shape

Two symmetric requirements:

1. The singleton must expose a `Shutdown()` that resets its
   content-tracking state (usually just `_initialized = false`).
2. `Shutdown()` must be wired into `UnloadGameData()`
   (`engine/Poseidon/Foundation/Platform/Shutdown.cpp`), symmetric
   with the existing `FontSystem::Instance().Shutdown()` call.

Both together: every teardown path (`Remount`, `DDTerm`, and any
future one) resets the singleton automatically. No per-call-site
plumbing.

## Diagnostic: `--mod` isolation test

The bug reproduces only via the in-game Mods menu (which triggers
`Remount()`). Direct-boot with `cwr-ce --mod <path>` (see
`DEBUGGING.md`) skips `Remount()` entirely and runs clean. If a crash
reproduces via Mods menu but not via `--mod`, look at what
`UnloadGameData()` fails to reset before assuming the crash site is
the bug site.

## Suspects still to audit

Any singleton in `engine/**` whose state is derived from `GScene`,
`GWorld`, `CfgScenePreload`, or content configs. Suspects at time of
writing:

- `FontSystem` — already has `Shutdown()` wired in; documented as the
  reference pattern.
- `ScenePreloader` — fixed 2026-07-03.
- `MaterialManager` — has a global `GMaterials`; check whether it
  caches `Shape*` from `GScene`.
- Global preloaded texture bank `GPreloadedTextures` — cleared in
  `UnloadGameData()` already; keep as reference.
- Global sound scene `GSoundScene` — `Reset()` is called explicitly in
  `UnloadGameData()`; keep as reference.
- Any singleton returning a `Ref<>` from `GScene` — those references
  become dangling when the Scene is deleted, then re-populated with
  garbage or left null after re-mount.

Sweep procedure:
1. `grep -rn "static [A-Za-z]* s;" engine/Poseidon/` — find Meyers
   singletons.
2. For each, check its `Initialize` for an `_initialized`-style guard.
3. For each guarded one, check that `Shutdown` exists AND is called
   from `UnloadGameData()`.

## Test coverage note

`tests/unit/engine/Poseidon/World/Scene/test_scene_preloader.cpp`
already exercises `Shutdown()` — the entry point was unit-tested. The
bug was purely at the wiring layer (nothing called it). When adding
`Shutdown()` to another singleton, extend both the unit test AND
`test_shutdown_order_audit.cpp` (`I-04`) to lock in the ordering
against `DestroyEngine`.
