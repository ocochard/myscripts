# CWR-CE CPU hotspot profile

Sampled call-graph profiling of `PoseidonGame` during real gameplay, taken
to answer "where does the frame time go, and is multithreading the right
lever?". Companion to `PERF-low-fps-cpu-bound.md`.

Headline: the frame is CPU-bound on a single main thread, and ~4% of it is
spent running **heavy validation sweeps that were meant to be assertions but
are not compiled out of the release build**. That is the cheapest win and it
beats multithreading as a first step.

## Method

- Tool: FreeBSD `hwpmc` / `pmcstat -S <unhalted-cycles> -O out sleep N`, then
  `pmcstat -R out -G graph`. The unhalted-cycles event only accrues on busy
  cycles, so idle/vsync waits never pollute the profile.
- System-wide sampling (the `sleep N` is just the timer); the call graph is
  then filtered to `PoseidonGame`. Kernel, Mesa (`libgallium`), libc, ZFS,
  ACPI, and the `claude` process itself appear too and are treated as noise.
- Percentages below are self-time as a share of *resolved* samples.

Two gotchas learned here:

- `--render-frame-log` emits on a ~16 s timer, **not** every 60 frames, so its
  line spacing is useless for FPS. The on-screen `--show-fps` overlay is the
  only reliable frame-rate source.
- `--benchmark <mission>` and passing a mission as a positional arg both still
  boot to the **main menu** — they do not auto-load the mission. Gameplay
  profiling requires driving into the mission by hand.

## Hosts

| host | CPU | GPU / Mesa | event | scene | result |
|------|-----|-----------|-------|-------|--------|
| `t420` | i5-2520M (2c/4t, 2011) | HD 3000 / Mesa 26.1.3 (GL 3.3) | `cpu_clk_unhalted.thread_p` | C02 Battlefields | ~20 FPS, CPU-bound |
| `ser6` | Ryzen 7 7735HS (8c/16t) | Radeon iGPU / Mesa 26.1.4 | `ls_not_halted_cyc` | unit-heavy editor mission | primary profile below |

`t420` is a muddier data point: a meaningful slice of its main-thread time is
`i915_gem_madvise_ioctl` + syscall overhead — weak-GPU Mesa/kernel submission
cost that cannot be fixed in the engine. `ser6` samples faster (more frames →
more hits) and its stronger GPU shrinks that driver noise, so its profile more
purely reflects engine compute. A unit-heavy scene amplifies the per-object
work that is the suspected bottleneck.

The build under test is the port's `Release` config: `-O2 -pipe
-fstack-protector-strong -fno-strict-aliasing -DNDEBUG`.

## Hot engine functions (ser6, unit-heavy scene)

Noise rows (`AcpiOsReadPort`, `lock_delay`, `zfs_lz4_compress`, `libgallium*`,
`/usr/local/bin/claude`, `doreti`) removed; engine functions only.

| self% | function | category |
|------:|----------|----------|
| 2.82% | `AIUnit::AssertValid() const` | **validation** |
| 2.23% | `Landscape::CheckVisibility()` | visibility cull |
| 1.77% | `AnimationRT::ApplyMatricesSimple()` | skinning |
| 1.43% | `strcasecmp_l` (libc) | case-insensitive name lookup |
| 1.19% | `World::CheckVehicleStructure() const` | **validation** |
| 0.95% | `SelectInterestingTarget()` | AI targeting |
| 0.90% | `Vector3P::SetFastTransform()` | math |
| 0.80% | `Landscape::GroundCollision()` | collision/terrain |
| 0.79% | `Landscape::PredictCollision()` | collision/terrain |
| 0.78% | `Landscape::ObjectCollision()` | collision/terrain |
| 0.77% | `Landscape::RoadSurfaceY()` | collision/terrain |
| 0.64% | `World::Simulate()` (self) | frame root |
| 0.60% | `AnimationRT::ApplyMatricesComplex()` | skinning |
| 0.55% | `HowMuchInteresting()` | AI targeting |
| 0.50% | `Object::OcclusionView() const` | occlusion |
| 0.47% | `BankInitArray<EntityType>::Find()` | name lookup |

The whole render path runs *under* `World::Simulate` on the main thread
(`Simulate -> RenderFrame -> AppIdle -> RunMainLoop`), confirming simulate and
render-submit are serial on one thread.

## Root cause of the validation cost

`PoseidonAssert` **is** correctly compiled out under `-DNDEBUG`
(`Foundation/Framework/DebugLog.hpp:64` — empty). The hot validators are not
reached through it; they go through **`AI_ERROR`**, which is intentionally not
guarded:

```cpp
// DebugLog.hpp:87 — evaluates expr in release BY DESIGN
#define POSEIDON_LOG_CHECK(cat, expr)  { if (!(expr)) LOG_ERROR(cat, "...check failed..."); }
#define AI_ERROR(expr) POSEIDON_LOG_CHECK(AI, expr)
```

The design intent (per the comment at `DebugLog.hpp:81`) is to keep invariant
checks live in release logs. That is reasonable for cheap one-liners, but here
it wraps expensive O(n) sweeps:

- `AISubgroup.cpp:1564,1580,1597` — `AI_ERROR(GLOB_WORLD->CheckVehicleStructure())`.
  `CheckVehicleStructure()` (`WorldImpl.cpp:1315`) loops every vehicle ×
  commander/pilot/gunner, each calling the deep `AIUnit::AssertValid()`.
- `AICenterImplPreview.cpp:529,534,571` — `AI_ERROR(AssertValid())`.

Net: ~4% of every frame (`AssertValid` 2.82% + `CheckVehicleStructure` 1.19%)
is spent validating structure and discarding the result, in the shipping
build, scaling with unit count.

## Recommendations (ordered by ROI)

1. **Release-gate the heavy `AI_ERROR` validators (~4%, near-free, low risk).**
   Do not wrap O(n) sweeps in the always-on `AI_ERROR`. Either `#ifndef NDEBUG`
   the specific call sites, or add an `AI_HEAVY_CHECK(expr)` macro that compiles
   out under `NDEBUG` and use it only for the expensive validators, keeping
   `AI_ERROR` for cheap one-liners. Grep other `AI_ERROR` / `NET_ERROR` sites
   for the same anti-pattern.
2. **Case-insensitive lookups** — `strcasecmp_l` (1.43%) + `BankInitArray::Find`
   (0.47%). The POSIX case-normalization cost (see
   `BUG-filecache-case-normalization`); cache or case-fold keys.
3. **Then multithread.** What remains hot is all per-unit/per-object: AI
   targeting (`SelectInterestingTarget` / `HowMuchInteresting`), collision
   (`Ground/Predict/Object`, `RoadSurfaceY`), visibility/occlusion
   (`CheckVisibility` / `OcclusionView`), skinning (`ApplyMatrices*`). This is
   genuinely parallelizable across a job system, with real headroom on ser6's
   16 threads — but a large, correctness-sensitive refactor (shared entity
   state, MP determinism). Highest payoff, worst effort/risk, so last.

Steps 1 and 2 are single-thread wins that help the 4-thread `t420` as much as
`ser6`; multithreading mostly benefits modern many-core hardware.

## Optimization plan

