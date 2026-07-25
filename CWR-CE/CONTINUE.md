# CONTINUE — next CWR-CE session

Paste the **Prompt** block below verbatim into the next Claude session.

State as of 2026-07-25: **the CPU-perf thread is tapped out on the available
hardware.** GPU skinning is falsified on the t420 (both scene regimes) and
Phase-4/5 CPU parallelization is SHELVED after the t420 profile showed a ~10%
frame-time ceiling for a high-risk restructure against a ~45%-GPU-driver-bound
frame. There is no queued perf task. The remaining open items are the determinism
close-out (blocked) and the upstream PR work — pick one, or bring a new goal.

---

## Prompt

> Working on CWR-CE. Read `~/myscripts/CWR-CE/README.md` (START HERE block), then
> the doc for whatever thread you pick below. For any perf question, read
> `PERF-multithread-scope.md` to the bottom (the `2026-07-25` sections + the
> "Phase-4/5 — SHELVED" close-out) and `PERF-hotspot-profile.md` → "t420 profile
> (2026-07-25)" FIRST — the CPU-perf lever is already characterized and closed;
> do not re-open it without new hardware.
>
> Context to load from the docs, not re-derive:
> - Engine tip `d7b13f2` on `ocochard/CWR-CE:gpu-skinning` (pushed); docs
>   `master` (`git log -1`). Port in DEV state (`GH_TAGNAME=gpu-skinning`).
> - **t420 is ONLINE** (`ssh t420`, i5-2520M + Intel HD 3000) and now runs the
>   `gpu-skinning` pkg; `Benchmark.Abel` + `CloseCombat.Abel` Test missions are
>   staged on it. ser6's `builder` jail is ABI-match (`1600019`) so ser6-built
>   pkgs `pkg add -f` onto the t420. `hwpmc` is loaded on the t420; the cycle
>   event is `cpu_clk_unhalted.thread_p`; PoseidonGame is a **native FreeBSD ELF**
>   (no linuxlator) and **not stripped**, so pmcstat/gprof resolve its frames.
> - **SETTLED — do NOT redo:** (1) GPU skinning falsified on the t420 — wash in
>   both regimes (distant patrol = skinning idle at coarse LOD; close view-LOD =
>   GPU-bound on the HD 3000). Stays off by default. (2) Phase-4/5 SHELVED — t420
>   frame is only ~35% Poseidon compute (~45%+ is serial Mesa/i915 GL-submission);
>   parallelizable work ≈ 9% → ~10% ceiling, not worth the restructure. (3)
>   `--mt-lod` net-negative — off. (4) Determinism residual = rare (~few-%)
>   Heisenbug, documented.
>
> **Then pick a task** (there is no default queued one — ask the user if unstated):
> 1. **Determinism close-out** — the valgrind triage is **DONE, and the
>    heap-aware pass FOUND A REAL BUG** (2026-07-25, see
>    `PERF-multithread-scope.md` → "Triage result" + "Heap-aware pass"). Stack
>    triage: 0 sim-relevant. Heap-aware pass (mimalloc rebuilt `MI_TRACK_VALGRIND`)
>    found **`Head` soldier-face `_*RandomLip` fields read uninitialised every sim
>    tick**, spuriously firing `NextRandomLip()`→`GRandGen.RandomValue()` and
>    desyncing the shared RNG — a **prime suspect for the rare determinism-gate
>    divergence.** Fixed (+ a `Tank::_doGearSound` uninit) on branch
>    **`ocochard/CWR-CE:valgrind-uninit-fixes`**; verified the contexts disappear.
>    **Next:** re-run the determinism gate (`--determinism-log`, many runs) with
>    the Head fix to confirm the ~few-% divergence is gone; then merge the branch
>    into `gpu-skinning` and submit upstream. (Helgrind for a race is only needed
>    if divergence persists after this.)
> 2. **Upstream PR work** — PR #51 (freebsd portability) is gated at
>    `action_required`; the engine-fix branches (`PR-*.md`) and GOG-pr are queued
>    behind it. Chase the CI gate / prep the next submission.
> 3. A new goal the user brings.
>
> Confirm you've read the docs by quoting the exact `--benchmark` command line
> back, then start on the chosen task.

---

## State snapshot (2026-07-25)

- **No engine change this session.** Work was measurement + docs only.
- **Docs** `ocochard/myscripts:master` (pushed). This session added the t420
  measurements and closed two threads:
  - `PERF-multithread-scope.md` — GPU-skinning t420 A/B (both regimes) +
    "Phase-4/5 — SHELVED" close-out.
  - `PERF-hotspot-profile.md` — "t420 profile (2026-07-25)": the CPU-bound box's
    own hotspot ranking (disagrees with ser6; `ApplyMatricesComplex` #1) + the
    ~35% Poseidon / ~45% GPU-driver frame-time split.
  - `MISSION-SQM-FORMAT.md` + `closecombat-mission/` — the sqm format doc and the
    view-LOD stress scene built for the GPU-skinning fair-shot test.
- **Perf verdict:** the CPU lever is exhausted on available hardware. Real further
  FPS on the t420 would require attacking the ~45% Mesa/i915 GL-submission cost
  (driver/GPU territory, not Poseidon), or newer hardware. Neither is queued.
- **Nothing pending.** Next session starts from a task choice above, not a
  handoff mid-flight.

### Open / blocked (not on any critical path)

- `--simulate` "hang" — RESOLVED 2026-07-25 (wrong binary + wrong path form, not
  a regression; use `PoseidonServer --simulate <mission-DIR>`). UX bug FIXED
  (`d7b13f2`): standalone `PoseidonGame --simulate` now errors + exits 1;
  `--check --simulate` smoke check still works.
- Valgrind determinism triage — DONE 2026-07-25 (0 sim-relevant; residual is
  heap-class). Only the no-mimalloc heap-aware rebuild remains (backlog below).
- Backlog: no-mimalloc rebuild for heap-aware memcheck + helgrind (only if
  airtight MP determinism becomes a hard requirement); revert the port to stock
  upstream after PR #51 + the branch stack land.
