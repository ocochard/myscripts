# Multithreading the main loop — scope (CWR-CE / Poseidon)

The single-threaded main loop is the last real FPS ceiling once vsync is uncapped.
This scopes how to spread it across ser6's idle cores. It supersedes the Phase 4/5
sketches in `PERF-hotspot-profile.md:180-203` with today's measured framing.

**Read first (do not re-derive):**
- `PERF-hotspot-profile.md:72` — the whole render path runs *under* `World::Simulate`
  on one thread (`Simulate -> RenderFrame -> AppIdle -> RunMainLoop`).
- `PERF-hotspot-profile.md:113-122, 180-203` — Phase 4 (pipeline) + Phase 5 (job
  parallelism) sketches; `:200` determinism gate.
- `PERF-low-fps-cpu-bound.md:48-58` — main thread pegs one core; GPU/other cores idle.
- `PERF-gpu-frametime-scope.md` — **the reframe:** ser6 at vsync=1 is *present-bound*
  (GPU + CPU both finish in ~half the 16.6 ms budget). Multithreading moves FPS
  ONLY where the main thread is the bound.

## Goal (2026-07-20, clarified)

Improve FPS on the **t420 (i5-2520M, 2c/4t, 2011) too**, and more broadly: add
modern optimization techniques that **reduce CPU *and* GPU load** so the game runs
better on *any* machine, old or modern. The load reduction is the portable win;
whether it shows as FPS depends on each machine's bound.

**Key correction from this session:** all measurement so far was on ser6, which is
**present/vsync-bound** — so CPU/GPU-load cuts vanish into slack and FPS doesn't
move. The **t420 is genuinely CPU-bound** (`PERF-low-fps-cpu-bound.md:48-58`, main
thread ~90% of one core at ~20 fps), so the *same* load cuts should translate to
FPS there. In particular **GPU skinning (~7-15% CPU removed) is likely a real t420
FPS win that ser6 could not show** — untested only because the **t420 is powered
off (~1 week)**. Re-run `prof_bench.sh` + `--gpu-timing` on the t420 when it's back
to confirm, and to pick the next technique from *its* bottleneck (CPU-T&L vs
GPU-fill vs submit) rather than ser6's.

## When this actually helps (set expectations)

| config | bound | MT payoff |
|---|---|---|
| ser6, vsync=1 (60) | present/vblank wait | **none** — frame already idle-waits |
| ser6, vsync=0 (~80) | main-thread CPU (~12.5 ms) | **yes** — the headroom lever |
| t420, CPU-bound (~20) | main-thread CPU (2c/4t) | **yes** — the FPS target |

MT spreads the single-threaded main loop across cores: modest on the t420's 4
threads, larger on ser6's 16 — but it moves FPS only where the main thread is the
bound (t420, or uncapped ser6), not the capped-60 default. Because the t420 is
offline, near-term MT work is validated by **correctness** (determinism gate) +
**work actually spreading off the main thread** (`pmcstat`/`ps -H` on ser6), with
the FPS confirmation deferred to the t420.

## What is already parallel

`TaskPool` (enkiTS wrapper, `Core/TaskPool.cpp`, 8 worker threads) with
`ParallelFor(count, [](begin,end){...})` exists and is used for **terrain segment
generation** (`Landscape.cpp:1249`). **Phase 5 needs no new infrastructure** —
just more `ParallelFor` call sites with a disciplined read/write split.

## The hard constraint: MP determinism

The *simulation* (AI decisions, collision, positions) must stay **bit-identical**
regardless of thread count/order, or MP sync and replays desync. This splits the
work sharply:
- **Render-side per-object work** (visibility, occlusion, skinning, draw-prep) does
  NOT feed MP sync -> parallelize freely; only intra-frame races matter.
- **Sim-side work** (AI targeting, collision resolution) is determinism-critical ->
  parallelize last, behind a determinism gate (identical results 1- vs N-thread).

## Two approaches

### A. Data parallelism (Phase 5) — RECOMMENDED FIRST, infra already exists

Parallelize the per-object loops that are read-mostly and off the sim-determinism
path, with a **read/compute phase then a serial apply/draw phase**:
- Top targets (self-time after Phase 1, all per-object, all render-side):
  `Landscape::CheckVisibility` (6.79%), `Object::OcclusionView` (2%),
  `PredictCollision` (2.5%). Skinning (`ApplyMatrices*`, ~15%) is better *removed*
  than parallelized — that is the GPU-skinning work, already done.
- Pattern: `ParallelFor(nObjects, ...)` computes each object's visibility/occlusion
  /LOD selection into per-object scratch (no shared writes); then the existing
  serial loop consumes the scratch and submits draws in order.
- Risk: **medium** — intra-frame races only (no MP determinism impact for the
  render-side set); incremental (one loop at a time), each independently measurable.
- Payoff: directly attacks the top remaining CPU self-time on the many-core box.

### B. Pipeline (Phase 4) — overlap simulate(N) with render-submit(N-1)

- ~2x if the two halves balance, but the **barrier is real**: `Object::Draw`
  mutates the entity during draw — `Animate(level)` writes the shape's skinned
  positions, draws, then `Deanimate(level)` restores (`Object.cpp:433-451`). So
  render(N-1) and sim(N) cannot share the live world.
- Requires a **double-buffered render snapshot**: sim writes the live world; a
  stable per-frame copy (transforms + which LOD + light state, NOT the whole
  entity graph) feeds the render thread. Defining that minimal snapshot in an
  engine that mutates entities mid-draw is the whole cost.
