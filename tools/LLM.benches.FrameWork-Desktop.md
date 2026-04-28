# llama-bench tuning on Framework Desktop (Strix Halo)

Hardware: AMD Ryzen AI MAX+ 395 (Strix Halo) + Radeon 8060S iGPU (gfx1151), 128 GB LPDDR5x UMA.
Models: `Qwen3.6-27B-UD-Q4_K_XL.gguf` (dense, 16.39 GiB) and `Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf` (MoE, 20.81 GiB).
Backends: Vulkan0 (RADV) on both OSes; ROCm0 only on Linux.
Goal: best parameters for **code writing** workloads.

This page compares two systems running the same hardware:

- **`framework`** — FreeBSD 16.0-CURRENT, Vulkan via Mesa 24.1.7 / vulkan-loader 1.4.349, drm-kmod from
  `ocochard/drm-kmod` branch `strix`, AMD firmwares from `ocochard/freebsd-ports` branch `strix-halo`.
  No ROCm available.
- **`framework2`** — Ubuntu 24.04.4 LTS, kernel 6.17.0-22-generic, Vulkan via Mesa (RADV) shipping
  Vulkan 1.3.275, ROCm 7.2.2 (HIP runtime, hipBLAS/hipBLASLt installed).

## TL;DR — Ubuntu vs FreeBSD on Strix Halo

| Topic | FreeBSD | Ubuntu | Verdict |
|-------|---------|--------|---------|
| Vulkan dense pp4096 (Qwen3.6-27B, fa=1) | 290.08 t/s | 274.38 t/s | FreeBSD ~5% faster |
| Vulkan dense tg128 | 11.99 t/s | 12.13 t/s | Tie (within noise) |
| Vulkan MoE pp4096 (Qwen3.6-35B-A3B) | 901.96 t/s | 926.83 t/s | Tie |
| Vulkan MoE tg128 | 52.41 t/s | 54.87 t/s | Tie (Ubuntu +5%) |
| `RADV_DEBUG=zerovram` needed | **YES** (else `vk::DeviceLostError`) | **NO** | Ubuntu Mesa is healthier |
| `-mmp 0` (no mmap) | **CRASHES** (wedges GPU, requires reboot) | **OK** (273.21 t/s) | Mesa 25.2.8 fix |
| `-ctk q8_0 -ctv q8_0` (quantized KV) | **CRASHES** | **OK** (269.43 t/s) | Mesa 25.2.8 fix |
| MoE depth d=8192 (empty-batch) | **CRASHES** (`llama-bench` only) | **OK** | Mesa 25.2.8 fix |
| ROCm backend (HIP) | **N/A** (no ROCm port) | Available but **HANGS on MoE** at any depth | Skip ROCm for MoE on Strix Halo regardless of OS |
| Vision encoder (mmproj) auto-load | OK (CPU/Vulkan path) | **HANGS** — `clip_ctx: CLIP using ROCm0` deadlocks; needs `--no-mmproj` | Ubuntu llama-server gotcha |

**Bottom line**: FreeBSD wins ~5 % on raw Vulkan pp throughput; Ubuntu's newer Mesa is materially more
stable (three crash classes that brick the FreeBSD GPU run cleanly on Ubuntu). For dense and MoE Vulkan
workloads, perf is essentially OS-independent — the silicon is the wall, not the driver. ROCm is not
worth the trouble on Strix Halo: dense models are ~2× slower than Vulkan ([tools/LLM.md](LLM.md)) and
MoE simply hangs.

## Software versions tested

| Component       | FreeBSD `framework`                | Ubuntu `framework2`                       |
|-----------------|------------------------------------|-------------------------------------------|
| OS              | FreeBSD 16.0-CURRENT (n285413)     | Ubuntu 24.04.4 LTS (noble)                |
| Kernel          | main-n285413-4602d45eb3b1 (custom) | Linux 6.17.0-22-generic                   |
| GPU driver      | drm-kmod `ocochard/strix` branch   | amdgpu in-tree                            |
| Firmware        | `freebsd-ports/strix-halo` branch  | linux-firmware (distro)                   |
| Mesa            | 24.1.7                             | 25.2.8 (≈ Vulkan 1.3.275)                 |
| vulkan-loader   | 1.4.349                            | (Mesa-bundled, instance v1.3.275)         |
| ROCm / HIP      | — (not packaged for FreeBSD)       | ROCm 7.2.2, HIP runtime 7.2.53211, ROCk 6.16.13 |
| llama.cpp build | `9d34231bb` (8929)                 | `f42e29fdf` (8961)                        |
| Compiler        | Clang 19.1.7                       | gcc 13.3 (default Ubuntu noble)           |
| CPU governor    | `powerd` adaptive                  | `performance` (set by bench harness)      |

