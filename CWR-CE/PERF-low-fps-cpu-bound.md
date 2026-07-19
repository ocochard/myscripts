# CWR-CE low-FPS investigation — shipped package is a debug/unoptimized build

Engineering log for the "stuck at ~20 FPS" report on `ser6fbsd`-class
hardware (AMD Ryzen 7 7735HS + Radeon 680M). Date: 2026-07-17.

## Status: RESOLVED (2026-07-18)

Rebuilt without `WITH_DEBUG` (`CWR-CE-3.01_2`, `-O2` on 1036/1037 compiles,
stripped 12.8 MB vs the old 213 MB) and reinstalled. **In-game FPS is now a
vsync-locked 60**, up from 20–30. Root cause and fix below.

## Verdict

The framerate is not GPU-, vsync-, or config-limited. The installed
package `CWR-CE-3.01_3` ships an **unoptimized binary with math
validation compiled in**: the hottest engine path (CPU software skinning)
runs `-O0` code where every vector-component read carries a stack frame, a
stack-protector canary, and a per-read NaN check wired to spdlog. The game
is single-thread CPU-bound in that path, so a fast GPU cannot help.

The port *requests* an optimized Release build; the binary is not one. That
mismatch is the bug.

## Symptom and the `--fps` red herring

- `--fps` / `--show-fps` only toggles the on-screen overlay
  (`AppConfig.cpp:335` — "Show FPS overlay on screen"). It does not uncap
  anything and does not write FPS to the log. Reading FPS requires the
  overlay; it is never in `--log-file`.
- Overlay shows iFPS and aFPS both ~20–30 (`EngineDrawing.cpp:46-71`,
  `drawRight "iFPS"/"aFPS"`).

## What was ruled out (with evidence)

| Suspect | Evidence it is NOT the cause |
|---------|------------------------------|
| Frame-rate auto-detail band | `UserInfo.cfg` had `frameRate=15` → target band 10–20 FPS (`Scene.cpp:593-600`, default 15 at `Scene.cpp:640`). Raised to 60 (band 40–80). FPS did **not** rise past ~30 → band was not the binding limit. |
| User FPS cap | `graphics.cfg` `fpsCap=0` (`GameLoop.cpp:123`, `GraphicsApply.cpp:98`). No cap. |
| Vsync present-path / compositor | `vsync=1` in `graphics.cfg`, but `env vblank_mode=0` did not change FPS. Rules out the DRI3 `xcb_wait_for_special_event` path (DEBUGGING.md §2b) and xfwm4 compositing. |
| Display refresh | HDMI-1 = 1920x1080 @ **60Hz** active (`xrandr`). Not a 30Hz/24Hz cap. |
| Supersampling / MSAA | `renderScale=1.0`, `msaaSamples=0` (`graphics.cfg`). |
| Software rendering | Game log: `GL33: OpenGL 4.6 (Core Profile) Mesa 26.1.4 — AMD — AMD Radeon 680M (radeonsi ...)` (`EngineGL33.cpp:445`). Real GPU driver, not llvmpipe. |
| CPU downclock | `dev.cpu.0.freq: 4414`, powerd running, TSC invariant. CPU boosting normally. |
| Slow timecounter | `kern.timecounter.hardware: TSC-low`; engine reads time via `clock_gettime(CLOCK_MONOTONIC)` (vDSO). The ACPI-timer samples in the profile were idle sibling cores doing C-state accounting, not the game. |

## Root cause

### 1. Single-thread CPU-bound in software skinning

Per-thread CPU while running (`ps -H -o lwp,pcpu,time,comm -p $(pgrep -x PoseidonGame)`):

```
100542  94.4%  PoseidonGame       ← main thread, pegged on one core
105900   0.6%  Poseidon:gdrv0     ← GPU driver thread, idle
```

Main thread saturates a single core at 4.4 GHz; the GPU is idle. The engine
does per-vertex character/vehicle animation on the CPU, single-threaded — a
property of the 2001 Poseidon design. Both the menu and missions render live
animated scenes, so the cost is always paid.