Each phase is independently shippable and must be measured before moving on.
Re-profile with the exact Method above and archive the graph under
`perf-data/` so gains are attributable. Work on a `perf` branch off `main`
(phases 1–3 are upstreamable; 4–5 are large enough to stage separately).

### Phase 0 — Reproducible bench (prerequisite)

- Fix the workload: one saved unit-heavy mission on Eden, a fixed camera view
  over the densest cluster, `--no-sound`. Drive into the mission by hand
  (menu-load caveat above), hold the view, sample 10 s.
- Record two numbers each run: the `--show-fps` overlay reading (real FPS) and
  the `pmcstat -G` top-self table. FPS is the acceptance metric; the table
  explains it.
- Baseline captured 2026-07-18 (this doc). Keep the raw `pmc-*.out` in
  `perf-data/`.

### Phase 1 — Release-gate heavy `AI_ERROR` validators

- Goal: remove ~4% (`AIUnit::AssertValid` + `World::CheckVehicleStructure`).
- Change: add `AI_HEAVY_CHECK(expr)` in `DebugLog.hpp` — identical to
  `AI_ERROR` under `!NDEBUG`, empty under `NDEBUG`. Convert the six heavy sites:
  `AISubgroup.cpp:1564,1580,1597` and `AICenterImplPreview.cpp:529,534,571`.
  Leave cheap `AI_ERROR` one-liners alone.
- Sweep: grep every `AI_ERROR` / `NET_ERROR` argument for calls to `*Valid()`,
  `Check*Structure`, or other O(n) helpers and convert those too.
- Verify: `AssertValid` and `CheckVehicleStructure` disappear from the top
  table; FPS rises. Correctness unchanged (checks still run in debug/test).
- Risk: minimal. Upstreamable.
- **Status: DONE (2026-07-18), verified — see "Phase 1 results" below.**

### Phase 2 — Case-insensitive lookup cost

- Goal: cut `strcasecmp_l` (1.43%) + `BankInitArray<EntityType>::Find` (0.47%).
- Change: normalize/case-fold bank keys once at insert and hash on the folded
  form, so per-lookup `strcasecmp` disappears. Tie into
  `BUG-filecache-case-normalization` so the fix is shared, not duplicated.
- Verify: `strcasecmp_l` drops out of the top table; no lookup regressions in
  the ports smoke tests.
- Risk: medium — lookup correctness on POSIX case-folding; cover with the
  case-normalization regression cases.

### Phase 3 — Micro-opt remaining serial hotspots + build tuning

- Continue the existing math line (`nearbyint`, `invsqrt`, `Vector3P` — already
  in git). Targets: `Vector3P::SetFastTransform` (0.90%) and the `Landscape`
  collision/terrain queries (`GroundCollision`, `PredictCollision`,
  `ObjectCollision`, `RoadSurfaceY`) — look for per-object recompute that can be
  cached per frame, and SIMD-friendly inner loops.
- Build tuning for a personal (non-port) binary: `-march=znver3` on ser6 /
  `-march=sandybridge` on t420, LTO, and PGO over the fixed bench. Keep the
  shipped port generic — arch-specific packages are not portable.
- Verify: each change re-profiled; keep only wins.
- Risk: low–medium; PGO/LTO are build-only.

### Phase 4 — Decouple render-submit from simulate

- Goal: overlap `simulate(frame N)` with render-submit of `frame N-1` on a
  second thread; approaches ~2x when the two halves are balanced.
- Change: double-buffer the render snapshot so the render thread reads a stable
  copy while simulate mutates the live world. The hard part is the snapshot
  boundary in an engine that currently mutates entities during draw (the whole
  draw path runs under `World::Simulate`).
- Verify: FPS vs frame-time variance; check for visual tearing/one-frame lag
  artifacts.
- Risk: high — shared-state boundary; must not change simulation results.

### Phase 5 — Job-system data parallelism

- Goal: spread the per-object work across cores (16 on ser6): AI targeting
  (`SelectInterestingTarget`/`HowMuchInteresting`), collision queries,
  visibility/occlusion (`CheckVisibility`/`OcclusionView`), skinning
  (`ApplyMatrices*`).
- Change: introduce a task scheduler; parallelize the per-unit/per-object loops
  that have no cross-object writes, with a clear read/write phase split.
- Verify: scaling vs thread count; **determinism gate** — identical results
  single- vs multi-threaded, or MP sync and replays break.
- Risk: highest — races, nondeterminism, MP desync. Do only after 1–4 and with
  a determinism test in place.

## Phase 1 results (2026-07-18, verified)

**Change.** Added `AI_HEAVY_CHECK(expr)` to `DebugLog.hpp` — identical to
`AI_ERROR` under `!NDEBUG`, `((void)0)` under `NDEBUG` — and converted the 16
heavy validator sites: `AISubgroup.cpp` (10), `AIArcade.cpp` (3),
`AICenterImplPreview.cpp` (3). Engine branch `perf-p1-ai-heavy-check`
(commit `2fd8637`, based on the shipped tip `8fc693b2`). Shipped through the
port as four `files/patch-engine_Poseidon_*` files + `PORTREVISION` 2 → 3.

**Measurement.** Built `RelWithDebInfo` (`-O2 -g -DNDEBUG`, `STRIP=`) per the
symbols recipe in `DEBUGGING.md` — asserts stay off, so the gate is real, but
symbols are retained so pmcstat can name Poseidon functions. Same host/method
as the baseline (ser6, `ls_not_halted_cyc`, unit-heavy scene).

**Result — confirmed.** Both validators are still *defined* in the binary
(`nm -C` finds `AIUnit::AssertValid` and `World::CheckVehicleStructure`) but
draw **zero samples** in the profile, versus 2.82% + 1.19% ≈ **4% of frame
CPU** at baseline. So the calls were gated out of the hot path, not the
functions removed; debug/test builds still run them.

Top self-time after Phase 1 (validators absent; remaining %s are relative, so
inflated by both the removed 4% and a denser view — not regressions):

| self% | function |
|------:|----------|
| 6.79% | `Landscape::CheckVisibility()` |
| 2.53% | `Landscape::PredictCollision()` |
| 2.05% | `Object::OcclusionView()` |
| 2.01% | `AnimationRT::ApplyMatricesSimple()` |
| 1.59% | `Vector3P::SetFastTransform()` |
| 1.45% | `Landscape::GroundCollision()` |
| 1.41% | `Landscape::ObjectCollision()` |
| 1.24% | `Landscape::RoadSurfaceY()` |
| 1.18% | `SelectInterestingTarget()` |
| 1.11% | `Landscape::CheckIntersection()` |
| 0.96% | `AnimationRT::ApplyMatricesComplex()` |

Expected FPS gain ≈ 4% on the single-thread CPU-bound frame (removing ~4% of
main-thread work). A same-build baseline FPS was not recorded, so the exact
FPS delta is unmeasured; the profile disappearance is the proof. `--show-fps`
readings should be logged as the acceptance metric from Phase 2 on.

**Next target:** `Landscape::CheckVisibility()` is now the clear #1 — the prime
candidate for Phase 3 (micro-opt) or Phase 5 (parallelize).

