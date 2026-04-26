# llama-bench tuning on Framework Desktop (Strix Halo, Vulkan)

Model: `Qwen3.6-27B-UD-Q4_K_XL.gguf` (qwen35moe 35B.A3B Q4_K_M, 20.70 GiB)
Backend: Vulkan0 — Radeon 8060S Graphics (RADV GFX1151)
Goal: best parameters for **code writing** workloads.

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

