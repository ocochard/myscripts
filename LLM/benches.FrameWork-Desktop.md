# llama.cpp on Framework Desktop (Strix Halo) — FreeBSD vs Ubuntu

Hardware: AMD Ryzen AI MAX+ 395 (Strix Halo) + Radeon 8060S iGPU (gfx1151),
128 GB LPDDR5x UMA. Backend: Vulkan (Mesa RADV). Same silicon in both hosts —
`frwk-bsd` (FreeBSD 16-CURRENT) and `frwk-linux` (Ubuntu 24.04).

**All measurements: llama.cpp b9925 (`ed8c26150`), 2026-07-10, single build on
both hosts, `--ctx-size 131072` (matches daily-use), no `--no-host` flag (A/B
proved it's a no-op on this stack — see "The `--no-host` non-finding" below).**
Harness: `LLM/bench-all.sh`.

## TL;DR

- **Default coding recipe: `MODEL=agents-a1-mtp`** — 75 t/s TG at 4k on FreeBSD,
  73 t/s on Ubuntu. Q8 MoE + MTP + agentic fine-tune. Beats plain Q4 on speed
  **and** quality.
- **TG is OS-neutral** (memory-bandwidth bound at ~250 GB/s). **PP is
  compiler/scheduler-bound**: FreeBSD wins by 5-40 % on dense at d=0 and MoE
  d≥8k; Ubuntu wins on dense at d=32k.
- **MoE MTP works** — ~1.5× decode on Agents-A1-MTP Q8_0. Set
  `--spec-draft-n-max 5`; N ≥ 8 is a cliff (Total TPS drops 50 % on MoE).
- **Dense MTP** (Qwen3.6-27B-MTP Q8) delivers **2.5×** decode (6.4 → 16.1 t/s
  at ~4 k) — even higher gain than MoE MTP.
- **ROCm is dead on gfx1151** (MES 0x83 firmware bug). Vulkan-only.

## Which recipe to use

Total TPS from `bench_model.py -t 256 -r 2` on b9925. `frwk-bsd / frwk-linux`.

| Recipe (`MODEL=`)    | Model                           | TG ~4 k     | TG ~32 k    | Notes                                        |
|----------------------|---------------------------------|------------:|------------:|----------------------------------------------|
| **`agents-a1-mtp`** ★| Agents-A1 Q8 + MTP N=5          | **75 / 73** | **56 / 61** | Default. Q8 + agentic fine-tune.             |
| `agents-a1`          | Agents-A1 Q4_K_M                | 66 / 67     | 55 / 56     | Q4 + agentic tuning; half the disk.          |
| `moe`                | Qwen3.6-35B-A3B Q4_K_XL         | 56 / 56     | 48 / 48     | Older Q4 baseline.                           |
| `moe-q8`             | Qwen3.6-35B-A3B Q8_K_XL         | 44 / 45     | 39 / 40     | Plain Q8. `USAGE=doc` alias.                 |
| `mtp`                | Qwen3.6-27B-MTP Q8_K_XL + N=5   | 16 / 17     | 15 / 15     | Dense MTP: 2.5× vs off, still ~5× slower TG than MoE. |
| `dense`              | Qwen3.6-27B Q4_K_XL             | 12 / 12     | 11 / 11     | Highest quality per token; slow.             |

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
  in the GGUF, extended RoPE theta 1e7 baked in — no YaRN scaling needed).
  Recommended `--ctx-size`:
  - **`131072`** (default above) — the practical sweet spot. KV reservation
    ~18 GiB in 93 GiB GTT; zero TG/PP cost until you actually fill past ~30 k.
  - **`65536`** — pick this if you never work past ~30 k prompts and want the
    smallest KV footprint (~9 GiB).
  - **`262144`** (native max) — works, no OOM, but cold prefill at the ceiling
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
| Mesa            | **26.1.3** ([FreeBSD bug 294948](https://bugs.freebsd.org/bugzilla/show_bug.cgi?id=294948), `mesa-dri` ships RADV ICD) | **25.2.8-0ubuntu0.24.04.2** |
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
  (32 919 tok). **PP TPS = `prompt_tokens / TTFT`** (cold prefill). Total TPS
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

HP firmware caps GPU PPT based on ACPI `platform_profile`; Framework Desktop
does not.

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
