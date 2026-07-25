# CONTINUE — next CWR-CE session

Paste the **Prompt** block below verbatim into the next Claude session.

Session goal: **decide the next perf lever now that GPU skinning is settled.** The
t420 A/B (2026-07-25) falsified the GPU-skinning FPS thesis on that hardware, so
the remaining candidate is the **Phase-4/5 CPU-side parallelization** — and the
patrol benchmark turns out to be genuinely CPU-bound with GPU headroom, so it now
has a real target. The valgrind determinism triage is still queued but is blocked
(see below) and is a nice-to-have, not the critical path.

---

## Prompt

> Working on CWR-CE performance. Read `~/myscripts/CWR-CE/README.md` (START HERE
> block), then `DEBUGGING.md` (exact `--benchmark` command + "Measuring frame
> rate" + the CLI reference), then `PERF-multithread-scope.md` **to the bottom** —
> especially the two `2026-07-25` sections ("GPU-skinning t420 A/B" and its
> close-combat follow-up) and the `2026-07-22` Phase-4/5 assessment above them.
> Also skim `MISSION-SQM-FORMAT.md` (mission format + the custom test scenes).
> Do this before running anything.
>
> Context to load from the docs, not re-derive:
> - **t420 is ONLINE** (`ssh t420`, 192.168.100.78; i5-2520M 2c/4t + Intel HD
>   3000). It is the CPU-bound validation box. ser6 is present/vsync-bound
>   (FPS-neutral). ser6's `builder` poudriere jail is ABI-match (`1600019` amd64),
>   so pkgs built on ser6 install on the t420 via `pkg add -f`.
> - Build loop = poudriere from the PUSHED `ocochard/CWR-CE:gpu-skinning` branch
>   (`USE_GITHUB`); port `~/freebsd-ports/games/CWR-CE/Makefile` is in DEV state
>   (`GH_TAGNAME=gpu-skinning`). Engine tip `08e850c`, docs `master` (`git log -1`).
> - **SETTLED — do NOT redo:** GPU skinning is **falsified on the t420** (both
>   scene regimes, 2026-07-25). Distant patrol: skinning idle (units at coarse
>   LOD), main-CPU flat, wash. Close view-LOD (`CloseCombat.Abel`): skinning DOES
>   engage (main-CPU −4 pt) but the scene is **GPU-bound on the HD 3000**, so no
>   FPS. The iGPU is too weak to ever benefit. GPU skinning stays off by default;
>   revisit only on a newer dGPU laptop (CPU-bound WITH GPU headroom). `--mt-lod`
>   is proven net-negative — stays off. Determinism residual = rare (~few-%)
>   Heisenbug, documented, not a blocker.
>
> **Then do the task.** The real remaining lever is the **Phase-4/5 CPU-side
> parallelization** (`PERF-multithread-scope.md` "Recommended sequence" +
> "Findings: what is (and isn't) a clean parallel-for"). The key new data point:
> on the t420 the **patrol benchmark is CPU-bound WITH GPU headroom** — main
> thread ~82%, `gdrv0` ~30% — so unlike the close scene it is NOT GPU-limited, and
> parallelizing the heavy per-object CPU work has somewhere to convert. Start by
> confirming the bound and picking the target from t420's own profile:
> 1. `prof_bench.sh`-style baseline on the t420 patrol scene + `ps -H` to re-confirm
>    main ~82% / gdrv ~30% (the CPU-bound-with-headroom signature).
> 2. `pmcstat` the t420 main thread on the patrol scene to get *its* hotspot
>    ranking (the existing self-time table is from ser6; the t420 may differ), then
>    pick the heaviest determinism-safe loop. The docs' candidates: hoist
>    `Man::Animate` out of `Object::Draw` into a parallel pre-pass (GPU skinning is
>    the enabler, but the CPU coarse-LOD skin remains — that's the target), or the
>    render-side `CheckVisibility`/`OcclusionView`. Avoid the cheap analysis loops
>    (LOD/shadow-LOD) — proven too fine-grained.
> 3. Validate correctness with the determinism gate / serial-verify, measure FPS on
>    the t420 (the only box that can show it).
>
> Confirm you've read the docs by quoting the exact `--benchmark` command line
> back, then start.

---

## State snapshot (2026-07-25)

- **Engine** `ocochard/CWR-CE:gpu-skinning` @ `08e850c` (pushed). No engine change
  this session — the GPU-skinning work was already built; this session only
  measured it on the t420.
- **Docs** `ocochard/myscripts:master` (pushed, tip = GPU-skinning-falsified
  commit). New this session: `MISSION-SQM-FORMAT.md`, `closecombat-mission/`
  (generator + mission + reference PNG + README); updated `PERF-multithread-scope.md`
  (two 2026-07-25 result sections) and `README.md`.
- **t420 install:** the `gpu-skinning` pkg (`CWR-CE-3.01_5`, built on ser6's
  `builder` jail) is now installed on the t420 via `pkg add -f` (it previously had
  a stale stock `3.01-unknown` build). Both `Benchmark.Abel` and `CloseCombat.Abel`
  Test-profile missions are staged on the t420 under
  `~/.config/CWR/Users/Test/Missions/`.
- **Immediate next step:** the Phase-4/5 CPU-parallelization scoping above, driven
  by a fresh t420 pmcstat profile.

### Blocked / open

- **`--simulate` hangs headless in this environment (observed 2026-07-25).** Both
  a custom mission AND the stock `Benchmark.Abel` stage the mission then hang at
  load under `--render dummy --simulate` on ser6 — contradicts the docs' claim
  that `08e850c` made `--simulate` run headless (verified 2026-07-22). Either a
  regression or environmental. **This blocks the valgrind determinism triage**,
  which needs `--simulate` to reach the sim loop. Recheck / re-fix `--simulate`
  before attempting that triage; `--check` still works but only reaches the boot
  path. (The engine also logs **no GPU-skinning activation line** — an
  observability gap; add one if you touch that path.)
- **valgrind `--track-origins` determinism triage** — still queued (the 208
  uninit errors), still a nice-to-have for airtight MP determinism, NOT the
  critical path. Blocked on `--simulate` above. Command + rationale preserved in
  `PERF-multithread-scope.md` → "Update (2026-07-22) — valgrind is UNBLOCKED".
- **Backlog (not now):** no-mimalloc rebuild for heap-aware memcheck + helgrind;
  revert the port to stock upstream only after PR #51 + the branch stack lands.
