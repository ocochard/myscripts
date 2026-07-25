# CWR-CE mission.sqm format + test-scene customizations

Working reference for the `mission.sqm` files that drive CWR-CE (Poseidon)
missions, written while building headless perf/visual test scenes. Covers the
format as the engine actually parses it on this fork, the coordinate
conventions that repeatedly cost time, and the two custom scenes committed here
(`closecombat-mission/`, and the sibling `paradrop-mission/`). It is descriptive
of what worked on the `gpu-skinning` build (`08e850c`), not an upstream spec.

## What a mission.sqm is

A `mission.sqm` is the editor's save format: a plain-text class tree in the
Bohemia config dialect (the same `class X { key=value; }` grammar as
`config.cpp`/`config.bin`). The in-game Arcade editor writes it; you can also
hand-write or generate it. One mission = one `mission.sqm` inside a per-mission
folder `<Name>.<World>/` (see README "Where the mission editor saves missions").

The engine stages a copy on every `--test-mission` launch, logging the path:

```
Test mission: <src>/mission.sqm -> /tmp/cwr/mission-smoke/<hash>/Missions/mission.sqm
```

so edits to the source are picked up per launch, and the log line tells you
exactly which file ran.

## Top-level structure

```
version=11;
class Mission
{
    randomSeed=3469315;
    class Intel   { /* weather, date, briefing params — empty is fine */ };
    class Groups
    {
        items=<G>;             // number of class ItemN groups that follow
        class Item0 { ... };
        ...
        class Item<G-1> { ... };
    };
    // optional: class Vehicles (empty/unmanned), class Markers, class Sensors
};
class Intro      { randomSeed=...; class Intel {}; };
class OutroWin   { randomSeed=...; class Intel {}; };
class OutroLoose { randomSeed=...; class Intel {}; };
```

- `version=11` is what the current editor writes; the loader accepts it.
- The `Intro`/`OutroWin`/`OutroLoose` blocks can be empty stubs but must be
  present — the editor always emits them.
- `items=<N>` inside any container class is **load-bearing**: it declares how
  many `class ItemN` children the loader reads. If it disagrees with the actual
  count you get missing units (too low) or a parse walk off the end (too high).
  Every generator must set it correctly.

## Groups → Vehicles → units

Units are nested two levels under `Groups`: each `class ItemN` under `Groups` is
a **group** (a squad, one `side`), and its `class Vehicles` holds the actual
units (soldiers/vehicles):

```
class Item0                        // a group
{
    side="WEST";                   // WEST | EAST | GUER | CIV
    class Vehicles
    {
        items=9;                   // units in THIS group
        class Item0                // a unit
        {
            position[]={7973.33, 32.17, 9290.42};
            azimut=135.000000;     // facing, degrees (0=N, 90=E, 180=S)
            id=0;                  // unique across the mission
            side="WEST";
            vehicle="SoldierWB";   // CfgVehicles class name
            player="PLAYER COMMANDER";  // only on the player unit (optional)
            leader=1;              // group leader (optional)
            rank="SERGEANT";       // optional
            skill=0.600000;        // 0..1
            init="...";            // optional SQF run at unit spawn
        };
        ...
    };
};
```

Common infantry `vehicle=` classes (all skinned, West side): `SoldierWB` (rifle/
basic), `OfficerW`, `SoldierWMG` (machine-gunner), `SoldierWG` (grenadier),
`SoldierWLAW` (AT). AI groups behave best at ≤ ~12 units, so large formations
are split into several groups.

## Coordinate conventions — the part that costs time

Two different orderings coexist, and mixing them puts units underground or the
camera in the wrong place:

- **In the sqm, `position[]={ mapX, altitude, mapY }`** — the MIDDLE value is the
  height (altitude ASL); the outer two are the horizontal map coordinates.
  Example: `{7973.33, 32.17, 9290.42}` = map (7973, 9290) at 32 m ASL.
- **In SQF script, positions are `[ x, y, height ]`** — `getpos`, `setpos`,
  `camCreate` all use height LAST. So the sqm `{x, alt, y}` becomes the script
  `[x, y, alt]`.
