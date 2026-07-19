# GPU skinning — design scope (CWR-CE / Poseidon GL33)

Scope for moving character/vehicle skinning from the CPU to the vertex shader.
This is the highest-leverage rendering change identified by the profiling
campaign: it is the **only** lever that attacks *both* of the two biggest
measured frame-cost buckets at once. Companion to `PERF-hotspot-profile.md`
(measurements) — this doc is the implementation scope, not a repeat of the data.

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

1. **Vertex format — add bone attributes.** Extend `SVertex` with
   `u8vec4 boneIdx` (loc 3) and `u8vec4 boneWeight` (loc 4, normalized) — +8 B/vtx.
   Wire in `SetupSVertexLayout` (`GLVertexAttribLayouts.hpp:61`). The
   `AnimationRTPair{char sel; u8 weight}` format maps 1:1.

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
