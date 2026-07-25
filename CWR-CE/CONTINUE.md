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
> 1. **Determinism close-out** — valgrind triage DONE; heap-aware pass found + fixed
>    a real uninit→RNG bug (`Head` `_*RandomLip`, + `Tank::_doGearSound`) on branch
>    **`ocochard/CWR-CE:valgrind-uninit-fixes`** (valgrind-verified gone). **BUT the
>    determinism gate did NOT confirm closure** (2026-07-25, `PERF-multithread-scope.md`
>    → "Gate result" + "Contention batch"): fixed clean 0/23, buggy clean 0/23,
>    buggy under CPU-burner contention 0/23, only **1 divergence in ~95 runs**
>    (fixed, tick 312, during a poudriere build) — matches the historical ~1% rate.
>    CPU contention did NOT reproduce it; the client sim-tick wall-clock hunt found
>    nothing (all `GlobalTickCount` uses benign/gated). **Key caveat: the gate ran
>    on `PoseidonServer --simulate`, but the residual was characterized on
>    `PoseidonGame --benchmark` (CLIENT). The server driver has its own
>    `GlobalTickCount` coupling, so the server gate is the WRONG vehicle** — the
>    1/95 may be a server artifact. **Next:** run `PoseidonGame --benchmark
>    --determinism-log` (client, needs DISPLAY) in a **100+**-run batch (the ~1%
>    rate needs it); that's the only valid gate. Separately: merge
>    `valgrind-uninit-fixes` → `gpu-skinning` + submit upstream (strict improvements
>    regardless). NOTE: installed binary is currently `gpu-skinning` (no fix —
>    poudriere overwrote the fix pkg during the A/B); rebuild/merge to run the fixes.
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
