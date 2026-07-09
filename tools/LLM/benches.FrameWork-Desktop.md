# llama.cpp on Framework Desktop (Strix Halo) — FreeBSD vs Ubuntu

Hardware: AMD Ryzen AI MAX+ 395 (Strix Halo) + Radeon 8060S iGPU (gfx1151),
128 GB LPDDR5x UMA. Backend: Vulkan (Mesa RADV). Same silicon in both hosts —
`frwk-bsd` (FreeBSD 16-CURRENT) and `frwk-linux` (Ubuntu 24.04).

**All measurements: llama.cpp b9925 (`ed8c26150`), 2026-07-08, single build on
both hosts.** Harness: `tools/LLM/bench-all.sh`.

## TL;DR

- **Default coding recipe: `MODEL=agents-a1-mtp`** — 76 t/s TG at 4k on FreeBSD,
  73 t/s on Ubuntu. Q8 MoE + MTP + agentic fine-tune. Beats plain Q4 on speed
  **and** quality.
- **TG is OS-neutral** (memory-bandwidth bound at ~250 GB/s). **PP is
  compiler/scheduler-bound**: FreeBSD wins by 5-27 % on dense; MoE PP is a wash
  or slight FreeBSD lead.
- **MoE MTP works** — ~1.5× decode on Agents-A1-MTP Q8_0. Set
  `--spec-draft-n-max 5`; N ≥ 8 is a cliff (Total TPS drops 50 % on MoE).
- **Dense MTP** (Qwen3.6-27B-MTP Q8) delivers **2.5×** decode (6.5 → 16.5 t/s
  at ~4 k) — even higher gain than MoE MTP.
- **ROCm is dead on gfx1151** (MES 0x83 firmware bug). Vulkan-only.

## Which recipe to use

Total TPS from `bench_model.py -t 256 -r 2` on b9925. `frwk-bsd / frwk-linux`.

| Recipe (`MODEL=`)    | Model                           | TG ~4 k     | TG ~32 k    | Notes                                        |
|----------------------|---------------------------------|------------:|------------:|----------------------------------------------|
| **`agents-a1-mtp`** ★| Agents-A1 Q8 + MTP N=5          | **76 / 73** | **57 / 60** | Default. Q8 + agentic fine-tune.             |
| `agents-a1`          | Agents-A1 Q4_K_M                | 66 / 66     | 56 / 56     | Q4 + agentic tuning; half the disk.          |
| `moe`                | Qwen3.6-35B-A3B Q4_K_XL         | 56 / 56     | 48 / 49     | Older Q4 baseline.                           |
| `moe-q8`             | Qwen3.6-35B-A3B Q8_K_XL         | 44 / 45     | 39 / 40     | Plain Q8. `USAGE=doc` alias.                 |
| `mtp`                | Qwen3.6-27B-MTP Q8_K_XL + N=5   | 16 / 16     | 15 / 14     | Dense MTP: 2.5× vs off, still ~5× slower TG than MoE. |
| `dense`              | Qwen3.6-27B Q4_K_XL             | 12 / 12     | 11 / 11     | Highest quality per token; slow.             |

★ = current default in `tools/LLM/llmsrv.sh`. `USAGE=coding` → `agents-a1-mtp`;
`USAGE=doc` → `moe-q8`.

## Recommended runtime config

`tools/LLM/llmsrv.sh` auto-detects OS/model. Canonical llama-server invocation:

```sh
llama-server \
  -hf protoLabsAI/Agents-A1-MTP-GGUF -hff Agents-A1-MTP-Q8_0.gguf \
  --device Vulkan0 --flash-attn on --no-host --no-warmup --no-mmproj \
  --jinja --spec-type draft-mtp --spec-draft-n-max 5 \
  --batch-size 2048 --ubatch-size 512 \
  --ctx-size 131072 --parallel 1
```

**Footnotes**:
- FreeBSD dense 27B: **drop `--no-host`** (crashes on Q4; Q8 unreliable on Mesa 25).
  Applies to `MODEL=dense` and `MODEL=mtp`.
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