- GPU skinning **helps here**: with the view LOD skinned on the GPU, `Object::Draw`
  no longer needs to `Animate`/`Deanimate` the drawn mesh (item 5b already removes
  that), shrinking the mutate-during-draw surface the snapshot must cover.
- Risk: **high** — snapshot boundary; a one-frame render lag; must not change sim
  results. Do after A proves the parallel infra on the render loops.

## Recommended plan

1. **Determinism gate first** — a repeatable check that a fixed scene produces
   identical sim state single- vs multi-threaded (checksum of positions/RNG each
   tick). Without it, nothing sim-side is safe to touch. (Reuse the `--benchmark`
   deterministic mission.)
2. **Parallelize `CheckVisibility` / `OcclusionView`** via `ParallelFor` with a
   read/apply split (render-side, no MP impact). Measure uncapped FPS + per-thread
   CPU (`ps -H`). This is the lowest-risk real win and proves the pattern.
3. **Then the sim-side loops** (collision queries) behind the determinism gate.
4. **Pipeline (B)** only if data parallelism plateaus and the snapshot surface is
   small enough (post-GPU-skinning) to be worth the risk.

## Gate validation (2026-07-20)

Built `--determinism-log` (World.cpp): each `Simulate()` tick logs an
order-independent XOR of per-entity FNV-1a over `ID()` + the 12 affine floats of
`WorldTransform()` (= authoritative `Transform()`), across `_vehicles` +
`_fastVehicles`. Validated by diffing two `--benchmark` runs of the 122-unit
patrol mission:

| gate state | runs identical through | remaining source |
|---|---|---|
| raw | tick **4** | variable timestep |
| + fixed dt (0.02 s) | tick **~897** | wall-clock RNG seed |
| + fixed `GRandGen` seed | tick **~872** | a wall-clock-*timed* event |

- **Fixed dt** (`World::Simulate` forces 0.02 s under the flag) killed the
  timestep jitter — the dominant early divergence.
- **Fixed seed** (`WorldInit.cpp` seeds `GRandGen` from a constant, not
  `GlobalTickCount()+time()`) removed the RNG-stream difference.