## CheckVisibility parallelization audit (2026-07-18) — DEFERRED

Investigated `CheckVisibility` (the #1 post-Phase-1 hotspot) as a Phase 5
job-system pilot. Verdict: **unsafe/low-ROI to parallelize as-is; deferred.**

**Where it's driven from.** Two paths reach the raycast
`Landscape::Visible → CheckVisibility → Object::Intersect`:
- **Path B — the sensor×target visibility matrix** (`SensorList`). Outermost
  loop `UpdateCell(r,c)` (`Visibility.cpp:334`); each cell writes only its own
  `row._info[c]` → embarrassingly parallel at the loop level. Driven from
  `World::Simulate → SmartUpdateAll` (`World.cpp:1753`), a distinct sub-phase
  AFTER `SimulateAllVehicles` (`World.cpp:1677`), so entity positions are final
  and effectively read-only during it.
- **Path A — per-vehicle firing LOS** (`VisibilityTracker::Value`,
  `Target.cpp:1358`), ~1 cached raycast per actively-firing vehicle, run inside
  the movement phase.

**Why parallelizing is the wrong first move:**

1. **The clean loop is throttled to nothing.** `SmartUpdateAll` is hard-budgeted
   to `maxTests=4, maxCalcs=4` (`Visibility.cpp:550`), round-robined across
   frames → only ~4-8 matrix raycasts actually run per frame. Nothing to
   parallelize unless the budget is lifted — and lifting it changes *which*
   cells update per frame, i.e. AI behavior + MP determinism.
2. **Shared-state race needs a core refactor (H1).** `Object::Intersect`
   transiently mutates the *shared* `LODShape` geometry via `Animate`/`Deanimate`
   (`ObjectIntersect.cpp:753,928` → `Object.cpp:316,395-426,532`). That shape is
   shared by every instance of a model (all trees of one type). Two threads
   intersecting two instances of the same model corrupt each other → wrong LOS →
   MP desync. Making it thread-safe (thread-local scratch geometry) touches the
   collision/animation core — the largest, riskiest change in the plan.
3. **Lazy caches (H2).** Normals (`Shape.cpp:1857`) and convex components
   (`Edges.cpp:233`) are validated on first touch → require a serial warm-up
   pass over every obstacle shape before any parallel batch.

**Already safe:** `VisCheckContext` is stack-allocated per query
(`Collisions.cpp:1830`), accumulation into `context.objVis` is thread-local and
order-independent; grid reads and the `VisiblePosition/VisibleSize/Occlusion*`
accessors are pure reads; no shared RNG.

**Single-thread win this surfaced (worth doing regardless):** `Object::Intersect`
runs `Animate`/`Deanimate` on *every* obstacle per raycast, but for rigid,
non-animated, non-ClipLand obstacles (most trees/walls/rocks) that deformation
is unnecessary. Skipping it there cuts cost from every raycast with no threading,
helps t420, and is a prerequisite for any future parallelization.

> **DEBUNKED (2026-07-19) — do not implement this. See "The `Object::Intersect`
> rigid-skip is a non-win" below.** The audit above did not trace into
> `AnimateComponentLevel`'s existing `IsAnimated` guard: the deformation it
> proposes skipping is *already* skipped for rigid obstacles. The residual
> cost is sub-noise, and rigid objects are already thread-safe, so it is not a
> parallelization prerequisite either.

If parallelization is ever revisited: parallelize Path B at row granularity over
a deterministic dirty-cell batch (schedule kept identical across clients), after
H1/H2 are fixed and the budget is lifted deterministically. Not before.

## Phase 2 (revised target): animation skinning micro-opt

CheckVisibility deferred → next contained target is the animation skinning path
`AnimationRT::ApplyMatricesSimple` (2.01%) + `ApplyMatricesComplex` (0.96%) ≈ 3%,
with `Vector3P::SetFastTransform` (1.59%) inside it. Self-contained numerical hot
loop, SIMD-friendly, low-risk, same lane as the existing InvSqrt/nearbyint
micro-opts.

Findings:

- `ApplyMatricesSimple` (`RtAnimation.cpp:958`) is single-bone skinning: per
  vertex `SetPos(i) = val * pos` (a `Matrix4P × Vector3P` =
  `Vector3P::SetFastTransform`) and `SetNorm(i) = val.Orientation() * norm`. It
  re-fetches `val` and re-extracts `val.Orientation()` every vertex even when
  consecutive vertices share a bone (`pwsel`).
- The transform primitive `Vector3P::SetFastTransform` (`Math3DP.cpp:310`, active
  under `#if !_PIII`) is **scalar**: 9 mul + 9 add. It is the 1.59% profile
  symbol and is called from **45 sites** engine-wide (collision, physics,
  rendering), so optimizing it is a broad win, not just skinning.
- A dormant `__m128` implementation exists at `Math3DPK.cpp:27-59` (dead — the
  whole file is gated `#if defined __ICL && defined _PIII`, never compiled on
  clang/FreeBSD). Usable as a reference for the SSE math.
- The engine already has a SoA `V3Quad`/`V3Array` (x[4],y[4],z[4], "one XMM
  register") for 4-wide SIMD that the skinning loop does not use.

Two options:
- **(A) SSE-ify `Vector3P::SetFastTransform`** (broad, surgical, proven pattern).
  Aliasing (`o` may alias `*this`) is already safe if computed in registers and
  stored last. **Prereq: verify `Matrix4P` memory layout** so the `__m128` matrix
  loads are correct (row padding / alignment) — broad blast radius means it must
  be validated, not assumed.
- **(B) Hoist redundant per-bone work in `ApplyMatricesSimple`** (cache `val` +
  `val.Orientation()` across same-bone vertex runs), optionally batch through the
  existing `V3Quad` SoA path for 4-wide skinning. Narrower, animation-only.

Recommendation: (A) first — verify `Matrix4P` layout, adapt the SSE reference,
regression-test the 45 callers via the ports smoke tests, then re-profile.

## Phase 2 result + the measurement wall (2026-07-18)

Phase 2 shipped: SSE `Vector3P::SetFastTransform` (`Math3DP.cpp:310`, port
`patch-engine_Poseidon_Foundation_Math_Math3DP.cpp`, `PORTREVISION` 4, engine
commit `6169e0e`).

**Correctness proven, frame-delta NOT measurable on ser6.**
- Correct: bit-identical to scalar over 20M random cases + aliasing (per-component
  op order preserved; IEEE-commutative multiplies).
- Cheaper per call: shipped binary's `SetFastTransform` is **10 packed SSE ops,
  0 scalar** (was 9 mul + 9 add scalar) — confirmed by `objdump`. The compiler
  safely lowered the trailing `_position` load (`movsd`, no over-read).

**Why we could not measure a frame delta — the key finding:** on ser6
(Ryzen 7735HS + Radeon) the game runs **vsync-capped**: observed aFPS fixed at
**58**, iFPS 58–62, with `graphics.cfg vsync=1` (60 Hz). The frame finishes
early and waits for the display, so there is spare CPU headroom and **CPU
optimizations do not move FPS at all** — you are present/GPU-cap bound, not
CPU-bound, at these scenes. This also invalidates cross-run pmcstat comparisons:
each mission reload framed a different-density scene, and `gprof` lumps the
collision/AI graph into one recursive cycle, so self-time is not stable
across runs.

**Implications for measuring micro-opts (Phase 0, now mandatory):**
- pmcstat/`-g` remains valid for *finding* hotspots (unhalted cycles ignore the
  vsync idle), but **FPS on ser6 cannot show CPU-opt gains while vsync-capped.**
- To measure CPU-opt FPS deltas, either **(a) uncap vsync on ser6**
  (`graphics.cfg vsync=0`) so frame rate reflects CPU throughput, or **(b) measure
  on t420** (genuinely CPU-bound at ~20 FPS, below the cap — CPU wins move FPS
  directly there).
- Fixed-scene harness still required: a saved mission + parked camera reloaded
  identically, FPS as the acceptance metric, ideally with vsync off.

**Confirmed by per-thread CPU** (top -H on the live game at aFPS 58–62 on ser6):
the main `{PoseidonGame}` thread runs only **~45–51% of one core**, `gdrv0` ~5%,
~95% system idle. The main thread finishes in ~half the frame budget and waits
on present — ser6 is **present-bound at ~60-62 fps with ~2× CPU headroom**, not
CPU-bound. (Contrast t420: main thread ~88% of a core at 20 fps — genuinely
CPU-bound.)

Net: Phase 1 (validators, ~4%) and Phase 2 (SSE transform) are correct and
reduce CPU work; their value shows on CPU-bound targets (t420, or ser6 with
vsync/present uncapped or a scene dense enough to saturate the main thread), not
on present-capped ser6, where freeing main-thread cycles only widens the idle
gap.

**Confirmed by uncapping ser6** (`graphics.cfg vsync=0`, high preset-3 settings):
in-world FPS rose from the ~58-62 present cap to **66–76 fps**, and per-thread
CPU showed the main `{PoseidonGame}` thread jump to **~97% of one core** (gdrv0
~10%) — genuinely CPU-bound. So the measurement bench for CPU micro-opts on ser6
is: **vsync=0 + a fixed dense scene + main-thread saturated**, then FPS reflects
CPU throughput. (Note: `sed -i` on this host is GNU sed via linuxlator — use
`sed -i 's/…/'`, not the BSD `sed -i '' 's/…/'`; and the in-game **menu** has its
own ~62.5 fps limiter independent of vsync, so only in-world readings count.)

To quantify Phase 1+2 exactly: rebuild the pre-opt baseline (upstream tip
`8fc693b2`, no `patch-*` opts) and A/B it against `3.01_4` at this fixed
vsync-off scene. Deferred/optional.

## A/B result: baseline `_90` vs Phase 1+2 `_4` (2026-07-18) — INCONCLUSIVE

Built a baseline pkg `CWR-CE-3.01_90` (shipped tip + pre-existing perf patches,
but the 5 Phase 1+2 `patch-*` files removed) and A/B'd it against `_4` on both
hosts, vsync off, spawn-and-hold on the same unit-heavy mission:

| host (vsync off) | baseline `_90` | Phase 1+2 `_4` |
|------------------|----------------|----------------|
| ser6 (preset 3)  | 58–62.5 aFPS   | 60–70 aFPS     |
| t420 (preset 1)  | 14–15 aFPS     | 13–15 aFPS     |

**Verdict: below measurement noise.** ser6 hints ~+5–8% but the ranges overlap;
t420 is flat (the two hosts disagree). Expected signal ≈ 5% of CPU ≈ ~0.7 fps at
t420's 14 fps / ~3 fps at ser6's 65 — smaller than the scene fluctuation
(±1–2 fps t420, ±5 ser6). Cause: spawn-and-hold is not a fixed scene — AI units
move and the frame load diverges each run more than the win.

Unchanged and solid: Phase 1+2 are correct (bit-identical) and cut CPU work
(disassembly-proven). Their FPS effect is real but too small to resolve without
a **scripted static-camera scene + fixed unit count** (the true Phase 0). Lesson:
don't chase sub-5% micro-opt FPS deltas without that harness; use the pmcstat
hotspot table to justify them instead, and batch several before re-measuring.

Packaging note: `poudriere` keeps only the current PORTREVISION's pkg — building
`_90` deleted `_4`. To hold both, copy each out of
`.../packages/builder-default/All/` before building the other (or `pkg create`
from an install, but that is slow on the 258 MB RelWithDebInfo pkg).

## `--benchmark` A/B with ministat (2026-07-19) — NO significant difference

Built a working `--benchmark` (three POSIX/quality bug fixes on branch
`benchmark-posix-fix` — see `DEBUGGING.md`) plus a deterministic no-combat patrol
mission (122 all-WEST units, `CYCLE` loops, fixed seed) at
`Users/Test/Missions/Benchmark.Abel/`. `--benchmark` logs `BENCHMARK RESULT`
(1000 frames after a 4 s warm-up), runs full-speed even when unfocused, and is
`draw=0` (the AutoTest camera never attaches to the player — units simulate but
don't render, so it's a pure CPU-simulation benchmark; adequate for these CPU
opts, and arguably cleaner since no GPU variance).

3 runs each on ser6, baseline `_91` (no opts) vs Phase 1+2 `_5`, via `ministat`:

```
    N     Min    Max   Median    Avg    Stddev
x   3    74.1   78.2    76.0    76.10   2.05     baseline (_91)
+   3    68.7   83.2    77.2    76.37   7.29     Phase 1+2 (_5)
No difference proven at 95.0% confidence
```

**Verdict: no measurable FPS difference.** Means 76.1 vs 76.37 (+0.35%); the
optimized spread (68.7–83.2) swamps any signal. The +2.4% from single runs was
noise. Consistent with every other attempt this campaign: the opts remove
~2–4% of *CPU* work, but each measurement's noise is larger. Even a
deterministic scene has ~±10% wall-clock timing variance run-to-run (OS
scheduling, CPU boost/thermal). Resolving a ~2% signal against σ≈5 fps needs
~n=100 runs, or noise control (pin CPU frequency, isolate cores, a much longer
benchmark).

**Conclusion for the campaign: the opts are justified by the profile, not by an
FPS A/B.** Phase 1 removes `AssertValid`/`CheckVehicleStructure`
(2.82%+1.19% → 0 samples); Phase 2 is fewer instructions, bit-identical — real
CPU-work reductions whose FPS footprint is below the measurement floor on this
hardware. Do not gate sub-5% CPU micro-opts on an FPS A/B; use the pmcstat
profile as the acceptance evidence.

## pmcstat during `--benchmark`: deterministic profile A/B (2026-07-19)

With `--benchmark` fixed, ran pmcstat **gated to the measured window**: a harness
(`scratchpad/prof_bench.sh`) launches `--benchmark`, watches the log, starts
sampling at the first `BENCHMARK:` line (warm-up done) and stops at
`BENCHMARK RESULT`, so samples cover only the steady frames. This profiles an
identical deterministic scene on both machines, with far stronger statistics
(300k-820k samples/run vs ~2k for the old interactive profiling).

Method note: `pmcstat -G` percentages are per-arc, not global self-time (summing
them over-counts wildly); use gprof **self-sample counts**. gprof's flat `%`
column is also unreliable here because it lumps the AI/collision graph into one
recursion cycle, but the per-function self-sample counts are clean.

ser6 profile A/B (baseline `_91` vs Phase 1+2 `_5`, same scene):
- **Phase 1**: validators (`AIUnit::AssertValid` + `CheckVehicleStructure` +
  group/subgroup/center) = **~2.57%** of frame CPU in baseline, **0** in
  optimized. Clean deterministic confirmation Phase 1 removes ~2.5% CPU.
- **Phase 2**: `SetFastTransform` 2.8% (scalar) vs 3.0% (SSE) = **no reduction**.
  Likely load/latency-bound (48 B matrix + 12 B vector per call, few FLOPs), so
  vectorizing the arithmetic buys nothing. Phase 2 is correct but not worth it
  on its own.

FPS (`ministat`, 3 runs each):
- ser6 uncapped: baseline 76.1 vs opt 76.37 -> no difference at 95%.
- t420 CPU-bound: baseline 22.567 vs opt 22.567 (identical means, sigma 0.25)
  -> no difference at 95%.

**Surprising, important:** Phase 1 provably removes ~2.57% CPU, yet FPS does not
move even on the CPU-bound t420. The freed cycles land in slack: the benchmark
frame (draw=0) is bound by a per-frame cost off the validators' critical path
(terrain draw / present), not by the AI sim. So a real CPU-work reduction does
not translate to FPS on this workload.

Bottom line: judge these opts by the profile (Phase 1 = real ~2.5% CPU cut;
Phase 2 = no gain), never by FPS. `--benchmark` + the log-gated pmcstat harness
is the reproducible way to profile; it is focus-independent, unlike everything
else in this campaign.

## A/B on a deterministic bench (2026-07-18) — clean NULL result + why

Built a no-combat steady-state bench (`bench.Demo`): 106 all-WEST units
(90 infantry + 12 M1Abrams + 4 AH64), each group converted from a single `SAD`
waypoint to a local 100 m `MOVE`×4 + `CYCLE` patrol loop (script:
scratchpad/patch_bench.py), fixed `randomSeed`, player left as a motionless
observer. Steady-state, deterministic → readings are exact and repeatable.

| host (vsync off, bench) | baseline `_90` | Phase 1+2 `_4` | Δ |
|-------------------------|----------------|----------------|-----|
| ser6 (preset 3)         | 71.43          | 71.73          | +0.30 fps (+0.42%) |
| t420 (preset 1)         | 12.20          | 12.20          | 0.00 (0%) |

**Trustworthy null result — and it's expected.** Making the scene deterministic
required removing combat, but **combat is what drives the paths Phase 1
optimized**: `AssertValid`/`CheckVehicleStructure`/the AI validators run hard
during target eval + firing + the sensor matrix. With no enemy the AI is nearly
idle, so Phase 1 saves ~nothing here. Phase 2's SSE transform does run (106
animating units) but was only ~1.6% of frame → ~0.8% ceiling, matching the
+0.4% seen on ser6 / below t420's rounding.

**Lesson (important):** a no-combat deterministic bench measures *rendering/
animation* opts well but **under-measures AI/combat opts by construction**.
Phase 1's ~4% is real but only in a fight — and that's proven by the pmcstat
profile (validators 2.82%+1.19% → 0 samples), which is the correct evidence for
combat-bound opts. Do not use a no-combat FPS bench to judge them. For AI opts,
trust the in-combat profile; reserve the FPS bench for render/animation work.

Net for the campaign: both opts are correct and reduce CPU work; ship them on
the profile evidence. Their FPS payoff is small on ser6 (present-capped in
normal play anyway) and concentrated in heavy combat on CPU-bound hardware
(t420), where a clean FPS number is inherently hard to get.

## The `Object::Intersect` rigid-skip is a non-win (2026-07-19)

Scoped the "single-thread win worth doing regardless" flagged in the
CheckVisibility audit above (skip `Animate`/`Deanimate` for rigid obstacles in
the raycast path) as the next optimization. **Verdict: don't implement it — the
deformation it proposes skipping is already gated off for rigid obstacles by
existing code.** The audit did not trace into `AnimateComponentLevel`'s guard.

**The raycast path.** `Landscape::Visible → CheckVisibility → Object::Intersect`
reaches the line-intersection overload (`World/Scene/ObjectIntersect.cpp:744-928`),
which calls `AnimateComponentLevel(geomLevel)` (`:753`) before the intersection
math and `Deanimate(geomLevel)` (`:928`) after. `IsAnimated(geomLevel)` is even
already computed at `:744` for the rejection factor.

**Why the expensive work is already skipped for rigid obstacles.** The predicates
line up exactly, so `IsAnimated(level)==false ⟺ Animate(level) mutates nothing`:

- `AnimateComponentLevel(level)` (`World/Scene/Object.cpp:526`):
  ```cpp
  bool change = IsAnimated(level);
  Animate(level);
  if (change) _shape->InvalidateConvexComponents(level);
  ```
  For a rigid obstacle `change==false` → convex components are never invalidated.
- `Animate(level)` (`Object.cpp:316`): its only costly work is two `O(NPos)`
  vertex loops — the destruction morph (guarded `_isDestroyed && _destroyPhase>0
  && GetDestructType()!=DestructTree`) and the ClipLand surface-conform loop
  (guarded `GetOrHints() & (ClipLandKeep|ClipLandOn) && GLOB_LAND`). Those are the
  **same two conditions** `IsAnimated` (`Object.cpp:205-231`) returns true for
  (plus `GetTotalDammage()>0`, which alone triggers neither loop). So for a rigid,
  undamaged, non-ClipLand tree/wall/rock, both branches are dead and `Animate` is
  a no-op but for the guard checks.
- Downstream re-derivation is consequently free: `RecalculateNormalsAsNeeded()`
  is `if(!_faceNormalsValid) RecalculateNormals(true)` (`Graphics/.../Shape.hpp:436`)
  → no-op, normals were never invalidated; `cc->RecalculateAsNeeded()` (`:769`)
  → no-op, components were never invalidated.
- `Deanimate(level)` (`Object.cpp:471`) residual for a rigid object = one
  `VertexTable::RestoreMinMax()` = 4 vector copies + a bool (`Graphics/.../Vertex.cpp:318`).

**What a "skip if rigid" guard would actually remove per rigid raycast:** ~2
function calls, one `_shape->Level()` lookup, a few hint-mask reads, one redundant
`IsAnimated` re-eval inside `AnimateComponentLevel`, and 4 vector copies. Sub-noise
— on a campaign that already could not resolve a provable 2.5% CPU cut in FPS. The
`CheckVisibility` 6.79% is real intersection math (the plane-clip loop at `:802-863`,
`IntersectBBox`, the sensor matrix), not redundant animation.

**Not a parallelization prerequisite either.** The H1 shared-`LODShape` race
(audit above) exists only for *animated* objects — they mutate shared geometry.
Rigid objects mutate nothing (`Animate` is a no-op), so they are already
thread-safe. Skipping them changes nothing for a future job system; the real H1
fix is thread-local scratch geometry for the *animated* case, unaffected by this.

**Implication for what to profile next.** The campaign's sharpest earlier finding
(this doc, "pmcstat during --benchmark"): Phase 1 provably removed ~2.57% CPU yet
FPS did not move even on CPU-bound t420, because the `draw=0` frame is bound by a
per-frame cost *off* the AI/collision critical path (terrain draw / present). Taken
with this finding, the top of the pmcstat table (`CheckVisibility` and the collision
cluster) is not what gates the frame, and it holds no cheap redundant work to remove.
Next lever is therefore **not** another off-critical-path CPU micro-opt but to
identify what actually bounds the frame: profile the terrain-draw / present path
under `--benchmark`, and measure the render-submit path the `draw=0` bench excludes
yet which still gates the frame.

## Full-frame breakdown: what actually gates the frame (2026-07-19)

Profiled the whole frame under `--benchmark` with **nothing filtered** (Mesa,
`amdgpu.ko`, kernel kept — for this question the driver frames *are* the present
path, unlike earlier profiles that treated them as noise). ser6, vsync=0
(genuinely CPU-bound: **~70 iFPS steady**, main thread saturated), the 122-unit
no-combat Benchmark.Abel scene, `ls_not_halted_cyc`, 816k samples over a
log-gated 12 s window.

### Harness (the invocation that actually works)

The plain `--benchmark` auto-load is **broken in the shipped `_5` binary**: it
sits at the menu forever (the benchmark branch never boots the mission), and
`--no-splash` does **not** fix it. The reliable trigger is the explicit
`--test-mission` path, which sets `AutoTest` + logs `Test mission: … -> …`:

```
# vsync=0 in ~/.config/CWR/graphics.cfg first (CPU-bound bench)
PoseidonGame -C ~/.local/share/CWR/base \
  --benchmark --test-mission ~/.config/CWR/Users/Test/Missions/Benchmark.Abel \
  --no-splash --no-sound --log-file bench.log --timeout 120 &
# wait for the first "BENCHMARK:" line (4 s warm-up done, steady state), then:
sudo pmcstat -S ls_not_halted_cyc -O bench.pmc sleep 12
```

`draw={}` in the `BENCHMARK:` line = `tp.drawMeshCalls` (a terrain-mesh counter),
**not** objects — objects *are* drawn (shadow + object passes). The old "draw=0
⇒ nothing rendered" reading was wrong.

### Subsystem breakdown (816k samples, unfiltered)

| share | bucket | representative symbols |
|------:|--------|------------------------|
| **~25%** | Mesa/GPU submit + present | `libgallium-26.1.4.so` (mostly unsymbolized `0x…`), `amdgpu_device_rreg` |
| **~15%** | **animation skinning, inside the draw path** | `AnimationRT::ApplyMatricesComplex` 7.1%, `Vector3P::SetFastTransform` 2.5%, `Object::RecalcShadow`, `Matrix4P::SetMultiply` |
| ~23% | other engine (misc draw/sim) | not yet drilled |
| **~11%** | terrain-collision queries | `Landscape::CheckIntersection` 3.4%, `IntersectWithGround` 2.8%, `GroundCollision`, `RoadSurfaceY`, `ObjectCollision` |
| ~10% | kernel | `AcpiOsReadPort` (timekeeping), `lock_delay`, `zfs_lz4_compress` |
| ~8% | terrain/mesh draw-prep | `VertexBufferGL33::CopyVertices`, `PrepareTexture`, `ScanMinMax` |
| ~5% | libc/malloc | `memcpy`, `memset`, mimalloc |
| ~2% | draw-order sort | `QSort<Ref<SortObject>>`, `CmpSurfaceObj` |

### Findings

1. **There is no single "terrain-draw wall." The frame is split** across GPU
   submit (~25%), animation (~15%), terrain-collision (~11%), mesh-prep (~8%).
   This *explains* the earlier "freed AI cycles land in slack" result: **~25%
   of the frame sits in the Mesa driver on the main thread** (draw-call
   submission + present), which no AI/collision micro-opt can touch. The "bound
   by terrain draw / present" hypothesis was directionally right but conflated
   two separate costs (driver-submit vs terrain compute).

2. **`Landscape::CheckVisibility` — the post-Phase-1 #1 (6.79%) — is essentially
   absent here.** It is combat-specific (sensor visibility matrix + firing LOS),
   and this bench has no combat. Confirms the standing caveat: the no-combat
   bench under-measures combat AI. It cleanly exposes the render/animation/terrain
   baseline that combat *sits on top of* — so both profiles are needed, not one.

3. **The #1 engine-optimizable cost is animation skinning during draw, not
   terrain draw.** `ApplyMatricesComplex` splits roughly evenly between the
   view-draw pass (`DrawObjectsAndShadowsPass1`, opaque draw at `drawLOD`,
   ~1520 samples) and the shadow work invoked from `Pass2` (~1570) — each unit
   is skinned ~twice per frame. **But the two skins are at DIFFERENT LODs, so
   they are not naively redundant** — see the correction below. Still ~15% of
   frame and the top engine lever.

4. **`SetFastTransform` is 2.5% here** — directly contradicting the Phase-2
   verdict ("SSE buys nothing"), which was measured on the *combat* profile where
   skinning was a smaller share. In an animation-heavy scene the transform is a
   real cost. (It is called from `ApplyMatricesComplex`, so hoisting redundant
   per-bone work in the caller beats micro-opting the primitive.)

5. **~50 terrain segments are drawn per frame** (`seg≈3500` at ~70 fps), each
   likely its own draw call — a large part of the ~25% Mesa submit bucket.
   **Batching terrain segments into fewer draw calls** is the lever for the
   driver cost, but it is a render-architecture change, not a micro-opt.

### Next levers (ranked by ROI)

1. **Skin-once across the view + shadow skins** (~half of `ApplyMatricesComplex`
   7%). **VERIFIED PARTIAL — see correction below.** The shadow skins a distinct
   coarser `shadowLOD`, so the view skin cannot simply be reused; the win is
   conditional (near units where `shadowLOD == drawLOD`) and smaller than a
   blanket 2× would suggest.
2. **Terrain draw-call batching** — ~~attacks the ~25% Mesa submit bucket; largest
   potential but a rendering-architecture change.~~ **KILLED — nothing to batch;
   see the "Levers investigated and killed" table below (~20-28 draws/frame,
   falsified by `--render-frame-log`). Re-confirmed 2026-07-20: live counter
   `render frame: passes=2 draws=28`.**
3. **Terrain-collision caching** — units re-query ground height/collision every
   frame (`RoadSurfaceY`/`SurfaceY`/`GroundCollision`, ~11%); cache per-unit
   per-frame where the position is unchanged.

Data: `perf-data/pmc-fullframe-benchmark-3.01_5.*` (archived). Note the
`_5` binary carries terrain instrumentation ahead of the source HEAD
(`ground`/`genSeg`/`frame` Mc + `draw`/`clip` counters in the `BENCHMARK:` line);
that source is not in the current checkout.

### Correction: the shadow skin is a distinct LOD, not a reusable duplicate (2026-07-19)

Verified the "skin-once across passes" lever against the code. It is **weaker
than first stated** — the two per-unit skins are at different LODs:

- `SortObject` carries separate `drawLOD` and `shadowLOD` (`SceneDraw.cpp:667,
  1140`), selected by different logic (`shadowLOD` via
  `FindShadowLevelWithComplexity`, `:1016`).
- `Object::Draw(drawLOD)` unconditionally `Animate(drawLOD)`s the view LOD
  (`Object.cpp:857`) — skin #1, in `Pass1`.
- The shadow work runs inside `Pass2`. With shadow-maps **off (the default,
  `SceneDraw.cpp:1703`)** the projected path loops all casters and calls
  `DrawExShadow` (`:1738-1746`) → `level = oi->shadowLOD` (`:1900`) →
  `Object::PrepareShadow(shadowLOD)` → `Animate(shadowLOD)` + `RecalcShadow`
  (`Shadow.cpp:551-554`; `RecalcShadow` is the 0.94% profile symbol) — skin #2,
  at the **coarser shadow LOD**.
- The newer shadow-map path (`SceneShadowPass.cpp:285-304`,
  `RenderShadowMapDepthPass`, off by default) is already the optimized version:
  it re-selects an even coarser caster LOD (`casterLodBias`, "never finer than
  the draw LOD") and caches static casters (`s_staticCasterCache`).

**Consequence.** You cannot reuse the view-LOD skinned mesh for the shadow — the
shadow deliberately wants a coarser mesh. The "skin once" win is therefore
conditional (only near units where `shadowLOD` happens to equal `drawLOD`), not
a blanket ~3.5%. Two better-shaped shadow levers instead:

### Prototype: coarser-shadowLOD bias (2026-07-19) — INCONCLUSIVE / no clear win

Prototyped the "bias `shadowLOD` coarser" lever: at the projected-shadow
`shadowLOD` selection (`SceneDraw.cpp:~1213`, `Scene::AdjustComplexity`),
multiply the shadow complexity target by `shadowLodBias = 0.25` so
`FindShadowLevelWithComplexity` picks a coarser level. Shipped as port patch
`patch-engine_Poseidon_World_Scene_SceneDraw.cpp`, built RelWithDebInfo/unstripped
via poudriere as `CWR-CE-3.01_6`, profiled with the same vsync=0 `--benchmark
--test-mission` + log-gated pmcstat harness.

Self-time, `_5` baseline (bench4) vs `_6` bias (bench6):

| function | `_5` | `_6` |
|----------|-----:|-----:|
| `ApplyMatricesComplex` | 7.16% | 6.32% |
| `ApplyMatricesSimple` | 0.82% | 0.69% |
| `RecalcShadow` | 0.94% | **0.95%** |
| `CheckIntersection` (terrain, control) | 3.43% | 3.26% |
| `IntersectWithGround` (terrain, control) | 2.78% | 2.71% |

**Verdict: not a demonstrated win.** Two reasons the ~0.84 pp `ApplyMatricesComplex`
drop cannot be banked:
1. **Confounded by scene variance.** bench6 frames were ~28% heavier (1207 vs
   945 pmc samples/frame; steady iFPS ~66 vs ~72) — the no-combat patrol is not
   a static scene, so unit positions (hence visible density and the %
   denominator) differ run-to-run by more than the effect. Single before/after
   pair can't resolve <1 pp against that.
2. **`RecalcShadow` is flat.** It is a pure shadow-path cost that scales with
   shadow-LOD vertex count; if the bias had actually coarsened shadow meshes it
   would have dropped too. Flat `RecalcShadow` suggests the casters' shadow LOD
   did *not* meaningfully coarsen — likely the soldier models have no coarser
   shadow LOD to drop to (few LODs), or these casters get `shadowLOD` via a path
   other than the patched general-loop site (e.g. the `level==0` pre-pass at
   `:1159` or a `forceDrawLOD` case). FPS did not improve.

**Before tuning the bias further, verify the mechanism takes effect** — instrument
the runtime `shadowLOD` histogram (log per-LOD caster counts) with bias 1.0 vs
0.25. If the distribution doesn't shift, the lever is dead for this content and
the effort belongs on the frozen-caster `ShadowCache` extension instead. Guessing
bias values against a ~10%-noise FPS/scene floor repeats the campaign's
measurement-wall mistake. Data: `perf-data/pmc-shadowlodbias-3.01_6.*`.

### Histogram verification (2026-07-19) — lever confirmed DEAD; two bugs found

Built an instrumented `_8` that logs the runtime shadow-LOD histogram (unbiased
vs biased level per caster). Two findings, one procedural, one substantive:

**Bug 1 — the `_6` bias was dead code.** `SceneDraw.cpp` has *two*
`Scene::AdjustComplexity()` bodies: `#if !DENSITY_LOD` (line ~778, the ACTIVE
build) and `#else` (line ~1024). The `_6`/`_7` edits went in the `#else`
(`DENSITY_LOD`) copy, which is not compiled — so the bias never ran and the `_6`
"prototype" measured a binary identical to `_5` (the bench6 null result was
100% scene noise). The instrumentation string being absent from the binary is
what exposed this. The active shadow-LOD selection is a *separate* function,
`Scene::AdjustShadowComplexity` (line 638), and it picks the LOD by **distance**
(`LevelShadowFromDistance2`), not by the complexity budget. The corrected bias
multiplies `distance2` (like the shadow-map path's `casterLodBias`).

**Bug 2 — even correctly applied, the lever is negligible.** Instrumented run,
300000 caster evaluations over 1000 frames (`shadowLodDistBias = 2.0`, i.e.
distance²×4):

```
n=300000 shifted=705 same=10558 invis=288737 oneLevel=0
baseHist=[2510,0,617,88,4735,3313,0,0]   (LOD 0..7)
biasHist=[2510,0,  0, 0,5440,3313,0,0]
```

- **96.2% of evaluations are non-casters** (`invis`): only ~11 objects/frame cast
  a shadow at all. The shadow-caster population is small.
- **The bias shifts only 705 casters** (~0.7/frame, LOD2+LOD3 → LOD4); 94% are
  unchanged.
- **It misses the expensive casters:** the near, high-detail **LOD0 casters
  (2510) do not move** — distance²×4 still resolves LOD0 — and the far LOD5
  (3313) are already coarsest. Only cheap mid-distance casters coarsen. Since
  shadow-skin vertex cost is dominated by the few near LOD0 casters, coarsening
  the cheap far ones saves almost nothing.
- `oneLevel=0`: models *have* multiple LODs, so it is not a missing-LOD problem —
  the distance-bias simply can't touch the near casters without a much larger
  bias that would visibly degrade near-unit shadows.

**Conclusion: abandon the shadow-LOD-bias lever.** It is not where the skinning
cost is. This also corrects the earlier "shadow skinning ≈ half of
`ApplyMatricesComplex`" estimate (which came from the flawed Pass1/Pass2 arc
split): with only ~11 shadow casters/frame vs ~122 view-drawn units,
`ApplyMatricesComplex` is dominated by **view** skinning, not shadow. The real
skinning lever, if any, is the view path (hoisting redundant per-bone work in
`ApplyMatricesSimple`/`Complex`, or SoA batching), not shadows. Data:
`perf-data/pmc-shadowlodbias-3.01_6.*` (dead-code `_6`) and the `_8` bench log.

## View-skinning bone-run structure (2026-07-19) — instrumented

Instrumented `ApplyMatricesComplex` (`RtAnimation.cpp:863`, the 7% hotspot) in an
`_9` build to measure the per-vertex bone structure and test the doc's
"re-extract `val.Orientation()` per vertex" redundancy hypothesis. Benchmark run,
190000 calls / 58.1M vertices:

```
verts=58.1M bonePairs=63.7M ws=[0, 53.1M, 4.44M, 544k, 6.6k, 0,0,0]
single=53.1M singleRunSame=40.3M multi=5.0M paletteMax=25
```

- **91.4% of vertices are single-bone** (`wsize==1`), 7.6% two-bone, ~1% three+.
  Avg 1.095 bones/vertex. The shapes go through `ApplyMatricesComplex` (not the
  cheaper `Simple`) only because ~8% of verts are multi-bone, which flips
  `weights.IsSimple()` false for the whole shape.
- **75.9% of single-bone vertices repeat the previous vertex's bone**
  (`singleRunSame`) — long same-bone runs exist.
- **Bone palette is tiny: 25 matrices**, vs 63.7M bone-pairs processed.

**The doc's hypothesis is WRONG — no orientation redundancy to remove.**
`Matrix4P::Orientation()` (`Math3DP.hpp:480`) is `__forceinline const Matrix3P&
Orientation() const { return _orientation; }` — it returns a **const reference**
to a stored member, zero cost. There is no per-vertex extraction to hoist, and no
"orientation palette" to precompute (the orientation already lives in the matrix).
Likewise `Matrix4Val mat = matrices[sel]` is a cheap indexed copy of a
cache-resident 64-byte matrix, not a recompute. The per-vertex `SetMultiply`
(matrix×vector) transforms are **genuine irreducible arithmetic** — each vertex
must be transformed.

**The one real (modest) lever the data exposes:** 91.4% of vertices are
single-bone yet run through the multi-bone blend machinery — the `wsize>0` branch
builds `res`/`resNorm`, applies `res *= pww` / `resNorm *= pww` (the weight, which
for a single-bone vertex is effectively 1.0 — `ApplyMatricesSimple` ignores it
entirely at `:977`), and sets up a `for w=1..wsize` loop that never iterates.
A `wsize==1` fast path (direct `SetPos = mat*pos; SetNorm = mat.Orientation()*norm`,
as `Simple` does) skips ~2 wasted vector×scalar multiplies + the blend scaffolding
for 92% of 58M verts/run. Estimated ceiling ~1-1.5% of frame (a slice of the 7%),
low-risk. The larger structural play is **SIMD over same-bone runs** (76% of
single-bone verts share the prior bone → transform 4 verts × 1 matrix with the
existing `V3Quad` SoA path), but that is a real refactor, not a micro-opt.

**Verdict:** view skinning is mostly irreducible transform arithmetic; the only
clean micro-lever is the single-bone fast path (~1%), and the original
Orientation-redundancy premise does not hold. Data:
`perf-data/viewskin-boneruns-3.01_9.txt`.

## Terrain draw-call batching (2026-07-19) — DEAD LEVER (nothing to batch)

Tested the "~25% Mesa = terrain draw-call submission, batch the segments" premise
without any rebuild, using the existing `--render-frame-log` flag
(`WorldFrameObserver.cpp:196`, logs `passes/draws/maxDrawsInPass` every ~60 frames):

```
render frame: passes=2 draws=31 maxDrawsInPass=29
render frame: passes=2 draws=12 maxDrawsInPass=10
```

**The whole frame issues ~12-31 draw calls, not hundreds.** A frame is only
draw-call-bound in the thousands; coarse OFP-era terrain draws in a handful of
large HWTL segments (`Landscape::DrawGround → shape->Draw`, `LandscapeRender.cpp:1341`),
not per-tile. There is nothing to batch.

This also **falsifies the "~25% Mesa = draw submission" assumption** (from the
full-frame breakdown above): you cannot spend 25% of a 14 ms frame submitting ~20
draws. The `libgallium`/`amdgpu` cost is almost certainly **dynamic vertex
streaming** — the CPU-transform pipeline (software skinning `ApplyMatrices*`,
software terrain transform `DoTransformPoints`) regenerates geometry every frame
and re-uploads it to GL buffers. That is per-vertex upload cost, not per-draw, and
it is **architectural** (the fix is GPU-side transform: vertex-shader skinning +
GPU terrain — a rewrite, not a tweak).

**Measurement caveat:** the AutoTest benchmark camera under-renders (the software
`DrawMesh` path is unused — `draw=0` in every `BENCHMARK:` line — and only ~20
draws issue). It is a clean CPU-*simulation* bench but a poor *rendering* bench.
To characterize the render/Mesa cost properly, profile **real gameplay with the
player camera** driven into a terrain vista, not `--benchmark`. That render
profile is the one gap this campaign never closed.

## Levers investigated and killed (instrument-first summary)

Each candidate was falsified by a cheap measurement (code read, histogram, or an
existing counter) **before** a real implementation was spent on it:

| lever | verdict | falsified by |
|-------|---------|--------------|
| `Object::Intersect` rigid-skip | already done by the existing `IsAnimated` guard | code read |
| shadow-LOD bias | negligible — near LOD0 casters (the skin-cost-dominant ones) don't shift | runtime histogram (`_8`) |
| orientation-precompute in `ApplyMatricesComplex` | non-lever — `Matrix4P::Orientation()` is a free `const&` | code read |
| terrain draw-call batching | nothing to batch (~20 draws/frame) | `--render-frame-log` |
| single-bone skinning fast path | real but ~1%, off critical path (present-bound), determinism-sensitive | view-skin histogram (`_9`) |

**Campaign bottom line.** On ser6 + this workload the `--benchmark` frame is bound
by present/GPU-driver work (dynamic vertex upload, ~25%) and irreducible per-object
CPU math — no single cheaply-removable hotspot remains. The only levers that would
move it are large: (1) GPU-side transform (vertex-shader skinning + GPU terrain) to
kill the dynamic-upload cost, and (2) render-thread decoupling (deferred Phase 4).
Everything smaller has been measured off the critical path. Instrument first: this
loop killed four plausible levers for the cost of profiling, not implementation.

**The recommended next move** is GPU skinning — the one change that hits *both*
big buckets (the ~7% CPU view-skinning and a large share of the ~25% Mesa
dynamic-upload). Implementation scope, with the GL33 vertex-format / bone-palette /
shader plumbing mapped out, is in `PERF-gpu-skinning-scope.md`.

Two better-shaped shadow levers instead:
- **Extend the frozen-caster `ShadowCache` (`Shadow.cpp:568`) to animated units.**
  Today only static/frozen casters hit the cache; every soldier re-skins its
  shadow LOD each frame. A soldier whose pose changed little between frames could
  reuse its prior shadow silhouette.
- **Bias the projected-path `shadowLOD` coarser** (as the shadow-map path already
  does via `casterLodBias`) so the shadow skin is over fewer vertices — the
  cheapest change, at some shadow-silhouette fidelity cost.
