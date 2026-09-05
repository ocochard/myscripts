# Best local model for FreeBSD-source documentation (DaemonDocs) — quality benchmark

**Question:** which locally-hostable model (Aug 2026) produces the most
*accurate* FreeBSD-internals documentation — i.e. hallucinates least about the
source — on the two Framework Desktop boxes (Strix Halo, 128 GB UMA, Vulkan)?
**Speed was explicitly not a criterion.**

This is a **quality** benchmark, distinct from `benches.FrameWork-Desktop.md`
(which measures tokens/sec). It complements the speed-only `BENCHMARKS.md`
inside the DaemonDocs repo.

Date: 2026-08-21/22. Host: `bigone` drove the runs; models served on
`framework` (FreeBSD) + `framework2` (Ubuntu) llama-servers.

## TL;DR

- **Dense models hallucinate ~2× less than the MoE baseline** on FreeBSD-source
  doc generation. Over the three chapters all three models completed:

  | Model | GGUF | Arch | Mean fact-check violations/draft (↓ better) |
  |-------|------|------|--------------------------------------------:|
  | **Qwen3.8-27B** ★ | `unsloth/Qwen3.8-27B-UD-Q8_K_XL` | dense | **6.4** |
  | Qwen3.6-27B | `unsloth/Qwen3.6-27B-UD-Q8_K_XL` | dense | 7.4 |
  | Qwen3.6-35B-A3B (current default) | `unsloth/Qwen3.6-35B-A3B-UD-Q8_K_XL` | MoE | 12.4 |

  ★ recommended for DaemonDocs quality runs. (Means over the 3 shared chapters —
  Kernel Core, Locking, VM — so the comparison is apples-to-apples; see caveats.)

