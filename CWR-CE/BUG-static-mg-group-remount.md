# Bug: grouped static weapons make the surviving gunner mount/unmount forever

**Status:** fixed and verified 2026-08-06 on ser6. Reproduced first with a
6-unit mission, root cause read from the code, fix built with poudriere and
confirmed in the original `load.Demo` mission by the reporter.

**Branch:** `fix/static-weapon-group-remount` (off `main`), single commit
`0c82386` — `AIGroupCmd: keep static-weapon crew assigned in AssignVehicles`.

**Port:** carried as
`~/freebsd-ports/games/CWR-CE/files/patch-engine_Poseidon_AI_AIGroupCmd.cpp`
(PORTREVISION 3 -> 4).

**Found while** watching the log of a heavy custom mission (`load.Demo`,
Malden demo island, ~200 units): an East soldier was seen repeatedly
mounting and unmounting his machine gun.

---

## Symptom

An AI soldier crewing a static weapon gets out of it and back in roughly
once per AI think (~1 Hz), indefinitely. He never walks away: measured
maximum distance from his own gun during the loop is 1.84 m. The unit is
effectively out of the fight, and the mission's defensive position is dead
weight.

Preconditions, all three required:

1. two or more static weapons (`M2StaticMG`, `M2StaticMGE`, …) in the
   **same group**;
2. the group is AI (no player in it);
3. one of the gunners **dies**, leaving a gun with no assigned crew.

With a single static weapon in the group, nothing happens. While both
gunners are alive, nothing happens.

## Root cause

`AIGroup::AssignVehicles()` (`engine/Poseidon/AI/AIGroupCmd.cpp:1483`) runs
on every AI think (`AIGroup.cpp:1364`, right before `GetInVehicles()`), and
decides per unit whether its current vehicle assignment can be left alone:

```cpp
Transport* veh = unit->VehicleAssigned();
if (veh)
{
    if (veh->IsAbleToMove() && veh->GetDriverAssigned())
    {
        continue;                       // settled - skip this unit
    }
    // we need to remove this vehicle
}
```

A static weapon has no driver position, so `GetDriverAssigned()` is null
forever and **the test can never pass**. Its gunner therefore falls through
into the `soldiers` candidate list on every single think, as if he were
unassigned.

That is harmless while every gun in the group already has an assigned
gunner — the assignment loop below finds nothing to give him. It stops
being harmless when a gunner dies: the dead man's gun is still in the
group's `_vehicles` list with no assigned gunner, so the loop
(`AIGroupCmd.cpp:1537-1548`) hands the survivor to *that* gun. Now:

- `AssignVehicles()` — survivor assigned to the empty gun, still sitting in
  his own;
- `GetInVehicles()` (`AIGroupImpl.cpp:408`) — first disjunct
  `assigned != unit->GetVehicle()` is true => "wrong vehicle" => **GetOut**;
- next think — his own gun now has no assigned gunner either, so the loop
  gives him back to it => he is a free soldier with an assignment =>
  **GetIn**;
- repeat.

The two guns keep stealing the same soldier. One gun alone has nothing to
swap with, which is why grouping two is what exposes the missing-skip bug.

## Fix

Treat a unit that already occupies the seat it is assigned to as settled,
which is what the `IsAbleToMove() && GetDriverAssigned()` test was trying to
express for driven vehicles:

```cpp
if (unit->GetVehicle() == veh &&
    (veh->GetGunnerAssigned() == unit || veh->GetCommanderAssigned() == unit ||
     veh->GetDriverAssigned() == unit))
{
    continue;
}
```

Deliberately narrow: it only short-circuits units that are *already seated
where they are assigned*, so re-assignment after a death, a bail-out or a
seat change is untouched.

## Repro

`MGTest.Demo` — two grouped `M2StaticMGE` at the coordinates taken from
`load.Demo` (ids 268/269), one shared SAD waypoint, plus a 4-man WEST patrol
to force contact. Mission file kept next to this doc as
`static-mg-mission/mission.sqm`.

Run it headless with the control channel open, and probe over SQF:

```sh
env -u DISPLAY XDG_RUNTIME_DIR=/tmp/xdg PoseidonServer \
    -C ~/.local/share/CWR/base --simulate <dir>/MGTest.Demo \
    --duration 400 --harness 0 --no-sound --log-level info --log-file /tmp/mg.log
# -> prints HARNESS_PORT=<n> on stdout; then, newline-delimited JSON on that port:
#    {"cmd":"eval","code":"format[\"%1\", vehicle manF]"}
```

Probe binding (`nearestObject` on the two gun positions, then track the
crew objects; sqm `{x, alt, y}` -> SQF `[x, y, alt]`):

```
mgL = nearestObject [[8402.13,9870.81,8.97],"M2StaticMGE"];
mgF = nearestObject [[8195.24,9874.84,25.56],"M2StaticMGE"];
manL = gunner mgL; manF = gunner mgF;
format["t=%1 Lalive=%2 Fin=%3 FdOwn=%4", time, alive manL, (vehicle manF) == mgF, manF distance mgF]
```

Observed timeline (1 Hz sampling, 327 samples):

| t (s)        | state                                                   |
|--------------|---------------------------------------------------------|
| 3.7 – 71.4   | both gunners alive and mounted, zero transitions         |
| 71.5         | leader-gun gunner killed                                 |
| 103.9        | survivor's first dismount                                |
| 103.9 – 333  | continuous mount/unmount; 55 flips at 1 Hz sampling, 125 flips in a finer-grained run over 220 s |

## Verification

Built with poudriere (`testport` then `bulk`, jail `builder`, tree `default`
-> `~/freebsd-ports`), installed as `CWR-CE-3.01_4`:

```
Queued: 1  Built: 1  Failed: 0        # both testport and bulk
```

Automated check — `static-mg-mission/verify_static_mg_fix.sh 120`, which boots
the repro mission headless, kills the leader's gunner over the harness
(`manL setDammage 1`) and counts seat changes:

```
samples=119  t=2.074..121.205  leader_died_at=2.074  seat_transitions=0
PASS  surviving gunner stayed seated
```

The reporter then confirmed the original `load.Demo` mission behaves
correctly with this build.

Caveat on the automated check: with the same script, a control build (the AI
patch removed, everything else identical) produced only **1** transition, not
the ~1 Hz loop of the original observation. Scripting the death at t=2 s does
not put the group in the same state as dying mid-firefight, so the script is a
weak detector on its own — treat 0 transitions as necessary, not sufficient,
and reproduce in a real mission when in doubt. Making the check faithful would
mean killing the gunner later, once the group is in its SAD/combat state.

Passive mode (`verify_static_mg_fix.sh <secs> natural`) waits for the
firefight to kill someone instead; it is flakier still — one 300 s run ended
with both gunners alive and reported INCONCLUSIVE.

### Unrelated blocker hit on the way

`all-perf-freebsd` does not compile: `EngineGL33_Shaders.cpp:1281-1282` call a
three-argument `CompileGLShader(type, source, name)` (from upstream `0c43ef8`,
the gamma-in-a-shader change) while the PR#126 shader-override rework in this
branch redefined the helper as `(type, name)` with lookup through
`ShaderSourceByName()`. Carried in the port as
`files/patch-engine_PoseidonGL33_EngineGL33__Shaders.cpp`, which re-adds the
source-taking overload. `upstream/main` is unaffected, so this patch is a
local carry, not part of the upstream PR. The alternative repair — moving the
gamma GLSL into the `ShaderSourceByName()` table — also changes
`HashShaderSources()`, i.e. the shader-cache key.

## Notes / non-findings

- The `AISubgroupFSM.cpp:1638` `check failed: veh == unit->VehicleAssigned()`
  errors seen in the original `load.Demo` session are **not** part of this
  loop: the minimal repro produces zero of them. Separate issue.
- The diagnostics that would have shown this directly in the log
  (`AIGroupImpl.cpp:1133-1171`) are behind `#if DIAGS`, and `DIAGS` is
  defined nowhere in the tree — so they are dead code. One of them
  (`:1166`) also passes 6 arguments to a 5-placeholder format string, which
  would break a build that defined `DIAGS`.
- `AIGroup::AllGetOut()` (`AIGroupImpl.cpp:1554`) has no callers.