`pmcstat -S ls_not_halted_cyc` (8 s, whole system, annotated with
`pmcstat -R ... -G`) puts the game's self-time in:

```
Object::AnimateGeometry
  → Man::Animate
    → AnimationRT::ApplyMatrices / ApplyMatricesSimple
      → Vector3P::SetMultiply(Matrix4P) / SetMultiply(Matrix3P)
        → Vector3P::operator[], X(), Y(), Z(), Get(), Matrix3P/4P::Get
```

No single function dominates (top self-time `Vector3P::operator[]` at
2.75%); it is death-by-a-thousand tiny scalar math calls in the per-vertex
inner loop.

### 2. The binary is unoptimized and validation-heavy

The installed file is the package, unstripped, 213 MB:

```
$ pkg which /usr/local/bin/PoseidonGame
… installed by package CWR-CE-3.01_3
$ ls -l /usr/local/bin/PoseidonGame
-r-xr-xr-x  … 213774072 … PoseidonGame   (unstripped, with debug_info)
```

`Vector3P::X() const` — source is `return _e[0];` — disassembles to ~60
instructions:

```
push %rbp; mov %rsp,%rbp; sub $0x90,%rsp        ; full frame, O0
mov  __stack_chk_guard, -0x8(%rbp)              ; stack canary
mov  %rdi,-0x50(%rbp); mov -0x50(%rbp),%rax     ; spill+reload arg = O0
movss (%rax),%xmm0                              ; the actual load
movss <const>,%xmm1; ucomiss; jne/jp  → …       ; per-read NaN check
  callq LogDetail::Get; memset; spdlog::source_loc;
  fmt::basic_string_view …                      ; NaN → full spdlog message
```

`operator[](int) const` is identical in shape. Every coordinate read in the
skinning loop pays: a stack frame, a canary load, and a NaN-validation
branch. That is a **debug build with math validation**, not the
`-O2 -DNDEBUG` Release the port asks for.

### 3. Confirmed cause: the package was built with a global `WITH_DEBUG`

The build log (`~/CWR-CE-3.01_4.log`) env dump is decisive:

```
line 88:  CFLAGS="-pipe  -g -fstack-protector-strong …"   ← no -O*, -g added
          CXXFLAGS="-pipe -g -fstack-protector-strong …"
          DONTSTRIP=yes  MK_DEBUG_FILES=no                 ← binary not stripped
line 122: WITH_DEBUG=yes
line 125: WITH_DEBUG_PORTS="games/CWR-CE"
```

A global `WITH_DEBUG` was set on the builder. FreeBSD's `bsd.port.mk` does
`CFLAGS:= ${CFLAGS:N-O*} ${DEBUG_FLAGS}` under `WITH_DEBUG` — it **filters
out every `-O*` flag** and appends `-g`, and sets `DONTSTRIP=yes`. So:

- All 665 C++ compiles ran at clang's default `-O0` (verified: `grep -c`
  for `-O2` over the log = 0).
- `CMAKE_BUILD_TYPE` stayed `release`, so `-DNDEBUG` survived (asserts that
  key off `NDEBUG` are gone) — but the per-read NaN validation in the math
  accessors is not `NDEBUG`-gated, so it stayed in.
- The binary was left unstripped → 213 MB.

This is not an engine or port-Makefile bug. A clean `make -V CMAKE_ARGS`
(no `WITH_DEBUG` in the environment) shows `-O2 … -DNDEBUG` correctly, and
`make -V CMAKE_BUILD_TYPE` = `Release`. The override was purely the global
`WITH_DEBUG` / `WITH_DEBUG_PORTS="games/CWR-CE"` in the build environment.

Fix: remove `WITH_DEBUG` (done — `/etc/make.conf` and the poudriere
`make.conf` set are now clean), rebuild, reinstall.

> Note: this also corrects DEBUGGING.md, which assumes "the port builds
> RelWithDebInfo". It normally would; this package was a one-off
> `WITH_DEBUG` build. Frames still symbolize because it is unstripped — but
> it is `-O0`, not RelWithDebInfo.

## Contributing engine issues (secondary)

