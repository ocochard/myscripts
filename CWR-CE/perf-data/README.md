# CWR-CE performance baselines (pmcstat)

Reference profiles for comparing future optimization work on the Poseidon
engine. See `../PERF-low-fps-cpu-bound.md` for the investigation narrative.

## Host / environment (constant across baselines)

- CPU: AMD Ryzen 7 7735HS (Zen3+, 8c/16t), boosting to ~4.4 GHz, powerd on
- GPU: AMD Radeon 680M (radeonsi), Mesa 26.1.4, OpenGL 4.6 core
- OS: FreeBSD 16.0-CURRENT; display HDMI-1 1920x1080 @ 60Hz; `vsync=1`
- Timecounter: TSC-low; `kern.timecounter.invariant_tsc=1`
- PMC event: `ls_not_halted_cyc` (cycles), 8 s system-wide sample
- Config: `UserInfo.cfg frameRate=60`, `graphics.cfg` preset=3, renderScale=1,
  msaa=0, fpsCap=0

## Baseline A — debug `-O0` build (the bug)

Package `CWR-CE-3.01_4`/`_3`, 213 MB unstripped. Built with a **global
`WITH_DEBUG`** that filtered `-O*` out of CFLAGS → whole engine at `-O0` +
per-read NaN validation + stack canaries.

- In-game: **20–30 FPS** (iFPS/aFPS overlay)
- Per-thread CPU: main thread **94.4%** (pegged on one core), `gdrv0`
  (GPU driver) **0.6%** (idle) → single-thread CPU-bound
- Top game self-time (symbolized — binary was unstripped): scalar
  `Vector3P`/`Matrix4P` math under `Object::AnimateGeometry → Man::Animate
  → AnimationRT::ApplyMatrices` (software skinning). No single fn > 2.75%.
- Data: `pmc-debug-O0-old.top-poseidon.txt`

## Baseline B — optimized `-O2` build (current)

Package `CWR-CE-3.01_2`, 12.8 MB stripped. `WITH_DEBUG` removed; `-O2` on
1036/1037 compiles; `CFLAGS="-O2 -pipe -fstack-protector-strong ..."`.

- In-game: **60 FPS** (vsync-locked)
- Per-thread CPU: main thread **77.8%**, `gdrv0` **6.6%** (GPU now working).
  Main thread still substantial → CPU still the frame limiter, just far
  faster per frame.
