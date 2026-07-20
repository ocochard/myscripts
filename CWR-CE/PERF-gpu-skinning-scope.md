# GPU skinning — design scope (CWR-CE / Poseidon GL33)

Scope for moving character/vehicle skinning from the CPU to the vertex shader.
This is the highest-leverage rendering change identified by the profiling
campaign: it is the **only** lever that attacks *both* of the two biggest
measured frame-cost buckets at once. Companion to `PERF-hotspot-profile.md`
(measurements) — this doc is the implementation scope, not a repeat of the data.

## Implementation status (2026-07-19)

In progress on branch `ocochard/CWR-CE:gpu-skinning` (based on the freebsd+GOG
tip `8fc693`, the FreeBSD-buildable tree — `main` lacks the portability fixes).
Built via poudriere by repointing the port at the branch (jail `builder`, tree
`default`; the README's `-p official` is stale). Everything below is inert until
the master switch flips: `ENGINE_CONFIG.enableGpuSkinning` (default **off**), so
the live renderer stays byte-identical until items 4+5 land.

- **Item 1 — vertex format: DONE, built.** Corrected from the original plan:
  do **not** extend `SVertex`. Its stride is shared by the global `_vaoMesh`
  streaming VAO (`EngineGL33_2DRendering.cpp:44-48`, reads a TLVertex buffer at
  `sizeof(SVertex)`), so growing it corrupts the 2D/streaming path. Added a
  separate `SSkinnedVertex` (+`SetupSkinnedVertexLayout`, integer bone attribs,
  weight rescaled /128 in the VS) used only by per-shape skinned VBOs.
- **Item 2 — bone bindings + skinned VBO fill: DONE, built.** `SkinVertexBinding`
  (u8×4 idx + u8×4 weight) stored on `VertexTable`, parallel to `_pos`; filled at
  `Skeleton::Prepare` from `AnimationRTWeights[level]`, quantized identically to
  the CPU `ApplyMatrices` path. `VertexBufferGL33` gained a `_skinned` mode
  (`= GpuSkinningEnabled() && Shape::HasSkin()`).
- **Item 3 — retain palette + BonePalette UBO: DONE (build pending).** Palette
  retained per-object on `Man` (`AutoArray<Matrix4> _bonePalette`, filled in
  `Animate` only when the switch is on) and exposed via a new virtual
  `IAnimator::GetBonePalette`. `Shape::Draw` uploads it once per skinned shape
  draw when `VertexBuffer::IsSkinned()`. `s_boneUBO` = `BonePalette{mat4
  bones[128]}` at binding 3, cloned from the `WorldInstances` UBO plumbing.
  `Matrix4` confirmed 64-byte 4×4 (uploaded like the world matrix, no expansion).
- **Item 4 — skinning VS + program selection: DONE (build pending).** `vsSkinned`
  is a standalone clone of `vsTransform` (same UBOs/outs/lit body verbatim, so the
  hot-path shader is untouched) that blends ≤4 bone matrices from the `BonePalette`
  UBO before the world transform; reproduces `ApplyMatricesComplex` exactly (Σw=1
  ⇒ blend-then-transform ≡ transform-then-sum). New `VSSkinned` program row
  (`NVertexShaders` 3→4). Selection: `Engine::SelectSkinnedMesh(bool)` brackets a
  skinned shape's sections in `Shape::Draw`; a `_meshSkinnedActive` flag remaps
  `VSTransform→VSSkinned` at the per-section `ApplyPassState` choke point (survives
  per-section re-selection), shadow pass untouched. Both VS glslang-validated.
- **Item 5 — static bind-pose view mesh + switch wiring: DONE (build pending).**
  Shipped the *safe half* — GPU skinning now renders and the per-frame re-upload
  is gone, with the CPU/sim paths bit-identical:
  - (a) `CopyVertices` uploads `OrigPos`/`OrigNorm` (bind pose; falls back to
    `Pos`/`Norm` if not yet saved) for skinned buffers — the VS re-skins from bind
    pose, so uploading CPU-skinned verts would double-transform.
  - (b) Skin bindings are **opt-in** (`Skeleton::Prepare`/`AnimationRT::Prepare`
    `gpuSkin` flag, passed true only by infantry — the only object retaining a
    palette) and **graphical-LOD-only** (`Resolution < 1000`). Geometry/shadow/
    memory LODs stay CPU (MP determinism; shadow pass never sees the skinned
    stride). Vehicles with skeletal anims (scud, parachute) stay CPU.
  - (c) Skinned VBOs are `GL_STATIC_DRAW`, uploaded once; `Update()` skips the
    per-frame re-copy → removes the dynamic-streaming (~libgallium) cost.
  - (d) CLI `--gpu-skinning` → `ENGINE_CONFIG.enableGpuSkinning`.

- **Item 5b — drop CPU skin for GPU-skinned view LODs: DONE (build pending).** The
  second hotspot bucket. `Man::Animate` skips `AnimationRT::ApplyMatrices` when the
  LOD is GPU-skinned (`shape->HasSkin() && enableGpuSkinning`) — the VBO holds the
  static bind pose and the VS skins from the palette, so the per-vertex CPU
  transform is pure waste. Palette still built/retained. Coarse LODs (no skin
  bindings) still CPU-skin → collision/shadow/bounding bit-identical (determinism).
  With CPU skin skipped, `Pos` stays bind pose → the item-5 `CopyVertices` fallback
  uploads the correct bind pose. Also hardened `Shape::Draw`: a GPU-skinned shape
  with no palette this frame draws its static bind pose through the normal mesh VS
  (skinned VAO locations 0–2 read fine) rather than skinning from a stale shared
  `BonePalette` UBO.
  **Risk to confirm visually:** the view LOD's `Pos` is now bind pose, not
  CPU-skinned — needs a pass to confirm nothing sync-uncritical reads it (muzzle /
  attach points). The doc's determinism analysis says only coarse LODs feed those.

- **Still deferred (item 5e):** vehicle/prop palette retention — replicate the `Man`
  `GetBonePalette` seam on other skinned proxies before enabling their GPU skinning.

## Benchmark A/B (2026-07-20) — FPS-neutral on ser6; CPU cut is profile-proven

Measured with `prof_bench.sh` (this dir): `--benchmark --test-mission
~/.config/CWR/Users/Test/Missions/Benchmark.Abel` (197 units, uncapped), 5 runs
each via `ministat`.

```
        N    Min    Max   Median   Avg    Stddev
base    5   75.2   85.5   77.1    79.94   5.03
gpu     5   67.5   80.5   76.5    75.40   4.79
No difference proven at 95.0% confidence
```

**Verdict: no significant FPS difference.** Same outcome, and same reason, as the
CPU-opt campaign (see `PERF-hotspot-profile.md`): the frame is bound by a
per-frame cost off the animation critical path (terrain/present), so a real
CPU-work reduction does not move FPS on this scene/hardware.

- **Profile (the acceptance evidence):** `AnimationRT::ApplyMatricesComplex` =
  **6.75%** of frame CPU (3875 samples, 100% from `Man::Animate`) in baseline,
  **0** with `--gpu-skinning`. The CPU skin of the view LOD is provably removed
  (plus the per-frame view-mesh re-upload). This is the win; FPS just can't show
  it here.
- **Optimization passes** (both landed): (1) no per-frame palette `Realloc` +
  orphaned `BonePalette` UBO; (2) batched the `VSTransform↔VSSkinned` program
  switch across consecutive skinned draws (~394/frame → ~2). Neither moved FPS
  out of the noise — expected, since FPS was never the bound.

**Where it would pay off:** a genuinely animation-CPU-bound config (t420 ~20 FPS)
or a present-bound one where the removed re-upload lowers the present ceiling.
On ser6 it is correct and CPU-lighter but FPS-neutral. Lands **off by default**
(`--gpu-skinning` / `ENGINE_CONFIG.enableGpuSkinning`); judge by the profile, per
the campaign's own rule. Visual A/B: soldiers skin correctly; non-skinned meshes
(terrain, trees, tanks) unaffected by the batched program-switch.

## Why (the two buckets it hits)

From the full-frame `--benchmark` profile (see `PERF-hotspot-profile.md`,
"Full-frame breakdown" + "View-skinning bone-run structure"):

- **~7% CPU** in `AnimationRT::ApplyMatricesComplex` — software skinning, run per
  drawn unit per frame. 91.4% of vertices are single-bone; palette is ~25 bones.
- **~25% Mesa** (`libgallium`) — NOT draw-call submission (only ~20 draws/frame,
  per `--render-frame-log`), but **dynamic vertex streaming**: skinned meshes are
  re-uploaded to their GL buffers every frame because the CPU rewrites their
  positions each frame.

GPU skinning removes the CPU skin of the view mesh **and** makes that mesh's
vertex buffer static (bind-pose uploaded once), eliminating the per-frame
re-upload. No other single change touches both buckets.

## Current architecture (CPU transform-and-light)

The engine is a 2001-era CPU T&L pipeline for geometry, but — critically —
**lighting already runs in the vertex shader**, which is what makes this
tractable. The GL33 backend lives in `engine/PoseidonGL33/` (a sibling module to
`engine/Poseidon/Graphics`).

### Skinning (CPU, today)
- `AnimationRT::ApplyMatrices` (`World/Simulation/Animation/RtAnimation.cpp:998`)
  dispatches on `AnimationRTWeights::IsSimple()` to `ApplyMatricesSimple` (`:958`,
  single-bone) or `ApplyMatricesComplex` (`:863`, ≤4-bone weighted). Both write
  `shape->SetPos(i) = mat*pos; shape->SetNorm(i) = mat.Orientation()*norm`
  (`:977-978` / `:918-919`), then `InvalidateBuffer()`.
- The bone-matrix palette (`Matrix4Array`, `RtAnimation.hpp:156`) is built
  per-frame in `Man::Animate` (`World/Entities/Infantry/SoldierOldSimProxy.cpp:939`):
  a stack array `MATRIX_4_ARRAY(matrix,128)` (`:956`), filled by
  `PrepareMatrices` (`:963,971`, sized to skeleton bone count ~25), consumed by
  `ApplyMatrices` (`:1007`), then **discarded before draw**.
- Per-vertex weights: `AnimationRTPair{char _sel; unsigned char _weight}`
  (`RtAnimation.hpp:9`, `WeightScale=128`), grouped in `AnimationRTWeight`
  (`VerySmallArray`, ≤4 bones/vertex). Built **once at model load** via
  `AnimationRTWeights::AddSelection` (`RtAnimation.cpp:120`) — i.e. **static per
  model/LOD**; only the matrices change per frame.

### Upload + draw (GL33)
- Vertex struct `SVertex{ Vector3P pos; Vector3P norm; UVPair t0; }`
  (`PoseidonGL33/EngineGL33.hpp:199`) — interleaved pos/norm/uv, **no color**
  (color is computed in the VS). One VAO+VBO+IBO per `Shape`.
- Attribute layout `SetupSVertexLayout()` (`PoseidonGL33/GLVertexAttribLayouts.hpp:61`)
  — locations 0/1/2 = pos/norm/uv.
- `VertexBufferGL33::CopyVertices` (`PoseidonGL33/EngineGL33_VertexBuffer.cpp:72`,
  fill at `:93-106`, note normals negated `:100`) reads `Shape::Pos/Norm/UV` into
  the VBO. `Update()` (`:209`) re-copies whenever `_dynamic || bufferDirty`;
  `bufferDirty` is set by `VertexTable::InvalidateBuffer` (`Graphics/Rendering/
  Primitives/Vertex.cpp:405`). **This is the per-frame skinned re-upload.**
- Draw: `Shape::Draw` (`Graphics/Rendering/Shape/ShapeDraw.cpp:78`) →
  `PrepareMeshTL` (`:93`, uploads the object world matrix) → `BeginMeshTL` (`:109`
  → `VertexBuffer->Update`, the re-upload) → `DrawSectionTL` (`:159,177`) →
  `EngineGL33::EmitDraw` (`EngineGL33_VertexBuffer.cpp:301`) → `glDrawElements`
  (`:343`) / `glDrawElementsInstanced` (`:338`).
- Vertex shader `s_vsTransformGLSL` (`PoseidonGL33/EngineGL33_Shaders.cpp:73`):
  in-attrs pos/norm/uv (`:108-110`); UBOs `VSConstants` (proj/view/world + lights,
  `:74`) and `WorldInstances{ mat4 worldArr[256] }` (binding 2, `:104`);
  `gl_Position = proj*view*worldArr[gl_InstanceID]*vec4(pos,1)` (`:120-123`);
  lighting computed in-shader. Compile plumbing: `CompileGLShader` (`:730`),
  `LinkGLProgram` (`:753`), `InitVertexShaders` (`:824`); UBO upload template
  `UploadWorldInstances`/`s_worldUBO` (`:840-843, 1085`). Live override via
  `--shader-override-dir` → `TryLoadShaderOverride` (`:715`).

## Design

The change is: **skin in the VS; keep bind-pose geometry static; send the bone
palette as a UBO.** Lighting stays exactly where it is (VS), so we only insert a
skin step ahead of the existing transform.

### Work items

1. **Vertex format — add bone attributes.** (Superseded — see Implementation
   status: use a *separate* `SSkinnedVertex`, not an extension of `SVertex`,
   because `_vaoMesh` shares the `SVertex` stride.) Bone attributes at loc 3/4,
   read as *integer* attribs (weight rescaled /128 in the VS, not GL-normalized).
   The `AnimationRTPair{char sel; u8 weight}` format maps 1:1.

2. **Fill bone attributes (static).** In `VertexBufferGL33::CopyVertices`
   (`EngineGL33_VertexBuffer.cpp:93`), populate boneIdx/weight from the shape's
   `AnimationRTWeights`. Because weights are static per model, this part of the
   VBO uploads **once** (`GL_STATIC_DRAW`). Requires plumbing the weights to the
   buffer fill (they are not connected to `VertexBufferGL33` today).

3. **Retain + upload the palette (dynamic, tiny).** Retain the per-frame bone
   palette (currently stack-local in `Man::Animate`, `SoldierOldSimProxy.cpp:939`)
   on the object, and plumb it through `Shape::Draw → PrepareMeshTL → EmitDraw`.
   Upload as a new `BonePalette{ mat4 bones[128] }` UBO — clone the existing
   `WorldInstances` UBO plumbing (`EngineGL33_Shaders.cpp:840`). ~25 mats × 64 B ≈
   1.6 KB per skinned object per frame — negligible vs the mesh re-upload it
   replaces.

4. **Skinning VS variant.** Add `s_vsSkinnedGLSL` (or a `#define SKINNED` branch of
   `s_vsTransformGLSL`): fetch bones from the UBO, compute
   `skinnedPos = Σ boneWeightᵢ · bones[boneIdxᵢ] · pos` (and the normal via the
   upper 3×3), then feed the **existing** transform+lighting unchanged. Select the
   program by the shape's "animated" flag (`matSource->GetAnimated`, already read
   at `ShapeDraw.cpp:108`).

