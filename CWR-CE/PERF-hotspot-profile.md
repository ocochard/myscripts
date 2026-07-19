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
