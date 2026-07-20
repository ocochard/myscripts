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

## When this actually helps (set expectations)

| config | bound | MT payoff |
|---|---|---|
| ser6, vsync=1 (60) | present/vblank wait | **none** — frame already idle-waits |
| ser6, vsync=0 (~80) | main-thread CPU (~12.5 ms) | **yes** — the headroom lever |
| t420, CPU-bound (~20) | main-thread CPU | **yes** — biggest relative win |

So MT is for **uncapped / high-refresh play and weak CPUs**, not the default 60-cap
ser6. Worth doing, but not the thing that makes the *capped* game feel faster.

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
