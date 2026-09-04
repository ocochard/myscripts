# llama.cpp on Framework Desktop (Strix Halo) — FreeBSD vs Ubuntu

Hardware: AMD Ryzen AI MAX+ 395 (Strix Halo) + Radeon 8060S iGPU (gfx1151),
128 GB LPDDR5x UMA (Unified Memory Architecture). Backend: Vulkan (Mesa RADV,
the open-source Vulkan driver for AMD Radeon). Same silicon in both hosts —
`frwk-bsd` (FreeBSD 16-CURRENT) and `frwk-linux` (Ubuntu 24.04).

**All measurements: llama.cpp b9925 (`ed8c26150`), 2026-07-10, single build on
both hosts, `--ctx-size 131072` (matches daily-use), no `--no-host` flag (A/B
proved it's a no-op on this stack — see "The `--no-host` non-finding" below).**
Harness: `LLM/bench-all.sh`.

**Update 2026-08-04 — b10267 (`7bd8282c3`) re-bench of the `agents-a1-mtp`
slot only** (the default coding recipe). Rebuilt on both hosts; only the
Agents-A1-MTP Q8_0 rows were re-measured, so numbers tagged **(b10267)** below
supersede the b9925 values for that one model — every other model's rows are
still b9925. FreeBSD gained ~5-7 % MoE-MTP decode (topk_moe sqrt(softplus)
fusion + MTP accepted-token-replay fix, PRs #26124 / #26320); Ubuntu was flat
within noise. `--spec-draft-n-max 5` and the N≥8 cliff are unchanged, so
`llmsrv.sh` defaults still hold. See the "b10267 re-bench" tables at the end.

## TL;DR

- **Default coding recipe: `MODEL=agents-a1-mtp`** — b10267: **79 t/s** Total
  TPS at ~4 k on FreeBSD, **71 t/s** on Ubuntu (was 75 / 73 on b9925).
  Q8 MoE (Mixture-of-Experts) + MTP (Multi-Token Prediction) + agentic
  fine-tune. Beats plain Q4 on speed **and** quality.
- **TG is OS-neutral** (memory-bandwidth bound at ~250 GB/s). **PP
  (Prompt Processing, the prefill phase) is compiler/scheduler-bound**:
  FreeBSD wins by 5-40 % on dense at d=0 and MoE d≥8k; Ubuntu wins on
  dense at d=32k.
- **MoE MTP works** — ~1.5× decode on Agents-A1-MTP Q8_0. Set
  `--spec-draft-n-max 5`; N ≥ 8 is a cliff (Total TPS — Tokens Per Second
  across the whole request — drops 50 % on MoE).
- **Dense MTP** (Qwen3.6-27B-MTP Q8) delivers **2.5×** decode (6.4 → 16.1 t/s
  at ~4 k) — even higher gain than MoE MTP.
- **ROCm is dead on gfx1151** (MES — MicroEngine Scheduler — 0x83 firmware
  bug). Vulkan-only.
- **Qwen3.8-Flash-Next (125B `qwen4exp`) runs — at UD-IQ3_XXS (82 GB), not
  bigger.** MTP works there (~37 t/s Total TPS at N=2, acceptance 0.74-0.84,
  ≥65 k context). One step up, UD-IQ4_XS (93.7 GB), cannot load an MTP head at
  all and caps context at 16-32 k; Q8_0 (192 GB) never fits. Needs the unmerged
  PR #28243. Still ~half of `agents-a1-mtp`. Added 2026-09-04.

## Which recipe to use

Total TPS from `bench_model.py -t 256 -r 2` on b9925 — `-t 256` caps the
**generated** output at 256 tokens; the `~4 k` / `~32 k` columns are the
**prompt-length regime** (`LLM/coding_prompt.txt` = 4 004 tokens,
`LLM/coding_prompt_32k.txt` = 32 919 tokens). Each cell is
Total TPS = (prompt_tokens + generated_tokens) / wall_clock,
formatted `frwk-bsd / frwk-linux`.

| Recipe (`MODEL=`)    | Model                           | Total TPS @ ~4 k prompt | Total TPS @ ~32 k prompt | Notes                                        |
|----------------------|---------------------------------|------------------------:|-------------------------:|----------------------------------------------|
| **`agents-a1-mtp`** ★| Agents-A1 Q8 + MTP N=5          |     **79 / 71** (b10267) |     **60 / 59** (b10267) | Default. Q8 + agentic fine-tune. b9925 was 75/73, 56/61. |
| `agents-a1`          | Agents-A1 Q4_K_M                |            66 / 67      |            55 / 56       | Q4 + agentic tuning; half the disk.          |
| `moe`                | Qwen3.6-35B-A3B Q4_K_XL         |            56 / 56      |            48 / 48       | Older Q4 baseline.                           |
| `moe-q8`             | Qwen3.6-35B-A3B Q8_K_XL         |            44 / 45      |            39 / 40       | Plain Q8. `USAGE=doc` alias.                 |
| `mtp`                | Qwen3.6-27B-MTP Q8_K_XL + N=5   |            16 / 17      |            15 / 15       | Dense MTP: 2.5× vs off, still ~5× slower decode than MoE. |
| `dense`              | Qwen3.6-27B Q4_K_XL             |            12 / 12      |            11 / 11       | Highest quality per token; slow.             |
| `flashnext`          | Qwen3.8-Flash-Next UD-IQ3_XXS + MTP N=2 |    **37 / 35**  |          **30 / 28**     | 125B `qwen4exp`, 82 GB. MTP works at both depths (accept 0.77-0.79); gain *widens* with depth. 32 k needs `CTX=65536` and ~2 min cold TTFT. Needs unmerged PR #28243; frwk-bsd MTP flaky (Mesa 26). |
| _(no slot)_          | Qwen3.8-Flash-Next UD-IQ4_XS    |            28 / 27      |            n/a           | 93.7 GB — one step too big: no MTP, ctx caps 32 k/16 k. Use IQ3_XXS instead. |

★ = current default in `LLM/llmsrv.sh`. `USAGE=coding` → `agents-a1-mtp`;
`USAGE=doc` → `moe-q8`.

## Recommended runtime config

`LLM/llmsrv.sh` auto-detects OS/model. Canonical llama-server invocation:

```sh
llama-server \
  -hf protoLabsAI/Agents-A1-MTP-GGUF -hff Agents-A1-MTP-Q8_0.gguf \
  --device Vulkan0 --flash-attn on --no-warmup --no-mmproj \
  --jinja --spec-type draft-mtp --spec-draft-n-max 5 \
  --batch-size 2048 --ubatch-size 512 \
  --ctx-size 131072 --parallel 1
```

**Footnotes**:
- **No `--no-host` flag.** Direct A/B on `frwk-linux` (3 reps, dense-27B Q4 +
  MoE Q4 at d=0 and d=32k) showed `--no-host 1` vs `--no-host 0` diverges by
  ≤ 0.6 % on every workload — it's a no-op with a small BIOS UMA carve-out
  (which both hosts use). It's still worth passing if you have a large
  "dedicated VRAM" carve-out; see the BIOS section below.
- FreeBSD post-boot: `sudo kldload amdgpu` (not autoloaded).
- **Agents-A1-MTP Q8 native context = 262 144 tokens** (`qwen35moe.context_length`
  in the GGUF, extended RoPE (Rotary Position Embedding) theta 1e7 baked in
  — no YaRN (Yet another RoPE extensioN) scaling needed).
  Recommended `--ctx-size`:
  - **`131072`** (default above) — the practical sweet spot. KV (Key-Value
    attention cache) reservation ~18 GiB in 93 GiB GTT (Graphics Translation
    Table, the GPU's system-RAM aperture); zero TG/PP cost until you actually
    fill past ~30 k.
  - **`65536`** — pick this if you never work past ~30 k prompts and want the
    smallest KV footprint (~9 GiB).
  - **`262144`** (native max) — works, no OOM (Out Of Memory), but cold
    prefill at the ceiling
    is ~20 minutes. Only worth it if you can amortize across many warm-cache
    turns. See the "Extended-depth sweep" table below.
- `--batch-size 2048 --ubatch-size 512` is peak; 4096/1024 is ~3 % slower.

## Hardware, software, and install

Same silicon (Ryzen AI MAX+ 395 + 128 GB LPDDR5x-8000 UMA). Stack inventory
and benches captured 2026-07-10 against the software below. `frwk-bsd`'s
dense-27B rows come from a same-day re-run at 17:22-19:07 with the finalised
no-`--no-host` recipe; MoE and Agents-A1 rows come from the main 12:37-15:00
run (same recipe on those slots, no drift).

| Component       | `frwk-bsd`                                              | `frwk-linux`                            |
|-----------------|---------------------------------------------------------|-----------------------------------------|
| OS              | FreeBSD 16.0-CURRENT                                    | Ubuntu 24.04.4 LTS (noble)              |
| Kernel          | 6.12-based via drm-kmod (`drm-latest-kmod 6.12.1600018_1`) | Linux 6.17.0-35-generic              |
| GPU driver      | [`ocochard/drm-kmod` `strix` branch](https://github.com/ocochard/drm-kmod/tree/strix) | amdgpu in-tree |
| GPU firmware    | `gpu-firmware-amd-kmod-* 20260519.1600018`              | linux-firmware (distro)                 |
| Mesa            | **26.1.3** ([FreeBSD bug 294948](https://bugs.freebsd.org/bugzilla/show_bug.cgi?id=294948), `mesa-dri` ships RADV ICD — Installable Client Driver) | **25.2.8-0ubuntu0.24.04.2** |
| Vulkan API      | 1.4.348 (RADV)                                          | 1.4.318 (RADV)                          |
| Compiler        | Clang 21.1.8                                            | gcc 13.3.0                              |
| CPU governor    | `powerd` adaptive                                       | `performance`                           |
| llama.cpp       | b9925 (`ed8c26150`)                                     | b9925 (`ed8c26150`)                     |

### Installing on FreeBSD

1. Build+install `strix`-branch drm-kmod from
   [github.com/ocochard/drm-kmod](https://github.com/ocochard/drm-kmod/tree/strix).
   Pull matching `gpu-firmware-amd-kmod-*` ports (dcn-3-1-5, dcn-3-5-1,
   gc-11-5-1, psp-14-0-1, sdma-6-1-1, vcn-4-0-6, vcn-4-0-6-1, vpe-6-1-1).
2. Install Mesa 26.1.3 via [FreeBSD PR 294948](https://bugs.freebsd.org/bugzilla/show_bug.cgi?id=294948).
   Verify: `pkg info mesa-libs mesa-dri` shows 26.1.3 and
   `vulkaninfo --summary` reports `driverName = radv` with `apiVersion 1.4.348`.
3. After every reboot: `sudo kldload amdgpu`. Verify with
   `~/llama.cpp/build/bin/llama-bench --list-devices`.
4. Build llama.cpp with `-DGGML_VULKAN=ON`. Runtime ICD `libvulkan_radeon.so`
   ships in `mesa-dri` (the `mesa-libgallium` package is OpenGL-only and not
   used by llama.cpp's Vulkan backend).

## Methodology

Driven by `~/myscripts/LLM/bench-all.sh`. Two harnesses:

- **`llama-bench`**: raw kernel throughput. `pp4096 + tg128` at d=0, 8192,
  32768, fa=1, b=2048, ub=512, r=2, mmap on, no `--no-host`.
- **`llama-server` + `bench_model.py -t 256 -r 2`**: real client-server load.
  Server = canonical config, `--ctx-size 131072 --parallel 1`. Prompts:
  `LLM/coding_prompt.txt` (4 004 tok), `LLM/coding_prompt_32k.txt`
  (32 919 tok). **PP TPS = `prompt_tokens / TTFT`** (TTFT = Time To First
  Token, i.e. cold prefill latency). Total TPS
  includes reasoning tokens (all runs hit 256-token cap, so Total TPS
  underestimates pure decode by a fixed amount that cancels in ratios).
- **MTP sweep**: `--spec-draft-n-max N ∈ {2, 3, 4, 5, 8, 16}` at ~4 k prompt
  for MTP-capable models.

## llama-bench — depth sweep

No `--no-host` flag on any run.

| Model             | Quant   | depth | `frwk-bsd` pp4096 | `frwk-bsd` tg128 | `frwk-linux` pp4096 | `frwk-linux` tg128 |
|-------------------|---------|------:|------------------:|-----------------:|--------------------:|-------------------:|
| Qwen3.6-27B       | Q4_K_XL |     0 |   337.19 ± 0.10   |  12.14 ± 0.00    |    279.89 ± 0.73    |    12.20 ± 0.00    |
| Qwen3.6-27B       | Q4_K_XL |  8192 |   284.38 ± 1.23   |  11.75 ± 0.00    |    241.72 ± 0.21    |    11.79 ± 0.01    |
| Qwen3.6-27B       | Q4_K_XL | 32768 |    84.48 ± 2.12   |  10.80 ± 0.01    |    124.46 ± 0.92    |    10.83 ± 0.00    |
| Qwen3.6-27B       | Q8_K_XL |     0 |   228.68 ± 0.74   |   6.48 ± 0.00    |    225.46 ± 0.39    |     6.55 ± 0.00    |
| Qwen3.6-27B       | Q8_K_XL |  8192 |   201.71 ± 0.32   |   6.35 ± 0.00    |    201.65 ± 0.06    |     6.42 ± 0.00    |
| Qwen3.6-27B       | Q8_K_XL | 32768 |    74.00 ± 0.80   |   6.07 ± 0.00    |    111.61 ± 0.01    |     6.12 ± 0.00    |
| Qwen3.6-35B-A3B   | Q4_K_XL |     0 |   990.75 ± 44.62  |  58.84 ± 0.08    |    939.85 ± 10.87   |    58.91 ± 0.01    |
| Qwen3.6-35B-A3B   | Q4_K_XL |  8192 |   902.73 ± 19.86  |  55.57 ± 0.20    |    805.27 ± 3.26    |    54.98 ± 0.06    |
| Qwen3.6-35B-A3B   | Q4_K_XL | 32768 |   654.52 ± 7.45   |  48.63 ± 0.20    |    591.65 ± 1.03    |    48.57 ± 0.03    |
| Qwen3.6-35B-A3B   | Q8_K_XL |     0 |   893.18 ± 7.64   |  45.71 ± 0.01    |    858.10 ± 10.85   |    46.53 ± 0.02    |
| Qwen3.6-35B-A3B   | Q8_K_XL |  8192 |   740.84 ± 0.32   |  43.76 ± 0.09    |    750.66 ± 3.58    |    44.40 ± 0.04    |
| Qwen3.6-35B-A3B   | Q8_K_XL | 32768 |   616.14 ± 2.09   |  39.18 ± 0.00    |    560.15 ± 0.15    |    40.04 ± 0.01    |
| Qwen3.6-27B-MTP   | Q8_K_XL |     0 |   235.56 ± 0.47   |   6.47 ± 0.00    |    224.93 ± 0.03    |     6.55 ± 0.00    |
| Qwen3.6-27B-MTP   | Q8_K_XL |  8192 |   207.36 ± 1.62   |   6.34 ± 0.00    |    199.34 ± 0.40    |     6.42 ± 0.00    |
| Qwen3.6-27B-MTP   | Q8_K_XL | 32768 |    74.10 ± 0.93   |   6.08 ± 0.00    |    110.89 ± 0.39    |     6.13 ± 0.00    |
| Agents-A1         | Q4_K_M  |     0 |  1031.70 ± 22.06  |  71.50 ± 0.29    |    924.52 ± 14.31   |    72.11 ± 0.02    |
| Agents-A1         | Q4_K_M  |  8192 |   900.93 ± 17.07  |  65.58 ± 0.53    |    796.09 ± 5.19    |    65.48 ± 0.13    |
| Agents-A1         | Q4_K_M  | 32768 |   640.43 ± 10.49  |  56.05 ± 0.26    |    579.09 ± 0.88    |    56.28 ± 0.12    |
| Agents-A1-MTP     | Q8_0    |     0 |  1004.67 ± 0.21   |  53.52 ± 0.10    |    931.20 ± 12.61   |    53.31 ± 0.03    |
| Agents-A1-MTP     | Q8_0    |  8192 |   856.81 ± 3.66   |  50.78 ± 0.20    |    798.92 ± 6.07    |    50.41 ± 0.03    |
| Agents-A1-MTP     | Q8_0    | 32768 |   662.30 ± 2.99   |  44.99 ± 0.20    |    583.05 ± 0.47    |    44.82 ± 0.00    |

### Observations

- **TG identical across OSes** at every model/quant/depth (within ~1 %) —
  memory-bandwidth bound.
- **FreeBSD wins pp at d=0 and d=8192**: dense-Q4 +20 % / +18 %, dense-Q8 +1 %
  / +0 % (tie), MoE-Q4 +5 % / +12 %, MoE-Q8 +4 % / −1 %, Agents-A1 Q4 +12 % /
  +13 %, Agents-A1-MTP Q8 +8 % / +7 %.
- **At d=32768, Ubuntu wins dense pp** (+47 % dense-Q4, +51 % dense-Q8) while
  FreeBSD still wins MoE pp (+11 %) and Agents-A1 pp (+11-14 %). Dense at deep
  depth is the one workload where Ubuntu is faster — pattern reproduces
  cleanly across three runs. Suspected cause: Mesa 26 on FreeBSD (26.1.3)
  handles deep-depth dense attention paths worse than Mesa 25 on Ubuntu; not
  a `--no-host` effect (confirmed by direct A/B on `frwk-linux`).
- **Agents-A1 vs Qwen3.6-35B-A3B**: same arch, same build, but Agents-A1 is
  published as **Q4_K_M** (~20 GB) while the Qwen3.6 baseline uses unsloth's
  **Q4_K_XL** (~21 GB, dynamic higher-precision layers). The size difference
  explains Agents-A1's ~+20 % TG (71 vs 59 t/s at d=0 on FreeBSD) — it's
  fewer bytes to move across the memory bus per token, not a fine-tune
  runtime advantage. Fine-tune contributes only quality (agentic
  instruction-following, tool use), zero runtime effect.

## llama-server + bench_model.py at ~4 k and ~32 k

Same recipe as `llmsrv.sh` defaults: `--ctx-size 131072 --parallel 1`, no
`--no-host`.

### Q4 / Q8 baselines (MTP-off)

| Model             | Quant   | Depth | host       | TTFT (ms) | PP t/s | Total TPS |
|-------------------|---------|-------|------------|----------:|-------:|----------:|
| Qwen3.6-27B       | Q4_K_XL | ~4 k  | frwk-bsd   |   13 207  | 303.4  |   11.9    |
| Qwen3.6-27B       | Q4_K_XL | ~4 k  | frwk-linux |   15 807  | 253.4  |   12.0    |
| Qwen3.6-27B       | Q4_K_XL | ~32 k | frwk-bsd   |  151 699  | 217.2  |   10.8    |
| Qwen3.6-27B       | Q4_K_XL | ~32 k | frwk-linux |  170 292  | 193.4  |   10.8    |
| Qwen3.6-27B       | Q8_K_XL | ~4 k  | frwk-bsd   |   18 952  | 213.0  |    6.4    |
| Qwen3.6-27B       | Q8_K_XL | ~4 k  | frwk-linux |   19 257  | 208.0  |    6.5    |
| Qwen3.6-27B       | Q8_K_XL | ~32 k | frwk-bsd   |  205 508  | 160.4  |    6.1    |
| Qwen3.6-27B       | Q8_K_XL | ~32 k | frwk-linux |  200 410  | 164.6  |    6.1    |
| Qwen3.6-35B-A3B   | Q4_K_XL | ~4 k  | frwk-bsd   |    4 547  | 881.9  |   55.7    |
| Qwen3.6-35B-A3B   | Q4_K_XL | ~4 k  | frwk-linux |    4 755  | 847.8  |   55.8    |
| Qwen3.6-35B-A3B   | Q4_K_XL | ~32 k | frwk-bsd   |   40 940  | 806.7  |   47.8    |
| Qwen3.6-35B-A3B   | Q4_K_XL | ~32 k | frwk-linux |   45 404  | 725.4  |   48.2    |
| Qwen3.6-35B-A3B   | Q8_K_XL | ~4 k  | frwk-bsd   |    4 912  | 817.2  |   43.8    |
| Qwen3.6-35B-A3B   | Q8_K_XL | ~4 k  | frwk-linux |    5 108  | 787.0  |   44.8    |
| Qwen3.6-35B-A3B   | Q8_K_XL | ~32 k | frwk-bsd   |   45 456  | 731.9  |   38.7    |
| Qwen3.6-35B-A3B   | Q8_K_XL | ~32 k | frwk-linux |   48 641  | 677.2  |   39.7    |
| Agents-A1         | Q4_K_M  | ~4 k  | frwk-bsd   |    4 430  | 915.5  |   65.8    |
| Agents-A1         | Q4_K_M  | ~4 k  | frwk-linux |    4 566  | 878.0  |   66.5    |
| Agents-A1         | Q4_K_M  | ~32 k | frwk-bsd   |   40 014  | 826.3  |   55.2    |
| Agents-A1         | Q4_K_M  | ~32 k | frwk-linux |   44 521  | 740.0  |   56.0    |

- **TG matches llama-bench**: dense 27B ~12 t/s (Q4) / ~6.4 t/s (Q8); MoE
  ~56 t/s (Q4) / ~44 t/s (Q8); Agents-A1 Q4 ~66 t/s.
- **FreeBSD wins PP at ~4 k on every model**, by +2-4 % on MoE Q4/Q8, +4 % on
  Agents-A1 Q4, +20 % on dense Q4, +2 % on dense Q8.
- **At ~32 k**, FreeBSD's PP lead widens on MoE (+8-12 %) and Agents-A1 (+12 %)
  but flips on dense Q4 (+12 % FreeBSD) and dense Q8 (Ubuntu +3 %).

## MTP speculative decoding

### Qwen3.6-27B-MTP Q8_K_XL (dense)

| Host       | MTP    | Depth | TTFT (ms) | PP t/s | Total TPS | vs off |
|------------|--------|-------|----------:|-------:|----------:|-------:|
| frwk-bsd   | off    |  ~4 k |   18 249  | 220.0  |    6.4    |   —    |
| frwk-bsd   | on N=5 |  ~4 k |   14 609  | 274.2  |   16.1    | **2.52×** |
| frwk-bsd   | off    | ~32 k |  197 116  | 167.6  |    6.1    |   —    |
| frwk-bsd   | on N=5 | ~32 k |  175 332  | 188.6  |   14.5    | **2.38×** |
| frwk-linux | off    |  ~4 k |   19 781  | 202.6  |    6.5    |   —    |
| frwk-linux | on N=5 |  ~4 k |   16 159  | 248.1  |   16.6    | **2.55×** |
| frwk-linux | off    | ~32 k |  204 265  | 161.4  |    6.1    |   —    |
| frwk-linux | on N=5 | ~32 k |  181 295  | 181.8  |   15.2    | **2.49×** |

Even under MTP, dense Q8 at ~15 t/s is ~5× slower TG than MoE. Use only when
dense quality justifies the cost.

### Agents-A1-MTP Q8_0 (MoE) — the default coding recipe

| Host       | MTP    | Depth | TTFT (ms) | PP t/s | Total TPS | vs off |
|------------|--------|-------|----------:|-------:|----------:|-------:|
| frwk-bsd   | off    |  ~4 k |    4 253  |  946.8 |   51.4    |   —    |
| frwk-bsd   | on N=5 |  ~4 k |    3 917  | 1022.6 |   75.2    | **1.46×** |
| frwk-bsd   | off    | ~32 k |   38 377  |  858.6 |   44.5    |   —    |
| frwk-bsd   | on N=5 | ~32 k |   40 003  |  825.2 |   55.7    | **1.25×** |
| frwk-linux | off    |  ~4 k |    4 429  |  911.6 |   51.2    |   —    |
| frwk-linux | on N=5 |  ~4 k |    4 445  |  936.5 |   72.5    | **1.42×** |
| frwk-linux | off    | ~32 k |   43 278  |  761.2 |   44.7    |   —    |
| frwk-linux | on N=5 | ~32 k |   45 326  |  726.9 |   61.0    | **1.36×** |

**MoE MTP works** — 1.4× at ~4 k, 1.25-1.36× at ~32 k. TTFT delta MTP-on vs
off is < 5 % (no meaningful prefill penalty).

### Extended-depth sweep — Agents-A1-MTP with `--ctx-size 262144` (native max)

The GGUF advertises `qwen35moe.context_length = 262144` (extended RoPE theta
1e7 baked in — no YaRN scaling). This table measures MTP-on N=5 at the two
depths past the ~32 k reference point, plus a run near the model's ceiling.
`bench_model.py -t 256 -r 2 --cache-prompt` default off (cold prefill per
run). b9925, **2026-07-09** — captured with `--no-host` still on the recipe;
same-day A/B on `frwk-linux` showed the flag is a ≤ 0.6 % no-op on this
workload, so these numbers still stand under the new no-flag recipe. Only
`--ctx-size` was varied: 131 072 for ~64 k / ~128 k, 262 144 for ~256 k.

| Host       | Depth  | Prompt tok | TTFT (s) | PP t/s | Total TPS |
|------------|--------|-----------:|---------:|-------:|----------:|
| frwk-bsd   |  ~64 k |    70 919  |   112    |  631.6 |   49.3    |
| frwk-bsd   | ~128 k |   126 819  |   282    |  449.6 |   42.1    |
| frwk-bsd   | ~256 k |   256 119  | **1 304**|  196.4 |   27.5    |
| frwk-linux |  ~64 k |    70 919  |   126    |  560.9 |   48.9    |
| frwk-linux | ~128 k |   126 819  |   313    |  405.6 |   43.3    |
| frwk-linux | ~256 k |   256 119  | **1 181**|  216.9 |   28.9    |

Observations:

- **KV allocation is free up to 131072** and cheap up to 262144 — server loads
  in seconds at either ceiling, no OOM. Raising `--ctx-size` has zero TG/PP
  cost until you actually fill it.
- **PP TPS decays with filled depth**, matching the O(n²) attention shape:
  ~950 t/s at 4 k → ~800 at 32 k → ~500 at 64 k → ~430 at 128 k → ~210 at
  256 k. Halving happens roughly every 4× depth increase.
- **TG decays too** but far more gently: ~76 → ~57 → ~49 → ~42 → ~28 t/s
  (still 3.6× the dense-27B baseline even at the ceiling).
- **Cold prefill dominates the user-visible cost.** TTFT scales super-linearly
  with depth: 4 k = 4 s, 32 k = 40 s, 64 k ≈ 120 s, 128 k ≈ 300 s, **256 k ≈
  22 minutes**. Warm reuse via prompt-cache (~88×) is the only way to make
  deep depths interactive.
- **Ubuntu wins PP at 256 k** (+10 %) — same cross-OS flip observed on dense
  Q8 at 32 k. Likely GTT-paging behaviour once KV working set exceeds a
  Linux-favourable threshold; not a stable finding.
- **Practical recommendation**: `--ctx-size 131072` is the sweet spot for
  daily use. `--ctx-size 262144` works but only makes sense if you can
  amortize the 20-minute cold prefill across many warm-cache turns.

### `--spec-draft-n-max` sweep at ~4 k

`N` = tokens proposed per verification step. Server default is 16 — a cliff
on both models on b9925.

**Qwen3.6-27B-MTP Q8_K_XL (dense)**:

| n_max | frwk-bsd Total TPS | frwk-linux Total TPS |
|------:|-------------------:|---------------------:|
|     2 |         13.4       |         13.8         |
|     3 |         15.2       |       **16.8** (peak)|
|     4 |         15.3       |         15.7         |
| **5** |       **16.2** (peak)|         16.7         |
|     8 |         13.4       |          9.6         |
|    16 |          9.8       |          8.8         |

**Agents-A1-MTP Q8_0 (MoE)**:

| n_max | frwk-bsd Total TPS | frwk-linux Total TPS |
|------:|-------------------:|---------------------:|
|     2 |         70.4       |         72.2         |
|     3 |         70.4       |         72.7         |
|     4 |       **75.7** (peak)|       **79.1** (peak)|
|     5 |         75.3       |         72.6         |
|     8 |         40.7       |         39.3         |
|    16 |         31.9       |         29.8         |

- **N=4 or 5 is the plateau** on both models, both OSes.
- **N ≥ 8 is a cliff on MoE** (76-79 → 40 → 30 = ~-60 %). On dense, N=8 is
  a moderate dip on FreeBSD (16 → 13) and Ubuntu (17 → 10). N=16 falls
  to ~9-10 (dense) / ~30 (MoE).
- **`llmsrv.sh` sets `--spec-draft-n-max 5`** for `MODEL=mtp` and
  `MODEL=agents-a1-mtp`. Recommend keeping N=5 — safer than N=4 which peaks
  on both hosts here but has a narrower plateau on other builds.

### Memory-bandwidth math

Bandwidth ceiling: 256-bit LPDDR5x-8000 ≈ 256 GB/s.

```
Agents-A1-MTP Q8 tg on frwk-bsd at ~4 k:  75 t/s × ~4 GB active ≈ 300 GB/s
  → 117 % of the naive ceiling → MTP delivers >1 useful token per weight read
Dense 27B Q8 tg off:                       6.4 t/s × ~26 GB ≈ 166 GB/s → 65 %
Dense 27B-MTP Q8 tg on:                   16.1 t/s × ~26 GB ≈ 419 GB/s → 164 %
Qwen3.6-35B-A3B Q4 tg (MoE, no MTP):      56 t/s × ~3 GB ≈ 168 GB/s → 66 %
```

TG on non-MTP models sits at 60-80 % of memory-bandwidth ceiling. MTP breaks
the ceiling by getting multiple accepted tokens per weight read. PP is
compute-shaped (matmul-heavy), which is where the OS-visible pp lead on
FreeBSD comes from.

## ROCm 7.2.4 dead-end (`frwk-linux`, 2026-07-07)

Every ROCm dispatch on gfx1151 faults ~1-2 s after warmup:

```
[gfxhub] page fault (src_id:0 ring:153 vmid:8 pasid:32770)
GCVM_L2_PROTECTION_FAULT_STATUS:0x00800932
Faulty UTCL2 client ID: CPF (0x4)
WALKER_ERROR: 0x1
PERMISSION_FAULTS: 0x3
```

**AMD firmware bug (MES 0x83)**. GPU wedged until reboot. Tracked in
[ROCm/ROCm#5890](https://github.com/ROCm/ROCm/issues/5890),
[#6186](https://github.com/ROCm/ROCm/issues/6186),
[#5724](https://github.com/ROCm/ROCm/issues/5724),
[#5534](https://github.com/ROCm/ROCm/issues/5534),
[#6146](https://github.com/ROCm/ROCm/issues/6146),
[Arch forum 310497](https://bbs.archlinux.org/viewtopic.php?id=310497).

Untested workarounds: `amdgpu.cwsr_enable=0` kernel cmdline; downgrade
linux-firmware-amdgpu to pre-MES-0x83; roll ROCm back to 7.1.

**Decision**: stay on Vulkan. Fully stable, ~2× faster than ROCm was.

## BIOS UMA frame-buffer carve-out (critical)

Large BIOS "dedicated VRAM" carve-outs shrink the GTT pool the Vulkan driver
can use for KV/weights, forcing an extra staging copy and tanking prompt
processing. This is the single biggest tunable on Strix Halo.

| BIOS UMA setting          | VRAM total | GTT total | MoE Q4 PP at d≈4 k    | TG       |
|---------------------------|-----------:|----------:|----------------------:|---------:|
| Large (64 GiB carve-out)  |     64 GiB |   93.7 GiB| **543 t/s**           | 49.5 t/s |
| Small / Auto (512 MiB)    |    512 MiB |   93.7 GiB| **712 t/s** (+31 %)   | 50.0 t/s |
| Reference (`frwk-linux`)  |    512 MiB |   61.4 GiB| 918 t/s               | 55.3 t/s |

Measured on HP ZBook (Ryzen AI MAX+ PRO 395) with identical software to
`frwk-linux`. **Set UMA Frame Buffer to the smallest value** (512 MiB or
"Auto"). Large carve-outs only help legacy code that hardcodes VRAM.

## Firmware power cap (`platform_profile` on laptops)

HP firmware caps GPU PPT (Package Power Tracking, the SoC-wide — System-on-Chip
— power budget) based on ACPI (Advanced Configuration and Power Interface)
`platform_profile`; Framework Desktop does not.

| Host / profile        | PPT avg | PPT p95 | PPT max | GPU max freq | MoE Q4 PP at d≈4 k |
|-----------------------|--------:|--------:|--------:|-------------:|-------------------:|
| zbook `balanced`      |  40 W   |  40 W   |  59 W   | 2070 MHz     |  519 t/s           |
| zbook `performance`   |  69 W   |  70 W   |  70 W   | 2898 MHz     |  741 t/s (+43 %)   |
| frwk-linux `balanced` |  83 W   | 110 W   | 113 W   | 2900 MHz     |  918 t/s           |

p95 = max on zbook is a firmware cap, not thermal throttling. **For laptops,
switch to `performance`** before heavy PP:

```sh
echo performance | sudo tee /sys/firmware/acpi/platform_profile
for c in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
  echo performance | sudo tee "$c" > /dev/null
done
```

Revert to `balanced` when done — 70 W sustained on a laptop spins fans up and
kills battery. TG is unaffected (memory-bound).

## Known crash signatures (FreeBSD `frwk-bsd`)

- **27B dense with `-fa 1 --no-host 1`**: was reported as "crashes on Q4
  always; Q8 unreliable" on Mesa 25.2.8. **Fixed on Mesa 26.1.3.** Verified
  with 10 back-to-back Q4 runs (all clean) and now baked into the default
  recipe (which drops `--no-host` entirely). Historical `vk::DeviceLostError`
  in `ggml_vk_buffer_write_2d` no longer reproduces.
- **Q8 dense cold-start GTT OOM** (Mesa 26.1.3): first Q8 llama-bench or
  llama-server startup after boot occasionally fails with
  `vk::Device::allocateMemory: ErrorOutOfDeviceMemory` even though the model
  (~33 GiB) fits well inside the 120 GiB GTT pool. Retry once — the arena
  warms up and subsequent starts succeed. `bench-all.sh` retries llama-bench
  automatically; llama-server needs a manual restart if it hits this.
- **`RADV_DEBUG=zerovram` on Mesa 25**: actively crashes runs that succeed
  without it. Do not set. (Was required on Mesa 24; the flag is still not
  needed on Mesa 26.)
- **Multi-value `llama-bench` sweeps** (e.g. `-fa 0,1`): crash on graph
  variant 2/3 on Mesa 25 — not retested on Mesa 26. Run one invocation per
  (model, config) pair to stay safe.
- **Reload after crash recovery**: on Mesa 25, subsequent benches often
  crashed even on configs that just succeeded. If you see this on Mesa 26,
  reboot rather than `kldunload amdgpu` + `kldload amdgpu` — the userspace
  Vulkan state does not fully recover from a driver reload.

## The `--no-host` non-finding

Earlier revisions of this doc credited `--no-host` with a large UMA-path
speedup. A direct A/B on `frwk-linux` (2026-07-10, 3 reps each) showed the
flag is a **no-op** on this stack when the BIOS UMA carve-out is small:

| Workload            | `--no-host 1` PP | `--no-host 0` PP | Δ |
|---------------------|-----------------:|-----------------:|--:|
| Dense-27B Q4 d=0    | 267.4            | 266.4            | +0.4 % |
| Dense-27B Q4 d=32k  | 121.2            | 121.9            | −0.6 % |
| MoE Q4 d=0          | 941.8            | 938.5            | +0.3 % |
| MoE Q4 d=32k        | 589.3            | 588.6            | +0.1 % |

All within measurement noise. The real UMA-GTT finding was always the
carve-out size (see the previous section) — `--no-host` matters only if
that carve-out is large enough to force the staging path. With a small
carve-out, the driver keeps everything in GTT regardless of the flag. The
default recipe drops `--no-host` accordingly.

## Pitfalls

- **`--cache-reuse N`** silently disabled on Qwen3-family models (M-RoPE KV
  cache can't be position-shifted). Not a regression — default prompt cache
  gives ~88× warm-reuse speedup.
- **`-hf` auto-loads the multimodal projector** for Qwen3.6-VL-derived
  weights. Pass `--no-mmproj` for text-only.
- **`--reasoning-budget 0`** disables `<think>...</think>` for short mechanical
  tasks. On MoE the savings are small; use `/no_think` inline instead.
- **`bench_model.py` warm-up populates the server prompt cache** — per-run
  TTFT is for cached re-eval. For cold prefill, hit `/v1/chat/completions`
  with curl and read `timings.prompt_n` / `timings.prompt_per_second`.

## Reproducing

```sh
# On each host (frwk-bsd, frwk-linux):
git clone https://github.com/ggerganov/llama.cpp && cd llama.cpp
cmake -B build -DGGML_VULKAN=ON && cmake --build build --config Release
# Then, from ~/myscripts/LLM/:
sh bench-all.sh   # ~2.5 h; produces /tmp/bench-all.md + .jsonl
```

Full script: `~/myscripts/LLM/bench-all.sh`. Model registry lives at the top
of the file; add slots there to bench new GGUFs.

## b10267 re-bench — `agents-a1-mtp` only (2026-08-04)

Scope: **Agents-A1-MTP Q8_0 slot only**, both hosts, llama.cpp **b10267
(`7bd8282c3`)**. Same recipe as the b9925 run above (Vulkan, fa on, b=2048,
ub=512, `--ctx-size 131072 --parallel 1`, `-t 256 -r 2`, no `--no-host`). Motive:
b10267 landed a topk_moe `sqrt(softplus)` fusion (#26124) on the Vulkan MoE hot
path and a server MTP accepted-token-replay correctness fix (#26320); this
measures whether either moved the default coding recipe. Every other model in
the doc is still b9925 — only the rows here are b10267.

Ran via `ONLY=agents-a1-mtp sh bench-all.sh`. (These runs originally needed a
trailing colon — `ONLY="agents-a1-mtp:"` — because `filter_only`'s whitespace
split left the colon on `$1` for colon-adjacent slot names. Fixed 2026-08-04 by
adding `:` to that `gsub` class; the bare slot name now matches.)

### llama-bench — depth sweep

| Host       | depth | pp4096            | tg128         |
|------------|------:|------------------:|--------------:|
| frwk-bsd   |     0 |  1072.62 ± 24.06  | 54.74 ± 0.06  |
| frwk-bsd   |  8192 |   935.07 ± 18.23  | 52.20 ± 0.08  |
| frwk-bsd   | 32768 |   670.06 ± 3.81   | 46.01 ± 0.01  |
| frwk-linux |     0 |   944.08 ± 11.92  | 52.51 ± 0.07  |
| frwk-linux |  8192 |   806.99 ± 7.29   | 49.35 ± 0.12  |
| frwk-linux | 32768 |   586.11 ± 0.46   | 44.20 ± 0.07  |

Raw tg128 is ~2 % higher than b9925 on frwk-bsd (54.7 vs 53.5 at d=0), flat on
frwk-linux — consistent with the fusion helping the FreeBSD Mesa 26 path slightly.

### llama-server + bench_model.py — MTP on/off (N=5)

| Host       | MTP    | Depth | TTFT (ms) | PP t/s | Total TPS | b9925 was |
|------------|--------|-------|----------:|-------:|----------:|----------:|
| frwk-bsd   | off    |  ~4 k |   4410.1  |  919.1 |   52.7    |   51.4    |
| frwk-bsd   | on N=5 |  ~4 k |   3810.4  | 1062.1 | **78.7**  |   75.2    |
| frwk-bsd   | off    | ~32 k |  38498.8  |  855.6 |   45.4    |   44.5    |
| frwk-bsd   | on N=5 | ~32 k |  39644.0  |  831.9 | **59.8**  |   55.7    |
| frwk-linux | off    |  ~4 k |   4711.2  |  853.2 |   50.7    |   51.2    |
| frwk-linux | on N=5 |  ~4 k |   4464.7  |  935.7 | **71.0**  |   72.5    |
| frwk-linux | off    | ~32 k |  43589.7  |  755.9 |   44.1    |   44.7    |
| frwk-linux | on N=5 | ~32 k |  45507.3  |  725.0 | **59.1**  |   61.0    |

MTP multiplier (on/off): frwk-bsd **1.49×** @4k, **1.32×** @32k (was 1.46× /
1.25×); frwk-linux **1.40×** / **1.34×** (was 1.42× / 1.36×).

### `--spec-draft-n-max` sweep at ~4 k (Total TPS)

| n_max | frwk-bsd | frwk-linux |
|------:|---------:|-----------:|
|     2 |   72.5   |    70.1    |
|     3 |   73.3   |    70.4    |
|     4 | **79.9** |  **77.3**  |
|     5 |   79.9   |    73.3    |
|     8 |   45.0   |    38.8    |
|    16 |   34.5   |    29.5    |

N=4/5 remain the plateau; N≥8 is still a hard cliff on both. Keep
`--spec-draft-n-max 5` in `llmsrv.sh`.

### Verdict

FreeBSD gained a real **+4.7 % @4k / +7.4 % @32k** on the default coding recipe;
Ubuntu moved **−2 % / −3 %**, inside run-to-run noise (`-r 2`), i.e. unchanged.
No config change warranted — b10267 is a free modest win on FreeBSD and neutral
on Ubuntu.

## Qwen3.8-27B (`qwen38-mtp` slot) — sidecar MTP is unstable, don't adopt (2026-08-15)

Scope: **`ggml-org/Qwen3.8-27B-GGUF` Q4_K_M + sidecar MTP-Q4_0 draft head**,
`frwk-bsd` only, llama.cpp **b10440 (`6b4344ecc`)**. Prompted by the llama.cpp
author's DGX-Spark recipe (`-hf …:Q4_K_M -hfd …:Q4_0 --spec-type draft-mtp`).
Unlike every other MTP slot here, this model's MTP head is a **separate GGUF**
passed via `--model-draft`/`-hfd`, not embedded. `bench-all.sh` gained a 7th
registry field (`draft`) to support this; `llmsrv.sh` gained `MODEL=qwen38-mtp`.

### Result: verified working end-to-end, but the draft head is too weak and too flaky to use

| Metric                    | Qwen3.8-27B Q4_K_M | vs existing `mtp` (Qwen3.6-27B-MTP Q8, embedded) |
|---------------------------|-------------------:|--------------------------------------------------|
| Baseline TG (spec-off) @4k |          11.2 t/s |  6.4 t/s (Q8 — Qwen3.8 Q4 is a lighter quant)    |
| llama-bench tg128 d=0      |          11.36    |  6.47                                            |
| MTP-on best observed @4k   |     ~26 t/s (2.3×)|  16.1 t/s (2.52×)                                |
| **Draft acceptance**       | **0–31 %, bimodal**| **~80 %** (stable)                              |

### Two separate problems — one is Mesa-26/FreeBSD-only, one is the model

A cross-OS A/B (2026-08-15, both hosts on the SAME llama.cpp `27df9199d`, SAME
GGUF, fixed N=4, 5 cold starts each) split the two cleanly:

| run | frwk-bsd (Mesa 26) | frwk-linux (Mesa 25.2.8) |
|----:|-------------------:|-------------------------:|
|   1 |  0.00 % (dead)     |  33.2 %                  |
|   2 |  31 %              |  34.1 %                  |
|   3 |  0.65 % (dead)     |  34.0 %                  |
|   4 |  40 %              |  37.4 %                  |
|   5 |  LOAD FAULT        |  33.8 %                  |
| **dmesg GPU faults** | **+1** | **0** |

1. **Instability + GPU fault = a Mesa-26/FreeBSD RADV bug, NOT the model and
   NOT intrinsic.** On Ubuntu/Mesa 25 the same binary + same GGUF is rock-steady:
   5/5 clean loads, acceptance tight at 33-37 %, **zero kernel faults**. The
   bimodal 0 %-acceptance dead-loads and the load-time GPUVM fault appear ONLY
   on frwk-bsd. dmesg fingerprint (frwk-bsd): `[gfxhub] page fault`, always the
   same address `0x800100135000`, `client ID: CPC (0x5)`, `PERMISSION_FAULTS
   0x5`, `RW 0x1` (a compute-queue write-permission fault), followed by
   `ring comp_1.x.0 timeout` and `vk::Queue::submit: ErrorDeviceLost`. No GPU
   reset line; each faulting process dies and the next starts fresh and refaults
   the same address — so it is a deterministic bad compute-write in the
   draft-mtp dispatch that Mesa 26 rejects and Mesa 25 handles. This is
   DISTINCT from the ROCm CPF/MES-0x83 firmware bug (that one is `CPF (0x4) /
   WALKER_ERROR 0x1`); do not conflate them. When a dead-load happens every
   drafted token is wasted verify compute, so Total TPS collapses BELOW the
   no-MTP baseline: **7.3 t/s at N=5, 3.4 t/s at N=16** vs 11.2 baseline.
2. **Acceptance is only ~34 % even on the healthy Ubuntu stack.** This is the
   model, not the driver — a q4_0 draft head against a Q4_K_M target is a weak
   match (the embedded `havenoammo` dense head does ~80 %). The ~26 t/s "good"
   frwk-bsd runs ride entirely on that ~34 %, and ~34 % on a dense recipe can't
   beat the MoE default regardless of OS.

### N-max sweep at ~4 k (working runs only; failed/dead runs excluded)

| n_max | Total TPS | note                                  |
|------:|----------:|---------------------------------------|
|     2 |     21.9  |                                       |
|     3 |     24.4  |                                       |
|     4 |     26.4  | peak of the working spins             |
|     5 |     26.5 / 7.3 | bimodal: on/off-summary got 26.5, sweep re-run got 7.3 (0 % accept) |
|     8 |      4.4  | dead-load                             |
|    16 |      3.4  | dead-load                             |

### Verdict

**Do not use `qwen38-mtp` for real work yet, on either host — but for two
different reasons.** On frwk-bsd it is unusable: the Mesa-26 RADV compute-write
fault makes cold starts a coin-flip between ~26 t/s and dead-load/crash. On
frwk-linux it is *stable* but *pointless*: ~34 % acceptance gives a dense recipe
that is still ~3× slower than the `agents-a1-mtp` MoE default (~79 t/s). The
slot + harness wiring are kept (the plumbing is correct and reusable for future
sidecar-MTP models). Two independent things would have to change to make this
worth adopting: (a) a Mesa fix — file/track a RADV bug with the CPC-write
fingerprint above (identical binary+GGUF is clean on Mesa 25, so it is a Mesa 26
regression, not llama.cpp); and (b) a better-trained / higher-precision draft
head to lift acceptance toward the ~80 % the embedded dense MTP achieves. The
DGX-Spark CUDA recipe sidesteps (a) entirely and may pair with a better head in
the NVFP4 path, so it can look fine there while failing here — that is a
driver+head finding, not proof the base model is good.

## Huihui abliterated 27B: Qwen3.8 vs Qwen3.6-MTP (Q8_0, 2026-08-20)

Scope: **`huihui-ai/Huihui-Qwen3.8-27B-abliterated-GGUF` Q8_0** vs
**`huihui-ai/Huihui-Qwen3.6-27B-abliterated-MTP-GGUF` Q8_0**, `frwk-bsd`,
llama.cpp **b10546 (`0e1d9185c`)**. Both are dense 27B (qwen35 arch), Q8_0
(~27 GiB each). Motive: evaluate the abliterated (uncensored) Huihui fine-tunes
for use where the stock Qwen refusal behaviour is in the way. Ran via
`ONLY=huihui-38-q8,huihui-36-q8 sh bench-all.sh`.

**Naming trap:** the repo the request named — `Huihui-Qwen3.6-27B-abliterated-GGUF`
(no `-MTP`) — returns HTTP 401 and does not exist as a public GGUF repo. The real
3.6 abliterated 27B GGUF is `Huihui-Qwen3.6-27B-abliterated-MTP-GGUF`, which ships
an **embedded** MTP head (like havenoammo/Agents-A1, not a sidecar like
`qwen38-mtp`). The 3.8 repo has **no** MTP head at all. So the comparison is
inherently asymmetric: 3.6 can attempt MTP, 3.8 cannot.

### llama-bench — depth sweep (identical, as expected)

| Model                      | Quant | depth | pp4096         | tg128        |
|----------------------------|-------|------:|---------------:|-------------:|
| Huihui-Qwen3.8-27B-abl     | Q8_0  |     0 | 318.47 ± 0.44  | 7.79 ± 0.00  |
| Huihui-Qwen3.8-27B-abl     | Q8_0  |  8192 | 272.92 ± 0.98  | 7.64 ± 0.01  |
| Huihui-Qwen3.8-27B-abl     | Q8_0  | 32768 | 124.61 ± 0.22  | 7.23 ± 0.00  |
| Huihui-Qwen3.6-27B-abl-MTP | Q8_0  |     0 | 318.09 ± 0.41  | 7.80 ± 0.00  |
| Huihui-Qwen3.6-27B-abl-MTP | Q8_0  |  8192 | 272.46 ± 0.94  | 7.64 ± 0.00  |
| Huihui-Qwen3.6-27B-abl-MTP | Q8_0  | 32768 | 125.30 ± 0.38  | 7.23 ± 0.00  |

Same arch + same quant + same size ⇒ **byte-for-byte-equal decode speed**
(~7.8 t/s TG at d=0, ~7.2 at 32 k). Abliteration has zero runtime effect; the
3.8-vs-3.6 base choice is a wash on speed — decide on output quality alone.
Note these Q8 dense TG numbers (~7.8) are slightly higher than the stock
Qwen3.6-27B Q8_K_XL rows earlier in this doc (~6.5) because Huihui ships plain
Q8_0, a lighter quant than unsloth's dynamic Q8_K_XL — fewer bytes/token.

### llama-server + bench_model.py — the 3.6 MTP head is a net loss on frwk-bsd

| Model                      | Quant | Depth | TTFT (ms) | PP t/s | Total TPS |
|----------------------------|-------|-------|----------:|-------:|----------:|
| Huihui-Qwen3.8-27B-abl     | Q8_0  | ~4 k  |  15737.1  | 258.3  |   7.7     |
| Huihui-Qwen3.8-27B-abl     | Q8_0  | ~32 k | 152824.6  | 216.2  |   7.2     |
| Huihui-Qwen3.6-27B-abl-MTP | Q8_0  | ~4 k off  | 14619.1 | 275.1 | 7.7   |
| Huihui-Qwen3.6-27B-abl-MTP | Q8_0  | ~32 k off | 151600.9 | 217.4 | 7.2  |
| Huihui-Qwen3.6-27B-abl-MTP | Q8_0  | ~4 k on N=5  | 13190.5 | 303.6 | **5.1** |
| Huihui-Qwen3.6-27B-abl-MTP | Q8_0  | ~32 k on N=5 | 155229.6 | 212.1 | **4.5** |

MTP-on is **slower than MTP-off** (5.1 vs 7.7 @4k). The plain server-stage row
for 3.6 also hit a cold-start failure (`(server failed)` in the raw table).

### `--spec-draft-n-max` sweep — bimodal garbage, not a plateau

| n_max | Total TPS | note                                   |
|------:|----------:|----------------------------------------|
|     2 |     6.4   |                                        |
|     3 |     5.9   |                                        |
|     4 |    19.9   | outlier — one rep dead-loaded, avg is nonsense |
|     5 |     5.1   |                                        |
|     8 |     3.9   |                                        |
|    16 |    15.1   | outlier — same coin-flip artefact      |

The N=4 / N=16 "wins" are **not real** — they are the averaging artefact of a
bimodal on/dead-load coin-flip (`-r 2` mixes one good rep with one dead-load).
Every genuine MTP-on rep is below the 7.7 spec-off baseline.

### Root cause: same two problems as `qwen38-mtp`

1. **Weak head.** Server log acceptance = **0.29–0.32** (208–213 accepted /
   ~660–723 generated, mean len ~5.4–6.1) — far below the ~0.80 the embedded
   *dense* havenoammo MTP achieves. A ~30 % accept rate can't pay for the
   verify overhead on a dense recipe.
2. **Mesa-26/FreeBSD RADV fault.** dmesg during the run:
   `drmn0: [gfxhub] page fault (src_id:0 ring:40 vmid:2 ...)` +
   `ring comp_1.1.0 timeout` — the same compute-queue fault class documented in
   the `qwen38-mtp` section. It wedges MTP-on cold starts into a dead-load
   coin-flip (hence the bimodal sweep).

### Verdict (frwk-bsd)

- **Both models decode at ~7.7 t/s dense Q8 — a wash on speed.** Pick 3.8 vs 3.6
  on quality; the extra Qwen generation (3.8) is the reasonable default.
- **Do not enable MTP on the 3.6 abliterated model on frwk-bsd.** ~30 %
  acceptance + the Mesa-26 RADV fault make it strictly slower and unstable —
  identical failure mode to `qwen38-mtp`. Run it dense, spec-off.
- **Both are ~10× slower than the `agents-a1-mtp` MoE default (~79 t/s).** Only
  worth running when the abliteration/uncensored behaviour is specifically
  required and ~8 t/s is tolerable.
- **frwk-linux (Mesa 25) cross-check flips the MTP verdict — see below. On
  Ubuntu the 3.6 MTP head works (2.6×), so the frwk-bsd MTP failure is a
  Mesa-26 driver bug, not the model.**

### frwk-linux (Ubuntu / Mesa 25.2.8) — 3.6-abl-MTP works, 2.6× decode

Same GGUF, llama.cpp b10553 (`cd26896c1`), `ONLY=huihui-36-q8 sh bench-all.sh`.
Only the 3.6 slot was re-run on frwk-linux (3.8 has no MTP head, and its dense
speed is already established as OS-neutral).

#### llama-bench

| Model                      | Quant | depth | pp4096         | tg128        |
|----------------------------|-------|------:|---------------:|-------------:|
| Huihui-Qwen3.6-27B-abl-MTP | Q8_0  |     0 | 237.61 ± 1.11  | 7.79 ± 0.00  |
| Huihui-Qwen3.6-27B-abl-MTP | Q8_0  |  8192 | 209.94 ± 0.12  | 7.62 ± 0.00  |
| Huihui-Qwen3.6-27B-abl-MTP | Q8_0  | 32768 |  89.24 ± 0.02  | 7.20 ± 0.00  |

TG matches frwk-bsd exactly (~7.8 → 7.2, memory-bound). PP is lower than
frwk-bsd (237 vs 318 @d=0, 89 vs 125 @32k) — the usual FreeBSD-wins-dense-PP
pattern documented elsewhere in this doc.

#### MTP on/off + N-max sweep — stable, real 2.6× win

| MTP    | Depth | TTFT (ms) | PP t/s | Total TPS | frwk-bsd was |
|--------|-------|----------:|-------:|----------:|-------------:|
| off    | ~4 k  |  18584.6  | 215.7  |   7.6     |   7.7        |
| off    | ~32 k | 195911.2  | 169.3  |   7.2     |   7.2        |
| on N=5 | ~4 k  |  14856.4  | 269.5  | **20.1**  | 5.1 (loss)   |
| on N=5 | ~32 k | 179899.9  | 183.1  | **20.7**  | 4.5 (loss)   |

N-max sweep @4k: N=2→17.2, N=3→**21.1**, N=4→19.7, N=5→20.1, N=8→7.5,
N=16→7.6. N=3–5 plateau; **N≥8 cliff** back to the spec-off baseline (same
shape as every other dense-MTP model here → keep `--spec-draft-n-max 5`).

- **MTP-on = 2.6× decode** (7.6 → 20.1 @4k, 7.2 → 20.7 @32k). Deterministic —
  no bimodal artefacts, all reps consistent.
- **Zero GPU faults** in dmesg across the whole run (frwk-bsd faulted).
- Acceptance **0.25–0.34** (215 acc / 624 gen, mean len ~6.4; etc.) — the *same*
  ~30 % as frwk-bsd. Acceptance is a model/head property, OS-independent. The
  difference is that Mesa 25 turns that 30 % into a real 2.6× win while Mesa 26
  dead-loads on it.

### Verdict (cross-OS)

- **Speed of the base models is a wash** (~7.8 t/s dense Q8, both OSes). Pick 3.8
  vs 3.6 on output quality; 3.8 (newer generation) is the reasonable default —
  *unless* you want MTP, which only 3.6 has.
- **The 3.6 MTP head is genuinely useful — but only on Mesa 25 (frwk-linux).**
  There it gives a stable **2.6× decode (~20 t/s)** at ~30 % acceptance. On
  frwk-bsd / Mesa 26 the identical binary+GGUF dead-loads with a `[gfxhub]`
  compute-queue fault → strictly slower than spec-off. **This is a Mesa-26 RADV
  regression, not a model defect** — the exact same driver split already
  documented for `qwen38-mtp`. The corrected frwk-bsd guidance: run 3.6 dense
  spec-off (MTP unusable there until Mesa is fixed); run it with MTP on
  frwk-linux.
- **Even at 20 t/s, the 3.6-abl-MTP is ~4× slower than the `agents-a1-mtp` MoE
  default (~79 t/s).** These abliterated dense 27B models are for when the
  uncensored behaviour is specifically required; otherwise the MoE default wins
  on speed by a wide margin.

## Qwen3.8-Flash-Next UD-IQ4_XS — one quant step too big (2026-09-04)

> **Superseded for practical use by the UD-IQ3_XXS section below**, which fits
> and runs MTP. Kept because it establishes *where* the 128 GB ceiling bites and
> rules out several candidate causes.

Scope: **`unsloth/Qwen3.8-Flash-Next-GGUF` UD-IQ4_XS (93.7 GB)** + the
`shared-Q8_0` sidecar MTP head, both hosts, llama.cpp **b10801 (`2c967293c`)**
— which is **[PR #28243](https://github.com/ggml-org/llama.cpp/pull/28243)
(`qwen4exp/mtp`), still OPEN, not mainline**. Built to `~/llama.cpp-mtp` so
`~/llama.cpp` and the `llmsrv.sh` endpoints stay on mainline.

A new architecture, not another Qwen3.x repack: arch `qwen4exp`, 125B total /
6B active, 512 experts (10 routed + 1 shared), 48 layers of
`3 × (Gated DeltaNet → MoE) → 1 × (Qwen Sparse Attention → MoE)`, plus a 20 M-entry
n-gram embedding (51B params on its own). Native context 262 144.

### Result: fastest decode-per-parameter here, but 93.7 GB of weights starves the context

| Metric (spec-off)          | frwk-bsd | frwk-linux | vs `moe-q8` (Qwen3.6-35B-A3B Q8) |
|----------------------------|---------:|-----------:|----------------------------------|
| llama-bench pp4096 d=0     |   196.70 | **311.51** | Ubuntu wins PP by **58 %**       |
| llama-bench tg128 d=0      |    24.29 |      24.31 | OS-neutral, as expected          |
| llama-bench pp4096 d=8192  |   192.41 | **291.64** |                                  |
| llama-bench tg128 d=8192   |    22.50 |      22.21 |                                  |
| llama-bench pp4096 d=32768 |   186.95 |  **crash** | bsd fits this depth, Ubuntu does not |
| llama-bench tg128 d=32768  |    19.25 |      crash |                                  |
| server Total TPS @ ~4 k    | **25.8** |       24.4 | `moe-q8` = 44 / 45               |

`± values in bench-all output; server rows are bench_model.py -t 256 -r 2.`
frwk-bsd server row ran at `--ctx-size 32768`, frwk-linux at `16384` — the most
each host would load (see the fit table). The `~32 k` server row is `?` on both:
`coding_prompt_32k.txt` (32 919 tokens) does not fit either context.

### The actual finding: a fit ceiling, not a speed problem

Probed both hosts directly, load-or-die, at 93.7 GB of resident weights:

| `--ctx-size` | MTP | frwk-bsd | frwk-linux |
|-------------:|-----|----------|------------|
| 32768        | off | **yes**  | no         |
| 16384        | off | yes      | yes        |
| 16384        | on  | no       | no         |
| 8192         | on  | no       | no         |

1. **MTP does not load at any context size on either host.** Dropping ctx 4×
   (32768 → 8192) changes nothing, and the failure lands at *draft-model load*
   ~20 s in, not at KV allocation:
   `radv/amdgpu: Not enough memory for command submission` →
   `vk::Queue::submit: ErrorDeviceLost`. The head itself is only 2.6 GB, so this
   is not head size — it is that loading a *second* model needs a Vulkan command
   submission the driver cannot fund once 93.7 GB is resident. Not the Mesa-26
   CPC-write fault documented for `qwen38-mtp`: **0** `[gfxhub] page fault` lines
   in dmesg, and it reproduces identically on Ubuntu/Mesa 25.
   Ruled out as causes: **our own flags** — upstream's bare recipe
   (`--model --model-draft --spec-type draft-mtp --spec-draft-n-max 5`, no
   `--flash-attn`, no batch/ctx/device overrides) dies the same way; and **head
   choice** — `shared-Q8_0` (upstream's pick, borrows token_embd/LM head from the
   target) and the self-contained `Q8_0` both fail. Note upstream's example pairs
   the head with **UD-Q4_K_XL (111 GB)**, which cannot fit here at all, so that
   recipe implicitly assumes >128 GB of memory.
2. **FreeBSD fits more context than Ubuntu on identical silicon** — 32768 vs
   16384 spec-off. Same weights, same build, same 128 GB UMA.
   **OPEN, not investigated:** Ubuntu's 58 % PP lead (311 vs 197 t/s at d=0)
   inverts this doc's usual finding that FreeBSD wins PP on MoE. Decode is
   identical (24.29 vs 24.31), so it is prefill-specific. Deliberately left
   unexplained here — troubleshoot separately rather than guessing a cause.
3. **Q8_0 was never an option.** 192 GB of weights against 128 GB of UMA; so are
   Q6_K_XL (169 GB), Q5_K_XL (158 GB) and Q4_K_XL (111 GB, upstream's own
   recommended pairing). UD-IQ4_XS at 93.7 GB is the largest quant that loads at
   all, and it only leaves room for 16-32 k of context.

### Verdict

**Not adoptable as a coding recipe, and not because it is slow.** Decode is the
best per-parameter result in this document — 24.3 t/s of raw tg128 out of a 125B
model — and Ubuntu's 311 t/s PP is the highest prefill measured here. On the
metric that decides a recipe, though, it loses: 26/24 Total TPS at ~4 k against
`moe-q8`'s 44/45 and the `agents-a1-mtp` default's 79/71, because there is no
MTP to multiply decode and the prefill advantage cannot offset that. The
blockers are structural: usable context caps at 16-32 k against the 131 072 every
other recipe in this doc runs at, and MTP — the entire reason for building an
unmerged PR — cannot load alongside the weights. `agents-a1-mtp` remains the
default.

Two things would change the picture, in order of value:

- **A smaller quant — DONE, and it works.** UD-IQ3_XXS (82 GB) was benched the
  same day and confirms finding 1: freeing 11.8 GB makes MTP load on both hosts
  and lifts spec-off context to ≥65 536. **Use IQ3_XXS, not IQ4_XS, on this
  machine** — see the next section.
- **PR #28243 merging**, so this stops requiring a side build. Track it before
  re-benching — the MTP graph is new code and the failure mode above may simply
  be an unfinished memory-fitting path (`qwen4exp requires ctx_other to be set`
  appears on every start, described in-tree as normal during fitting).

Harness changes made for this run (kept, all models benefit): `bench-all.sh`
gained an 8th registry field (`ctx`) for per-slot `--ctx-size`, sharded-GGUF
support (pass shard `00001`, llama.cpp opens the rest), `--metrics` plus a
`spec_metrics()` scraper so a dead draft head is visible as `0.00000` instead
of masquerading as a merely-slow row, and a quant-column regex that handles
`UD-IQ4_XS`-style names. Note `llama-bench` has **no** `--ctx-size` (it sizes KV
from `-d`), so the field applies to the server stages only.

## Qwen3.8-Flash-Next UD-IQ3_XXS — MTP works here; this is the usable quant (2026-09-04)

Scope: same model/build/harness as the IQ4_XS section above, but
**UD-IQ3_XXS (81.96 GB)** — 11.8 GB smaller. Run directly to test that
section's finding 1 (MTP fails for lack of headroom, not head size).
`--ctx-size 32768`, `shared-Q8_0` head, `--spec-type draft-mtp`.

### Confirmed: the 11.8 GB buys both MTP and 4× the context

| `--ctx-size` | MTP | frwk-bsd | frwk-linux | at IQ4_XS (93.7 GB) |
|-------------:|-----|----------|------------|---------------------|
| 32768        | on  | **UP**   | **UP**     | both failed         |
| 16384        | on  | **UP**   | **UP**     | both failed         |
| 65536        | off | **UP**   | **UP**     | not reachable       |
| 32768        | off | UP       | **UP**     | bsd only            |

### llama-bench depth sweep (spec-off)

| depth | frwk-bsd pp4096 | frwk-linux pp4096 | frwk-bsd tg128 | frwk-linux tg128 |
|------:|----------------:|------------------:|---------------:|-----------------:|
|     0 |  207.42 ± 2.08  |  **312.44 ± 1.98**|  26.45 ± 0.08  |   26.33 ± 0.46   |
|  8192 |  194.17 ± 0.47  |  **291.15 ± 5.37**|  23.97 ± 0.06  |   23.92 ± 0.46   |
| 32768 |  190.45 ± 0.72  |  **224.71 ± 0.66**|  20.11 ± 0.13  |   19.76 ± 0.03   |

Decode is up ~9 % vs IQ4_XS (26.4 vs 24.3 at d=0) and Ubuntu now completes
d=32768, which crashed at IQ4_XS. TG stays OS-neutral at every depth.

### llama-server, spec-off, at `--ctx-size 65536`

Re-run at 65536 to fill the `~32 k` cells the 32768 run could not
(`coding_prompt_32k.txt` is 32 919 tokens). 65536 holds under a real deep prompt
on both hosts — `n_ctx_slot = 65536`, no `ErrorDeviceLost`.

| Depth | frwk-bsd TTFT (ms) | PP t/s | Total TPS | frwk-linux TTFT (ms) | PP t/s | Total TPS |
|-------|-------------------:|-------:|----------:|---------------------:|-------:|----------:|
| ~4 k  |           14 116.7 |  288.0 |  **28.2** |             15 649.9 |  258.9 |      26.9 |
| ~32 k |          115 658.5 |  285.1 |  **21.8** |            132 091.0 |  249.8 |      20.6 |

**The cost of deep context here is TTFT, not throughput.** Total TPS only drops
~23 % from 4 k to 32 k (28.2 → 21.8), but time-to-first-token goes to
**116 s on frwk-bsd / 132 s on frwk-linux** — near two minutes before the first
token appears. PP t/s barely moves (288 → 285), so this is prefill volume, not a
slowdown: ~33 k tokens at ~285 t/s ≈ 115 s. Interactive use at 32 k is therefore
painful on a cold cache regardless of OS; it only pays off across many warm-cache
turns, the same caveat this doc already records for `agents-a1-mtp` at 262 144.

Note frwk-bsd's PP lead inverts here (285 vs 250) — the opposite of the
llama-bench `pp4096` result at the same quant (207 vs 312). The two tools measure
different windows (`bench_model.py` derives PP from TTFT), so do not read them as
contradicting; both are recorded, and the OS gap is the deferred open item above.

### MTP on/off at ~4 k — a real gain, unlike every other sidecar-MTP slot here

| config      | frwk-bsd Total TPS | frwk-linux Total TPS |
|-------------|-------------------:|---------------------:|
| off         |               28.2 |                 26.9 |
| on N=5      |           **37.1** |                 32.7 |
| on N=2/best |         **37.0** (N=2) |           **35.0** (N=2) |
| gain (best) |          **+31 %** |              **+30 %** |

**Draft acceptance 0.74-0.84** on both hosts **on `coding_prompt.txt`** — the
range that makes speculation pay, and the reason this differs from `qwen38-mtp`
(~34 %, pointless) and `huihui-36-q8`. It is prompt-dependent, not a constant: a
short throwaway prompt through `llmsrv.sh` measured 0.372 (32 accepted / 86
drafted). Quote the 4 k-coding-prompt figure only for coding-shaped work.

Mean accepted draft length is ~1.8 tokens, and `/metrics`
`spec_decode_num_accepted_tokens_per_pos_total` shows why: position 0 accepts,
**position 1 accepts zero**. Only the first speculated token ever lands, which
is the mechanism behind N=2 being the peak — larger N drafts tokens that are
never used.

### MTP-on at `--ctx-size 65536`, both depths (N=2)

MTP loads and runs fine at 65536 — `n_ctx_slot = 65536`, no `ErrorDeviceLost` on
either host, so the IQ4_XS-era worry that a deeper context would re-break the
draft head does not apply at 82 GB.

| Depth | Host       | MTP-on Total TPS | spec-off (same ctx) | gain     | accept  | TTFT (ms) |
|-------|------------|-----------------:|--------------------:|----------|--------:|----------:|
| ~4 k  | frwk-bsd   |             36.9 |                28.2 | **+31 %**| 0.76923 |  14 404.9 |
| ~32 k | frwk-bsd   |         **29.6** |                21.8 | **+36 %**| 0.78556 | 118 139.6 |
| ~4 k  | frwk-linux |             34.3 |                26.9 | **+28 %**| 0.78667 |  16 028.3 |
| ~32 k | frwk-linux |         **27.6** |                20.6 | **+34 %**| 0.77322 | 134 510.9 |

**The MTP gain gets *larger* with depth, not smaller** (+31 → +36 % on frwk-bsd),
and MTP-on at 32 k (29.6) beats spec-off at 4 k (28.2). Acceptance is stable at
0.77-0.79 across both depths, so the draft head does not degrade as context
fills. This contradicts the plausible guess that prefill-dominance would dilute
speculation: TTFT is unchanged by MTP (118 s vs 116 s spec-off — MTP accelerates
decode, not prefill), so the whole gain lands on the generation phase, where it
compounds over the 256 generated tokens regardless of how deep the prompt was.

`accepted_tokens_per_pos` still reads **position 0 = 359, position 1 = 0** at
this context — every accepted token is the first speculated one, at both depths.
That is the invariant behind N=2: this head reliably lands exactly one token.

### `--spec-draft-n-max` sweep at ~4 k (Total TPS)

| n_max | frwk-bsd | frwk-linux |
|------:|---------:|-----------:|
|     2 | **37.0** |   **35.0** |
|     3 |     33.8 |       34.4 |
|     4 |     36.2 |       34.6 |
|     5 |  (fault) |       32.9 |
|     8 |     35.7 |       34.4 |
|    16 |  (fault) |       33.4 |

**N=2 is the peak on both hosts, and there is no cliff** — 16 still beats
spec-off (33.4 vs 26.9 on Ubuntu). That is unlike the MoE cliff documented for
`agents-a1-mtp` (50 % drop at N≥8); the curve here is flat-to-slightly-declining
from N=3 to N=16, consistent with a short mean draft length (~1.8) meaning large
N never gets used.

frwk-bsd's `(fault)` at N=5 and N=16 is the **Mesa-26 RADV compute-write fault**,
not memory: 3 dmesg faults with the exact fingerprint already documented for
`qwen38-mtp` — `[gfxhub] page fault`, `Faulty UTCL2 client ID: CPC (0x5)`,
`PERMISSION_FAULTS: 0x5`, `ring comp_1.1.0 timeout`. Ubuntu/Mesa 25 completed all
six N values with zero faults. Note the IQ4_XS failure was a *different* thing
(zero dmesg faults, hit both OSes) — do not conflate them.

### Verdict

**IQ3_XXS is the quant to use for this model on 128 GB UMA, with MTP on,
`--spec-draft-n-max 2`, and `--ctx-size 65536`.** ~37 Total TPS at ~4 k on
frwk-bsd / 35 on frwk-linux, **29.6 / 27.6 still at ~32 k**, 65 k of context
usable with MTP on, and acceptance 0.77-0.79 that holds at depth — MTP earns its
keep at every depth measured, and its advantage widens as context fills. It still does **not** displace `agents-a1-mtp` (79/71) as the coding
default — it is roughly half the speed — but it is the first way to run a 125B
model on this machine at usable speed, and it is the right slot when the larger
model's quality is specifically wanted.

Caveats to respect:

- **frwk-bsd needs the Mesa fix for reliable MTP.** Two of six N values faulted.
  Same RADV bug as `qwen38-mtp`/`huihui-36-q8`; N=2 and N=4 ran clean, so it is
  usable but not dependable. On frwk-linux MTP is stable.
- **Deep context works but is TTFT-bound.** At `CTX=65536` and ~32 k of filled
  depth: 29.6 / 27.6 Total TPS with MTP on, but 118 s / 135 s to first token.
  Throughput at depth is fine; the cold-cache wait is the cost. (The `?` cells in
  the two `--ctx-size 32768` MTP tables above are superseded by the 65536 table —
  they were a context limit, not a failure.)
- **Per-N acceptance is approximate.** The exact values above come from a
  side-channel log tap, because the in-flight run had the old
  `draft_acceptance()` (which read `$NF` — the *mean len* field — not the ratio,
  hence the bogus `1.76`/`1.81` in the raw `Draft accept` column). The 0.74-0.84
  range is solid; per-N attribution is not. `spec_metrics()` (scrapes
  `llamacpp:spec_decode_*` from `--metrics`) now replaces it and is correct for
  future runs.
- **PR #28243 is still unmerged**, so this needs the `~/llama.cpp-mtp` side build.

### Runtime

`llmsrv.sh` gained `MODEL=flashnext`, verified end-to-end on frwk-bsd
(loads, serves, `spec_decode` counters non-zero):

```sh
MODEL=flashnext ./llmsrv.sh
```

The slot forces `LLAMA_DIR=~/llama.cpp-mtp` (mainline cannot do qwen4exp MTP),
lowers `CTX` to 32768 unless the caller set it explicitly, warns above 65536,
pins `--spec-draft-n-max 2`, and refuses to start with a pointer to the build
recipe if `~/llama.cpp-mtp` is missing. It is **not** the default and not a
`USAGE=` alias — `qwen38-mtp` stays the default.