- **This is a real grounding win, not a fluency artifact.** It does *not* repeat
  the earlier Q4→Q8 finding (BENCHMARKS.md run1→run2) where a heavier quant of
  the *same* model bought zero accuracy. The dense models ground better because
  they **explore the source far harder** before writing (15–64 tool-steps/draft
  vs the MoE's handful).

- **The cost of that quality is severe: the dense models are ~10× slower
  end-to-end** — not just lower t/s, but many more tool-call/read steps per
  draft. Several dense drafts hit the writer's 80-step cap. For DaemonDocs,
  where a chapter already takes 30–250 min, this pushes dense chapters toward
  the multi-hour tail. Acceptable given "speed doesn't matter," but real.

- **DeepSeek V4-Flash was ruled out**: doesn't fit 128 GB at usable quant
  (Q4_K_M 160 GiB / Q8 162 GiB; only IQ2/IQ1 fits = heavy quant damage, wrong
  direction for a hallucination-sensitive task).

## Why this benchmark exists

DaemonDocs' whole design is defense-in-depth against one failure: the writer
emitting a plausible-but-fictional C signature/struct/field cited from training
memory instead of quoted from the file ("Behavior B" in its README annex). The
generator ships a deterministic `fact_check_draft` that counts exactly these:
missing/mismatched structs, struct fields, function names, function arities,
paths, kernel options, DTrace probes, MALLOC tags (and sysctl OIDs when the
codebase-memory-mcp graph is present).

That makes "best model" answerable **empirically**: run the same chapters
through each candidate, count fact-check violations, lowest wins. No subjective
grading.

Prior art in the repo said not to assume bigger/newer = better: the Q4→Q8
upgrade of the *same* MoE gave +55 % tokens / +28 % wall-clock for **zero**
accuracy gain, and one quant upgrade made hallucination *worse*. The real
hypothesis here: do the newer/dense 2026 models actually lower the violation
count, or just hallucinate more fluently? Answer: **dense genuinely lowers it.**

## Method

- **Scored the RAW writer draft**, before DaemonDocs' own fact-fix self-repair —
  so this measures which model hallucinates least *at the source*, not how well
  the pipeline patches it afterward.
- Harness: `~/score_models.py` (read-only wrt the repo; imports `generate-doc.py`
  via importlib and calls `build_chapter_prompt` → writer agent → `fact_check_draft`).
  Never calls `run_chapter`.
- **Score = `total_issues − sysctls_not_found`.** The sysctl category depends on
  the codebase-memory-mcp graph (which disconnected mid-run); excluding it makes
  the ranking invariant to graph state.
- **3 reps per (model, chapter)** at the production sampling (`temp 0.6,
  top_p 0.95, top_k 20`). Rep-to-rep variance is large (single-chapter scores
  swing 4→20), so averaging matters.
- Chapters chosen for fact density / historical hallucination-proneness:
  Kernel Core (sysinit), Locking Primitives, Virtual Memory, mbuf.
- Same quant recipe (`UD-Q8_K_XL`) across all three models — fair quant axis.
- Served via llama-server, Vulkan0, `-fa on`, ctx 131072, one model per endpoint.

## Results

### Per-chapter mean violations (lower = better)

| Chapter | Qwen3.6-35B-A3B (MoE) | Qwen3.8-27B (dense) | Qwen3.6-27B (dense) |
|---------|----------------------:|--------------------:|--------------------:|
| Kernel Core       | 9.3 (n=3) | 7.0 (n=3) | **3.0** (n=3) |
| Locking Primitives| 18.3 (n=3)| **6.0** (n=3)| 8.7 (n=3) |
| Virtual Memory    | 9.7 (n=3) | **6.0** (n=2)| 10.7 (n=3) |
| mbuf              | — (lost)  | — (not run)  | 16.0 (n=3) |
| **Pooled (3 shared chapters)** | **12.4** (n=9) | **6.4** (n=8) | **7.4** (n=9) |

Reading the rows: the MoE is worst on every shared chapter. Between the two
dense models it's chapter-dependent — Qwen3.6-27B wins Kernel Core decisively
(3.0 vs 7.0), Qwen3.8-27B wins Locking (6.0 vs 8.7), roughly tied on VM — but
Qwen3.8-27B has the better pooled mean and lower variance.

### Category breakdown (MoE vs Qwen3.6-27B dense; per-draft means)

Only these two have per-category data (Qwen3.8's shard was reconstructed from
logs after an early stop and carries totals only — see caveats). The MoE's
violations concentrate in the two hardest-to-ground categories:

| Category | MoE (A) | Qwen3.6-27B dense (C) |
|----------|--------:|----------------------:|
| `funcs_not_found` (invented functions) | 5.2 | 2.7 |
| `struct_fields_bogus` (wrong struct fields) | 3.0 | 0.8 |
| `struct_field_refs_bogus` | 1.6 | 1.8 |
| `structs_not_found` | 1.4 | 1.1 |
| everything else | <1 each | <1 each (+dtrace 2.0 on one chapter) |

The MoE's headline weakness is **inventing function names** (5.2/draft) and
**fabricating struct fields** (3.0/draft) — precisely the "verified
hallucination" failure DaemonDocs was built to catch. The dense model roughly
halves both.

## Worth adding: a fixed sampler seed

`score_models.py` sets `api_base` / `model_id` / `api_key` in `MODEL_CONFIG`
but **no seed**, so `llama-server` defaults to `-1` — a fresh random seed per
request. At the production sampling used here (`temp 0.6, top_p 0.95,
top_k 20`) that is a large part of why "rep-to-rep variance is large
(single-chapter scores swing 4→20)".

Measured on this hardware (see `fbsd-quality/README.md`), with MTP **on** —
4 seeded vs 4 unseeded generations of one prompt, compared by pairwise text
similarity:

| | mean similarity | min | identical pairs |
|---|---:|---:|---:|
| **seeded** | **0.884** | 0.768 | **3 of 6** |
| unseeded | 0.433 | 0.340 | 0 of 6 |

A fixed seed roughly doubles run-to-run similarity, so the same confidence
needs fewer reps — directly useful for a bench that pays for 3 reps per
(model, chapter) precisely because of this variance. Full determinism is not
achievable while MTP is enabled (speculative accept/reject varies with batch
composition), and MTP must stay on because the bench also reports speed.

Note the speed benches (`bench-all.sh`, `bench_model.py`,
`bench-agents-a1.sh`) do **not** need this: `bench_model.py` already runs at
`temperature=0.0` (greedy — no sampling RNG to seed) and already discards a
warm-up run, and they measure tokens/second at a fixed token count rather than
which tokens are produced. `llama-bench` generates no real text at all.

## Caveats (read before trusting the exact numbers)

This run was **stopped early by design** once the ranking was unambiguous and
the dense models proved runaway-slow. The data is therefore uneven:

- **Qwen3.6-35B-A3B (A): 9/12 drafts.** The mbuf chapter (3 reps) was lost — I
  restarted its endpoint to load the next model while its harness thread was
  still mid-run (operator error, not a model fault). Pooled mean uses its 9
  completed drafts on the 3 shared chapters.
- **Qwen3.8-27B (B): 8/12 drafts** (Kernel Core ×3, Locking ×3, VM ×2; mbuf 0).
  Stopped for runaway step counts. Its shard was reconstructed from the run log,
  so it has per-draft totals but **no per-category breakdown**.
- **Qwen3.6-27B (C): 12/12** — the only fully-complete model.
- The **pooled means use only the 3 chapters all three models share** (Kernel
  Core, Locking, VM), so the headline comparison is apples-to-apples despite the
  uneven totals. mbuf (C-only, 16.0) is excluded from the ranking.
- Sample size is small (n≈8–9/model). The MoE-vs-dense gap (~2×) is large enough
  to be safe; the Qwen3.8-vs-Qwen3.6 dense ordering (6.4 vs 7.4) is **not**
  robust at this n — treat the two dense models as roughly equivalent, with
  Qwen3.8 slightly ahead.
- Raw harness artifacts: `~/model-scoring/QUALITY.md`, `shard_{A,B,C}.json`.

## Why the dense models are slow (the mechanism behind the quality)

The quality advantage and the slowness are the same phenomenon. The dense
writer agents issue far more `read_freebsd_source` / `resolve_c_definition` /
`search_books` tool calls before composing — 15 to 64 steps per draft against
the writer's `max_steps=80` cap, with individual generation steps emitting
6000+ tokens. They *look things up instead of recalling them*, which is exactly
what lowers hallucination — and also what makes them ~10× slower end-to-end than
the MoE (which drafts in a handful of steps and hallucinates the gaps). A few
dense drafts hit the 80-step cap; raising that cap would likely improve dense
quality further at even more wall-clock.

## Recommendation

- **For DaemonDocs quality runs, use `MODEL=qwen38-q8` (Qwen3.8-27B dense Q8)** —
  best pooled accuracy, newest generation. `MODEL=dense-q8` (Qwen3.6-27B dense
  Q8) is a near-equal fallback and won Kernel Core outright.
- **Keep the MoE (`moe-q8`) for speed-sensitive / bulk regen**, accepting ~2×
  more hallucinations for the fact-fix pipeline to catch.
- New `llmsrv.sh` slots added for this: `dense-q8`, `qwen38-q8`.
- If adopting a dense model for a full 28-chapter regen, budget for the ~10×
  slowdown and consider raising the writer `max_steps` above 80 so deep-exploring
  drafts finish instead of truncating.

## Reproduce

```sh
# On bigone, with DaemonDocs venv (see DaemonDocs/README.md — version-agnostic venv):
cd ~/DaemonDocs
# serve model A on framework, B on framework2 (one model per endpoint):
#   MODEL=moe-q8   HOST=0.0.0.0 ./llmsrv.sh   # on framework
#   MODEL=qwen38-q8 HOST=0.0.0.0 ./llmsrv.sh  # on framework2
.venv/bin/python ~/score_models.py --verify                        # sanity, no LLM
.venv/bin/python ~/score_models.py --endpoints A:framework,B:framework2 --reps 3
# then swap an endpoint to model C and:
.venv/bin/python ~/score_models.py --endpoints C:framework --reps 3
.venv/bin/python ~/score_models.py --report                        # -> ~/model-scoring/QUALITY.md
```

Endpoint IPs: `framework` = 192.168.100.7, `framework2` = **192.168.100.8**
(the .136 in DaemonDocs' old CLAUDE.md is stale — corrected in the harness).
