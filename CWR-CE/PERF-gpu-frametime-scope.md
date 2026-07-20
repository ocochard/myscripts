# GPU frame-time breakdown — scope (CWR-CE / Poseidon GL33)

Close the one render-side gap the perf campaign never measured. Everything so far
profiled **CPU** cycles (pmcstat), which by construction cannot see GPU execution
or the present wait — the exact costs that bound ser6.

**Read first (do not re-derive):** `PERF-hotspot-profile.md`
- `:381` — ser6 is **present-bound at ~60-62 fps with ~2x CPU headroom**; the main
  thread finishes in ~half the frame budget and waits on present.
- `:880` — the "~25% Mesa" is **dynamic vertex streaming**, not draw submission
  (only ~20-28 draws/frame; terrain draw-call batching is KILLED, `:904`).
- `:887-892` — the AutoTest `--benchmark` **under-renders** (camera never frames a
  terrain vista, `draw=0`); *"profile real gameplay with the player camera ... That
  render profile is the one gap this campaign never closed."* **This doc is that.**

## Goal

Measure **GPU milliseconds per pass** plus the **present wait**, on a real rendered
scene, to decide the actual bound:
- terrain/grass/shadow passes dominate GPU ms -> **fill/overdraw-bound** (attack
  grass-layer overdraw, shadow resolution, render scale, pixel-shader cost);
- `SwapWindow` wall-time dominates while GPU passes are cheap -> **present/vsync-
  bound** (only uncapping or a lighter present helps);
- GPU passes ~= frame budget -> **GPU-bound**, and the breakdown says which stage.

## Mechanism (GL 3.3, `GL_ARB_timer_query` — core, no extension)

- A **ring of N=3 frames** of timestamp queries. Each marker is
  `glQueryCounter(GL_TIMESTAMP, q)` — records when the GPU *reaches* that point.
- Read back the **oldest frame in the ring** with `glGetQueryObjectui64v`
  (`GL_QUERY_RESULT`) — by then it is complete, so the read is **non-blocking**
  (no `glFinish`/pipeline stall). Diff consecutive timestamps -> ns per stage.
- Separately measure the **present wait** as CPU wall-clock around
  `SDL_GL_SwapWindow` (`EngineGL33_VertexBuffer.cpp:645`): on a vsync-capped,
  present-bound frame that wall-time is where the "missing" ms hide, and the GPU
  timestamps alone won't show it.

## Marker points (pass structure already located)

Per frame, in order (`LandscapeRender.cpp` / `SceneDraw.cpp`):
1. frame start
2. after **opaque terrain** — `DrawGround(opaqueLayer)` (`LandscapeRender.cpp:1512`)
3. after **objects + projected shadows** — `DrawObjectsAndShadowsPass1` (`:1540`)
4. after **grass/alpha layers** — the `DrawGround(mode.layers[i])` loop (`:1576`)
5. after **Pass2 / shadow-map** — `DrawObjectsAndShadowsPass2` (`:1586`)
6. before/after **present** — around `SDL_GL_SwapWindow`

The GL33 backend already sees only `passes=2` at its level (`--render-frame-log`),
too coarse; the finer terrain-vs-objects-vs-grass split needs these World-level
marks.

## Design

- `Engine::MarkGpuStage(const char* label)` — virtual, base no-op; GL33 override
  records a timestamp query into the current ring frame when `--gpu-timing` is on.
  Called from the World pass boundaries above. The present marks + ring
  advance/readback + logging live entirely in the GL33 backend (it owns the swap).
- CLI `--gpu-timing` -> `ENGINE_CONFIG.gpuTiming` (mirror `--render-frame-log`).
- Output: one line per frame (or every ~60), e.g.
  `GPU: terrain=2.1 objs=3.4 grass=1.8 shadow=4.0 present=5.2 (cpuFrame=6.1) ms`.

## Constraints / catches

- **Timestamp queries are async and cannot nest** — use `GL_TIMESTAMP` markers
  (point-in-time), not `GL_TIME_ELAPSED` (begin/end spans that can't overlap).
- **Read one frame late** — reading the current frame's query forces a stall
  (defeats the point). The 3-deep ring guarantees the read target is done.
- **Tiling/deferred drivers reorder** — on the Radeon/AMD gallium stack the
  timestamps are meaningful; note that "GPU reached marker" != "work for the prior
  stage fully retired" if the driver overlaps stages. Good enough to find the
  dominant stage.
- **Must run on real gameplay**, not `--benchmark` (the campaign's whole point,
  `:887`). The instrumentation is always-available; drive a real terrain vista.

## First measurement (2026-07-20) — present/vsync-bound, GPU render is cheap

`--gpu-timing` on the 197-unit `--benchmark` scene (vsync=1), per-second:

```
GPU(ms): terrain=1.06  objects=0.05  grass=0.00  pass2=3.53  swap=0.53  present=7.35
GPU(ms): terrain=1.06  objects=0.05  grass=0.00  pass2=4.10  swap=0.44  present=9.28
GPU(ms): terrain=1.30  objects=0.04  grass=0.00  pass2=0.95  swap=3.63  present=8.88
```

- **`objects` ~0.05 ms** — 197 object draws are trivial on GPU (instanced, cheap
  shaders). NOTE the split needed a `gpuTiming`-gated `FlushQueues` after `Pass1`;
  without it the drain shows up misattributed as a fat "world" stage (the earlier
  ~5-13 ms reading was that artifact, not real object cost).
- **`terrain` ~1 ms, `pass2` (shadows+alpha) ~0.3-4 ms, `swap` ~0.5-3.6 ms** — all small.
- **`present` ~7-9 ms — dominant.** `SDL_GL_SwapWindow` blocking on the 60 Hz
  vblank: the GPU finishes the frame in a few ms and waits ~half the budget.

**Verdict: ser6 is present/vsync-bound on this scene** (confirms `PERF-hotspot-
profile.md:381`, now with measured GPU numbers). No GPU-render fat to trim (objects
0.05 ms, terrain 1 ms); no CPU micro-opt helps (freed time just extends the vsync
wait — why the whole CPU campaign was FPS-neutral). **Only real FPS levers:**
(a) **uncap vsync** (60→80, verified), (b) **multithread the single-threaded main
loop** (the architectural ceiling; render side is already cheap).

**Caveat / next:** `--benchmark` under-renders a *terrain vista* (`:887`). A real
gameplay capture (player camera over open terrain/shadows) is still worth one run
to confirm terrain/`pass2` don't dominate there — the `--gpu-timing` tool is ready
for it; drive the scene and read the `GPU(ms):` lines.

## Effort & payoff

- **Effort:** small — a query ring + ~6 marker calls + one log line; a few dozen
  lines, isolated behind the flag. No behavior change when off.
- **Payoff:** the first direct read of where the GPU/present milliseconds go —
  turns "FPS won't move and we don't know why" into a targeted next lever
  (overdraw vs shadows vs present). This is the prerequisite for any real ser6
  FPS work; every CPU lever so far landed in present slack for lack of it.
