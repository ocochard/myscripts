# CWR-CE perf PRs — measured on a CPU-bound scene

Measured the open perf PRs on a heavy battle (259 vehicles / 333 units, demo island;
AMD Ryzen 7 7735HS, FreeBSD, vsync off; 5 `--benchmark` runs each, ministat 95%):

| Build | aFPS |
|---|---|
| baseline (opts reverted) | 58.8 |
| with the opts (shipped default) | **98.1 → +67%** |
| + GPU skinning enabled | **106.5 → +81% vs baseline** |

Profiled with `pmcstat` (60 s headless `--simulate`) to confirm where the time went.

**What each PR does:**

- **#105 — `cvtss2si` rounding.** Replaces `std::nearbyint` (a libm `nearbyintf` call that
  runs `fegetenv` every time) with a single SSE `cvtss2si` instruction. Removes ~18% of
  retired instructions (`nearbyintf` 9.0% + `fegetenv` 7.4% + `rintf` 1.1%) — the bulk of
  the +67%.
- **#106 — `rsqrtss` for `InvSqrt`.** SSE reciprocal-sqrt + one Newton step instead of a
  table lookup: `InvSqrt` drops 3.96% → 0.84% of CPU.
- **#112 — SSE `Vector3P::SetFastTransform`.** Vectorizes the per-vertex transform (scalar → SSE).
- **#111 — gate heavy AI validators out of Release.** *Profile shows this is a no-op in
  Release — the asserts it gates already compile out — so it only helps debug/checked
  builds. Keep or drop as you like.*
- **#110 — fix `--benchmark` on POSIX.** Needed to run this measurement at all (mission
  never booted, backslash paths, no warm-up).
- **GPU skinning** (off by default, `--gpu-skinning`): moves character mesh skinning from
  the CPU to the GPU vertex shader. Adds **+9%** on top here.

Full writeup + method: `PERF-low-fps-cpu-bound.md` → "PROVEN on a CPU-bound scene".
