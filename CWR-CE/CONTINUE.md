# CONTINUE — next CWR-CE session

Paste the **Prompt** block below verbatim into the next Claude session.

Session goal: **continue the valgrind `--track-origins` triage — categorize the
208 uninitialised-value errors into "benign fixed-buffer" vs "real /
sim-state-touching", and fix the real ones.**

---

## Prompt

> Working on CWR-CE performance. Read `~/myscripts/CWR-CE/README.md` — start with
> its **START HERE** block, then `DEBUGGING.md` (exact benchmark command + the
> **"Visual A/B via screenshots"** section + the full **"CLI arguments — full
> reference"**), then `PERF-multithread-scope.md` (the **determinism residual**
> section — read to its bottom, incl. the `2026-07-22` valgrind-unblocked update).
> Do this before running anything.
>
> Context to load from the docs, not re-derive:
> - Host is **ser6** (present/vsync-bound => FPS-neutral here). FPS wins validate
>   on **t420** (CPU-bound) — currently **OFFLINE**.
> - Build loop = **poudriere from the PUSHED `ocochard/CWR-CE:gpu-skinning`
>   branch** (`USE_GITHUB`). The port `~/freebsd-ports/games/CWR-CE/Makefile` is in
>   DEV state (`GH_TAGNAME=gpu-skinning`). To build a local engine change: commit +
>   push to `gpu-skinning`, then **regen distinfo** (`sudo rm` the stale distfile in
>   `/usr/ports/distfiles`, `sudo make makesum DISTDIR=/usr/ports/distfiles`,
>   `sudo chown olivier:wheel distinfo`) then
>   `sudo poudriere bulk -C -j builder -p default games/CWR-CE`, then
>   `sudo pkg add -f` the resulting `.pkg`.
> - Engine tree: `~/CWR-CE`, branch `gpu-skinning` (tip **`08e850c`**). Docs repo
>   `~/myscripts` branch `master` (`git log -1` for the tip). Both fully pushed.
> - **Settled — do NOT redo:** GPU skinning implemented + verified (infantry +
>   item 5e parachute; off by default via `--gpu-skinning`); the viewer is wired
>   for `--viewer --gpu-skinning`; `--simulate` fixed (defaults to the **dummy
>   no-GL backend**, runs headless). `--mt-lod` parallel-for is proven correct but
>   **net-negative — stays off**. **Phase-4/5 sim-side parallelization = DEFERRED**
>   (gated on the offline t420 — see the assessment dated 2026-07-22). The
>   determinism residual is a rare (~few-%) Heisenbug.
>
> **Then do the task:** continue the valgrind determinism triage. Current state
> (see `PERF-multithread-scope.md` → determinism section → `2026-07-22` update):
> valgrind memcheck **now runs headless** (the `--simulate`/dummy fix unblocked it)
> and reports **208 uninitialised-value errors from 66 contexts**. **Run the
> `--track-origins=yes` pass and categorize the 208 into "benign fixed-buffer"
> (the `strcatLtd`/`Bstring.hpp` fixed-buffer over-read class — harmless) vs "real
> / sim-state-touching" (origin feeds a checksummed entity / RNG / AI decision —
> determinism-relevant); fix the real ones.** Caveat: `somalloc=nouserintercepts`
> leaves mimalloc owning `malloc`, so the **heap is not tracked** (blind to uninit
> HEAP reads, the most-likely residual class) — if triage misses it AND airtight
> determinism is wanted, do the no-mimalloc rebuild for heap coverage.
>
> Exact valgrind command (verified 2026-07-22):
> ```
> env -u DISPLAY XDG_RUNTIME_DIR=/tmp/xdg valgrind --tool=memcheck \
>   --soname-synonyms=somalloc=nouserintercepts --track-origins=yes \
>   --error-exitcode=42 --trace-children=no \
>   PoseidonGame -C ~/.local/share/CWR/base --no-sound --render dummy \
>   --simulate ~/.config/CWR/Users/Test/Missions/Benchmark.Abel/mission.sqm \
>   --duration 10 --timeout 180
> ```
> (valgrind runs ~10-50x slower; `--check` instead of `--simulate` is faster for
> boot-path errors, but only `--simulate` reaches the sim loop where the
> determinism-relevant reads live.)
>
> Confirm you've read the docs by quoting the exact `--benchmark` command line
> back, then start the triage.

---

## State snapshot (2026-07-22)

- **Engine** `ocochard/CWR-CE:gpu-skinning` @ `08e850c` (pushed): item 5e parachute
  GPU skinning, viewer `--gpu-skinning` wiring, `--simulate` dummy-backend fix.
- **Docs** `ocochard/myscripts:master` (pushed): all `CWR-CE/*.md` current, incl.
  the valgrind-unblocked update and this file.
- **Visual artifacts** (local, not in git): `~/cwr-5e-visual/` — parachute A/B
  stills + `viewer_canopy_*` + the paradrop missions (also committed under
  `CWR-CE/paradrop-mission/`).
- **Immediate next step:** the valgrind `--track-origins` triage above.
- **Backlog (not now):** close the determinism residual definitively (no-mimalloc
  rebuild + heap-aware memcheck + helgrind); Phase-4/5 parallelization (needs t420
  online); revert the port to stock upstream only after PR #51 + the branch stack
  lands upstream.