Note: the llama.cpp builds differ by ~32 commits but the relevant kernels (Vulkan dense / MoE
`qwen35moe`) are unchanged between them; we verified by re-running Stage 0 on both.

## Per-stage cross-OS comparison

### Stage 0 — Sanity (Vulkan, fa=0, p=512, d=0)

| OS      | pp512        | tg128        |
|---------|--------------|--------------|
| FreeBSD | 290.03 ± 4.09 | 12.01 ± 0.02 |
| Ubuntu  | 286.02 ± 0.68 | 12.07 ± 0.00 |

Within ±2 % — backends are interchangeable at the silicon level.

### Stage 1 — Core knobs (Vulkan, pp4096+tg128, d=0, b=2048, ub=512, r=2)

| Sub-stage | Config              | FreeBSD pp4096 | FreeBSD tg128 | Ubuntu pp4096 | Ubuntu tg128 |
|-----------|---------------------|---------------:|--------------:|--------------:|-------------:|
| 1.1       | fa=0 f16 KV         | 282.03         | 11.97         | 268.68        | 12.09        |
| 1.2       | fa=1 f16 KV         | **290.08**     | 11.99         | **274.38**    | 12.13        |
| 1.3       | fa=1 q8_0 KV        | **CRASH**      | —             | 269.43        | 12.07        |
| 1b.1      | fa=1 +zerovram      | 285.64         | 11.87         | 273.77        | 12.12        |
| 1b.2      | fa=1 +zerovram --no-host=1 | 287.98 | 11.91         | 273.76        | 12.12        |
| 1b.3      | fa=1 -mmp 0         | **CRASH**      | —             | 273.21        | 12.11        |

**Findings:**
- `-fa 1` is the Stage 1 winner on both OSes (small +pp, no tg cost).
- `RADV_DEBUG=zerovram` costs ~1.5 % pp on FreeBSD and is a hard requirement there. On Ubuntu it's
  unnecessary — pp delta is within noise (273.77 vs 274.38).
- `q8_0` KV cache and `-mmp 0` brick the FreeBSD GPU but run fine on Ubuntu.
- `--no-host` is neutral on both (it documents the UMA topology to the runtime; perf flat).

### Stage 2 — Batch / ubatch sweep (fa=1, d=0)

| -b / -ub      | FreeBSD pp4096 | FreeBSD tg128 | Ubuntu pp4096 | Ubuntu tg128 |
|---------------|---------------:|--------------:|--------------:|-------------:|
| 1024 / 256    | (not tested)   | —             | **276.40**    | 12.13        |
| **2048 / 512**| **287.98**     | 11.91         | 273.88        | 12.12        |
| 4096 / 1024   | 278.36         | 11.98         | 257.21        | 12.12        |

**Finding**: 2048/512 (the FreeBSD winner) is essentially tied with 1024/256 on Ubuntu. The 4096/1024
config is ~5–10 % slower on both OSes. Recommend `--batch-size 2048 --ubatch-size 512` as the cross-OS
default.

### Stage 3 — Depth sweep (Qwen3.6-27B dense, fa=1, b=2048, ub=512)

| Depth | FreeBSD pp4096 | FreeBSD tg128 | Ubuntu pp4096 | Ubuntu tg128 |
|------:|---------------:|--------------:|--------------:|-------------:|
|     0 | 287.98         | 11.91         | 273.88        | 12.12        |
|  8192 | 246.60         | 11.42         | 238.57        | 11.71        |
| 32768 | 131.33         | 10.64         | 124.15        | 10.72        |
| 65536 |  65.57         |  9.59         |  66.34        |  9.70        |

**Finding**: depth scaling is identical (within 3 %) on both OSes — pp drops from ~280 to ~65 t/s as
depth grows from 0 → 64 k, tg degrades only ~20 %. FreeBSD's `pp4096 @ d8192` did **not** crash with
`llama-bench` on dense (it crashes only on the MoE model); Ubuntu ran cleanly throughout.

### Stage 4 — Prompt size sweep (fa=1, b=2048, ub=512)

| Prompt × Depth | FreeBSD       | Ubuntu        |
|----------------|--------------:|--------------:|
| pp2048 @ d8192 | 250.34 / 11.56 | 239.73 / 11.70 |
| pp16384 @ d=0  | 257.27 / 12.02 | 245.04 / 12.11 |

Same shape. Larger prompts incur a small per-token-cost penalty on both OSes.

### Stage 5 — `--ctx-size 131072` stability

Both systems can reserve and serve a 131 072-token context on Vulkan. Memory split (Ubuntu, captured
at server shutdown):