5. **Make the view mesh static.** Stop CPU-skinning the **view LOD** for drawing:
   keep bind-pose positions in the VBO and do not set `bufferDirty` per frame for
   it. This is where the CPU-skin removal and the re-upload removal both land.

### Constraints / catches (the real scope risk)

- **CPU skinning cannot be deleted outright.** Collision (`Object::Intersect`),
  projected/shadow-map casters (`PrepareShadow → Animate`), bounding boxes, and
  occlusion all read CPU-skinned `Shape` positions. But they use **coarser LODs**
  (geometry LOD, shadow LOD) than the vertex-heavy **view LOD** that dominates the
  draw upload. Plan: GPU-skin the *view LOD draw* only; leave the coarse
  collision/shadow LODs on the existing CPU path. Result: the biggest mesh stops
  CPU-skinning and re-uploading, while collision stays **bit-identical CPU** — so
  **MP determinism is unaffected** (the sync-critical path never changes).
- **Palette lifetime.** The retained palette must be valid across
  `Animate → Draw → Deanimate` (ordering already established in `Object.cpp`); a
  per-object retained `Matrix4Array` covers it. Must handle objects animated but
  not drawn, and drawn across multiple passes.
- **Coverage.** Vehicles and animated props use the same `ApplyMatrices` path, so
  they come along automatically — but need visual verification (turrets, flags,
  destruction morph, LOD transitions, the `wsize>1` weighted joints).
