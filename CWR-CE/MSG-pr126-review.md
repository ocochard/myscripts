# PR #126 review — measured on FreeBSD (GL33, CPU-side render cost)

PR: https://github.com/ofpisnotdead-com/CWR-CE/pull/126 ("enable instanced terrain
rendering by default" + GL33 draw-path batching, tip `3a7a170`).

Measured it **isolated from any other renderer change** (no GPU-skinning): PR #126 on
top of only the minimum FreeBSD portability patch, versus the same baseline without it.

- **BEFORE** = `main` + FreeBSD/POSIX portability only → `ocochard/CWR-CE@main-freebsd`
- **AFTER**  = BEFORE + PR #126 → `ocochard/CWR-CE@pr126-freebsd`

The portability commit touches 11 files (build/POSIX shims) with **zero overlap** with any
file PR #126 changes, so the A/B delta is PR #126 and nothing else.

## Method

- Two scenes, both Malden @ **view distance 5000 m**, vsync off, to bracket the effect by
  how render-bound the frame is:
  - **sim-bound** — `load.Demo` (**259 vehicles / 333 units**, AI actively fighting);
  - **render-bound** — one player unit, no AI (`RenderBound.Abel`), so the frame is almost
    entirely terrain + static-object drawing.
- AMD Ryzen 7 7735HS + Radeon 680M, FreeBSD 16-CURRENT, GL33 backend.
- Build: `RelWithDebInfo` (`-O2 -DNDEBUG`, unstripped) — identical codegen to Release but
  symbolizable. Verified `NDEBUG` on (no assert branches in the binary).
- FPS: engine `--benchmark`, 3000-frame flythrough, steady-state avg FPS. n=4 BEFORE / n=3
  AFTER (BEFORE stable warm; AFTER warms 36.3→39.4 as textures cache — means used).
- Profile: `pmcstat -S ls_not_halted_cyc` (CPU cycles), 20 s steady-state window, samples
  attributed to the `PoseidonGame` image, self-samples normalized **per rendered frame**.

## Result — FPS (the effect is entirely about how render-bound the scene is)

| Scene | BEFORE (no #126) | AFTER (#126) | Δ |
|---|---|---|---|
| sim-bound (`load.Demo`, 259 vehicles) | 32.8 | 37.8 | **+15%** |
| render-bound (1 unit, 5 km VD) | 113.5 | **367.6** | **+224% (3.2×)** |

Same build, same view distance — the only difference is whether AI sim or rendering owns the
frame. PR #126 cuts render CPU by the same mechanism in both (below); on the sim-bound scene
Amdahl caps the FPS gain at +15%, on the render-bound scene it lands the full **3.2×**. This
is the PR's "24→160 at 5 km" claim reproduced on FreeBSD.

## Result — where the CPU went (per-frame self-samples, `load.Demo`)

| Function | BEFORE | AFTER | Δ |
|---|---|---|---|
| `Landscape::DrawGround` (CPU terrain draw) | 83.4 | 6.4 | **−92%** |
| `Shape::Draw` | 13.2 | 5.1 | **−62%** |
| `Scene::ObjectForDrawing` | 12.9 | 11.4 | −11% |
| `VertexBufferGL33` | 13.8 | 12.7 | −8% |
| `DrawObjectsAndShadowsPass1` + its sort* | 34.6 | 23.2 | **−33%** |
| **Net render path** | **193** | **110** | **−43%** |

\* `DrawObjectsAndShadowsPass1` self-time alone reads +100% (11.6→23.2), but that is an
attribution shift, not a regression: PR #126 replaces the draw-list `QSort`+comparators
(`CmpShapeObj`/`CmpRevDistObj`, 23/frame in **separate** leaves) with inlined bucket/radix
sorts (`BucketDrawMergersByShape`/`RadixSortRefListByFloatDesc`). `QSort` drops 43551→40
samples; that cost moves *into* the function's self-time, and the cheaper sort makes the
combined figure fall 33%.

Noise floor (sim functions PR #126 doesn't touch — `FindPath`, `LockPosition`,
`AddNewTargets`, `Simulate`) drifts ±13% run-to-run from AI non-determinism, so treat
anything under ~15% as flat. `DrawGround −92%`, `Shape::Draw −62%`, and net render `−43%`
are all well above it.

## Reading

- **The instanced terrain change is the win.** `DrawGround` — the per-tile CPU terrain
  submission — essentially disappears (−92% on `load.Demo`, −97% on the render-bound scene).
  It's the bulk of the render-CPU drop and behaves the same regardless of scene.
- The draw restructure **shifts** some cost: `DrawObjectsAndShadowsPass1` self-time rises only
  because the draw-list sort moved inside it (see note above); the combined figure falls.
- **The FPS gain is all about the render fraction.** The render-CPU savings are the same in
  both scenes; what changes is whether that CPU was the bottleneck:
  - `load.Demo` is sim-bound (AI/pathfinding/collision dominate, untouched by #126) → Amdahl
    caps it at **+15%** even though render CPU fell 43%.
  - Render-bound (1 unit, 5 km VD): net render CPU **69→11 samples/frame (−85%)**, and with no
    AI to bottleneck on, FPS goes **113→368 (3.2×)**.

**Bottom line:** confirmed on FreeBSD, isolated from any other renderer change — PR #126 cuts
CPU render cost 43–85% (terrain draw −92 to −97%), for **+15% FPS on a sim-heavy scene and
3.2× on a render-bound one**. No correctness or portability issues surfaced. Recommend merge.