- **`__forceinline` degrades to a hint on clang.** `platform.hpp:43`:
  `#define __forceinline inline`. The hot math (`Math3DP.hpp:135,140,555,566`,
  `Vector3P::operator[]`, `SetMultiply`) is marked `__forceinline`, but on
  clang that is a plain `inline` the optimizer may ignore — and does, given
  the embedded NaN-log path. MSVC honors it, so Windows inlines these away.
  A portable `#define __forceinline inline __attribute__((always_inline))`
  (non-MSVC branch) would let the accessor chain inline and auto-vectorize.
- **The SSE math path is dead code.** `Math3DPK.cpp` is wrapped in
  `#if defined __ICL && defined _PIII` (Intel compiler, Pentium III). It
  compiles to nothing on every modern toolchain — Windows, Linux, FreeBSD
  all run the scalar path.

## Follow-up: profiling the optimized build (2026-07-18)

After the `-O2` rebuild (60 FPS), re-profiled to see the new hot path.
Full data in `perf-data/` (baseline B). Per-thread CPU shifted from
main 94.4% / gdrv0 0.6% (debug) to **main 77.8% / gdrv0 6.6%** — CPU is
still the frame limiter, but far cheaper per frame, and the GPU is finally
doing real work.

New #1 CPU cost (idle-core ACPI noise filtered):

```
9.09%  fegetenv     @ libm.so.5
8.85%  nearbyintf   @ libm.so.5     ~19% combined
1.44%  rintf        @ libm.so.5
```

**Item 3 (now the top lever): `std::nearbyint` is a libm call, not one
instruction.** `Foundation/Common/FltOpts.hpp` routes every float→int
conversion — `toInt`, `toLargeInt`, `to64bInt`, `toIntFloor/Ceil`,
`fastRound`, and `Fixed(float)` — through `std::nearbyint`. Its comment
(`FltOpts.hpp:162`) asserts it "lowers to a single cvtss2si", but the
profile disproves that on clang/FreeBSD: without `-fno-math-errno` /
`-ffast-math`, `nearbyint` must suppress the inexact flag, so clang emits a
real `nearbyintf` call that does `fegetenv` each time. These helpers are
called pervasively (coords, fixed-point, time, per-vertex/per-pixel), so it
dominates. Candidate fixes, cheapest first:
  - Compile the hot TUs (or the whole engine) with `-fno-math-errno`
    (and `-ffp-contract=fast`) so the rounding lowers to `cvtss2si`.
  - Replace the `std::nearbyint` bodies with a direct SSE conversion
    (`_mm_cvtss_si32` / `lrintf` under `FE_TONEAREST`) — one instruction,
    no libm call, and it stops blocking vectorization.

**Items 1 & 2 status — item 1 likely overstated.** A key correction:
`Vector3P`'s accessors carry `PoseidonAssert(_e[i] != FLT_MAX)`, and
`PoseidonAssert` is `#ifdef NDEBUG` → **a no-op in release**
(`DebugLog.hpp:63`). So in the shipped release the accessors are trivial
`return _e[i]` that clang inlines at `-O2` regardless of the
`__forceinline`→`inline` mapping. The earlier evidence that they ran
out-of-line came from `-O0`/`WITH_DEBUG` binaries (asserts on), which is
misleading — **item 1 is probably not a real cost in release.**

### Measured verdict (RelWithDebInfo, symbolized — baseline C)

Built `RelWithDebInfo` (`-O2 -g -DNDEBUG`, 1036/1037 compiles, unstripped,
562 `Vector3P` symbols) and both static-disassembled and live-profiled it.
This is faithful to the shipped release. Data: `perf-data/*relwithdebinfo*`.

- **Item 1 (`__forceinline`→`inline`) — NOT a real cost. No action.**
  `Vector3P::operator[]` and `X()` have **0 out-of-line copies** (fully
  inlined). `SetMultiply` inlines into `AnimationRT::ApplyMatricesSimple`
  (its only `call`s are `VertexTable::SaveOriginalPos/InvalidateBuffer` and
  `Shape::InvalidateNormals` — none to the math). clang inlines the small
  math at `-O2` regardless of the degraded hint. The earlier "out-of-line"
  evidence was a `-O0`/`WITH_DEBUG` artifact.