- **Residual:** still diverges at ~tick 872-898, at a *variable* tick across run
  pairs, while every tick before it is **bit-identical**. That signature = a
  discrete event triggered off **wall-clock/real time** (fires at the same real
  second but a different tick number, since the benchmark's fps varies), mutating
  a checksummed entity. Candidate: a periodic weather/effect or AI timer keyed to
  `GlobalTickCount()` rather than sim `deltaT`. Route it through sim time for a
  fully clean gate.

**Usable now.** ~870 ticks (~14 s of sim) of bit-exact reproducibility is far more
than enough to catch a parallelization determinism break — a race in
`CheckVisibility`/`OcclusionView` would diverge in the *first* ticks, not at 870.
So step 2 can proceed against this baseline; closing the residual (one more
real-time -> sim-time fix) makes the gate airtight but is not a blocker.

## Step 2 result (2026-07-21) — `--mt-lod` implemented + verified correct

Parallelized `Scene::AdjustComplexity` (per-object draw-LOD/`passNum` selection)
across the task pool via `ParallelFor`, with an order-independent atomic
complexity reduction. Because ser6 gives no FPS signal (present-bound) and can't
surface visual artifacts, `--mt-lod` also runs a serial reference each call and
logs `MT-LOD verify FAILED` on any per-object or total mismatch.

**Validated on ser6:** `--benchmark --mt-lod`, ~960 frames, **0 verify failures**,
clean shutdown, 8-thread pool active. So the parallel result is byte-identical to
serial — the callees (`LevelFromDistance2`, `PassNum`, `GetComplexity`) are
thread-safe reads, and the read/apply pattern is proven. Off by default.

- **What this establishes:** the reusable, determinism-safe parallel-for pattern
  (disjoint per-object writes + atomic reduction + runtime serial verify) for the
  remaining per-object loops. `AdjustComplexity` itself is a modest cost; the same
  template applies to the heavier per-object work (animation prep, collision).
- **FPS payoff: pending the t420.** ser6 (present-bound) cannot show it; measure
  `prof_bench.sh` with/without `--mt-lod` on the CPU-bound t420 when it is back.
  Drop the serial-verify (make it a separate flag) before the perf run — with
  verify on, `--mt-lod` does 2x the LOD work by design.

## Findings: what is (and isn't) a clean parallel-for (2026-07-21)

Investigated the heavy per-object loops. They split into two classes:

**Cleanly parallelizable — render-side ANALYSIS loops** (iterate a flat draw list,
write only that object's `SortObject` slot, plus an integer reduction). These take
the pattern directly (`ParallelFor` + atomic reduction + serial verify), and are
NOT determinism-critical (render-only), so the runtime verify is the whole gate:
- `Scene::AdjustComplexity` — draw-LOD selection. **DONE** (`--mt-lod`, verified).
- `Scene::AdjustShadowComplexity` — shadow-LOD selection. **DONE** (below).
- Occlusion/visibility culling passes — same shape, candidates.

**NOT clean loops — heavy sim work embedded in the serial per-entity `Simulate`
/ `Draw`.** These are the docs' Phase-4/5 barrier, not template drop-ins:
- **Animation-prep** (`Man::Animate` → `ApplyMatrices`) writes the **shared**
  `LODShape::SetPos` (instances share one shape) — parallel `Animate` would corrupt
  it. `Object::Draw` does `Animate → draw → Deanimate` inline. **GPU skinning lifts
  the barrier** (item 5b skips the shared-shape write, keeps a per-object palette),
  but it still needs `Animate` hoisted out of `Object::Draw` into a parallel
  pre-pass — a real draw-loop refactor.
- **Collision** (`Landscape::ObjectCollision`) is a read-only per-*entity* query,
  but called ad-hoc **inside each entity's serial `Simulate`**, with its result
  feeding that entity's immediate movement/response. No hoistable "detect-all"
  loop; parallelizing needs a detect(parallel)/respond(serial) split — and it is
  **sim-side**, so it must be validated by the **determinism gate**, not a serial
  verify. Higher risk; do behind the gate, and (per the docs) caching per-object
  ground queries may beat parallelizing them.

**Takeaway:** the pattern extends freely across the render-side analysis loops
(cheap, safe, verifiable now). The big CPU wins (animation, collision) require the
determinism-gated draw-loop / sim restructure — the Phase-4/5 lift — and are
unmeasurable until the t420. GPU skinning is the key enabler for the animation one.

## CPU-load measurement (2026-07-21) — pattern distributes, but LOD is too fine-grained

Can't measure FPS on ser6 (present-bound), but CPU-load distribution IS measurable
here. Split `--mt-verify` out of `--mt-lod` so a plain `--mt-lod` run measures true
parallel load, then pmcstat (`ls_not_halted_cyc`) on the 197-unit scene, serial vs
`--mt-lod`, ~10 s each:

- **Distribution PROVEN.** The `--mt-lod` call graph shows the LOD work on the
  **enkiTS task threads** — `Poseidon::(anon)::RangeTask::ExecuteRange(enki::
  TaskSetPartition)` ← `TaskPool::ParallelFor`. That symbol is absent in the serial
  run. The pattern genuinely spreads per-object work across cores.
- **But load impact is NEGATIVE for these loops.** Total samples: serial **427k**
  vs `--mt-lod` **473k** (**~+11% CPU**), and the main thread now shows
  `enki::TaskScheduler::WaitforTask` — it dispatches the tiny LOD work then blocks
  on it. No main-thread reduction.
- **Why:** LOD selection over ~122 objects is ~microseconds; the enkiTS dispatch +
  `WaitforTask` + task-thread spin overhead exceeds the work saved. Classic
  too-fine-grained parallelism.

**Rule this establishes (for the next person):** the parallel-for pattern is
correct and distributes, but **only parallelize loops where per-object work ≫ the
~µs dispatch cost.** The cheap analysis loops (LOD, shadow-LOD) fail that test —
`--mt-lod` proves the machinery but is net-negative and **should stay off**. Go
straight for the **heavy** per-object work (animation ~15%, collision ~11%), which
clears the bar — but those are the loops behind the determinism-gated Phase-4/5
restructure. So: no more parallelizing analysis loops; the next real step is the
restructure, measured on the t420.

## Determinism residual hunt (2026-07-21) — a rare Heisenbug; gate is usable-but-not-airtight

Hunted the tick-~873 divergence the gate surfaced. Findings:

- **It's intermittent and rare** — ~1-2 of 10 runs diverge (at ~tick 873); the rest
  reproduce **bit-exact for 1000+ ticks**. A deterministic-sim event would diverge
  every run at the same tick; this doesn't, so it's a **race / nondeterministic
  input**, not a missed constant.
- **Ruled out** (each verified): variable timestep (fixed 0.02), the `GRandGen`
  wall-clock seed (fixed), other RNG instances (none — all use `GRandGen`),
  wall-clock reads in AI/entities (none), stateful `GRandGen` on task threads
  (terrain/clutter use the position-seeded *stateless* variant; `RandomValue()`
  does `_seed++`, not thread-safe, but nothing off-main-thread calls it), audio
  (`DynSound::Simulate` is main-thread), and **parallel terrain-segment generation**
  (forcing it serial did NOT fix it — so it's not that thread, and not the only
  frame-level parallelism after all).
- **It's a Heisenbug.** Adding per-entity hash logging (to pinpoint the culprit
  entity) **suppressed it — 0 of 35 runs diverged** vs 1-2/10 without. So the
  observation perturbs the timing/layout that triggers it. Log-diffing can't
  localize it.

**Most likely: uninitialized memory or a subtle non-terrain race** (both timing/
layout-sensitive, matching the Heisenberg behaviour). This is the classic kind of
rare MP-desync bug.

**Consequence for the gate:** it's **usable-but-not-airtight**. 1000+ ticks of
bit-exact reproducibility in ~90% of runs is enough to validate a parallelization —
a real break would diverge **early and every run** (from the first ticks),
trivially distinguishable from this rare late flake. So sim-side parallelization can
proceed against it; just run a few times and treat an *early, consistent*
divergence as the real signal.

**To close it definitively (separate effort):** a non-perturbing tool, not more
log-diffing — **valgrind memcheck / MSAN** for the uninitialized read, or
**helgrind/drd** / an ASLR-off A/B (`proccontrol -m aslr -s disable`) to
confirm/deny a race or pointer-order dependence. That's the right next tool if/when
airtight MP determinism is the goal; it's not a blocker for the MT validation work.

### Follow-up (2026-07-21) — categorization attempts, both inconclusive; bug is rarer than first measured

Tried the two categorizing tools above. Neither pinned it — and the reason is
informative: **the divergence is far rarer than the early 1-2/10 suggested.**

- **valgrind — blocked, not usable as-is.** Three obstacles, in order:
  1. **mimalloc.** The binary statically links `mimalloc-static` built `MI_OVERRIDE=ON`
     (owns global `new`/`delete`; `Core/GlobalOperators.cpp` excluded to avoid dup
     symbols — see `engine/Poseidon/CMakeLists.txt:67-71,351-352`). valgrind's own
     malloc/new interception collides with mimalloc's arena → **SIGSEGV in early
     init**. `--soname-synonyms=somalloc=nouserintercepts` cut errors 95k→209 but
     didn't fix the crash.
  2. **`--simulate` was itself broken — FIXED 2026-07-22** (`08e850c`). It kept
     the default `gl33` backend, which fails headless → `GEngine` null →
     `Scene::Init` null-derefs `GEngine->TextBank()` (`Scene.cpp:165`), SIGSEGV at
     `WorldInit.cpp:117`. Fix: `--simulate` now defaults to the **dummy** (no-GL)
     backend unless `--render` is explicit. Verified: `--simulate <mission>` with
     no display runs headless (0 GL init, dummy 160x120 viewport, world + mission
     load, no crash). So the ideal no-GL valgrind target now exists.
  3. FreeBSD valgrind (3.27.1) is less mature than Linux's.
  To make valgrind viable = a **no-mimalloc poudriere rebuild** (drop `libmimalloc.so`
  from `LIB_DEPENDS`, re-enable `GlobalOperators.cpp`) **plus** fixing `--simulate` or
  eating GL noise. Real yak-shave; deferred. (valgrind *did* prove it can flag
  uninitialized reads in the game's own code — benign `strcatLtd`/`Bstring.hpp`
  fixed-buffer hits — once it runs, so the mechanism works.)
- **ASLR-off A/B — ran clean, inconclusive.** Clean-gate binary (no per-entity log),
  15 runs each under `proccontrol -m aslr -s disable` vs stock:
  `ASLR-off: 0/15`, `ASLR-on: 0/15`. The A/B can only categorize if the **baseline**
  reproduces the divergence — it didn't fire at all.
- **The real finding: the rate is a few percent, not ~10-15%.** Across the recent
  clean-gate + per-entity-log builds the divergence hit **0 times in ~85 runs**
  (0/35 + 0/30 ASLR + 0/20), while the *earliest* builds hit 1/6 and 1/10. At a ~3%
  true rate, 0/85 is plausible (the early 1/6 was the unlucky tail). No code change
  fixed it (the diverging serial-terrain build and the clean-gate build share
  fixed-dt+seed+parallel-terrain); it's the **same rare bug**, just too infrequent to
  catch reliably in 15-30-run batches — which is exactly why every categorization
  (log-diff, ASLR) keeps coming up empty.

**Net:** the residual is a **rare (~few-%) intermittent** that resists cheap
categorization. The gate's usability verdict is **unchanged and, if anything,
stronger** — the sim reproduces bit-exact in ~95-98% of runs, so a parallelization
break (early + every run) is trivially distinguishable. **Decision: document and move
on.** Pinning it would need either large batches (100+ runs to catch it, then
categorize) or a CPU-contention batch (loads all cores to widen a race window — the
discriminating test for "race"), on top of the no-mimalloc valgrind rebuild. Not worth
it unless airtight MP determinism becomes a hard requirement.

### Update (2026-07-22) — valgrind is UNBLOCKED; 208 uninit errors to triage

> **Superseded 2026-07-25:** the `PoseidonGame … --simulate` here reaches only the
> boot path (`--check`), not the sim loop — `PoseidonGame` has no headless sim
> driver (see "Root cause of the `--simulate` headless hang" above). The 208/66
> count was boot-only. The corrected `PoseidonServer … --simulate <dir>` command
> reaches the running sim and reports **505 errors from 128 contexts** — that is
> the real triage input. `--duration` is *real* seconds, so under valgrind's
> 10-50x slowdown use a large value (≥30) to grind through actual sim ticks.

The `--simulate` dummy-backend fix (`08e850c`) incidentally unblocked valgrind.
The early mimalloc SIGSEGV the earlier attempt hit was on the **GL path**; the
headless **dummy** backend avoids it. Verified: `memcheck --soname-synonyms=
somalloc=nouserintercepts PoseidonGame ... --render dummy --check` ran clean to
`Initialization check complete`, no crash, and reported **208 uninitialised-value
errors from 66 contexts** (e.g. `AddonSystem::ParseAddonConfig:178`).

- **So no no-mimalloc rebuild is needed to START** — memcheck runs today.
- **Caveat — heap is NOT tracked.** `nouserintercepts` leaves mimalloc owning
  `malloc`/`new`, so the HEAP SUMMARY reads `0 allocs, 0 frees`. memcheck catches
  **stack/static** uninit reads (the 208) but is largely **blind to uninitialised
  HEAP reads** — the single most-likely determinism-residual class. Full heap
  coverage still wants the no-mimalloc rebuild (drop `libmimalloc` from
  `LIB_DEPENDS`, re-enable `Core/GlobalOperators.cpp`).

### Triage result (2026-07-25) — DONE: 0 sim-relevant; residual must be heap-class

Ran the corrected command below (`PoseidonServer --simulate <dir> --duration 60
--track-origins=yes --num-callers=30 --error-limit=no`). It reached the running
sim — **134 sim frames** ticked (122 vehicles / 130 units) — and reported **503
errors from 128 contexts**, all with **stack** origins (heap untracked; see
caveat). Parsed and categorized every one of the 128 contexts by origin:

| category | contexts | where the uninit value is born |
|---|---:|---|
| benign fixed-buffer / config-IO | 66 | `LoadFromFile` (`QBStream.cpp:282`) → `strcatLtd`/`BString` (`Bstring.hpp`), during PBO-bank + addon-config loading at boot (`Globals::Init → LoadBanksEx → ParseAddonConfig`). Plus `unixPath`, `FileOps_posix`, `PreprocC`. |
| master-server network I/O | 62 | `BuildMasterServerServiceServerId` / `TryParse…Address` (`MasterServerServiceClient.cpp`), `NetServer::GetURL`, `createPeer`, socket `bind`/`sendto` — outbound registration/heartbeat strings (curl/cjson/nghttp2). |
| **real / sim-state-touching** | **0** | — |

**No tracked uninit read reaches the deterministic sim.** `World::Simulate` /
`NetworkServer::OnSimulate` appear only as *outer callers* of the master-server
publish path (the dedicated server pings the master server from inside the tick
loop); the checksummed sim itself — AI think, `GRandGen`, entity `Transform`,
collision, `AnimationRT` — produced **zero** uninit reads across all 134 frames.
The 66-context class is exactly the `BString`-accumulator over-read the docs
already called benign (its backing `char _data[Size]` inits only `_data[0]` + the
sentinel, so `operator+=`'s NUL-scan reads uninit middle bytes); harmless and not
determinism-relevant. Nothing to fix for determinism.

**So the residual is NOT a stack-uninit read** — which, given the heap caveat
below, points squarely at an **uninitialized *heap* read** (mimalloc-hidden) as
the residual's class, matching the original hypothesis. Two honest coverage gaps:
1. **Heap untracked (mimalloc)** — `nouserintercepts` leaves mimalloc owning
   `malloc`/`new`, so every heap uninit read is invisible. This is the dominant
   gap and the most-likely residual class.
2. **134 ticks covered, not the residual's ~tick 873.** The recurring sim paths
   ran 134× and are clean, but a determinism read that fires only on a rare late
   event is not excluded (lower-probability than the heap gap).

**To actually reach the residual (only if airtight MP determinism is wanted):** the
no-mimalloc rebuild (drop `libmimalloc` from `LIB_DEPENDS`, re-enable
`Core/GlobalOperators.cpp`) → heap-aware memcheck, plus helgrind for the race
hypothesis. Still the documented "not worth it unless it becomes a hard
requirement" backlog item — the triage did not surface a determinism bug, so the
gate's usable-but-not-airtight verdict is unchanged.

**Original next-session framing (now completed above):** split the errors into
benign fixed-buffer vs real / sim-state-touching, fix the real ones. Result (stack
only): all benign (config-IO + network); zero real. The real ones were in the
**heap** — see the heap-aware pass below.

### Heap-aware pass (2026-07-25) — DONE: found + fixed a real RNG-desync determinism bug

Did the no-mimalloc-equivalent so memcheck can see the heap: rebuilt the FreeBSD
`devel/mimalloc` port with **`MI_TRACK_VALGRIND=ON`** (mimalloc then reports every
block to valgrind via client requests — no allocator surgery, no CWR-CE source
change; the mimalloc-recommended way). Port wrinkle: `MI_TRACK_VALGRIND` needs the
valgrind headers as a build dep AND renames the lib `libmimalloc-valgrind.*`
(breaks the plist) — dropped the rename with a `post-patch` (the client-request
code is gated on the `MI_TRACK_VALGRIND` *define*, not the lib name). Rebuilt
CWR-CE against it (it links `mimalloc-static`), and memcheck's `HEAP SUMMARY` went
from `0 allocs` to **~810k allocs tracked**. Same command as above.

**Contexts: 128 → 156 (+28 heap-origin).** Triaged the 28 heap-origin ones; most
were benign (dummy-backend artifacts, boot-time `Scene`/quality-config reads,
static type-bank loads). **Two were real per-entity uninitialised heap fields read
in the live sim tick** — entities are heap-allocated via non-zeroing
`operator new`, and these ctors never set the fields:

1. **`Head` (soldier face) `_actualRandomLip` / `_wantedRandomLip` /
   `_speedRandomLip` / `_nextChangeRandomLip`** — read every tick in
   `Head::Simulate` (`Head.cpp:559-564`), unconditionally (not gated on
   `_randomLip`; only `SetRandomLip()` ever initialised them). The
   `if (Glob.time >= _nextChangeRandomLip) NextRandomLip()` trigger fires on
   garbage and calls `GRandGen.RandomValue()` — **advancing the shared RNG stream
   by a run-dependent amount → MP/replay desync.** This is a **prime suspect for
   the rare (~few-%) determinism-gate divergence** the whole hunt has chased: an
   uninit heap value (varies run-to-run) that perturbs RNG consumption exactly
   when it happens to trip the trigger. Fixed by initialising all four in the
   ctor (far-future `_nextChangeRandomLip` → deterministic no-op until
   `SetRandomLip` enables the feature).
2. **`Tank::_doGearSound`** — bitfield read every tick in `Tank::Sound`
   (`Tank.cpp:117`), never set by the ctor. Sound-only (not determinism-critical),
   but a genuine uninit read. Defaulted false.

**Fixes are on branch `ocochard/CWR-CE:valgrind-uninit-fixes`** (off `gpu-skinning`
so it builds on FreeBSD; clean/cherry-pickable for upstream). **Verified:** rebuilt
the branch, re-ran the identical heap-aware memcheck → the `Head::Simulate`,
`Tank::Sound`, and all `NewVehicle`-origin contexts are **gone** (156 → 152), heap
still tracked. Remaining 152 are the benign config-IO / network / dummy-backend
classes.

### Gate result (2026-07-25) — the Head fix is real but does NOT close the gate

Ran the determinism gate to test whether the Head RandomLip fix closes the
residual. `PoseidonServer --simulate <dir> --determinism-log --duration 40`
(~1700 ticks, past the historical ~873 divergence), 24 runs per config, comparing
the per-tick `DETERMINISM: sum=` sequence against run 1 (joined on tick — the
number of ticks per run varies because `--duration` is *real* seconds, so
length differences are NOT divergence; only a **sum mismatch at a shared tick** is).

| batch | divergence |
|---|---|
| **fixed** (branch), clean | **0/23** |
| **buggy** (`gpu-skinning`), clean | **0/23** |
| **fixed**, under CPU contention (parallel build) | **1/24** (sum mismatch at tick 312) |

**Verdict: the gate is NOT confirmed closed by the fix.** Clean runs show no
difference (both 0/23 — the residual is too rare to fire in 24 clean runs, matching
the docs' "0/85" history), and — decisively — the **fixed binary still diverged
under CPU contention**. Since the Head fix is valgrind-proven to remove the
uninit→RNG path, that surviving divergence is a **separate** nondeterminism.
Under `--determinism-log`'s fixed 0.02 s timestep the sim *should* be wall-clock
independent, so a divergence that appears only under CPU load means **something in
the sim reads real/wall-clock time**, not sim `deltaT` — exactly the docs' other
residual candidate (a `GlobalTickCount()`-keyed event). The Head RandomLip bug was
a real determinism bug worth fixing, but it was **not** (or not the only) residual.

**Follow-ups (open):**
- **Hunt the wall-clock-timed residual** — the discriminating test the docs
  flagged: run fixed AND buggy under deliberate all-core CPU contention (widen the
  window) and compare rates; then grep the sim/AI/effects paths for
  `GlobalTickCount()` / real-time reads that should be sim-`deltaT` (weather,
  periodic effects, AI timers) and route them through sim time.
- **Merge `valgrind-uninit-fixes` into `gpu-skinning`** and submit upstream
  (`PR-*.md` pattern) — the fixes are strict improvements regardless of the gate.
- **Host state:** poudriere overwrote the fix pkg with the buggy `gpu-skinning`
  one during the A/B, so the **installed binary is currently `gpu-skinning`
  (no fix)** — rebuild the branch (or merge it) to run the fixes. The installed
  mimalloc is back to stock; the `MI_TRACK_VALGRIND` variant is only in the git
  history of `~/freebsd-ports/devel/mimalloc` (reverted).

Exact command — **corrected 2026-07-25** (the 2026-07-22 form used the wrong
binary AND the wrong path; see the `--simulate` root-cause note below):
```
env -u DISPLAY XDG_RUNTIME_DIR=/tmp/xdg valgrind --tool=memcheck \
  --soname-synonyms=somalloc=nouserintercepts --track-origins=yes \
  --error-exitcode=42 --trace-children=no \
  PoseidonServer -C ~/.local/share/CWR/base --no-sound --render dummy \
  --simulate ~/.config/CWR/Users/Test/Missions/Benchmark.Abel \
  --duration 10 --stats 2
```
Two fixes vs the old command: **`PoseidonServer`, not `PoseidonGame`** (the
duration-driven headless sim loop is server-only), and **the mission
*directory*, not `mission.sqm`** (the server derives the world from the dir name's
`.Abel` suffix; a bare `mission.sqm` stem has no suffix and is rejected). Verified
2026-07-25: this actually ticks the sim (`vehicles=122 units=130`, frame 1→90→177)
and exits code 2 on duration. A `--check`-only run is faster for boot-path errors;
use `--simulate` to reach the sim loop where the determinism-relevant reads live.

### Root cause of the "`--simulate` headless hang" (2026-07-25)

The 2026-07-22 note below called `--simulate` a regression that hangs headless. It
is **not a regression** — it was the wrong invocation, on two counts:
1. **Wrong binary.** `--simulate`'s duration-terminated headless sim loop is
   `ServerApplication::DedicatedServerLoop` (`apps/cwr/Server/`), which reads
   `IsSimulateMode()`/`GetSimulateDuration()` and `_exit(2)`s when the duration
   elapses. **`PoseidonGame` consumes neither** — `--simulate` there only sets
   dummy-backend + a test-mission path, boots the mission into the *client* main
   loop, and (no window/focus → `enableDraw` false) sits in the `AppIdle` →
   `Sleep(50)` throttle (`GameLoop.cpp:201`) forever. Not a deadlock; an
   unterminated idle loop. The `08e850c` "fix" only stopped the GL null-deref
   crash — it never made `PoseidonGame` *drive* a headless sim, because that code
   lives in the server binary.
2. **Wrong path form.** `--simulate` must point at the mission **directory**
   (`…/Benchmark.Abel`), not `…/Benchmark.Abel/mission.sqm`. The staging in
   `NetworkServerSimulate.cpp:437-456` names the template from the *directory*
   name (keeps the `.Abel` world suffix) but from a *file*'s **stem** (`mission`,
   suffix lost); `:560` then rejects a suffix-less template ("has no world
   suffix") and the run idles to timeout without simulating.

(UX bug FIXED 2026-07-25, `d7b13f2`: `RunAfterArgumentParsing` now rejects
standalone `PoseidonGame --simulate` — `LOG_ERROR` pointing at PoseidonServer +
the mission-directory arg form, then `return 1` — instead of idling. Gated on
`!CheckInitAndExit()` so the `--check --simulate` mission smoke check is
unaffected. Verified: standalone errors+exits 1; `--check --simulate` still boots
the smoke check to completion.)

## Measurement

Uncapped (`vsync=0`) on the 197-unit `--benchmark` mission: `prof_bench.sh` for FPS
means (MT gains show only uncapped), plus `ps -H -o lwp,pcpu,comm` to confirm work
actually spread off the main thread. Determinism: sim-state checksum per tick,
1-thread vs N-thread, must match.

## Effort & payoff

- **Effort:** step 2 is small-medium (a couple of `ParallelFor` conversions +
  scratch buffers). The determinism gate + sim-side + pipeline are progressively
  larger and riskier.
- **Payoff:** the only lever with real headroom on modern many-core hardware once
  the render side is confirmed cheap and vsync is uncapped — but **zero on the
  vsync-capped default**, so scope the expectation honestly before building.

## GPU-skinning t420 A/B (2026-07-25) — MEASURED: no win on the benchmark scene

The t420 came back online; ran the "free, decisive" test the assessment below
deferred. **Verdict: GPU skinning does NOT improve FPS on the benchmark scene —
the documented t420 thesis is falsified for it.**

Setup: t420 (i5-2520M 2c/4t, **Intel HD 3000 / Mesa 26.1.3**), FreeBSD
16.0-CURRENT. Installed the `gpu-skinning` pkg (`08e850c`, built on ser6's
`builder` jail — same `1600019` ABI) via `pkg add -f`; the t420 had a stale stock
`3.01-unknown` build. Copied the Test-profile `Benchmark.Abel` mission over (was
missing). Harness: 6 interleaved `--benchmark --test-mission` runs per config,
1000 frames (~45 s each at ~22 fps), `BENCHMARK RESULT` + ministat.

| config | mean FPS | σ | n |
|---|---|---|---|
| baseline | 22.22 | 0.42 | 6 |
| `--gpu-skinning` | 22.75 | 0.63 | 6 |

**ministat: "No difference proven at 95% confidence"** (+0.53 fps ≈ +2.4%, in noise).

**Root cause — main-thread CPU is unchanged**, so the ~7-15% the assessment
expected GPU skinning to *remove* is not being removed here:

| thread | baseline | `--gpu-skinning` |
|---|---|---|
| main | 82.5% | 82.4% |
| `gdrv0` (GPU driver) | 29.7% | 31.7% |

GPU skinning only covers infantry **view** LODs; the benchmark's 197 units patrol
at camera distance on **coarse LODs** (exactly what the `ApplyMatrices*` row below
says "must stay CPU"), so the skinned path barely runs. On the weak HD 3000 the
offload even nudges the GPU-driver thread *up*. Bound confirmed CPU (main ~85%),
but the addressable cost isn't view-LOD skinning in this scene.

**Scope of this result:** proves no win on the *distant-patrol benchmark*. The
follow-up below tested the opposite regime (close view-LOD) and also came up
empty — for a *different* reason. The engine logs **no skinning-activation line**
(observability gap — engagement is inferred from the main-CPU delta, not logs).

### Follow-up (2026-07-25) — close-combat view-LOD scene: skinning engages, still no FPS win (GPU-bound)

Built `CloseCombat.Abel` (`closecombat-mission/`, `MISSION-SQM-FORMAT.md`): 110
soldiers frozen (`disableAI "MOVE"`) in a 2 m-spaced grid packed at an eye-level
camera, so many render at the **view LOD** — the regime GPU skinning is designed
for. Same 6-run A/B harness:

| config | mean FPS | σ | n |
|---|---|---|---|
| baseline | 15.72 | 0.29 | 6 |
| `--gpu-skinning` | 15.93 | 0.44 | 6 |

**ministat: no difference at 95%** (+0.21 fps). But per-thread CPU shows the
mechanism is *different* from the patrol — here skinning **does** engage:

| thread | baseline | `--gpu-skinning` |
|---|---|---|
| main | 61.9% | **58.2%** (−~4 pt) |
| `gdrv0` (GPU driver) | 57.4% | 56.7% |

Two facts vs the patrol: (1) `gdrv0` is now **~57%** (was ~30%) — the HD 3000 is a
co-bottleneck rendering 110 detailed soldiers; (2) `--gpu-skinning` shaves ~4 pt
off the main thread, so the offload is real this time. It still yields no FPS
because the scene is **GPU-bound on the weak iGPU**: skinning moves work *off* the
non-bottleneck (main CPU, already only ~60%) *onto* the bottleneck (the GPU). The
freed CPU has nowhere to go.

**Complete verdict for the t420 (i5-2520M + Intel HD 3000):** GPU skinning is a
wash in **both** regimes, for two different reasons —
- **distant** (patrol/benchmark): units at coarse LOD, skinned path barely runs,
  main-CPU flat → nothing offloaded;
- **close** (view LOD): skinned path runs and *does* cut ~4 pt main-CPU, but the
  scene is GPU-bound on the HD 3000 → the cut doesn't convert to frames.

The HD 3000 is simply too weak to ever be the beneficiary: infantry are either far
(skinning idle) or near (GPU saturated). **GPU skinning needs a host that is
CPU-bound *with GPU headroom to spare* — which this iGPU is not.** The documented
"t420 will show the win ser6 couldn't" thesis is falsified on this hardware; a
newer dGPU laptop (CPU-bound, GPU idle) is where it could still pay. **Consequence:
the "free GPU-skinning win" that justified deferring Phase-4/5 is spent and empty
on the only CPU-bound machine available — Phase-4/5's case now rests entirely on
the heavier CPU-side loops (animation-prep, collision), not this lever.**

## Phase-4/5 worth-it assessment (2026-07-22) — DEFER, gated on the t420

Asked whether to pick up the Phase-4/5 sim-side parallelization next. **Verdict:
not now.** The blocker is *measurement*, not engineering readiness — and the
cheapest lever in this whole area (GPU skinning) is already done and unvalidated.

**The addressable CPU (post-Phase-1 self-time, `PERF-hotspot-profile.md:225-242`):**

| loop | self-time | side | clean parallel? |
|---|---|---|---|
| `CheckVisibility` | 6.79% | render | **No** — recurses `Object::Intersect` into the shared collision/animation core (audit `:250-286` DEFERRED it as "largest, riskiest") |
| `OcclusionView` | 2.05% | render | closest to clean, but modest |
| `PredictCollision`+`Ground`+`Object` collision | ~5.4% | **sim** | determinism-gated; docs suggest *caching* may beat parallelizing |
| `ApplyMatrices*` (residual) | ~3% | mixed | view LOD already GPU-offloaded; the rest is coarse LODs that **must** stay CPU |

**Amdahl ceiling is small for the safe subset.** The only *cleanly* parallel,
determinism-free loops are the render-side analysis ones — and those were already
proven **net-negative** (`--mt-lod`, `+11% CPU`, too fine-grained). The one big
render-side item (`CheckVisibility`, 6.79%) is *not* clean. So the "easy" data
parallelism (Phase 5) tops out around a **~10% frame-time** ceiling *if* the hard
`CheckVisibility` refactor lands, and less otherwise. The real 2x is the **Phase-4
pipeline** (overlap sim(N)/render(N-1)) — but that needs the double-buffered render
snapshot, a one-frame lag, and must not change sim results: **high risk**.

**Three hard blockers, in priority order:**
1. **The t420 is offline** — it is the *only* CPU-bound machine, so it is the only
   place any of this can be FPS-validated. ser6 is present-bound → **zero FPS
   signal** (proven repeatedly). Building a large, risky restructure whose entire
   justification is CPU-bound FPS, with no way to measure it, is premature.
2. **The highest-leverage CPU cut is already built and unmeasured** — GPU skinning
   removed the view-LOD skin + re-upload (`~7-15% CPU`, off by default). On the
   t420 that is *likely a real FPS win by itself* and needs **zero new code** —
   just a `prof_bench.sh` run. Spend that first; it may make Phase-4/5 unnecessary.
3. **The determinism gate isn't airtight** (rare ~few-% Heisenbug). Fine for
   render-side (serial-verify is the gate), but the collision work is sim-side and
   leans on the gate — added risk until closed.

**Recommended sequence (when the t420 is back):**
1. `prof_bench.sh` ± `--gpu-skinning` and `--gpu-timing` on the t420 → confirm the
   CPU bound and **cash in the already-done GPU-skinning win**. Free, decisive.
2. Only if that leaves the frame animation-CPU-bound: hoist `Man::Animate` out of
   `Object::Draw` into a parallel pre-pass (GPU skinning is the enabler, item 5b).
   Higher leverage than the render-side analysis loops, and clears the grain-size
   bar the LOD loops failed.
3. Collision (sim-side) behind the determinism gate — or cache the per-object
   ground queries instead (docs' hint), which may beat parallelizing outright.
4. Phase-4 pipeline last, only if data parallelism plateaus.

**One t420-independent prerequisite — DONE (2026-07-22, `08e850c`; usage
corrected 2026-07-25):** the `--simulate` GL null-deref is fixed (defaults to the
dummy no-GL backend; `:277`). Headless sim runs with no display via
**`PoseidonServer --simulate <mission-DIR> --duration N`** (NOT `PoseidonGame`, and
NOT a `mission.sqm` file — see the root-cause note above), which is the no-GL
target the valgrind determinism close-out needs.

**Bottom line:** the parallel-for machinery is proven and the plan is sound, but
Phase-4/5 is a high-effort, high-risk restructure that cannot be validated on the
only online machine and whose thesis (CPU-cuts → FPS) is cheaper to test first via
the GPU-skinning build already sitting on the branch. **Don't start it until the
t420 confirms there's FPS to be won that GPU skinning didn't already capture.**

## Phase-4/5 — SHELVED (2026-07-25), settled by the t420 profile

The t420 is back; profiled it (`PERF-hotspot-profile.md` → "t420 profile
(2026-07-25)") and **decided not to build Phase-4/5.** The confirming
condition the bottom line above set — "the t420 confirms there's FPS to be won
that GPU skinning didn't capture" — **failed**:

- The t420 busy main thread is only **~35% Poseidon compute**; **~45%+ is serial
  GPU-driver/GL-submission** (Mesa gallium 16.6% + i915/dmabuf/drm ~10% + the
  kernel ioctl path), which task-parallelism cannot touch (one GL context) and
  which forms a hard floor.
- The parallelizable Poseidon compute is coarse-LOD skinning (~3.8%,
  `ApplyMatricesComplex` — the t420's #1, *not* ser6's `CheckVisibility`) +
  collision (~4.9%) ≈ **~9% of frame → ~10% ceiling, ≈ +2 fps at 22 fps**.
- The #1 target needs the `Man::Animate`-out-of-`Object::Draw` restructure; the
  collision cluster is sim-side behind the not-airtight determinism gate.

~10% for a multi-day high-risk draw-loop/sim restructure is not worth it, and the
bigger ~45% slice is old-GPU + heavy-modern-Mesa-driver cost the engine can't
batch away (terrain batching already KILLED). **The CPU-perf lever is tapped out on
the available hardware.** The t420 hotspot profile is the deliverable; revisit only
if a newer machine (fast CPU + GPU with headroom) changes the bound, or if the
GPU-driver-submission cost itself becomes the target (a different investigation:
Mesa/driver, not Poseidon task-parallelism).
