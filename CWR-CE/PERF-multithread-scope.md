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