- **Item 2 (dead SSE `Math3DPK.cpp`) — low value.** `ApplyMatricesSimple`
  already emits packed SIMD (`mulps`/`addps`) from clang's auto-vectorizer,
  mixed with scalar. The only holdout is the scalar `Vector3P::SetFastTransform`
  (1.58% self-time). Reviving the KNI intrinsic would save ~1%; the compiler
  already vectorizes the rest.
- **Item 3 (`std::nearbyint`) — the real and only big lever.** On the
  faithful build, libm float→int rounding is **~28% of samples**:
  `fegetenv 13.3% + nearbyintf 13.0% + rintf 2.0%`. Root: `FltOpts.hpp`
  (`toInt`/`toLargeInt`/`toIntFloor/Ceil`/`fastRound`/`Fixed`). It is also
  called *from* the terrain hot path (grid indexing), so fixing it speeds up
  the Landscape cluster too. Fix: `-fno-math-errno` on the hot TUs, or a
  direct SSE conversion (`_mm_cvtss_si32` / `lrintf`).

**Faithful game-side hot path** (symbolized, idle filtered):
```
 4.10%  Landscape::CheckVisibility        ┐
 1.28%  Landscape::GroundCollision        │ terrain / visibility / collision
 1.09%  Landscape::SurfaceY               │ cluster ≈ 11% (much of it feeds
 1.06%  Landscape::IntersectWithGround    │ toInt → part of the 28% above)
 1.06%  Landscape::RoadSurfaceY           │
 1.01%  Landscape::ObjectCollision        ┘
 2.74%  Foundation::InvSqrt               (normalization; rsqrtss candidate)
 1.59%  AnimationRT::ApplyMatricesSimple  ┐ software skinning ≈ 4.5%
 1.58%  Vector3P::SetFastTransform        │ (scalar — item 2's ~1%)
 1.30%  AnimationRT::ApplyMatricesComplex ┘
```

**Bottom line:** the "two secondary items" are essentially non-issues in the
real release build. The single high-value optimization is `std::nearbyint`
(item 3, ~28%); `Foundation::InvSqrt` (~2.7%) is a distant second. Neither
`always_inline` nor reviving the SSE math path is worth pursuing.

### Fix applied: `std::nearbyint` → `cvtss2si` (branch `fltopts-nearbyint-cvtss2si`)

Routed `FltOpts.hpp`'s float→int helpers through a `fastRoundToInt()` that
uses `cvtss2si` (SSE2 baseline; round-to-nearest via MXCSR = the documented
x86 default) instead of `std::nearbyint`. Cross-toolchain: verified clang 21
and gcc 14 both emit `callq nearbyint` for the old code and a single
`cvtss2si` for the new (helps Windows/Linux/FreeBSD equally). Built via
poudriere RelWithDebInfo (same faithful config as baseline C).

**Binary check (installed package):**
```
$ objdump -d /usr/local/bin/PoseidonGame | grep -c nearbyint   # was pervasive
0
$ objdump -d .../PoseidonGame | grep -c cvtss2si
1397
```
`toInt`/`toLargeInt` inline away into their callers; not a single
`nearbyintf` call remains in the binary.

**Re-profile (baseline D, faithful symbolized, same scene class):**

| metric | before (baseline C) | after fix (D) |
|--------|---------------------|---------------|
| libm rounding (`fegetenv`+`nearbyintf`+`rintf`) | **~28%** | **0** (absent) |
| main-thread CPU @ vsync-locked 60 FPS | 77.8% | **60.5%** |

Same 60 FPS, but the frame is ~22% cheaper on the main thread. Real
headroom recovered (higher uncapped FPS, more budget for detail/units). The
game-side hot path is unchanged in shape but now dominates its own smaller
total: `Landscape::CheckVisibility 7.6%`, `ApplyMatricesSimple 4.3%`,
`Foundation::InvSqrt 4.3%` (next lever, `rsqrtss`), then the
terrain/collision cluster. Data: `perf-data/pmc-nearbyint-fixed-*`.