- Top *active* samples (idle-core ACPI noise filtered):
  - `fegetenv`   @ libm.so.5 — **9.09%**
  - `nearbyintf` @ libm.so.5 — **8.85%**
  - `rintf`      @ libm.so.5 — **1.44%**
  - → ~19% combined in libm float→int rounding (new #1 cost)
  - PoseidonGame frames below that are `0x…` unsymbolized (stripped binary)
- Root of the rounding cost: `engine/.../Common/FltOpts.hpp` — `toInt`,
  `toLargeInt`, `toIntFloor/Ceil`, `fastRound`, `Fixed` all call
  `std::nearbyint`, which lowers to a libm `nearbyintf` **call** (not the
  single `cvtss2si` the source comment assumes) without
  `-fno-math-errno`/`-ffast-math`.
- Data: `pmc-optimized-O2-3.01_2.out.gz` (raw samples, gzipped),
  `pmc-optimized-O2-3.01_2.top60.txt`,
  `pmc-optimized-O2-3.01_2.top30-active.txt`

## Baseline C — RelWithDebInfo `-O2 -g -DNDEBUG` (faithful + symbolized)

Package `CWR-CE-3.01_2` built with `CMAKE_BUILD_TYPE=RelWithDebInfo` +
`STRIP=` (unstripped, 208 MB, 562 `Vector3P` symbols). Same runtime speed as
the shipped release (`-g` costs only disk), but pmcstat resolves every
Poseidon function. Built to settle the "secondary items". 60 FPS in-game.

- **Item 1** (`__forceinline`→`inline`): non-issue. `operator[]`/`X()` have 0
  out-of-line copies (fully inlined); `SetMultiply` inlines into
  `ApplyMatricesSimple`. clang inlines the small math at `-O2` anyway.
- **Item 2** (dead SSE `Math3DPK.cpp`): low value. `ApplyMatricesSimple`
  already emits packed `mulps`/`addps`; only `SetFastTransform` stays scalar
  (~1%).
- **Item 3** (`std::nearbyint`): confirmed #1 — **~28%** of samples in libm
  rounding: `fegetenv 13.3% + nearbyintf 13.0% + rintf 2.0%`.
- Symbolized game-side top: `Landscape::CheckVisibility 4.1%`,
  `Foundation::InvSqrt 2.7%`, then the terrain/collision cluster and
  animation. Much of the terrain code feeds `toInt` → part of the 28%.
- Data: `pmc-relwithdebinfo-3.01_2.out.gz`, `*.top40.txt`.

Note: `WITH_DEBUG` is the WRONG way to get this — it drops `NDEBUG`, turning
`PoseidonAssert` on in every accessor, which stops inlining and misreports
items 1/2. Use `RelWithDebInfo`. See `../DEBUGGING.md` "low FPS" section.

## Baseline D — nearbyint fix (`fltopts-nearbyint-cvtss2si`)

Same RelWithDebInfo config as C, plus the `FltOpts.hpp` fix routing
float→int through `cvtss2si` instead of `std::nearbyint`. Port patch:
`files/patch-engine_Poseidon_Foundation_Common_FltOpts.hpp`.

- Binary check: `nearbyintf` refs **0** (was pervasive), `cvtss2si` **1397**.
- libm rounding cost: **~28% → 0** (`nearbyintf`/`fegetenv`/`rintf` absent).
- Main-thread CPU @ vsync-locked 60 FPS: **77.8% → 60.5%** (frame ~22%
  cheaper; more headroom for uncapped FPS / detail / units).
- New game-side top: `Landscape::CheckVisibility 7.6%`,
  `ApplyMatricesSimple 4.3%`, `Foundation::InvSqrt 4.3%` (next lever:
  `rsqrtss`), terrain/collision cluster.
- Data: `pmc-nearbyint-fixed-3.01_2.out.gz`, `*.top40.txt`.

## Baseline E — nearbyint + invsqrt (`invsqrt-rsqrtss` on top of D)

Adds the `MathOpt.cpp` InvSqrt fix (SSE `rsqrtss` + Newton, activating dead
`_KNI` code and fixing its never-compilable namespace bug) on top of the
nearbyint fix.

- Binary: `InvSqrt` is now `rsqrtss` + Newton (no table load); `nearbyintf` 0.
- `InvSqrt` cost: **~4.3% (D) → ~0.65% of total CPU**, out of the hot top-12.
- Main-thread CPU @ 60 FPS: **58.7%** vs 60.5% (D). Small, within scene noise.
- Verdict: correct portable micro-opt, but not a visible-FPS win on its own
  (InvSqrt was only ~4%; rsqrtss vs warm-L1 table is a modest per-call gain).
- Data: `pmc-nearbyint+invsqrt-3.01_2.out.gz`, `*.top30.txt`.

## Full-frame breakdown F — unfiltered `--benchmark` profile (`_5`, vsync=0)

Not an A/B baseline — the whole-frame subsystem breakdown answering "what gates
the frame". ser6, **vsync=0** (CPU-bound, ~70 iFPS steady), 122-unit no-combat
Benchmark.Abel, 816k samples over a 12 s log-gated window. **Nothing filtered**
(Mesa/`amdgpu`/kernel kept — the driver frames are the present path here).

- ~25% Mesa/GPU submit+present, **~15% animation skinning in the draw path**
  (`ApplyMatricesComplex` 7.1% + `SetFastTransform` 2.5%, skinned in *both*
  shadow and object passes), ~11% terrain-collision, ~8% terrain mesh-prep.
- `CheckVisibility` (the combat-scene #1) is ~absent — this bench has no combat.
- Full analysis + next levers: `../PERF-hotspot-profile.md` "Full-frame
  breakdown" section.
- Harness note: plain `--benchmark` stays stuck at the menu in `_5`; the working
  trigger is `--benchmark --test-mission <Benchmark.Abel dir>`.
- Data: `pmc-fullframe-benchmark-3.01_5.out.gz`, `*.top40.txt`, `*.bench-log.txt`.

## Prototype G — coarser-shadowLOD bias (`_6`, vsync=0) — INCONCLUSIVE

`shadowLodBias=0.25` on the projected-shadow `shadowLOD` selection
(`SceneDraw.cpp`), built RelWithDebInfo via poudriere as `_6`. Same harness as F.

- `ApplyMatricesComplex` 7.16% → 6.32%, but **confounded**: bench6 frames ~28%
  heavier (1207 vs 945 samples/frame, iFPS ~66 vs ~72 — scene variance), and
  `RecalcShadow` stayed flat (0.94→0.95), so the shadow LODs likely didn't
  actually coarsen. No FPS gain. Full analysis: `../PERF-hotspot-profile.md`
  "Prototype: coarser-shadowLOD bias".
- Next: instrument the runtime `shadowLOD` histogram to confirm the bias changes
  LOD selection before tuning further.
- Data: `pmc-shadowlodbias-3.01_6.out.gz`, `*.top30.txt`, `*.bench-log.txt`.

## Reproduce / compare a new profile

```
# 1. Sample the running game (8 s)
PID=$(pgrep -x PoseidonGame)
sudo pmcstat -S ls_not_halted_cyc -O /tmp/pmcNEW.out sleep 8

# 2. Annotate
pmcstat -R /tmp/pmcNEW.out -G /tmp/pmcNEW.graph
grep -E "^[0-9]+\.[0-9]+%" /tmp/pmcNEW.graph | grep -viE "Acpi|cpu_idle|lock_delay|doreti" | head -30

# 3. Re-annotate an OLD baseline for apples-to-apples
gunzip -k pmc-optimized-O2-3.01_2.out.gz
pmcstat -R pmc-optimized-O2-3.01_2.out -G /tmp/base.graph
```

## Symbol resolution caveat

The shipped package is stripped, so live pmcstat cannot name Poseidon
functions (only `0x…` offsets + library symbols). To get a symbolized
game-side callgraph, build/run an **unstripped `-O2`** binary (e.g. the
CMake output in `work/.build/` before `install-strip`, or a RelWithDebInfo
build) and profile that. Library frames (libm `nearbyintf`, Mesa, libc)
resolve regardless — which is how baseline B's #1 cost was still identified.