```
| memory breakdown [MiB]                      | total    free     self   model   context   compute    unaccounted |
|   - Vulkan0 (8060S Graphics (RADV GFX1151)) | 63404 = 36131 + (25823 = 16104 +    8790 +     929) +        1449 |
|   - Host                                    |                    958 =   682 +       0 +     276                |
```

Translation: model 16.1 GB + KV (f16, 4 slots × 131k) 8.8 GB + compute 0.9 GB ≈ 25.8 GB on Vulkan0 —
fits easily into the 64 GB GTT/UMA budget on either OS. End-to-end inference at d≈4k context returned
12.31 t/s tg on Ubuntu, matching FreeBSD's ~11.9 t/s.

**Ubuntu-only gotcha**: `llama-server -hf unsloth/Qwen3.6-27B-GGUF` auto-downloads the **vision encoder
(mmproj)** because this is the Qwen3.6-VL series. The CLIP encoder defaults to ROCm0, which hangs at
load time on Strix Halo (same root cause as the MoE ROCm hang below). Workaround: pass `--no-mmproj` —
or rely on Vulkan-only with `--mmproj-offload` overrides. On FreeBSD the same issue does not apply:
there is no ROCm, so CLIP falls back to a working code path automatically.

### Stage 6 — Qwen3.6-35B-A3B MoE on Vulkan

| Depth |  FreeBSD pp4096 | FreeBSD tg128 | Ubuntu pp4096 | Ubuntu tg128 |
|------:|----------------:|--------------:|--------------:|-------------:|
|     0 |          901.96 |         52.41 |        926.83 |        54.87 |
|  8192 | **CRASH** (empty-batch path in `llama-bench`; `llama-server` works with `--no-warmup`) | — | 818.30 | 51.40 |
| 32768 |        (server-only on FreeBSD: 760 PP / 45.1 TG)  | — | 600.44 | 46.07 |
| 65536 |        (n/a)    | —             |        431.69 |        40.52 |

**Finding**: MoE Vulkan is fast and stable on Ubuntu at all depths — Ubuntu reproduces the FreeBSD
`llama-server` results without the empty-batch crash workaround. The `-d N>0` `llama-bench` crash
documented for FreeBSD is gone on Mesa 25.2.8.

### Stage 6b — Qwen3.6-35B-A3B MoE on **ROCm**

Tested only on Ubuntu (FreeBSD has no ROCm). Result: **HANGS**. Probe with reduced workload
(`-p 1024 -n 64 -r 1 -d 0`) timed out at 5 min (CPU 100 %, GPU 0 % busy). Same hang at d=8192. ROCm
HIP loads the model but never schedules MoE expert kernels successfully on gfx1151. Stick to Vulkan
for MoE on Strix Halo regardless of OS.

ROCm dense Qwen3.6-27B was **not benchmarked** on this run (the multi-backend matrix invocation hung
similarly). Per `tools/LLM.md` benchmarks on smaller models, ROCm pp is comparable to Vulkan but tg is
~½, so dense ROCm has no upside on this hardware either.

## Recommended runtime config (cross-OS)

The same flags work well on both OSes; the only OS-specific bit is `RADV_DEBUG`:

```sh
# FreeBSD: prefix with RADV_DEBUG=zerovram to avoid vk::DeviceLostError.
# Ubuntu:  no RADV_DEBUG needed.

build/bin/llama-server \
  -hf unsloth/Qwen3.6-35B-A3B-GGUF:UD-Q4_K_XL \
  --device Vulkan0 \
  --flash-attn on \
  --no-host \
  --no-warmup \
  --batch-size 2048 --ubatch-size 512 \
  --ctx-size 65536 \
  --jinja
```

On Ubuntu, also pass `--no-mmproj` if the model has a vision projector you don't need (Qwen3.6-VL
does); otherwise `llama-server` will hang on CLIP load.

## Memory bandwidth as the wall