### Fix applied: `InvSqrt` table lookup → `rsqrtss` (branch `invsqrt-rsqrtss`)

`InvSqrt` used a Graphics Gems table approximation. An SSE `rsqrtss` +
Newton-step version already existed in `MathOpt.cpp` but was dead code behind
the `_KNI` (Pentium III) macro, and that dead path did not even compile: its
`namespace Poseidon::Foundation {` open sat inside the `#ifndef` table branch,
so activating it left `InvSqrt` in the global namespace with an unmatched
brace. Fix: hoist the namespace open above the `#ifndef` and gate the SSE path
on x86 (`__x86_64__`/`_M_X64`/...). Verified clang and gcc emit `rsqrtss`;
`InvSqrt` in the binary is now `rsqrtss` + one Newton step, no table load.

**Re-profile (baseline E, nearbyint + invsqrt):**
- `InvSqrt` dropped from a top-3 function (~4.3% in D) to **~0.65% of total
  CPU** (~1.2% of game CPU), out of the hot top-12.
- Main-thread CPU: **58.7%** vs 60.5% (D).

Honest caveat: the 60.5% → 58.7% delta is small and within scene-to-scene
noise (this was a fresh session, not a byte-identical scene). `InvSqrt` was
only ~4% to start, and `rsqrtss` vs a warm-L1 table lookup is a modest
per-call gain. This is a clean, portable micro-optimization (removes a lookup
table, fixes never-compilable dead code) worth keeping, but not a visible-FPS
win on its own, unlike nearbyint. Data: `perf-data/pmc-nearbyint+invsqrt-*`.

## Fix / next steps

1. **Rebuild without `WITH_DEBUG` and reinstall.** Cause confirmed above.
   With `WITH_DEBUG` cleared:
   ```
   sudo rm -f /usr/local/poudriere/data/packages/builder-official/.latest/All/CWR-CE-3.01*.pkg
   sudo poudriere bulk -j builder -p official games/CWR-CE
   # then ship + pkg add -f the new .pkg
   ```
   Verify the new binary is optimized: `Vector3P::X()` must be ~2
   instructions (`movss (%rdi),%xmm0; ret`), no canary, no NaN branch:
   ```
   objdump -d -C /usr/local/bin/PoseidonGame | \
     awk '/<Poseidon::Foundation::Vector3P::X\(\) const>:/{f=1} f{print} f&&/ret/{exit}'
   ```
   Expect a large FPS jump once this holds.
2. **Fix `__forceinline` for clang** (`platform.hpp:43`) — one-line,
   portable, benefits Linux and FreeBSD. Good upstream PR candidate,
   matches the engine-fix branch pattern in README.
3. Optionally raise `frameRate` in `UserInfo.cfg` (already set to 60 here)
   so the auto-detail balancer targets a higher band once the CPU path is
   fast enough to reach it.

## Config change already applied

- `~/.config/CWR/Users/olivier/UserInfo.cfg`: `frameRate` 15 → 60. Correct,
  but not sufficient on its own — the CPU path cannot reach the new band
  until the build is optimized. `vsync=1` left as-is (clean 60 lock once
  the frame budget allows it).

## Repro / diagnostic commands

```
# 1. Confirm GPU vs software + settings (run in the X session)
DISPLAY=:0 sudo XAUTHORITY=/var/run/slim.auth glxinfo | grep -i "OpenGL renderer"

# 2. Confirm single-thread CPU-bound (game running)
ps -H -o lwp,pcpu,time,comm -p $(pgrep -x PoseidonGame) | sort -k2 -rn | head

# 3. Profile the hot path
sudo pmcstat -S ls_not_halted_cyc -O /tmp/pmc.out sleep 8
pmcstat -R /tmp/pmc.out -G /tmp/pmc.graph
grep -E "^[0-9]+\.[0-9]+%.*PoseidonGame" /tmp/pmc.graph | head

# 4. Prove the build is unoptimized
objdump -d -C /usr/local/bin/PoseidonGame | \
  awk '/<Poseidon::Foundation::Vector3P::X\(\) const>:/{f=1} f{print} f&&/ret/{exit}'
```