- **`camCreate` height is above-ground (AGL), not ASL.** Verified empirically on
  Abel: ground there is ~32 m ASL; `camcreate [x, y, 34]` put the camera ~34 m
  **up** (a downward bird's-eye view), while `camcreate [x, y, 2]` gave an
  eye-level shot. Use a small AGL number (≈1.7–2) for a soldier's-eye camera.

The islands used here: `abel` (= Malden, the benchmark/close-combat land),
`noe`, `eden`, `demo`. The `<World>` folder suffix must match
`Glob.header.worldname`.

## Unit `init` — SQF gotchas in test mode

The `init` string is SQF executed when the unit spawns. In `--test-mission`
runs (which default `--strict` ON in Debug/RelWithDebInfo builds) it is sharp:

- **Any script ERROR aborts the whole run** (`Script error … — aborting`) → no
  screenshot, no benchmark. Check the log first when a run produces nothing.
- **Quotes are doubled.** Inside the sqm's `init="..."` string, a literal `"`
  is written `""`. So `_x setBehaviour "SAFE"` becomes
  `init="this setbehaviour ""SAFE""";`.
- **`_underscore` locals are rejected in global space in test mode**
  (`Local variable in global space`). Use a global var (no underscore, e.g.
  `pcam`) or nest the expression so no local is assigned.
- **`createVehicle` ignores the Z you pass** — it spawns on the ground; lift
  afterward with `setpos` if you need altitude (the paradrop trick).

## The scripted camera pattern

To frame a headless `--auto-screenshot` (or just to fix the view for a stable
benchmark), put a camera in one unit's `init` — conventionally the player's:

```
pcam = "camera" camCreate [X, Y, AGL];   // "" in the sqm
pcam camSetTarget this;                   // rotates each frame to keep target framed
pcam cameraEffect ["internal","back"];
pcam camCommit 0;
```

- `camSetTarget <obj>` tracks the object (camera **rotates** to keep it framed),
  but the camera **position is static** — `camSetPos`/`camSetRelPos` are one-shot,
  so the camera does not follow a moving/falling target. Place it where you want
  it and let the target rotate the view.
- Targeting `this` (the unit carrying the init) points the camera at that unit;
  put that unit at the far side of what you want in frame so the whole group sits
  between camera and target.

## Custom scene: `closecombat-mission/` (GPU-skinning view-LOD stress)

Purpose: give `--gpu-skinning` a fair shot. GPU skinning only offloads infantry
**view** LODs (the highest-detail model, used when the unit is close). The stock
`Benchmark.Abel` scene is a 197-unit patrol at camera distance, so its units sit
at **coarse** LODs and the skinned path barely runs — measured on the t420 as a
no-op (main-thread CPU unchanged; see `PERF-multithread-scope.md`, 2026-07-25).
This scene forces the opposite: many soldiers packed at view LOD.

Design (generated by `gen_closecombat.sh`):

- **Dense grid** — 11 groups × 10 soldiers = 110 units, 2 m spacing, in a
  ~20 m × 22 m block on Abel's flat area (the same known-good land the benchmark
  uses, ground ≈ 32 m ASL).
- **Frozen formation** — every unit's `init` runs
  `this disableAI "MOVE"; this disableAI "AUTOTARGET"; this setBehaviour "SAFE"`
  so the AI does **not** disperse the grid (the first attempt without this let
  them scatter into a loose mid-distance crowd — mostly LOD1/2, defeating the
  purpose). Frozen soldiers still play idle animation, so the skinning path stays
  exercised while density stays constant → a clean, repeatable A/B.
- **Eye-level camera** — the back-center soldier is the player; its `init` (after
  the freeze) spawns the camera 3 m in front of the block at 2 m AGL, targeting
  itself, so the view looks **down the packed column**: the front rows fill the
  frame at view LOD, receding into depth. See `closecombat_viewlod.png`.

Run it exactly like the benchmark, just point `--test-mission` at this folder:

```
env DISPLAY=:0 XDG_RUNTIME_DIR=/tmp/xdg PoseidonGame -C ~/.local/share/CWR/base \
  --no-splash --no-sound --benchmark --test-mission \
  ~/.config/CWR/Users/Test/Missions/CloseCombat.Abel [--gpu-skinning]
```

`--benchmark` honors the `--test-mission` scene (it counts frames once gameplay
reaches `GModeArcade`), so the same `prof_bench.sh`/`t420_bench.sh` A/B harness
works by passing the mission name.

### Regenerating / retuning

`gen_closecombat.sh <out.sqm>` writes the mission; tunables at the top: `ROWS`,
`COLS`, `SP` (spacing), block center `CX`/`FRONTY`, ground `Z`, camera
`CAMY`/`CAMH`. Denser/closer = more view-LOD soldiers = more skinning load.
To install: copy to `~/.config/CWR/Users/Test/Missions/CloseCombat.Abel/
mission.sqm` (create the folder). The `<World>` suffix must be `.Abel` to load on
Malden.

## Validation gotchas hit while building this

- **Headless `--simulate` hangs at mission load on this host.** The docs say the
  `08e850c` dummy-backend fix made `--simulate` run headless, but in this
  environment `--simulate <mission>` (and `--render dummy --simulate`) stages the
  mission then hangs at load — the **stock `Benchmark.Abel` hangs the same way**,
  so it is not a mission-file fault. Consequence: validate scenes with a **real
  GL** `--test-mission --auto-screenshot` run on a machine with a display
  (the t420 or ser6), not headlessly. A structurally broken sqm shows up as a
  parse error or missing units in that GL run, not a hang.
- **A hang at "GL33: Initializing engine" is graphics/display, not the mission.**
  Seen once on ser6 over SSH; unrelated to the sqm (see DEBUGGING.md §2b, the X11
  Present-wait hang). Kill and retry, or run where the display is healthy.
- **Use the engine framebuffer screenshot** (`--auto-screenshot "FRAME:PATH"`),
  not scrot/xwd — see DEBUGGING.md "Visual A/B via screenshots".

## See also

- `DEBUGGING.md` — the benchmark command, `--test-mission` staging, screenshot
  capture, CLI reference.
- `paradrop-mission/` — the sibling custom scene (parachute canopy A/B): same
  camera-init pattern, plus the `createVehicle`/lift and side-camera tricks.
- `PERF-multithread-scope.md` — why this scene exists (the GPU-skinning t420
  measurement it was built to enable).