[A blog post benchmarking the Framework Laptop 13 with Ryzen AI 9 HX 370 + Radeon 890M](https://msf.github.io/blogpost/local-llm-performance-framework13.html)
reports ~75 % memory-bandwidth utilization for Vulkan inference and identifies the 89.6 GB/s
DDR5-5600 bus as "the hard wall." The Strix Halo Framework Desktop benched here has roughly **3×
that bandwidth** (256-bit LPDDR5x ≈ 256 GB/s theoretical) and ~2.5× more CUs (40 vs 16). Translating
our tg128 numbers (12 t/s on a 16.4 GB Q4 model) to bandwidth:

```
16.4 GB × 12 t/s = 197 GB/s ≈ 77 % of the 256 GB/s theoretical max
```

— almost exactly the same utilization ratio, on different silicon. This confirms tg is **memory-bound,
not compute-bound or driver-bound** on this hardware. That's why FreeBSD and Ubuntu post identical tg
numbers despite very different driver stacks: there's no software headroom to claim, only bandwidth.
PP is more compute-shaped (matmul-heavy) and that's where the ~5 % FreeBSD/Ubuntu gap appears.

---

# FreeBSD-only deep-dive (the original tuning narrative)

What follows is the FreeBSD-side multi-stage tuning that produced the recommendations above. Stages
1-6 below were re-run on Ubuntu (results in the comparison tables above); the narrative — including
crash signatures, workarounds, and the FreeBSD-specific drm-kmod context — is preserved verbatim
because most of it is what one needs when reproducing this on another FreeBSD machine.

## Methodology

Coding workloads care about both:
- **Prompt processing (pp)**: speed of ingesting code context (files, diffs, conversation).
- **Token generation (tg)**: speed of emitting code.

Multi-stage tuning to keep total runtime tractable:
1. Stage 1 — Core knobs (fa, mmap, no-host, KV cache type) at d=0.
2. Stage 2 — Batch / ubatch on winner.
3. Stage 3 — Depth sweep.
4. Stage 4 — Prompt size sweep & final recommendation.

Note: an initial run with `-mmp 0 --no-host 1 -d 32768` triggered a Vulkan
`DeviceLostError`. Started with safer defaults and ramped up cautiously.

## Build / model detection note

Current llama.cpp build: `9d34231bb (8929)`. Under this build, the model is
detected as a **dense `qwen35 27B Q4_K - Medium` (16.39 GiB, 26.90 B params)**
— not as MoE like the older `94ca829b6 (8679)` build in the doc above (which
showed `qwen35moe 35B.A3B`, 20.70 GiB). This explains why current tg numbers
(~12 t/s) are far below the previous ~50 t/s: the dense path activates all
weights per token instead of routing 3B active params through MoE. Tuning
results below apply to the **current** detection.

After several `vk::DeviceLostError` crashes pre/post-reboot, the GPU stabilized
once a small baseline run (`-p 512 -n 128 -r 2`) succeeded. All Stage 1+ runs
below were stable.

## Baseline (sanity)

| test  |   t/s         |
| ----- | ------------- |
| pp512 | 290.03 ± 4.09 |
| tg128 |  12.01 ± 0.02 |

## Stage 1 — Core knobs (pp4096 + tg128, d=0, b=2048, ub=512, r=2)

| -fa | type_k | type_v | test   |   t/s         |
| --- | ------ | ------ | ------ | ------------- |
|  0  | f16    | f16    | pp4096 | 282.03 ± 0.74 |
|  0  | f16    | f16    | tg128  |  11.97 ± 0.01 |
|  1  | f16    | f16    | pp4096 | 290.08 ± 0.36 |
|  1  | f16    | f16    | tg128  |  11.99 ± 0.05 |
| 1   | q8_0   | q8_0   | —      | **CRASH** (vk::DeviceLostError) — quantized KV cache unsupported on RADV here |

**Stage 1 winner**: `-fa 1` with f16 KV cache. (+2.8% pp, tg unchanged.) q8_0
KV cache is unusable on this build; do not retry.

## Workaround for vk::DeviceLostError

After enabling `kern.msgbufsize=524288` and `drm.debug=0xff`, captured a clean
trace and confirmed the workaround:

```
RADV_DEBUG=zerovram ./llama-bench ...
```

`zerovram` zeroes newly-allocated VRAM, which prevents the device-loss. This
indicates a RADV/ACO bug on **GFX1151 (Strix Halo)** where some shader is
reading **uninitialized GPU memory**. Cost: ~1.5% pp regression (285.64 vs
290.08 t/s at pp4096+fa1+f16-KV).

All subsequent stages run with `RADV_DEBUG=zerovram` set in the environment.

## Stage 1b — mmap / no-host (with RADV_DEBUG=zerovram, pp4096+tg128, d=0, fa=1, r=2)

| -mmp | --no-host | test    |   t/s         | notes |
| ---- | --------- | ------- | ------------- | ----- |
| 1    | 0         | pp4096  | 290.08 ± 0.36 | (Stage 1 baseline) |
| 1    | 0         | tg128   |  11.99 ± 0.05 | |
| 1    | 0         | pp4096  | 285.64 ± 0.75 | with zerovram (~1.5% slower) |
| 1    | 0         | tg128   |  11.87 ± 0.18 | |
| 1    | 1         | pp4096  | 287.98 ± 0.63 | --no-host 1, zerovram |
| 1    | 1         | tg128   |  11.91 ± 0.00 | |
| 0    | 0         | —       | **CRASH**     | -mmp 0 still crashes even with zerovram (Vulkan device wedged) |

**Stage 1b winner**: `--mmap 1` (default) + `--no-host 1`. `--no-host` is
~+0.8% pp neutral on tg vs default. `-mmp 0` is unusable — wedges the
Vulkan device hard enough that `kldunload/kldload amdgpu` cannot recover
it (Vulkan probe finds no devices); requires a reboot.

## Status — paused

- Host **framework** unreachable since ~16:30 (FreeBSD likely doing fsck or
  awaiting console input after kernel hang).
- Need: power-cycle / console check, then `sudo kldload amdgpu` after boot.

### What is settled
- `-fa 1` is +2.8% pp over `-fa 0`; tg unchanged. **Use `-fa 1`.**
- KV cache **must stay f16** — `q8_0` crashes Vulkan/RADV on this build.
- `-mmp 0` crashes Vulkan/RADV on this build (at least when combined with
  this model size). Leave `--mmap 1` (default).
- llama.cpp build `9d34231bb (8929)` detects the model as **dense 27B**
  (16.39 GiB, 26.90 B params), not MoE 35B.A3B as in the older `8679`
  build — explains tg dropping from ~50 t/s to ~12 t/s vs. the previous
  numbers in `Framework-desktop.md`.

### Resume plan when host is back

1. `ssh framework "sudo kldload amdgpu && kldstat | grep amdgpu"`
2. Sanity baseline: `-p 1024 -n 64 -fa 1 -r 1` — confirm Vulkan is alive.
3. Stage 1b finish (one at a time, separated by sanity checks):
   - `-fa 1 --no-host 1` (mmap default = 1).
4. **Stage 2** — batch / ubatch on winner: `-fa 1 -b 1024,2048,4096
   -ub 256,512,1024` at pp4096+tg128, d=0. Run **single-config invocations**
   to avoid the multi-value crash pattern seen in Stage 1.
5. **Stage 3** — depth sweep on winner: `-d 0`, then `8192`, then `32768`,
   then `65536`. Stop at the first crash; the previous depth is the ceiling.
6. **Stage 4** — prompt size sweep on winner: `-p 2048,8192,16384`.
7. **Final** — write recommendation block (flags ready to paste into
   `llama-server`, expected pp/tg at typical and worst-case depth).

## End-to-end validation via llama-server + tools/bench_model.py

Started `llama-server` with the recommended config and ran
`tools/bench_model.py` against three deterministic prompts of increasing
size, no prompt cache, 3 runs + warm-up each, max_tokens=256, temp=0.0.

```
RADV_DEBUG=zerovram llama-server -m <model> --device Vulkan0 \
  --flash-attn on --no-host --batch-size 2048 --ubatch-size 512 \
  --ctx-size 65536 --port 8080 --host 127.0.0.1
```

| Prompt size | TTFT avg  | PP TPS | Total TPS | ITL P95  | comparable llama-bench config |
| ----------- | --------- | -----: | --------: | -------- | ----------------------------- |
|  4089 tok   |   14.4 s  |  285.6 |     11.7  |  85.9 ms | pp4096 @ d=0    → 287.98 / 11.91 |
| 12468 tok   |   47.0 s  |  265.3 |     11.4  |  88.7 ms | pp4096 @ d=8192 → 246.60 / 11.42 |
| 38589 tok   |  202.7 s  |  190.5 |     10.4  |  96.5 ms | pp4096 @ d=32768 → 131.33 / 10.64 |

**Cross-validation analysis:**

- **Token generation matches within 2%** at every depth — llama-bench's
  tg numbers are reliable predictors of real server tg.
- **PP TPS at d=0 matches within 1%** (285.6 vs 287.98) — the server
  ingestion path costs essentially nothing on top of raw decode.
- **PP TPS at deeper context diverges in the server's favor**: at the
  ~36k mark, the server hits 190.5 t/s vs llama-bench's 131.3 t/s
  (+45%). The reason: `llama-bench -p 4096 -d 32768` measures
  processing 4k *on top of* a 32k pre-filled KV cache (per-token cost
  is dominated by the 32k attention reads), while the server processes
  the 36k prompt as one contiguous batch (better cache locality, batch
  efficiency).
- **Real interactive coding behavior is closer to the server measurement**
  — when you paste a 36k context block, the server processes it as one
  batch, not as deltas on top of pre-existing context.
- **No GPU crashes across all three depths** with the recommended
  config. Stable.

**Updated expectations for typical coding sessions:**
- Fresh ~4k context: TTFT ~14 s, then ~12 t/s → first 256 tokens in
  ~36 s.
- Mid-session ~12k context: TTFT ~47 s, then ~11.4 t/s.
- Deep ~36k context: TTFT ~3.4 min, then ~10.4 t/s.

`bench_model.py` was extended this session: `--prompt-file`,
`--cache-prompt` (default off), PP TPS metric (`prompt_tokens / TTFT`
via `stream_options.include_usage`).

## llama-server validation (--kv-unified)

`--kv-unified` is not exposed by `llama-bench`, so it was tested via
`tools/bench_model.py` against `llama-server`. Identical 4k-token coding
prompt, 256 max_tokens, temperature 0, seed-equivalent (greedy), 3 runs +
warm-up, `cache_prompt=false` so each run re-ingests the prompt:

| Config              | PP TPS | Total TPS | TTFT     |
| ------------------- | -----: | --------: | -------: |
| without `--kv-unified` | 279.5  | 11.8      | 14328 ms |
| with    `--kv-unified` | 280.0  | 11.7      | 14298 ms |

Delta < 0.5% — within run-to-run noise. `--kv-unified` only matters when
serving concurrent requests across parallel slots; for a single coding
client it's a no-op.

`tools/bench_model.py` was extended for this comparison: PP TPS metric
(prompt_tokens / TTFT), `--prompt-file`, `--cache-prompt` flag (default
off so PP measurements aren't poisoned by KV cache reuse), and
`stream_options.include_usage` to get prompt_tokens out of streamed
responses.

### Known crash signatures (do not retry)
- `-mmp 0` (any combo) — wedges Vulkan; `kldunload/kldload amdgpu` cannot
  recover (Vulkan probe finds no devices); requires reboot.
- `-dio 1` / `--direct-io 1` — same wedge pattern as `-mmp 0` (also bypasses
  page cache). Crashes pp4096+fa1+no-host=1+zerovram. Requires reboot.
- `-ctk q8_0 -ctv q8_0` — quantized KV cache unsupported by RADV here.
- Multi-value sweeps (e.g. `-b 1024,2048,4096 -ub 256,512,1024`) that
  produce many ggml graph variants in one run. Split into single-config
  invocations.

## Stage 2 — Batch / ubatch (single-config, pp4096+tg128, d=0, fa=1, no-host=1, r=2)

| -b   | -ub  | test    |   t/s         |
| ---- | ---- | ------- | ------------- |
| 2048 | 512  | pp4096  | 287.98 ± 0.63 |
| 2048 | 512  | tg128   |  11.91 ± 0.00 |
| 4096 | 1024 | pp4096  | 278.36 ± 0.23 |
| 4096 | 1024 | tg128   |  11.98 ± 0.00 |

**Stage 2 winner**: default `-b 2048 -ub 512` (the larger 4096/1024 is ~3%
slower on pp, tg essentially unchanged). The doc's previous
`--batch-size 4096 --ubatch-size 1024` choice helped under the old MoE
detection but does **not** help with the current dense detection.

## Stage 3 — Depth sweep (pp4096+tg128, fa=1, no-host=1, b=2048, ub=512, r=2)

| -d    | test            |   t/s         |
| ----- | --------------- | ------------- |
|     0 | pp4096          | 287.98 ± 0.63 |
|     0 | tg128           |  11.91 ± 0.00 |
|  8192 | pp4096 @ d8192  | 246.60 ± 0.78 |
|  8192 | tg128  @ d8192  |  11.42 ± 0.24 |
| 32768 | pp4096 @ d32768 | 131.33 ± 0.21 |
| 32768 | tg128  @ d32768 |  10.64 ± 0.04 |
| 65536 | pp4096 @ d65536 |  65.57 ± 0.31 |
| 65536 | tg128  @ d65536 |   9.59 ± 0.03 |

Key observation: prompt processing degrades sharply with depth (FA scales
as O(n) per token but pp does many tokens), tg degrades gently
(-20% from d=0 to d=65536). For coding workloads typical depth is
8k–32k; expect 130–250 t/s pp and 10.6–11.4 t/s tg.

## Stage 4 — Prompt size sweep (fa=1, no-host=1, b=2048, ub=512, r=2)

| -p    | -d   | test            |   t/s         |
| ----- | ---- | --------------- | ------------- |
|  2048 | 8192 | pp2048 @ d8192  | 250.34 ± 0.16 |
|  2048 | 8192 | tg128  @ d8192  |  11.56 ± 0.04 |
|  4096 |    0 | pp4096          | 287.98 ± 0.63 |
|  4096 | 8192 | pp4096 @ d8192  | 246.60 ± 0.78 |
| 16384 |    0 | pp16384         | 257.27 ± 0.38 |
| 16384 |    0 | tg128           |  12.02 ± 0.01 |

Larger prompts have slightly **lower** pp/s (the per-token cost rises with
in-flight context). At realistic coding depth (d=8k), pp2048 and pp4096 are
within 1.5% of each other — prompt size matters less than depth.

# Final recommendation — `llama-server` flags for code writing

```sh
RADV_DEBUG=zerovram \
build/bin/llama-server \
  -m ~/.cache/huggingface/hub/models--unsloth--Qwen3.6-27B-GGUF/snapshots/82d411acf4a06cfb8d9b073a5211bf410bfc29bf/Qwen3.6-27B-UD-Q4_K_XL.gguf \
  --alias qwen36-coder \
  --device Vulkan0 \
  --temp 0.6 --top-p 0.95 --top-k 20 --min-p 0.00 \
  --flash-attn on \
  --no-host \
  --batch-size 2048 --ubatch-size 512 \
  --ctx-size 65536
```

**Why these settings:**
- `RADV_DEBUG=zerovram` — required to avoid `vk::DeviceLostError` crashes
  on this RADV/GFX1151 + drm-kmod combo. Cost ~1.5% pp.
- `--flash-attn on` — +2.8% pp, free.
- `--no-host` — +0.8% pp, free, and reduces host memory pressure on this
  UMA system.
- Default `--batch-size 2048 --ubatch-size 512` — `4096/1024` is 3% slower.
- `--ctx-size 65536` — proven stable; deeper contexts untested but tg holds
  up well so up to 131072 (the doc's prior value) likely also works.
- f16 KV cache (default) — q8_0 KV crashes Vulkan here.
- **Removed** `-mmp 0` / `--no-mmap` from the doc's prior config — wedges
  the GPU on this build.
- **Removed** `--direct-io` — also crashes the GPU (same wedge as `-mmp 0`).
- **Removed** `--kv-unified` — tested via `tools/bench_model.py` against
  `llama-server` with a 4k-token coding prompt × 3 runs (+ warm-up). No
  measurable effect for single-client coding workloads (PP 279.5 vs
  280.0 t/s; tg 11.8 vs 11.7 t/s — well within variance). The flag
  controls KV layout across **parallel slots**; with one client it's a
  no-op. Re-test if you ever serve concurrent requests.

**Expected throughput at typical coding depth (d=8192):**
- Prompt processing: ~247 t/s (pp4096) → ingesting a 4k-token codebase
  context takes ~16 s.
- Token generation: ~11.4 t/s → roughly 680 tokens/min, or one short
  function per minute.

**Note on tg vs the prior doc:** the previous `Framework-desktop.md` showed
~50 t/s tg128 because llama.cpp build `94ca829b6 (8679)` detected the
model as MoE (`qwen35moe 35B.A3B`, only 3B active params per token). Build
`9d34231bb (8929)` detects it as dense `qwen35 27B`, activating all 27B
params per token — that's the cause of the ~4× tg drop. If MoE behavior
matters, **either** rebuild llama.cpp at the older `8679` commit, **or**
wait for upstream to restore MoE detection for this Qwen3.6 model.

## Stage 5 — Validating `--ctx-size 131072` (for qwen-code agent use)

Goal: 65 k truncates real qwen-code agentic loops; check whether the
GPU/driver can cope with `--ctx-size 131072` and what the throughput
penalty is at deep context.

Server config (one slot, full ctx available):

```sh
RADV_DEBUG=zerovram build/bin/llama-server ... \
  --ctx-size 131072 --parallel 1
```

Bench: `tools/bench_model.py --prompt-file <file> -t 64 -r 1` (with the
HTTP timeout bumped to 1800 s — at deep context, prefill alone is over
5 min and easily blows the previous 300 s default).

| Prompt file                | Tokens (incl. chat tmpl) | TTFT       |  PP TPS | tg t/s | ITL ms |
| -------------------------- | -----------------------: | ---------: | ------: | -----: | -----: |
| `coding_prompt.txt`        |              ~4 067      |    14.3 s  |   279.6 |   11.9 |   85   |
| `coding_prompt_32k.txt`    |             ~30 414      |   140.1 s  |   217.0 |   10.8 |   94   |
| `coding_prompt_96k.txt`    |             ~91 382      |   980.9 s  |    93.1 |    9.1 |  112   |
| `coding_prompt_120k.txt`   |            ~114 482      |  1552.5 s  |    73.7 |    8.5 |  120   |

**No crash anywhere up to 114 k depth** (~87 % of the 131 072 ctx).
At d≈114k, prefill alone takes **~26 minutes** for a single response,
and tg drops to 8.5 t/s. Past ~90 k depth the system is technically
working but no longer interactive.

Implications for `--ctx-size 131072`:

- Driver-stable at the depths tested (no `vk::DeviceLostError`, no
  `[drm] *ERROR*`). Memory budget (~16 GB KV at 128 k f16 + ~16 GB
  weights) fits the 64 GB GTT.
- **Throughput collapses sharply**: PP drops from 280 t/s at d=4k to
  93 t/s at d=91k. TTFT for a near-full context is **15+ minutes**.
  This is FA scaling (O(n) per generated token, but PP processes
  many tokens so it's effectively quadratic in depth at the prefill
  phase).
- For interactive coding, **65k stays the better default**. Bump to
  131072 only when you need it (long agentic sessions); accept that
  the first response on a deep context will take many minutes.

The recommended config in `Framework-desktop.md` therefore stays at
`--ctx-size 65536`. For qwen-code: configure the agent to summarize
or drop earlier turns rather than letting context grow past 65k —
that keeps interactive latency tolerable.

### Tooling change made for this stage

`tools/bench_model.py`: bumped per-request `urlopen` timeout
`300 → 1800` s. Without this, deep-context prefill races the client
timeout and the run shows `Error: timed out` even though the server
is happily processing (PP ~93 t/s × 91 k tokens ≈ 16 min prefill).


## Stage 6 — Qwen3.6-35B-A3B MoE (build 9d34231bb / 8929)

The dense Qwen3.6-27B benched above is great quality but **slow on
this hardware**: ~9-12 t/s tg, and ~127 t/s cold prefill at d≈65k means
each fresh qwen-code session takes ~9 min just to ingest its repo
context. Unsloth ships a sibling MoE variant —
`unsloth/Qwen3.6-35B-A3B-GGUF` (35B total, 256 experts, 8 active per
token, ~3B active params per forward pass) — that was a better fit.

### Setup

- File: `Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf` (22.4 GB)
- Architecture: `qwen35moe`, n_expert = 256, n_expert_used = 8,
  detected as `qwen35moe 35B.A3B` in the model loader
- Same launch flags as 27B (RADV_DEBUG=zerovram, FA on, no-host,
  b=2048/ub=512, ctx=65k, parallel=1) **plus `--no-warmup`**.

### Quirk: warmup decode crashes the GPU

llama-server's default warmup decode (`common_init_from_params`
issues an empty-batch decode to prime caches) hits a
`vk::DeviceLostError` in `ggml_vk_buffer_write_2d` for this MoE
model. The same workload via `llama-bench` runs fine, so it's the
empty-batch path that crashes, not the model itself. **Use
`--no-warmup`** to skip it; first real request after startup serves
as warmup.

`llama-bench -d N>0` (depth seeding) hits the same crash — also
empty-batch. Use real prompts via `bench_one.sh` to measure depth.

### Results (real prompts via curl, cold prefill)

| Depth (tokens) | Wall | PP TPS | TG TPS |
| ------:        | ---: | -----: | -----: |
|    4 004 |    6.2 s |   810 | 49.7 |
|   15 909 |   20.4 s |   840 | 48.1 |
|   30 475 |   41.7 s |   760 | 45.1 |
|   49 353 |   75.1 s |   673 | 41.8 |

`llama-bench` at d=0:

| test | t/s |
| ---- | --- |
| pp4096 | 901.96 ± 32.75 |
| tg128  |  52.41 ± 0.02  |

### Comparison vs. Qwen3.6-27B dense at the same depths

| Depth | 27B dense PP | MoE PP   | speedup | 27B dense TG | MoE TG | speedup |
| ----: | -----------: | -------: | ------: | -----------: | -----: | ------: |
| ~4k   | 285.6 t/s    | 810 t/s  | 2.8×    | 11.7 t/s     | 49.7   | 4.2×    |
| ~12k  | 265.3 t/s    | ~840 t/s | 3.2×    | 11.4 t/s     | 48.1   | 4.2×    |
| ~30k  | 190.5 t/s    | 760 t/s  | 4.0×    | 10.4 t/s     | 45.1   | 4.3×    |
| ~50k  | ~150 t/s     | 673 t/s  | 4.5×    | ~10 t/s      | 41.8   | 4.2×    |

For the qwen-code use case (50–60k of repo context per session), the
MoE turns the 9-minute cold prefill into ~75 seconds, and per-turn
generation from ~110 s of thinking to ~25 s.

### Recommendation

Switch the default `~/llmsrv.sh` model from
`Qwen3.6-27B-GGUF:UD-Q4_K_XL` (16 GB, dense) to
`Qwen3.6-35B-A3B-GGUF:UD-Q4_K_XL` (22 GB, MoE), and add
`--no-warmup` to the launch line. ~4× faster on every metric, fits
trivially in the 120 GB UMA budget. Quality difference per Unsloth
is "slightly weaker" — acceptable trade for an interactive coding
agent.