Same silicon (Ryzen AI MAX+ 395 + 128 GB LPDDR5x-8000 UMA), same Mesa 25.2.8.
Differences below are OS/kernel/compiler.

| Component       | `frwk-bsd`                                              | `frwk-linux`                            |
|-----------------|---------------------------------------------------------|-----------------------------------------|
| OS              | FreeBSD 16.0-CURRENT                                    | Ubuntu 24.04.4 LTS (noble)              |
| Kernel          | 6.12-based via drm-kmod                                 | Linux 6.17.0-22-generic                 |
| GPU driver      | [`ocochard/drm-kmod` `strix` branch](https://github.com/ocochard/drm-kmod/tree/strix) | amdgpu in-tree |
| GPU firmware    | `gpu-firmware-amd-kmod-* 20260406.1600018`              | linux-firmware (distro)                 |
| Mesa            | **25.2.8** ([FreeBSD bug 294948](https://bugs.freebsd.org/bugzilla/show_bug.cgi?id=294948)) | **25.2.8-0ubuntu0.24.04.1** |
| Vulkan API      | 1.4.318 (RADV)                                          | 1.4.318 (RADV)                          |
| Compiler        | Clang 21.1.8                                            | gcc 13.3                                |
| CPU governor    | `powerd` adaptive                                       | `performance`                           |
| llama.cpp       | b9925 (`ed8c26150`)                                     | b9925 (`ed8c26150`)                     |

### Installing on FreeBSD

1. Build+install `strix`-branch drm-kmod from
   [github.com/ocochard/drm-kmod](https://github.com/ocochard/drm-kmod/tree/strix).
   Pull matching `gpu-firmware-amd-kmod-*` ports (gc-11-5-1, psp-14-0-1,
   sdma-6-1-1, vcn-4-0-6, vcn-4-0-6-1, vpe-6-1-1, dcn-3-5-1, dmcub-3-5-0,
   imu-11-5-1).
2. Install Mesa 25.2.8 via [FreeBSD PR 294948](https://bugs.freebsd.org/bugzilla/show_bug.cgi?id=294948).
   Verify: `pkg info mesa-libs mesa-dri mesa-libgallium` shows 25.2.8.
3. After every reboot: `sudo kldload amdgpu`. Verify with
   `~/llama.cpp/build/bin/llama-bench --list-devices`.
4. Build llama.cpp with `-DGGML_VULKAN=ON`. Runtime ICD from `mesa-dri`.

## Methodology

Driven by `~/myscripts/tools/LLM/bench-all.sh`. Two harnesses:

- **`llama-bench`**: raw kernel throughput. `pp4096 + tg128` at d=0, 8192,
  32768, fa=1, b=2048, ub=512, r=2, `--no-host` where safe, mmap on.
- **`llama-server` + `bench_model.py -t 256 -r 2`**: real client-server load.
  Server = canonical config, `--ctx-size 65536 --parallel 1`. Prompts:
  `tools/LLM/coding_prompt.txt` (4 004 tok), `tools/LLM/coding_prompt_32k.txt`
  (32 919 tok). **PP TPS = `prompt_tokens / TTFT`** (cold prefill). Total TPS
  includes reasoning tokens (all runs hit 256-token cap, so Total TPS
  underestimates pure decode by a fixed amount that cancels in ratios).
- **MTP sweep**: `--spec-draft-n-max N ∈ {2, 3, 4, 5, 8, 16}` at ~4 k prompt
  for MTP-capable models.

## llama-bench — depth sweep

`--no-host 1` on MoE + dense-on-Ubuntu; dropped on FreeBSD dense 27B (crashes).

| Model             | Quant   | depth | `frwk-bsd` pp4096 | `frwk-bsd` tg128 | `frwk-linux` pp4096 | `frwk-linux` tg128 |
|-------------------|---------|------:|------------------:|-----------------:|--------------------:|-------------------:|
| Qwen3.6-27B       | Q4_K_XL |     0 |   335.05 ± 1.22   |  12.22 ± 0.02    |    263.61 ± 0.60    |    12.22 ± 0.00    |
| Qwen3.6-27B       | Q4_K_XL |  8192 |   281.84 ± 1.37   |  11.78 ± 0.01    |    228.74 ± 0.04    |    11.79 ± 0.02    |
| Qwen3.6-27B       | Q4_K_XL | 32768 |    87.71 ± 2.07   |  10.82 ± 0.00    |    120.94 ± 0.49    |    10.82 ± 0.01    |
| Qwen3.6-27B       | Q8_K_XL |     0 |   232.52 ± 0.43   |   6.50 ± 0.00    |    200.07 ± 0.22    |     6.55 ± 0.00    |
| Qwen3.6-27B       | Q8_K_XL |  8192 |   217.74 ± 1.49   |   6.37 ± 0.00    |    189.36 ± 0.40    |     6.43 ± 0.00    |
| Qwen3.6-27B       | Q8_K_XL | 32768 |    79.24 ± 2.38   |   6.11 ± 0.00    |    107.32 ± 0.07    |     6.13 ± 0.00    |
| Qwen3.6-35B-A3B   | Q4_K_XL |     0 |   979.01 ± 44.71  |  59.05 ± 0.03    |    929.16 ± 8.27    |    58.78 ± 0.00    |
| Qwen3.6-35B-A3B   | Q4_K_XL |  8192 |   895.95 ± 19.52  |  55.70 ± 0.15    |    799.31 ± 1.51    |    54.86 ± 0.01    |
| Qwen3.6-35B-A3B   | Q4_K_XL | 32768 |   656.82 ± 6.98   |  48.61 ± 0.08    |    590.82 ± 2.19    |    48.52 ± 0.08    |
| Qwen3.6-35B-A3B   | Q8_K_XL |     0 |   826.99 ± 23.70  |  45.78 ± 0.09    |    825.58 ± 8.39    |    46.30 ± 0.02    |
| Qwen3.6-35B-A3B   | Q8_K_XL |  8192 |   766.00 ± 19.04  |  44.08 ± 0.02    |    737.18 ± 2.10    |    44.50 ± 0.02    |
| Qwen3.6-35B-A3B   | Q8_K_XL | 32768 |   609.71 ± 11.13  |  39.55 ± 0.00    |    555.03 ± 0.51    |    40.13 ± 0.02    |
| Qwen3.6-27B-MTP   | Q8_K_XL |     0 |   254.20 ± 0.14   |   6.50 ± 0.00    |    205.20 ± 0.59    |     6.55 ± 0.00    |
| Qwen3.6-27B-MTP   | Q8_K_XL |  8192 |   223.07 ± 1.70   |   6.38 ± 0.00    |    184.95 ± 0.33    |     6.42 ± 0.00    |
| Qwen3.6-27B-MTP   | Q8_K_XL | 32768 |    80.06 ± 2.01   |   6.10 ± 0.00    |    105.63 ± 0.09    |     6.13 ± 0.00    |
| Agents-A1         | Q4_K_M  |     0 |  1003.08 ± 15.00  |  71.75 ± 0.07    |    918.52 ± 11.34   |    70.96 ± 0.16    |
| Agents-A1         | Q4_K_M  |  8192 |   866.23 ± 41.08  |  65.59 ± 0.36    |    789.40 ± 1.09    |    64.79 ± 0.24    |
| Agents-A1         | Q4_K_M  | 32768 |   651.80 ± 8.83   |  56.27 ± 0.18    |    577.57 ± 1.58    |    56.09 ± 0.11    |
| Agents-A1-MTP     | Q8_0    |     0 |  1019.59 ± 44.26  |  53.73 ± 0.14    |    915.14 ± 11.21   |    53.29 ± 0.03    |
| Agents-A1-MTP     | Q8_0    |  8192 |   869.14 ± 41.91  |  51.01 ± 0.20    |    792.18 ± 5.36    |    50.55 ± 0.03    |
| Agents-A1-MTP     | Q8_0    | 32768 |   653.72 ± 15.72  |  45.39 ± 0.13    |    578.64 ± 0.25    |    44.95 ± 0.02    |

### Observations

- **TG identical across OSes** at every model/quant/depth (within ~1 %) —
  memory-bandwidth bound.
- **FreeBSD wins dense-Q4 pp at d=0** (+27 %), dense-Q8 pp at d=0 (+16 %),
  MoE-Q4 pp at d=0 (+5 %). MoE-Q8 pp at d=0 is a tie.
- **At d=32768, Ubuntu wins dense pp** (+27-35 %) — likely because FreeBSD
  dense runs without `--no-host` (crash workaround), losing the UMA path when
  the KV cache is large.
- **Agents-A1 vs Qwen3.6-35B-A3B**: same arch, same build, but Agents-A1 is
  published as **Q4_K_M** (~20 GB) while the Qwen3.6 baseline uses unsloth's
  **Q4_K_XL** (~21 GB, dynamic higher-precision layers). The size difference
  explains Agents-A1's ~+20 % TG (71 vs 59 t/s at d=0 on FreeBSD) — it's
  fewer bytes to move across the memory bus per token, not a fine-tune
  runtime advantage. Fine-tune contributes only quality (agentic
  instruction-following, tool use), zero runtime effect.

## llama-server + bench_model.py at ~4 k and ~32 k

Same recipe as `llmsrv.sh` defaults, `--ctx-size 65536 --parallel 1`.

### Q4 / Q8 baselines (MTP-off)

| Model             | Quant   | Depth | host       | TTFT (ms) | PP t/s | Total TPS |
|-------------------|---------|-------|------------|----------:|-------:|----------:|
| Qwen3.6-27B       | Q4_K_XL | ~4 k  | frwk-bsd   |   13 191  | 304.8  |   12.0    |
| Qwen3.6-27B       | Q4_K_XL | ~4 k  | frwk-linux |   15 050  | 266.1  |   12.0    |
| Qwen3.6-27B       | Q4_K_XL | ~32 k | frwk-bsd   |  156 852  | 212.3  |   10.8    |
| Qwen3.6-27B       | Q4_K_XL | ~32 k | frwk-linux |  163 925  | 201.1  |   10.8    |
| Qwen3.6-27B       | Q8_K_XL | ~4 k  | frwk-bsd   |   17 017  | 236.9  |    6.4    |
| Qwen3.6-27B       | Q8_K_XL | ~4 k  | frwk-linux |   16 821  | 238.4  |    6.5    |
| Qwen3.6-27B       | Q8_K_XL | ~32 k | frwk-bsd   |  185 600  | 178.1  |    6.1    |
| Qwen3.6-27B       | Q8_K_XL | ~32 k | frwk-linux |  179 142  | 183.8  |    6.1    |
| Qwen3.6-35B-A3B   | Q4_K_XL | ~4 k  | frwk-bsd   |    4 507  | 888.5  |   56.2    |
| Qwen3.6-35B-A3B   | Q4_K_XL | ~4 k  | frwk-linux |    4 708  | 857.0  |   56.1    |
| Qwen3.6-35B-A3B   | Q4_K_XL | ~32 k | frwk-bsd   |   41 059  | 803.5  |   48.0    |
| Qwen3.6-35B-A3B   | Q4_K_XL | ~32 k | frwk-linux |   44 819  | 734.8  |   48.5    |
| Qwen3.6-35B-A3B   | Q8_K_XL | ~4 k  | frwk-bsd   |    5 030  | 827.9  |   44.0    |
| Qwen3.6-35B-A3B   | Q8_K_XL | ~4 k  | frwk-linux |    5 241  | 767.1  |   44.8    |
| Qwen3.6-35B-A3B   | Q8_K_XL | ~32 k | frwk-bsd   |   47 106  | 723.7  |   39.0    |
| Qwen3.6-35B-A3B   | Q8_K_XL | ~32 k | frwk-linux |   49 447  | 666.4  |   39.8    |
| Agents-A1         | Q4_K_M  | ~4 k  | frwk-bsd   |    4 433  | 905.1  |   66.2    |
| Agents-A1         | Q4_K_M  | ~4 k  | frwk-linux |    4 674  | 858.9  |   65.7    |
| Agents-A1         | Q4_K_M  | ~32 k | frwk-bsd   |   40 033  | 825.7  |   55.6    |
| Agents-A1         | Q4_K_M  | ~32 k | frwk-linux |   45 303  | 727.3  |   55.5    |

- **TG matches llama-bench**: dense 27B ~12 t/s (Q4) / ~6 t/s (Q8); MoE
  ~56 t/s (Q4) / ~44 t/s (Q8); Agents-A1 Q4 ~66 t/s.
- **FreeBSD wins PP at ~4 k on every model**, by +2-6 % on MoE and +14 % on
  dense Q4.
- **At ~32 k**, FreeBSD's PP lead widens on MoE (+9-13 %) but narrows on dense.

## MTP speculative decoding

### Qwen3.6-27B-MTP Q8_K_XL (dense)

| Host       | MTP    | Depth | TTFT (ms) | PP t/s | Total TPS | vs off |
|------------|--------|-------|----------:|-------:|----------:|-------:|
| frwk-bsd   | off    |  ~4 k |   17 780  | 225.5  |    6.5    |   —    |
| frwk-bsd   | on N=5 |  ~4 k |   15 067  | 266.6  |   16.5    | **2.54×** |
| frwk-bsd   | off    | ~32 k |  192 526  | 171.6  |    6.1    |   —    |
| frwk-bsd   | on N=5 | ~32 k |  180 578  | 183.0  |   15.0    | **2.46×** |
| frwk-linux | off    |  ~4 k |   16 810  | 238.9  |    6.5    |   —    |
| frwk-linux | on N=5 |  ~4 k |   16 354  | 244.9  |   16.5    | **2.54×** |
| frwk-linux | off    | ~32 k |  179 615  | 183.6  |    6.1    |   —    |
| frwk-linux | on N=5 | ~32 k |  183 176  | 179.9  |   14.5    | **2.38×** |

Even under MTP, dense Q8 at ~15 t/s is ~5× slower TG than MoE. Use only when
dense quality justifies the cost.

### Agents-A1-MTP Q8_0 (MoE) — the default coding recipe

| Host       | MTP    | Depth | TTFT (ms) | PP t/s | Total TPS | vs off |
|------------|--------|-------|----------:|-------:|----------:|-------:|
| frwk-bsd   | off    |  ~4 k |    3 955  | 1043.5 |   51.8    |   —    |
| frwk-bsd   | on N=5 |  ~4 k |    4 238  |  952.1 |   76.2    | **1.47×** |
| frwk-bsd   | off    | ~32 k |   38 745  |  852.2 |   44.8    |   —    |
| frwk-bsd   | on N=5 | ~32 k |   41 203  |  799.3 |   57.4    | **1.28×** |
| frwk-linux | off    |  ~4 k |    4 694  |  861.6 |   51.2    |   —    |
| frwk-linux | on N=5 |  ~4 k |    4 693  |  877.1 |   72.7    | **1.42×** |
| frwk-linux | off    | ~32 k |   45 435  |  724.6 |   44.7    |   —    |
| frwk-linux | on N=5 | ~32 k |   47 523  |  693.7 |   60.3    | **1.35×** |

**MoE MTP works** — 1.4× at ~4 k, 1.28-1.35× at ~32 k. TTFT delta MTP-on vs
off is < 5 % (no meaningful prefill penalty).

### Extended-depth sweep — Agents-A1-MTP with `--ctx-size 262144` (native max)

The GGUF advertises `qwen35moe.context_length = 262144` (extended RoPE theta
1e7 baked in — no YaRN scaling). This table measures MTP-on N=5 at the two
depths past the ~32 k reference point, plus a run near the model's ceiling.
Same `llmsrv.sh` config as above, only `--ctx-size` raised to 131072 (for
~64 k / ~128 k) and 262144 (for ~256 k). `bench_model.py -t 256 -r 2 --cache-prompt` default off (cold prefill per run). b9925, 2026-07-09.

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
|     2 |         13.5       |         13.8         |
|     3 |         15.3       |       **16.7** (peak)|
|     4 |         15.9       |         15.7         |
| **5** |       **16.3** (peak)|         16.6         |
|     8 |         13.9       |          8.4         |
|    16 |         10.0       |          7.2         |

**Agents-A1-MTP Q8_0 (MoE)**:

| n_max | frwk-bsd Total TPS | frwk-linux Total TPS |
|------:|-------------------:|---------------------:|
|     2 |         71.1       |         72.3         |
|     3 |         71.1       |         70.7         |
|     4 |       **76.5** (peak)|       **74.7** (peak)|
|     5 |         76.0       |         72.9         |
|     8 |         40.2       |         39.2         |
|    16 |         31.5       |         29.6         |

- **N=4 or 5 is the plateau** on both models, both OSes.
- **N ≥ 8 is a cliff on MoE** (76 → 40 → 31 = -58 %). On dense, N=8 is only
  a mild dip on FreeBSD (16 → 14) but Ubuntu falls harder (16 → 8).
  N=16 falls to 10 (dense) / 30 (MoE).
- **`llmsrv.sh` sets `--spec-draft-n-max 5`** for `MODEL=mtp` and
  `MODEL=agents-a1-mtp`. Recommend keeping N=5 — safer than N=4 which peaks
  on one host each and slightly under-performs on the other.

### Memory-bandwidth math

Bandwidth ceiling: 256-bit LPDDR5x-8000 ≈ 256 GB/s.

```
Agents-A1-MTP Q8 tg on frwk-bsd at ~4 k:  76 t/s × ~4 GB active ≈ 305 GB/s
  → 119 % of the naive ceiling → MTP delivers >1 useful token per weight read
Dense 27B Q8 tg off:                       6.5 t/s × ~26 GB ≈ 170 GB/s → 66 %
Dense 27B-MTP Q8 tg on:                   16.5 t/s × ~26 GB ≈ 429 GB/s → 168 %
Qwen3.6-35B-A3B Q4 tg (MoE, no MTP):      56 t/s × ~3 GB ≈ 168 GB/s → 66 %
```

TG on non-MTP models sits at 60-80 % of memory-bandwidth ceiling. MTP breaks
the ceiling by getting multiple accepted tokens per weight read. PP is
compute-shaped (matmul-heavy), which is where the OS-visible pp lead on
FreeBSD comes from.

## ROCm 7.2.4 dead-end (framework2, 2026-07-07)

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

llama.cpp's Vulkan backend with `--no-host` uses the UMA-aware GTT path.
Large BIOS "dedicated VRAM" carve-outs force an extra staging copy and tank
prompt processing.

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
| framework2 `balanced` |  83 W   | 110 W   | 113 W   | 2900 MHz     |  918 t/s           |

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

All on Mesa 25.2.8. `vk::DeviceLostError` in `ggml_vk_buffer_write_2d`;
drm-kmod auto-recovers but userspace Vulkan state degrades. **Reboot is the
only reliable recovery** — `kldunload amdgpu` + `kldload amdgpu` does not
restore Vulkan probing.

- **27B dense with `-fa 1 --no-host 1`**: crashes on Q4 always; Q8 unreliable
  across reboots. MoE + Agents-A1 fine with `--no-host`. `bench-all.sh`
  drops `--no-host` on FreeBSD dense automatically.
- **`RADV_DEBUG=zerovram` on Mesa 25**: actively crashes runs that succeed
  without it. Do not set. (Was required on Mesa 24.)
- **Multi-value `llama-bench` sweeps** (e.g. `-fa 0,1`): crash on graph
  variant 2/3. Run one invocation per (model, config) pair.
- **Reload after crash recovery**: subsequent benches often crash even on
  configs that just succeeded. Reboot between heavy config switches.

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
# On each host (framework, framework2):
git clone https://github.com/ggerganov/llama.cpp && cd llama.cpp
cmake -B build -DGGML_VULKAN=ON && cmake --build build --config Release
# Then, from ~/myscripts/tools/LLM/:
sh bench-all.sh   # ~4 h; produces /tmp/bench-all.md + .jsonl
```

Full script: `~/myscripts/tools/LLM/bench-all.sh`. Model registry lives at the top
of the file; add slots there to bench new GGUFs.
