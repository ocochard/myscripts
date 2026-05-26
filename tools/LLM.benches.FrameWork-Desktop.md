# llama.cpp on Framework Desktop (Strix Halo) — FreeBSD vs Ubuntu, May 2026

Hardware: AMD Ryzen AI MAX+ 395 (Strix Halo) + Radeon 8060S iGPU (gfx1151), 128 GB LPDDR5x UMA.
Models: `unsloth/Qwen3.6-27B-GGUF` (dense, 26.90 B) and `unsloth/Qwen3.6-35B-A3B-GGUF` (MoE, 34.66 B
total / 3 B active per token), each in `UD-Q4_K_XL` and `UD-Q8_K_XL` quantizations.
Backend: Vulkan (Mesa RADV) on both OSes — same upstream Mesa version.

## Hosts

- **`frwk-bsd`** — FreeBSD 16.0-CURRENT, drm-kmod from
  [github.com/ocochard/drm-kmod (`strix` branch)](https://github.com/ocochard/drm-kmod/tree/strix),
  Mesa 25.2.8 RADV (FreeBSD ports update tracked in
  [bug 294948](https://bugs.freebsd.org/bugzilla/show_bug.cgi?id=294948)), vulkan-loader 1.4.349,
  llama.cpp `27aef3dd9` (b8985).
- **`frwk-linux`** — Ubuntu 24.04.4 LTS, kernel 6.17.0-22-generic, Mesa 25.2.8-0ubuntu0.24.04.1
  (from `noble-updates`), Vulkan 1.4.318, llama.cpp `27aef3dd9` (b8985).

Both hosts run the **same upstream Mesa version (25.2.8)** and the **same llama.cpp build hash**.
Differences below are due to OS / kernel / compiler, not Mesa.

## Summary

| Topic                                              | FreeBSD `frwk-bsd`              | Ubuntu `frwk-linux`             | Verdict                           |
|----------------------------------------------------|---------------------------------|---------------------------------|-----------------------------------|
| Vulkan dense 27B Q4 pp4096 d=0                     | 295.4 t/s                       | 266.0 t/s                       | FreeBSD ~11 % faster pp           |
| Vulkan dense 27B Q4 tg128                          | 12.04 t/s                       | 12.15 t/s                       | Tie                               |
| Vulkan dense 27B Q8 pp4096 d=0                     | 266.4 t/s                       | 203.2 t/s                       | **FreeBSD ~31 % faster pp**       |
| Vulkan dense 27B Q8 tg128                          | 6.07 t/s                        | 6.15 t/s                        | Tie                               |
| Vulkan MoE Q4 pp4096 d=0                           | 892.4 t/s                       | 919.4 t/s                       | Tie                               |
| Vulkan MoE Q4 tg128                                | 54.1 t/s                        | 55.4 t/s                        | Tie                               |
| Vulkan MoE Q8 pp4096 d=0                           | 871.7 t/s                       | 820.5 t/s                       | FreeBSD ~6 % faster pp            |
| Vulkan MoE Q8 tg128                                | 42.5 t/s                        | 43.0 t/s                        | Tie                               |
| `--no-host 1` server flag                          | OK on MoE; **crashes 27B dense** | OK on every config             | Drop on FreeBSD dense only        |
| `RADV_DEBUG=zerovram`                              | **harmful** (don't set)         | not needed                      | No env prefix on either OS        |
| Qwen3.6-27B-MTP Q8 + `--spec-type mtp` (~4 k)      | 14.2 t/s (vs 6.0 off)           | not measured                    | **2.37× decode** (see Stage 5)    |
| Qwen3.6-27B-MTP Q8 + `--spec-type mtp` (~32 k)     | 12.9 t/s (vs 5.7 off)           | not measured                    | **2.26× decode** (see Stage 5)    |

**Bottom line**: silicon dominates — Vulkan tg is essentially identical across both OSes (within 2 %
on every model/quant). FreeBSD wins pp by ~6–31 % depending on model/quant; the gap is largest on
dense Q8. The only OS-specific footnote is `--no-host 1` on FreeBSD dense 27B (crashes both Q4 and
Q8); MoE works fine with `--no-host` on both OSes.

If you want the simplest setup with the fewest crash classes, run Ubuntu. If you want the fastest
prompt processing for dense models, run FreeBSD with `--no-host` dropped from the dense recipe.

## Software versions tested

| Component         | FreeBSD `frwk-bsd`                                   | Ubuntu `frwk-linux`                          |
|-------------------|------------------------------------------------------|----------------------------------------------|
| OS                | FreeBSD 16.0-CURRENT                                 | Ubuntu 24.04.4 LTS (noble)                   |
| Kernel            | 6.12-based via drm-kmod                              | Linux 6.17.0-22-generic                      |
| GPU driver        | [`ocochard/drm-kmod` `strix` branch](https://github.com/ocochard/drm-kmod/tree/strix) | amdgpu in-tree     |
| GPU firmware      | `gpu-firmware-amd-kmod-* 20260406.1600018`           | linux-firmware (distro)                      |
| Mesa              | **25.2.8** ([FreeBSD bug 294948](https://bugs.freebsd.org/bugzilla/show_bug.cgi?id=294948)) | **25.2.8-0ubuntu0.24.04.1** |
| Vulkan API        | 1.4.318 (RADV)                                       | 1.4.318 (RADV)                               |
| vulkan-loader     | 1.4.349                                              | 1.3.275 (libvulkan1)                         |
| llama.cpp build   | `27aef3dd9` (b8985); Stage 5 only: `c0b933255` (b9124, master + PR #22673) | `27aef3dd9` (b8985)              |
| Compiler          | Clang 19.1.7                                         | gcc 13.3 (Ubuntu noble default)              |
| CPU governor      | `powerd` adaptive                                    | `performance`                                |

### Installing this stack on FreeBSD

1. Build and install the `strix`-branch drm-kmod from
   [github.com/ocochard/drm-kmod (branch `strix`)](https://github.com/ocochard/drm-kmod/tree/strix).
   Pull the matching `gpu-firmware-amd-kmod-*` ports for `gc-11-5-1`, `psp-14-0-1`, `sdma-6-1-1`,
   `vcn-4-0-6`, `vcn-4-0-6-1`, `vpe-6-1-1`, `dcn-3-5-1`, `dmcub-3-5-0`, `imu-11-5-1`.
2. Install Mesa 25.2.8 via the FreeBSD ports update tracked in
   [PR 294948](https://bugs.freebsd.org/bugzilla/show_bug.cgi?id=294948). Verify:
   ```sh
   pkg info mesa-libs mesa-dri mesa-libgallium  # all 25.2.8
   ```
   A Mesa-only upgrade does **not** require rebuilding llama.cpp — the Vulkan ICD is dlopen'd at
   runtime via `vulkan-loader` (verified with `ldd libggml-vulkan.so.0` showing only
   `libvulkan.so.1`).
3. After every reboot: `sudo kldload amdgpu`. `amdgpu` is **not** autoloaded on FreeBSD. Verify with
   `~/llama.cpp/build/bin/llama-bench --list-devices` — should show `Vulkan0`.
4. Build llama.cpp with Vulkan backend (`-DGGML_VULKAN=ON`); `vulkan-headers` and `vulkan-loader`
   are the only build/link deps. The runtime ICD comes from `mesa-dri`
   (`/usr/local/share/vulkan/icd.d/radeon_icd.x86_64.json` → `libvulkan_radeon.so`).

## Methodology

Five stages, recording `llama-bench` markdown tables verbatim. The skill that drove this is
`~/.claude/skills/llama-bench-tune` — it prunes the parameter space stage by stage so a full sweep
doesn't take a day or wedge the GPU.

- **Stage 0**: sanity (`-p 512 -n 128 -fa 0` on Ubuntu; `-p 4096 -n 128 -fa 1` on FreeBSD).
- **Stage 1**: core knobs (`fa`, `--no-host`, KV cache type) at d=0 with `-p 4096 -n 128`.
- **Stage 3**: depth sweep at d=8 192 and d=32 768 (`pp4096 @ dN + tg128 @ dN`).
- **Stage 4**: real-load validation — `llama-server` with the recommended flags + `bench_model.py`
  hitting `/v1/chat/completions` against `tools/coding_prompt.txt` and `tools/coding_prompt_32k.txt`.

## Stage 0 / 1 — d=0 baseline (Vulkan, fa=1, p=4096, n=128, b=2048, ub=512, r=2)

### FreeBSD `frwk-bsd` (Mesa 25.2.8, no env prefix)

| Model            | Quant   | Config         | pp4096          | tg128         |
|------------------|---------|----------------|----------------:|--------------:|
| Qwen3.6-27B      | Q4_K_XL | fa=1           | 295.41 ± 0.29   | 12.04 ± 0.00  |
| Qwen3.6-27B      | Q4_K_XL | fa=1 nohost    | 301.01 ± 0.12   | 12.05 ± 0.00  |
| Qwen3.6-27B      | Q8_K_XL | fa=1           | 266.35 ± 0.96   |  6.07 ± 0.00  |
| Qwen3.6-35B-A3B  | Q4_K_XL | fa=1           | 892.40 ± 15.16  | 54.11 ± 0.14  |
| Qwen3.6-35B-A3B  | Q4_K_XL | fa=1 nohost    | 897.02 ± 39.03  | 53.86 ± 0.05  |
| Qwen3.6-35B-A3B  | Q8_K_XL | fa=1           | 871.70 ± 40.91  | 42.48 ± 0.77  |
| Qwen3.6-35B-A3B  | Q8_K_XL | fa=1 nohost    | 902.05 ± 10.81  | 41.01 ± 0.91  |

The `27B Q4 fa=1 nohost` row above ran cleanly when 27B Q4 was the only model loaded that boot — but
across multiple reboots `--no-host` on dense 27B is unreliable and crashes more often than not. Treat
`--no-host` as **not safe for dense 27B on FreeBSD**.

### Ubuntu `frwk-linux` (Mesa 25.2.8, no env prefix)

| Sub | Model            | Quant   | Config         | pp4096          | tg128         |
|-----|------------------|---------|----------------|----------------:|--------------:|
| 1.1 | Qwen3.6-27B      | Q4_K_XL | fa=0           | 261.65 ± 0.51   | 12.11 ± 0.00  |
| 1.2 | Qwen3.6-27B      | Q4_K_XL | fa=1           | 265.96 ± 0.01   | 12.15 ± 0.01  |
| 1.3 | Qwen3.6-27B      | Q4_K_XL | fa=1 q8KV      | 258.84 ± 0.07   | 12.11 ± 0.00  |
| 1.4 | Qwen3.6-27B      | Q4_K_XL | fa=1 nohost    | 266.51 ± 0.01   | 12.16 ± 0.00  |
| 1.5 | Qwen3.6-27B      | Q4_K_XL | fa=1 nommap    | 266.35 ± 0.05   | 12.16 ± 0.00  |
| 1.1 | Qwen3.6-35B-A3B  | Q4_K_XL | fa=0           | 892.08 ± 6.03   | 55.01 ± 0.10  |
| 1.2 | Qwen3.6-35B-A3B  | Q4_K_XL | fa=1           | 913.92 ± 11.09  | 55.21 ± 0.02  |
| 1.4 | Qwen3.6-35B-A3B  | Q4_K_XL | fa=1 nohost    | 919.35 ± 3.24   | 55.36 ± 0.08  |
| 1.2 | Qwen3.6-27B      | Q8_K_XL | fa=1           | 174.00 ± 0.24   |  6.13 ± 0.00  |
| 1.4 | Qwen3.6-27B      | Q8_K_XL | fa=1 nohost    | 203.15 ± 0.05   |  6.15 ± 0.00  |
| 1.2 | Qwen3.6-35B-A3B  | Q8_K_XL | fa=1           | 816.26 ± 6.34   | 42.74 ± 0.00  |
| 1.4 | Qwen3.6-35B-A3B  | Q8_K_XL | fa=1 nohost    | 820.49 ± 2.71   | 42.97 ± 0.00  |

**Ubuntu winner**: `-fa 1 --no-host 1` for both models, both quants. `--no-host` is +0–17 % pp on Q8
(UMA-aware path), neutral on Q4. q8KV runs fine here.

## Stage 3 — Depth sweep (Vulkan, fa=1, b=2048, ub=512, r=2)

### Ubuntu `frwk-linux` (with `--no-host 1`)

| Model            | Quant   | depth | pp4096          | tg128         |
|------------------|---------|------:|----------------:|--------------:|
| Qwen3.6-27B      | Q4_K_XL |  8192 | 230.11 ± 0.14   | 11.73 ± 0.01  |
| Qwen3.6-27B      | Q4_K_XL | 32768 | 119.64 ± 0.14   | 10.72 ± 0.00  |
| Qwen3.6-27B      | Q8_K_XL |  8192 | 135.86 ± 0.06   |  6.00 ± 0.00  |
| Qwen3.6-27B      | Q8_K_XL | 32768 |  96.12 ± 0.28   |  5.76 ± 0.00  |
| Qwen3.6-35B-A3B  | Q4_K_XL |  8192 | 823.46 ± 4.00   | 51.69 ± 0.35  |
| Qwen3.6-35B-A3B  | Q4_K_XL | 32768 | 600.40 ± 0.90   | 46.46 ± 0.13  |
| Qwen3.6-35B-A3B  | Q8_K_XL |  8192 | 749.63 ± 3.92   | 40.95 ± 0.06  |
| Qwen3.6-35B-A3B  | Q8_K_XL | 32768 | 563.19 ± 0.29   | 37.50 ± 0.00  |

### FreeBSD `frwk-bsd` (no `--no-host` on dense; `--no-host` on MoE)

| Model            | Quant   | depth | pp4096          | tg128         | Notes                                    |
|------------------|---------|------:|----------------:|--------------:|------------------------------------------|
| Qwen3.6-27B      | Q4_K_XL | 32768 | 135.26 ± 0.06   | 10.72 ± 0.01  | d=8192 crashed once; d=32768 reproducible |
| Qwen3.6-27B      | Q8_K_XL |  8192 | 199.37 ± 0.80   |  5.92 ± 0.02  |                                          |
| Qwen3.6-27B      | Q8_K_XL | 32768 | 111.07 ± 0.50   |  5.66 ± 0.03  |                                          |
| Qwen3.6-35B-A3B  | Q4_K_XL | 32768 | 619.69 ± 7.48   | 44.06 ± 0.15  |                                          |
| Qwen3.6-35B-A3B  | Q8_K_XL | 32768 | 592.81 ± 4.41   | (1 sample)    |                                          |

The dense 27B `-d 8192` slot crashed on the run that produced this table (rerun after the d=32768
slot succeeded). The depth itself is not inherently fragile — crashes on dense 27B are more about
config-switch ordering than the value of `-d`.

**Cross-OS Stage 3 takeaway** (Vulkan, identical Mesa version):

| Model & quant     | pp gap (BSD vs Linux) at d=32 k | tg gap |
|-------------------|---------------------------------|--------|
| 27B Q4            | BSD +13 %                       | BSD tie |
| 27B Q8            | BSD +16 %                       | tie    |
| MoE Q4            | BSD +3 %                        | BSD ~5 % slower |
| MoE Q8            | BSD +5 %                        | tie    |

## Stage 4 — `bench_model.py` validation, all 4 (model, quant) pairs

`llama-server` with the recommended runtime flags (see [Recommended runtime
config](#recommended-runtime-config)), `--ctx-size 65536 --parallel 1`. Bench:
`bench_model.py -t 256 -r 2` against `tools/coding_prompt.txt` (4 004 tok) and
`tools/coding_prompt_32k.txt` (32 919 tok). PP TPS is `prompt_tokens / TTFT` from the streaming
response — i.e. **cold prefill** the first time the prompt is seen. Total TPS is the end-to-end rate
including reasoning tokens (all runs hit the 256-token cap, so Total TPS underestimates pure decode).

FreeBSD: rebooted between every (model, quant) combo to avoid Mesa 25 GPU-state contamination.
Ubuntu: ran all four sequentially in one boot (no instability).

### Qwen3.6-35B-A3B MoE (Q4 → coding default; Q8 → doc default)

| Host       | Quant | Depth   | TTFT (ms) | PP t/s | Total TPS |
|------------|-------|---------|----------:|-------:|----------:|
| frwk-bsd   | Q4    |  ~4 k   |    4 419  | 906.0  |    48.3   |
| frwk-linux | Q4    |  ~4 k   |    4 256  | 940.9  |    51.6   |
| frwk-bsd   | Q4    | ~32 k   |   42 290  | 778.4  |    40.6   |
| frwk-linux | Q4    | ~32 k   |   44 027  | 747.7  |    44.6   |
| frwk-bsd   | Q8    |  ~4 k   |    4 520  | 886.0  |    40.0   |
| frwk-linux | Q8    |  ~4 k   |    4 622  | 866.3  |    39.9   |
| frwk-bsd   | Q8    | ~32 k   |   43 451  | 757.6  |    35.8   |
| frwk-linux | Q8    | ~32 k   |   46 661  | 706.0  |    35.9   |

### Qwen3.6-27B dense

| Host       | Quant | Depth   | TTFT (ms) | PP t/s | Total TPS |
|------------|-------|---------|----------:|-------:|----------:|
| frwk-bsd   | Q4    |  ~4 k   |   13 839  | 289.3  |    11.5   |
| frwk-linux | Q4    |  ~4 k   |   14 713  | 272.1  |    11.5   |
| frwk-bsd   | Q4    | ~32 k   |  156 597  | 210.2  |    10.4   |
| frwk-linux | Q4    | ~32 k   |  167 265  | 196.8  |    10.4   |
| frwk-bsd   | Q8    |  ~4 k   |   21 928  | 265.2  |     5.9   |
| frwk-linux | Q8    |  ~4 k   |   18 655  | 214.6  |     5.9   |
| frwk-bsd   | Q8    | ~32 k   |  170 511  | 193.1  |     5.6   |
| frwk-linux | Q8    | ~32 k   |  199 935  | 164.7  |     5.6   |

### Cross-host takeaway

- **TG is OS-neutral**: every model/quant decodes within ~5 % across both OSes. The hardware sets the
  ceiling.
- **PP is OS-skewed in FreeBSD's favour on dense**: Q4 +6 % at d=0, +7 % at d=32k; Q8 +24 % at d=0,
  +17 % at d=32k. Compiler/scheduler difference, not driver.
- **PP is mixed on MoE**: Ubuntu wins MoE Q4 (+4 % at d=0) but FreeBSD wins MoE Q8 (+2 % at d=0,
  +7 % at d=32k). Within-noise across reboots.
- **Quant choice for daily use**: MoE Q4 for coding (54 t/s TG, 906 PP at d≈4 k), MoE Q8 for
  documentation (~22 % slower TG but better prose quality — the small 3-B active path is more
  sensitive to quant noise than a 30-B-active dense forward pass).
- **Dense 27B is the slow path** on this hardware: Q4 decodes at ~12 t/s and Q8 at ~6 t/s; the 4×
  TG advantage of MoE is real on every depth.

## Stage 5 — MTP speculative decoding (Qwen3.6-27B-MTP, Q8, FreeBSD only)

`havenoammo/Qwen3.6-27B-MTP-UD-GGUF:UD-Q8_K_XL` is the dense Qwen3.6-27B fine-tuned with Multi-Token
Prediction (NextN) heads. Loaded into `llama-server` with `--spec-type mtp`, the draft path proposes
N tokens per step and the main model verifies them in a single batched forward pass; accepted
tokens are kept. Observed acceptance rate on coding prompts: ~80–86 % (e.g. `draft_n_accepted:
30/35` on smoke test).

**Build divergence — important.** These rows were measured on `~/llama.cpp` at commit
`c0b933255` (b9124 = master + [PR #22673](https://github.com/ggml-org/llama.cpp/pull/22673)
"llama + spec: MTP Support" merged via `git merge --no-ff pr-22673`). All Stage 0/1/3/4 rows
above were on `27aef3dd9` (b8985). Existing rows were **not** re-measured — only the new MTP rows
use b9124. Treat the MTP-off ~4 k / ~32 k rows in the table below as the like-for-like baseline
for the MTP rows; the Stage 4 Q8 dense rows are the same hardware/model but a different upstream
snapshot and serve as a cross-check (Total TPS within 2 %).

Server flags (Strix Halo, FreeBSD, Vulkan, gfx1151): same as Stage 4 dense Q8 recipe plus
`--jinja --chat-template-kwargs {"preserve_thinking":true} --spec-type mtp`. Bench harness
identical to Stage 4: `bench_model.py -t 256 -r 2` against `coding_prompt.txt` and
`coding_prompt_32k.txt`.

| Host     | MTP | Depth | TTFT (ms) | PP t/s | Total TPS | vs MTP-off |
|----------|-----|-------|----------:|-------:|----------:|-----------:|
| frwk-bsd | off |  ~4 k |   15 320  | 261.4  |     6.0   |    —       |
| frwk-bsd | on  |  ~4 k |   17 182  | 233.0  |    14.2   | **2.37×**  |
| frwk-bsd | off | ~32 k |  178 987  | 183.9  |     5.7   |    —       |
| frwk-bsd | on  | ~32 k |  196 612  | 167.4  |    12.9   | **2.26×**  |

### Takeaways

- **Decode throughput ~2.3× across depths.** MTP turns the dense-Q8 slow-path (5.7–6.0 t/s) into a
  12.9–14.2 t/s range — close to the dense **Q4** speed without Q4. The 2.26× at 32k vs 2.37× at 4k
  shows acceptance holds up well under long context on this model.
- **TTFT and PP TPS get worse, not better.** PP drops ~11 % (261 → 233 at 4k) and TTFT rises ~12 %
  because the draft heads run during prefill too. MTP is a decode-side win; on prefill-dominated
  workloads (single large doc, no generation) it's a small net loss.
- **Memory-bandwidth ceiling is partially defeated.** Stage 4 framed dense Q8 as bandwidth-bound at
  ~6 t/s ≈ 26 GiB × 6 / 256 GB/s ≈ 61 % of peak. With MTP at 14 t/s we'd be at ~140 % of that
  budget on a naive single-token model — confirming MTP gets multiple useful tokens per memory pass
  (each verified token costs <1 full read of weights).
- **Reasoning content preserved.** `--chat-template-kwargs {"preserve_thinking":true}` plus
  `--jinja` keeps `<think>…</think>` blocks emitted into `reasoning_content` (verified in smoke
  test); accepted-draft tokens stream the same way as non-MTP output.

### `--spec-draft-n-max` sweep (~4 k prompt)

`--spec-draft-n-max N` caps how many tokens MTP proposes per verification step (`b9124` default
is 16). Each verify is one batched forward pass regardless of N, so larger N trades acceptance
rate per chain-position for fewer verification rounds. Sweep at ~4 k prompt, single pass r=2,
same flags as the table above:

| n_max | TTFT (ms) | PP t/s | Total TPS | vs default |
|------:|----------:|-------:|----------:|-----------:|
|     2 |   17 231  | 232.4  |   11.2    |   -21 %    |
|     3 |   17 138  | 233.6  |   11.9    |   -16 %    |
|     4 |   17 199  | 232.8  |   13.4    |    -6 %    |
|     5 |   17 126  | 233.8  |   13.9    |    -2 %    |
|     8 |   17 195  | 232.9  |   12.7    |   -11 %    |
| **16 (default)** | **17 182** | **233.0** | **14.2** | **best** |

- **Default `n_max=16` is the peak** on this hardware. Curve is monotonic 2 → 5 then dips at 8 and
  recovers at 16. The N=8 dip is probably real (it's wider than typical run-to-run noise here ~0.3
  t/s) but a re-bench with more repetitions would confirm.
- **N=5 is within 2 % of the default** — a reasonable cap if you want to bound worst-case verify
  batch width (e.g. if you suspect memory pressure or want predictable per-step latency).
- **TTFT and PP are flat** across N — prefill cost doesn't depend on draft chain length, only
  decode does. Matches theory: the draft heads are tiny relative to the main forward pass.
- **Caveat on third-party guidance**: a benchmark gist
  ([am17an/228edfb84ed082aa88e3865d6fa27090](https://gist.github.com/am17an/228edfb84ed082aa88e3865d6fa27090))
  claims N=3 is optimal at 21.6 t/s. That's likely a different model arch or a separate draft
  model (where small N is conventional); on havenoammo Qwen3.6-27B-MTP + Strix Halo + Vulkan,
  bigger is better up to the default cap.

### Caveats

- Different upstream snapshot than the rest of this doc — re-bench the Stage 4 Q8 dense row on
  b9124 if you want apples-to-apples (skipped here because the MTP-off rows in this section already
  provide the controlled comparison).
- `--spec-type mtp` requires PR #22673 merged; the `am17an/mtp-clean` fork uses a different tensor
  layout and fails to load the havenoammo GGUF with `missing tensor 'blk.64.ssm_conv1d.weight'`.
- All Total TPS rows hit the 256-token cap so the figures are mild underestimates; the MTP/no-MTP
  ratio is unaffected (both are capped identically).

## Recommended runtime config

Same recipe on both OSes; the only OS-specific footnote is `--no-host` on FreeBSD dense.

```sh
# Ubuntu — every model/quant:
llama-server \
  -hf unsloth/Qwen3.6-35B-A3B-GGUF:UD-Q4_K_XL \
  --device Vulkan0 \
  --flash-attn on \
  --no-host \
  --batch-size 2048 --ubatch-size 512 \
  --ctx-size 65536 --parallel 1 \
  --no-mmproj --jinja

# FreeBSD — same recipe for MoE. For dense 27B, drop --no-host:
llama-server \
  -hf unsloth/Qwen3.6-27B-GGUF:UD-Q4_K_XL \
  --device Vulkan0 \
  --flash-attn on \
  --batch-size 2048 --ubatch-size 512 \
  --ctx-size 65536 --parallel 1 \
  --no-mmproj --jinja
```

`--ctx-size 65536` is the working ceiling — both stacks can reserve `--ctx-size 131072` but TTFT
collapses past d ≈ 30 k on Strix Halo regardless of OS (memory bandwidth, not driver).

The launcher `tools/llmsrv.sh` auto-detects OS and model and applies the right flags. Use
`USAGE=coding` (default, MoE Q4) or `USAGE=doc` (MoE Q8) to pick the quant for the working profile.

## Memory bandwidth as the wall

[A blog post benchmarking the Framework Laptop 13 with Ryzen AI 9 HX 370 + Radeon
890M](https://msf.github.io/blogpost/local-llm-performance-frmk-bsd13.html) reports ~75 %
memory-bandwidth utilization on the 89.6 GB/s DDR5-5600 bus. The Strix Halo Framework Desktop
benched here has roughly **3× that bandwidth** (256-bit LPDDR5x ≈ 256 GB/s) and ~2.5× more CUs
(40 vs 16). Translating MoE Q4 tg128 numbers (~54 t/s on a 20.81 GiB total / 3 GB active path):

```
3 GB (Q4 active path) × 54 t/s ≈ 162 GB/s ≈ 63 % of 256 GB/s theoretical max
```

For dense Q4 27B (16.4 GiB Q4 model × 12 t/s ≈ 197 GB/s ≈ 77 %) we hit the same ceiling reported on
the laptop. tg is **memory-bound, not compute-bound and not driver-bound** — that's why Vulkan tg is
identical across both OSes. PP is more compute-shaped (matmul-heavy) and that's where the OS gap
appears: FreeBSD's compiler/scheduling gives ~6–31 % more pp on dense models; on MoE the gap
collapses (smaller active path, less compute pressure).

## Known crash signatures (FreeBSD `frwk-bsd`)

All on Mesa 25.2.8. Same `vk::DeviceLostError` signature in `ggml_vk_buffer_write_2d`:
`radv/amdgpu: The CS has been cancelled because the context is lost.` The drm-kmod auto-recovers
(`GPU reset(N) succeeded!` in `dmesg`) but userspace Vulkan state degrades after recovery — a
follow-up bench can crash again. **Reboot is the only reliable recovery.** `kldunload amdgpu` then
`kldload amdgpu` does **not** restore Vulkan probing (returns "No devices found").

- **27B dense with `-fa 1 --no-host 1`**: crashes on Q4 always; Q8 is unreliable across reboots.
  MoE works fine with `--no-host`.
- **`RADV_DEBUG=zerovram`**: actively crashes runs that succeed without it. **Do not set.**
- **Multi-value `llama-bench` sweeps** (e.g. `-fa 0,1`): crash on graph variant 2/3. Run one
  invocation per (model, config) pair.
- **Reload after a crash recovery**: subsequent benches often crash even on configs that just
  succeeded. Reboot between heavy config switches if you need clean numbers.

## Pitfalls

- **`--cache-reuse N`** is silently disabled on Qwen3-family models because their KV cache uses
  M-RoPE / IM-RoPE which cannot be position-shifted. The server logs `cache_reuse is not supported
  by ...` and the flag becomes a no-op. The default server prompt cache + checkpoints already give
  ~88× speedup on warm reuse of a 30 k prompt, so this is not a regression — just don't recommend
  the flag for these models.
- **`-hf` auto-loads the multimodal projector** for Qwen3.6-VL-derived weights (the "coder" repo is
  one of these). Pass `--no-mmproj` for text-only use to save VRAM and avoid the
  `cache_reuse is not supported by multimodal` log line.
- **`--reasoning-budget 0`** disables `<think>...</think>` blocks for short, mechanical tasks.
  Measured ~8.6× speedup on a "is_prime" task on Qwen3.6-27B with correct output. The launcher no
  longer exposes a "fast" mode — on MoE the gen-time savings are small and quality drops; if you
  really need it for an agent loop, pass the flag manually or inline `/no_think` in the prompt.
- **`bench_model.py` warm-up populates the prompt cache** on `llama-server`, so the per-run TTFT it
  prints is for cached re-evaluation. To measure cold prefill, hit `/v1/chat/completions` with curl
  and read `timings.prompt_n` / `timings.prompt_per_second` directly — the
  `~/.claude/skills/llama-bench-tune` skill includes a `bench_one.sh` snippet for this.

## BIOS UMA frame-buffer carve-out (critical)

Strix Halo's iGPU shares system RAM as UMA. The BIOS exposes a **UMA Frame Buffer Size** setting
that pre-allocates a region as "dedicated VRAM" (reported by amdgpu as
`/sys/class/drm/card*/device/mem_info_vram_total`). The remainder is exposed as **GTT** (Graphics
Translation Table — regular system RAM the GPU accesses via paging,
`mem_info_gtt_total`).

llama.cpp's Vulkan backend with `--no-host` is designed for the UMA-aware GTT path — it accesses
host-pointer buffers directly. **Configuring a large dedicated VRAM region forces an extra staging
copy through the carved-out region and tanks prompt processing.**

| BIOS UMA setting | `mem_info_vram_total` | `mem_info_gtt_total` | MoE Q4 PP at d≈4 k | TG  |
|------------------|----------------------:|---------------------:|-------------------:|----:|
| Large (64 GiB carve-out) | 64 GiB | 93.7 GiB | **543 t/s** | 49.5 t/s |
| Small / Auto (512 MiB)   | 512 MiB | 93.7 GiB | **712 t/s** (+31 %) | 50.0 t/s |
| Reference (`frwk-linux`) | 512 MiB | 61.4 GiB | 918 t/s | 55.3 t/s |

Measured on a second Strix Halo host (HP ZBook, AMD RYZEN AI MAX+ PRO 395) running the **identical**
software stack as `frwk-linux` (same kernel 6.17.0-29, Mesa 25.2.8, Vulkan 1.3.275, llama.cpp
b0df4c0cf, same `llmsrv.sh` cmdline, 8× LPDDR5-8000 in 8 channels = 256 GB/s). The BIOS UMA setting
alone explains a ~31 % PP swing; TG is unaffected (memory-bandwidth-bound, doesn't care about the
VRAM/GTT split).

**Recommendation**: set UMA Frame Buffer to the **smallest** value the BIOS allows (typically 512 MiB
or "Auto"). The amdgpu driver will allocate from GTT on demand, which is the fast UMA path. A large
dedicated carve-out is only useful for legacy code that hardcodes VRAM allocations — not llama.cpp.

## Firmware power cap (`platform_profile` on laptops)

After fixing the UMA carve-out, a residual gap remained on the laptop. Sampling
`/sys/class/hwmon/hwmon*/power1_average` (amdgpu PPT label) at 2 Hz during the bench identified the
cause: HP firmware caps GPU PPT depending on the ACPI `platform_profile` setting, while Framework
Desktop firmware does not. Both hosts were on `platform_profile=balanced` initially.

| Host / profile        | GPU PPT active avg | GPU PPT p95 | GPU PPT max | GPU max freq | MoE Q4 PP at d≈4 k |
|-----------------------|-------------------:|------------:|------------:|-------------:|-------------------:|
| zbook `balanced`      |  40 W              |  40 W       |  59 W       | 2070 MHz     |  519 t/s           |
| zbook `performance`   |  69 W              |  70 W       |  70 W       | 2898 MHz     |  741 t/s (+43 %)   |
| framework2 `balanced` |  83 W              | 110 W       | 113 W       | 2900 MHz     |  918 t/s           |

On zbook the p95 and max being identical at 40 W (balanced) or 70 W (performance) is the textbook
signature of a firmware-imposed hard cap, not thermal throttling — GPU temperature peaked at 83 °C
under the 70 W cap, well below the ~95 °C silicon throttle ceiling. Framework Desktop on the same
`balanced` profile lets PPT spike to 113 W and sustains ~83 W — so HP's "balanced" is a real cap
where Framework's is a hint.

**Recommendation for laptops**: switch to `performance` profile when running llama.cpp prompt
processing workloads:

```sh
echo performance | sudo tee /sys/firmware/acpi/platform_profile
for c in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
  echo performance | sudo tee "$c" > /dev/null
done
```

Revert with `balanced` / `balance_performance` when done — sustained 70 W on a laptop will spin the
fans up and reduce battery life. TG is barely affected by the profile change (memory-bound), so for
pure decoding workloads `balanced` is fine.

The HP BIOS may expose a higher cTDP override (look under Advanced → Power Management, or HP-specific
menus like "AI Engine Power" / "Workstation Performance"). If not, `ryzenadj --stapm-limit=...` can
raise SMU power limits at runtime on Ryzen Mobile — assuming HP firmware doesn't lock SMU writes.

### Summary of the laptop vs desktop PP gap

| Cause                                       | PP impact on zbook                |
|---------------------------------------------|-----------------------------------|
| BIOS UMA carve-out (64 GiB → 512 MiB VRAM)  | 544 → 712 t/s (+31 %)             |
| `platform_profile` (balanced → performance) | 519 → 741 t/s (+43 %)             |
| Residual vs framework2 (`performance` zbook vs `balanced` framework2) | ~20 % (~70 W cap vs 113 W headroom) |

The residual gap correlates almost 1:1 with the remaining PPT headroom (70 W cap vs 110+ W observed
on framework2). To close it would require unlocking sustained TDP above 70 W on the laptop — chassis
thermal design likely limits how far this can practically go.