- **Bind-pose source.** The VBO must hold the *original* (pre-skin) positions.
  `Shape::SaveOriginalPos`/`OrigPos` already exists (used by `ApplyMatrices`), so
  the bind pose is available to upload once.
- **Weight edge cases.** `_isSimple` shapes (all single-bone) vs complex; the
  ≤4-bone cap already matches a `u8vec4` attribute; verify no shape exceeds it.

## Effort & payoff

- **Effort:** a real but well-bounded renderer feature — roughly **1–2 weeks** for
  someone comfortable in the `PoseidonGL33` module. Fiddliest parts: the
  vertex-format/weight plumbing (item 2) and palette lifetime (item 3), both with
  existing templates to copy (`SVertex` layout, `WorldInstances` UBO).
- **Payoff:** removes most of the ~7% CPU view-skinning **and** the per-frame
  view-mesh re-upload (a large share of the ~25% Mesa dynamic-streaming). On the
  CPU-bound t420 that is direct FPS; on the present-bound ser6 it lowers the
  upload/present ceiling. Unlike the four levers the campaign killed, the profile
  predicts a real gain on **both** hotspot buckets.

## Validation plan

- **Visual A/B**: same scene, CPU-skin vs GPU-skin build — soldiers/vehicles at
  several distances (LOD switches), aiming/leg blends, destruction, shadows.
- **Profile A/B** (the campaign's harness, `PERF-hotspot-profile.md`): confirm
  `ApplyMatricesComplex` drops and the `libgallium` share drops; capture with the
  `--benchmark --test-mission` + log-gated pmcstat method.
- **Determinism gate**: collision path unchanged → MP sync + replays must be
  bit-identical (they never leave the CPU path).
- **Draw-count sanity**: `--render-frame-log` unchanged (~20 draws/frame; this is
  a per-vertex-cost change, not a draw-count change).

## Open questions

- Does any skinned shape exceed 128 bones (UBO size) or 4 weights/vertex? (Expect
  no — palette measured at ~25, weights capped at 4.)
- Are there skinned meshes drawn via the **software** `FaceArray::Draw`
  (`ClipShape.cpp:202/443`, OnSurface/no-buffer) path rather than the HWTL mesh
  path? Those would keep CPU skinning; quantify how many.
- Non-uniform scale in the world/bone matrices → normal matrix handling (use the
  upper 3×3, or an inverse-transpose if any bone carries non-uniform scale).
