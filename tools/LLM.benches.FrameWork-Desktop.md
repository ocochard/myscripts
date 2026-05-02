# llama.cpp on Framework Desktop (Strix Halo) — FreeBSD vs Ubuntu, May 2026

Hardware: AMD Ryzen AI MAX+ 395 (Strix Halo) + Radeon 8060S iGPU (gfx1151), 128 GB LPDDR5x UMA.
Models: `unsloth/Qwen3.6-27B-GGUF` (dense, 26.90 B) and `unsloth/Qwen3.6-35B-A3B-GGUF` (MoE, 34.66 B
total / 3 B active per token), each in `UD-Q4_K_XL` and `UD-Q8_K_XL` quantizations.
Backends: Vulkan (Mesa RADV) on both OSes; ROCm only on Linux.

This is a re-bench of the previous `LLM.benches.FrameWork-Desktop.md` after switching the FreeBSD
host from a custom drm-kmod branch to the official one — see [What changed since the prior
bench](#what-changed-since-the-prior-bench).

> **Update 2026-05-02 — FreeBSD upgraded to Mesa 25.2.8.** The FreeBSD numbers and crash classes
> below were collected on Mesa **24.1.7** and are kept as the historical baseline. After upgrading
> `mesa-libs`/`mesa-dri`/`mesa-libgallium` to 25.2.8 (no llama.cpp rebuild needed — the Vulkan ICD is
> dlopen'd at runtime), the picture shifts substantially. See
> [Mesa 25.2.8 update](#mesa-2528-update-on-freebsd) at the bottom for the new numbers, crash
> classes, and revised recipe.

## Hosts

- **`frwk-bsd`** — FreeBSD 16.0-CURRENT (`main-n285626`), `drm-latest-kmod-6.12.1600018_4`
  (official), `gpu-firmware-amd-kmod-* 20260406.1600018`, **Mesa 24.1.7 RADV**, vulkan-loader 1.4.349,
  llama.cpp `27aef3dd9` (b8985). No ROCm available.
- **`frwk-linux`** — Ubuntu 24.04.4 LTS, kernel 6.17.0-22-generic, **Mesa 25.2.8** (Vulkan 1.3.275),
  ROCm 7.2.2, llama.cpp `27aef3dd9` (b8985).

Both hosts run the **same llama.cpp build hash** (`27aef3dd9`), so model-detection differences and
kernel changes between builds don't apply here.

## TL;DR

| Topic                                              | FreeBSD                          | Ubuntu                          | Verdict                           |
|----------------------------------------------------|----------------------------------|---------------------------------|-----------------------------------|
| Vulkan dense 27B Q4 pp4096 @ d=8 k                 | 249.7 t/s                        | 230.1 t/s                       | FreeBSD ~8 % faster pp            |
| Vulkan dense 27B Q4 tg128                          | 11.54 t/s                        | 11.73 t/s                       | Tie                               |
| Vulkan dense 27B Q8 pp4096 @ d=8 k                 | 189.7 t/s                        | 135.9 t/s                       | **FreeBSD ~40 % faster pp**       |
| Vulkan dense 27B Q8 tg128                          | 5.99 t/s                         | 6.00 t/s                        | Tie                               |
| Vulkan MoE Q4 pp4096 @ d=8 k                       | 829.7 t/s                        | 823.5 t/s                       | Tie                               |
| Vulkan MoE Q4 tg128                                | 47.6 t/s                         | 51.7 t/s                        | Ubuntu ~9 % faster tg             |
| Vulkan MoE Q8 pp4096 @ d=8 k                       | 783.0 t/s                        | 749.6 t/s                       | FreeBSD ~4 % faster pp            |
| `RADV_DEBUG=zerovram` needed                       | **YES** (else `vk::DeviceLostError`) | **NO**                       | Ubuntu Mesa is healthier          |
| `--no-host 1` server flag                          | **CRASHES on 27B Q4 + 35B Q8**   | OK                              | Drop on FreeBSD                   |
| `-mmp 0`, `-ctk q8_0 -ctv q8_0`                    | OK on this build (was crashing)  | OK                              | Newer drm-kmod fixed both         |
| ROCm backend (HIP)                                 | n/a                              | **HANGS all model sizes**       | Skip ROCm entirely                |

**Bottom line**: Silicon dominates — Vulkan tg is essentially identical across both OSes. FreeBSD
wins pp by 4-40 % depending on model/quant; the gap is largest on dense Q8. Ubuntu's newer Mesa is
materially more stable: it doesn't need `RADV_DEBUG=zerovram` and `--no-host 1` doesn't crash. If you
need a working setup with the smallest number of footnotes, run Ubuntu. If you want the fastest
prompt processing for dense models and you're willing to manage the FreeBSD/RADV crash classes, run
FreeBSD.

ROCm 7.2.2 on Ubuntu now hangs every model size we tested — even single-backend dense Q4. Don't.

## Software versions tested

| Component         | FreeBSD `frmk-bsd`                       | Ubuntu `frwk-linux`                          |
|-------------------|-------------------------------------------|----------------------------------------------|
| OS                | FreeBSD 16.0-CURRENT (`main-n285626`)     | Ubuntu 24.04.4 LTS (noble)                   |
| Kernel            | `9c18d55a768a` (May 2026)                 | Linux 6.17.0-22-generic                      |
| GPU driver        | `drm-latest-kmod-6.12.1600018_4`          | amdgpu in-tree                               |
| GPU firmware      | `gpu-firmware-amd-kmod-* 20260406.1600018`| linux-firmware (distro)                      |
| Mesa              | 24.1.7                                    | 25.2.8 (Vulkan 1.3.275)                      |
| vulkan-loader     | 1.4.349                                   | (Mesa-bundled)                               |
| ROCm / HIP        | — (not packaged for FreeBSD)              | ROCm 7.2.2                                   |
| llama.cpp build   | `27aef3dd9` (b8985)                       | `27aef3dd9` (b8985)                          |
| Compiler          | Clang 19.1.7                              | gcc 13.3 (Ubuntu noble default)              |
| CPU governor      | `powerd` adaptive                         | `performance`                                |

## What changed since the prior bench

- **FreeBSD `drm-kmod`**: previously a custom `ocochard/strix` branch with `freebsd-ports/strix-halo`
  firmware. Now the **official** FreeBSD ports: `drm-latest-kmod-6.12.1600018_4` +
  `gpu-firmware-amd-kmod-*-20260406.1600018`.
- **Mesa unchanged on FreeBSD** at 24.1.7. That matters: the `RADV_DEBUG=zerovram` requirement and
  the `--no-host` crash class are **in Mesa**, not in the kernel driver. They persist because Mesa
  did not move.
- **GPU reset auto-recovery**: the new official drm-kmod logs `GPU reset(N) succeeded!` and the
  kernel module survives a Vulkan crash. Userspace state still degrades after recovery — a reboot is
  still required after multiple crashes. The previous custom kmod needed a reboot every time.
- **Two crash classes have gone away on FreeBSD**: `-mmp 0` (no mmap) and `-ctk q8_0 -ctv q8_0`
  (quantized KV cache) used to wedge the GPU. They run cleanly on this drm-kmod (we did not retest
  q8_0 KV in this run because it doesn't help quality; the previous bench documented the crash).
- **ROCm regressed**: previously hung on MoE only. Now `--device ROCm0` hangs all four
  (dense+MoE × Q4+Q8) configurations within the bench timeout.
- **`amdgpu` is still not autoloaded at boot on FreeBSD**: `sudo kldload amdgpu` is required after
  every reboot, otherwise `ggml_vulkan: No devices found`.

## Methodology

Five stages, run on both hosts, recording `llama-bench` markdown tables verbatim. The skill that
drove this is `~/.claude/skills/llama-bench-tune` — it prunes the parameter space stage by stage so a
full sweep doesn't take a day or wedge the GPU.

- **Stage 0**: sanity (`-p 512 -n 128 -fa 0`).
- **Stage 1**: core knobs (`fa`, `--no-host`, KV cache type) at d=0 with `-p 4096 -n 128`.
- **Stage 3**: depth sweep on the Stage 1 winner at d=8 192 and d=32 768 (`pp4096 @ dN + tg128 @ dN`).
- **Stage 4**: real-load validation — `llama-server` with the recommended flags + `bench_model.py`
  hitting `/v1/chat/completions` against `tools/coding_prompt.txt` and `tools/coding_prompt_32k.txt`.

(Stages 2/4/5 from the prior tuning skill — batch/ubatch sweep, prompt size, server-only flags —
were elided this round; the previous bench established the winners and they did not need re-tuning.)

## Stage 0 — Sanity (Vulkan, fa=0, p=512, n=128, d=0, r=2)

### FreeBSD `frmk-bsd` Vulkan (`RADV_DEBUG=zerovram`)

| Model            | Quant   | pp512          | tg128          | Notes                                                                  |
|------------------|---------|---------------:|---------------:|------------------------------------------------------------------------|
| Qwen3.6-27B      | Q4_K_XL | 295.96 ± 6.11  | 11.89 ± 0.09   | First run after boot crashes (`vk::DeviceLostError`); shown post-warmup. |
| Qwen3.6-27B      | Q8_K_XL | 230.74 ± 4.44  |  6.08 ± 0.00   | Crashes if loaded first; works after warming with MoE.                 |
| Qwen3.6-35B-A3B  | Q4_K_XL | 733.65 ± 10.21 | 51.93 ± 1.54   | Stable.                                                                |
| Qwen3.6-35B-A3B  | Q8_K_XL | 705.78 ± 41.51 | 42.29 ± 1.19   | Stable.                                                                |

### Ubuntu `frwk-linux` Vulkan (no env prefix)

| Model            | Quant   | pp512          | tg128          |
|------------------|---------|---------------:|---------------:|
| Qwen3.6-27B      | Q4_K_XL | 236.38 ± 1.21  | 12.01 ± 0.01   |
| Qwen3.6-27B      | Q8_K_XL | 198.35 ± 1.15  |  6.15 ± 0.00   |
| Qwen3.6-35B-A3B  | Q4_K_XL | 940.13 ± 16.85 | 55.21 ± 0.08   |
| Qwen3.6-35B-A3B  | Q8_K_XL | 845.52 ± 21.63 | 42.73 ± 0.04   |

### Ubuntu `frwk-linux` ROCm

| Model            | Quant   | Result               |
|------------------|---------|----------------------|
| Qwen3.6-27B      | Q4_K_XL | HANG (timeout 300 s) |
| Qwen3.6-27B      | Q8_K_XL | HANG (timeout 300 s) |
| Qwen3.6-35B-A3B  | Q4_K_XL | HANG (timeout 300 s) |
| Qwen3.6-35B-A3B  | Q8_K_XL | HANG (timeout 300 s) |

**Verified post-reboot**: rebooted Ubuntu (was up 3.7 days when initial ROCm probes hung), `lsmod`
shows fresh `amdgpu`, `rocminfo` enumerates `gfx1151` cleanly, Vulkan dense Q4 runs fine
(`pp128 266 t/s / tg32 12 t/s`). ROCm dense Q4 still hangs even with a tiny `-p 128 -n 32 -r 1`
workload (timeout 120 s). The hang is not a session-state artifact — ROCm 7.2.2 / gfx1151 is
fundamentally broken on this stack.

## Stage 1 — Core knobs (Vulkan, pp4096 + tg128, d=0, b=2048, ub=512, r=2)

### Ubuntu `frwk-linux`

| Sub | Model             | Quant   | Config           | pp4096          | tg128         |
|-----|-------------------|---------|------------------|----------------:|--------------:|
| 1.1 | Qwen3.6-27B       | Q4_K_XL | fa=0             | 261.65 ± 0.51   | 12.11 ± 0.00  |
| 1.2 | Qwen3.6-27B       | Q4_K_XL | fa=1             | 265.96 ± 0.01   | 12.15 ± 0.01  |
| 1.3 | Qwen3.6-27B       | Q4_K_XL | fa=1 q8KV        | 258.84 ± 0.07   | 12.11 ± 0.00  |
| 1.4 | Qwen3.6-27B       | Q4_K_XL | fa=1 nohost      | 266.51 ± 0.01   | 12.16 ± 0.00  |
| 1.5 | Qwen3.6-27B       | Q4_K_XL | fa=1 nommap      | 266.35 ± 0.05   | 12.16 ± 0.00  |
| 1.1 | Qwen3.6-35B-A3B   | Q4_K_XL | fa=0             | 892.08 ± 6.03   | 55.01 ± 0.10  |
| 1.2 | Qwen3.6-35B-A3B   | Q4_K_XL | fa=1             | 913.92 ± 11.09  | 55.21 ± 0.02  |
| 1.4 | Qwen3.6-35B-A3B   | Q4_K_XL | fa=1 nohost      | 919.35 ± 3.24   | 55.36 ± 0.08  |
| 1.2 | Qwen3.6-27B       | Q8_K_XL | fa=1             | 174.00 ± 0.24   |  6.13 ± 0.00  |
| 1.4 | Qwen3.6-27B       | Q8_K_XL | fa=1 nohost      | 203.15 ± 0.05   |  6.15 ± 0.00  |
| 1.2 | Qwen3.6-35B-A3B   | Q8_K_XL | fa=1             | 816.26 ± 6.34   | 42.74 ± 0.00  |
| 1.4 | Qwen3.6-35B-A3B   | Q8_K_XL | fa=1 nohost      | 820.49 ± 2.71   | 42.97 ± 0.00  |

**Ubuntu Stage 1 winner**: `-fa 1 --no-host 1` for both models, both quants. `--no-host` is +0–17 %
pp on Q8 (Ubuntu UMA-aware path), neutral on Q4. q8KV runs fine here (no crash).

### FreeBSD `frmk-bsd`

| Sub | Model             | Quant   | Config           | pp4096      | tg128       | Notes                                       |
|-----|-------------------|---------|------------------|------------:|------------:|---------------------------------------------|
| 1.1 | Qwen3.6-27B       | Q4_K_XL | fa=0             | **CRASH**   | —           | Retried 3× post-reboot.                     |
| 1.4 | Qwen3.6-27B       | Q4_K_XL | fa=1 nohost      | **CRASH**   | —           | Retried 3× post-reboot — repeatable.        |
| 1.2 | Qwen3.6-27B       | Q8_K_XL | fa=1             | 256.01      |  6.08       | Post-MoE warmup.                            |
| 1.4 | Qwen3.6-27B       | Q8_K_XL | fa=1 nohost      | 257.95      |  6.09       | Works on Q8 even though it crashes on Q4.   |
| 1.4 | Qwen3.6-35B-A3B   | Q8_K_XL | fa=1 nohost      | **CRASH**   | —           | Retried 3× — repeatable.                    |

**FreeBSD Stage 1 finding**: `--no-host 1` is **not a safe default** on FreeBSD/RADV. It crashes on
27B Q4 and 35B-A3B Q8, but works on 27B Q8 and 35B-A3B Q4. The crashes are repeatable across reboots
on the same model+config combo. **Recommended**: omit `--no-host` in the FreeBSD recipe.

## Stage 3 — Depth sweep (fa=1, b=2048, ub=512, r=2)

### Ubuntu `frwk-linux` Vulkan (with `--no-host 1`)

| Model             | Quant   | depth | pp4096          | tg128         |
|-------------------|---------|------:|----------------:|--------------:|
| Qwen3.6-27B       | Q4_K_XL |  8192 | 230.11 ± 0.14   | 11.73 ± 0.01  |
| Qwen3.6-27B       | Q4_K_XL | 32768 | 119.64 ± 0.14   | 10.72 ± 0.00  |
| Qwen3.6-27B       | Q8_K_XL |  8192 | 135.86 ± 0.06   |  6.00 ± 0.00  |
| Qwen3.6-27B       | Q8_K_XL | 32768 |  96.12 ± 0.28   |  5.76 ± 0.00  |
| Qwen3.6-35B-A3B   | Q4_K_XL |  8192 | 823.46 ± 4.00   | 51.69 ± 0.35  |
| Qwen3.6-35B-A3B   | Q4_K_XL | 32768 | 600.40 ± 0.90   | 46.46 ± 0.13  |
| Qwen3.6-35B-A3B   | Q8_K_XL |  8192 | 749.63 ± 3.92   | 40.95 ± 0.06  |
| Qwen3.6-35B-A3B   | Q8_K_XL | 32768 | 563.19 ± 0.29   | 37.50 ± 0.00  |

### FreeBSD `frmk-bsd` Vulkan (`RADV_DEBUG=zerovram`, no `--no-host`)

| Model             | Quant   | depth | pp4096          | tg128         | Notes                                |
|-------------------|---------|------:|----------------:|--------------:|--------------------------------------|
| Qwen3.6-27B       | Q4_K_XL |  8192 | 249.69 ± 0.83   | 11.54 ± 0.03  |                                      |
| Qwen3.6-27B       | Q4_K_XL | 32768 | 133.23 ± 0.38   | 10.61 ± 0.04  |                                      |
| Qwen3.6-27B       | Q8_K_XL |  8192 | 189.69 ± 0.13   |  5.99 ± 0.00  |                                      |
| Qwen3.6-27B       | Q8_K_XL | 32768 | 116.06 ± 0.57   |  5.70 ± 0.00  |                                      |
| Qwen3.6-35B-A3B   | Q4_K_XL |  8192 | 829.69 ± 11.31  | 47.61 ± 3.18  | First run crashed; result on retry.  |
| Qwen3.6-35B-A3B   | Q4_K_XL | 32768 | 593.66 ± 1.12   | 43.91 ± 0.85  | Retry result.                        |
| Qwen3.6-35B-A3B   | Q8_K_XL |  8192 | 782.98 ± 0.06   | 40.32 ± 0.91  |                                      |
| Qwen3.6-35B-A3B   | Q8_K_XL | 32768 | 574.55 ± 9.30   | 34.63 ± 0.05  |                                      |

**Cross-OS Stage 3 takeaway**:

| Model & quant     | pp gap (FB vs FW2) at d=8 k | pp gap at d=32 k | tg gap         |
|-------------------|-----------------------------|------------------|----------------|
| 27B Q4            | FB +8 %                     | FB +11 %         | tie            |
| 27B Q8            | **FB +40 %**                | FB +21 %         | tie            |
| MoE Q4            | tie                         | tie              | FW2 +9 % tg    |
| MoE Q8            | FB +4 %                     | FB +2 %          | FW2 ~5–8 % tg  |

## Stage 4 — `bench_model.py` validation

`llama-server` with the recommended runtime flags (see [Recommended runtime
config](#recommended-runtime-config)), Qwen3.6-35B-A3B Q4 (the coding default), `--ctx-size 65536
--parallel 1`. Bench: `bench_model.py -t 256 -r 2` against `tools/coding_prompt.txt` (4 004 tok) and
`tools/coding_prompt_32k.txt` (32 919 tok). The PP TPS is `prompt_tokens / TTFT` from the streaming
response — i.e. **cold prefill** the first time the prompt is seen.

| Host       | Depth   | TTFT (ms) | PP t/s | Total TPS |
|------------|---------|----------:|-------:|----------:|
| frmk-bsd  |  ~4 k   |    4 443  | 901.3  |    48.9   |
| frwk-linux |  ~4 k   |    4 413  | 907.4  |    51.5   |
| frmk-bsd  | ~32 k   |   43 252  | 761.1  |    42.6   |
| frwk-linux | ~32 k   |   44 043  | 747.4  |    44.7   |

These match Stage 3's `llama-bench` numbers within the expected gap (cold prefill at d≈4 k beats
`llama-bench`'s warm-after-warmup numbers slightly). Ubuntu's small TG edge for MoE persists, FreeBSD
matches/beats on PP.

## Recommended runtime config

The same recipe works on both OSes; the only OS-specific bits are `RADV_DEBUG` (FreeBSD only) and
`--no-host` (Ubuntu only).

```sh
# FreeBSD: RADV_DEBUG=zerovram is required, --no-host is NOT.
# Ubuntu:  no env prefix needed, --no-host adds +0-17 % pp.

[RADV_DEBUG=zerovram] llama-server \
  -hf unsloth/Qwen3.6-35B-A3B-GGUF:UD-Q4_K_XL \
  --device Vulkan0 \
  --flash-attn on \
  [--no-host] \
  --batch-size 2048 --ubatch-size 512 \
  --ctx-size 65536 --parallel 1 \
  --no-mmproj \
  --jinja
```

`--ctx-size 65536` is the working ceiling — both stacks can reserve `--ctx-size 131072` but TTFT
collapses past d ≈ 30 k on Strix Halo regardless of OS (memory bandwidth, not driver).

## Memory bandwidth as the wall

[A blog post benchmarking the Framework Laptop 13 with Ryzen AI 9 HX 370 + Radeon
890M](https://msf.github.io/blogpost/local-llm-performance-frmk-bsd13.html) reports ~75 %
memory-bandwidth utilization on the 89.6 GB/s DDR5-5600 bus. The Strix Halo Framework Desktop
benched here has roughly **3× that bandwidth** (256-bit LPDDR5x ≈ 256 GB/s) and ~2.5× more CUs
(40 vs 16). Translating our MoE Q4 tg128 numbers (~52 t/s on a 20.81 GiB model active path):

```
3 GB (Q4 active path) × 52 t/s ≈ 156 GB/s ≈ 60 % of 256 GB/s theoretical max
```

For dense Q4 27B (16.4 GiB Q4 model × 12 t/s ≈ 197 GB/s ≈ 77 %) we hit the same ceiling reported on
the laptop. tg is **memory-bound, not compute-bound and not driver-bound** — that's why Vulkan tg is
identical across both OSes. PP is more compute-shaped (matmul-heavy) and that's where the OS gap
appears: FreeBSD's compiler/scheduling gives ~5–40 % more pp on dense models; on MoE the gap
collapses (smaller active path, less compute pressure).

## Known crash signatures (FreeBSD frmk-bsd, Mesa 24.1.7 RADV)

- **First-run-after-boot of any large model**: usually crashes with `vk::DeviceLostError` in
  `ggml_vk_buffer_write_2d`. Warm with a smaller MoE config first if the bench order matters.
- **27B Q4 with `-fa 0` (no flash-attn)**: repeatable crash post-reboot. Use `-fa 1`.
- **27B Q4 with `-fa 1 --no-host 1`**: repeatable crash. Q8 of the same model works.
- **35B-A3B Q8 with `-fa 1 --no-host 1`**: repeatable crash. Q4 of the same model works.
- **Multi-value `llama-bench` sweeps** (e.g. `-fa 0,1`): crash on graph variant 2/3. Run one
  invocation per (model, config) pair — the test scripts in this repo already do that.
- **Recovery**: `dmesg` shows `GPU reset(N) succeeded!` on the new official drm-kmod, and
  `kldstat` still lists `amdgpu`. But the userspace Vulkan device may be in a degraded state — a
  follow-up bench can crash again. **Reboot is the only reliable recovery.** `kldunload amdgpu` then
  `kldload amdgpu` does **not** restore Vulkan probing (returns "No devices found").

## Reproducing this on another FreeBSD frmk-bsd-class machine

1. Install the official drm-kmod and firmwares from FreeBSD ports:
   ```
   pkg install drm-latest-kmod gpu-firmware-amd-kmod-{dcn-3-5-1,gc-11-5-1,psp-14-0-1,sdma-6-1-1,vcn-4-0-6,vcn-4-0-6-1,vpe-6-1-1,mes-11-0-0,umsch-mm-4-0-0,vcn-4-0-6,dmcub-3-5-0,imu-11-5-1}
   ```
   (Pull the matching `gpu-firmware-amd-kmod-*` set; `pkg search gpu-firmware-amd-kmod` lists them.)
2. After every reboot: `sudo kldload amdgpu`. Verify with
   `~/llama.cpp/build/bin/llama-bench --list-devices` — should show `Vulkan0`.
3. Build llama.cpp with Vulkan backend (`-DGGML_VULKAN=ON`); `vulkan-headers` and `vulkan-loader`
   are the only build/link deps. The runtime ICD is provided by `mesa-dri`
   (`/usr/local/share/vulkan/icd.d/radeon_icd.x86_64.json`).
4. Always set `RADV_DEBUG=zerovram` in the env when launching `llama-bench` or `llama-server`.
   Without it, the first run after boot is essentially guaranteed to crash with
   `vk::DeviceLostError`. Cost: ~1.5 % pp.
5. Do **not** combine `--no-host 1` with 27B Q4 or 35B-A3B Q8 (see crash list).
6. If the GPU wedges past `GPU reset succeeded`: `sudo shutdown -r now`, then `sudo kldload amdgpu`.

## Pitfalls revisited

- **`--cache-reuse N`** is silently disabled on Qwen3-family models because their KV cache uses
  M-RoPE / IM-RoPE which cannot be position-shifted. The server logs `cache_reuse is not supported
  by ...` and the flag becomes a no-op. The default server prompt cache + checkpoints already give
  ~88× speedup on warm reuse of a 30 k prompt, so this is not a regression — just don't recommend
  the flag for these models.
- **`-hf` auto-loads the multimodal projector** for Qwen3.6-VL-derived weights (the "coder" repo is
  one of these). Pass `--no-mmproj` for text-only use to save VRAM and avoid the
  `cache_reuse is not supported by multimodal` log line.
- **`--reasoning-budget 0`** disables `<think>...</think>` blocks for short, mechanical tasks.
  Measured ~8.6× speedup on a "is_prime" task on Qwen3.6-27B with correct output. Use a separate
  launch mode (`MODE=fast`) rather than baking into the default.
- **`bench_model.py` warm-up populates the prompt cache** on `llama-server`, so the per-run TTFT it
  prints is for cached re-evaluation. To measure cold prefill, hit `/v1/chat/completions` with curl
  and read `timings.prompt_n` / `timings.prompt_per_second` directly — the
  `~/.claude/skills/llama-bench-tune` skill includes a `bench_one.sh` snippet for this.

## Raw data files

The verbatim `llama-bench` markdown tables and `bench_model.py` summaries from this run are in
`/tmp/bench-results.md` on the host that drove the bench. Logs on the test hosts:

- frmk-bsd: `/tmp/fb_stage0.log`, `/tmp/fb_stage3.log`, `/tmp/srv-qwen36-moe-q4.log`.
- frwk-linux: `/tmp/fw2_stage1.log`, `/tmp/fw2_stage3.log`, `/tmp/srv-qwen36-moe-q4.log`.

## Mesa 25.2.8 update on FreeBSD

After upgrading FreeBSD `frmk-bsd` from `mesa-* 24.1.7` to `mesa-* 25.2.8` on 2026-05-02 (vulkan-loader
and vulkan-headers unchanged at 1.4.349, drm-kmod unchanged, llama.cpp **not rebuilt** — the Vulkan ICD
is dlopen'd at runtime so no rebuild is needed for a Mesa-only upgrade). Same hardware, same llama.cpp
build `27aef3dd9`, same models, same flags.

### Headline changes

| Metric                                  | Mesa 24.1.7         | Mesa 25.2.8        | Delta             |
|-----------------------------------------|--------------------:|-------------------:|-------------------|
| 27B Q4 pp4096 d=0 (no zerovram)         | crashed             | 295.4 t/s          | now stable        |
| 27B Q4 tg128 d=0                        | 11.89               | 12.04              | +1 %              |
| 27B Q4 pp4096 d=32 768                  | 133.2               | 135.3              | +1.6 %            |
| 27B Q8 pp4096 d=0                       | 230.7               | 266.4              | **+15 %**         |
| 27B Q8 tg128 d=0                        | 6.08                | 6.07               | tie               |
| 35B-A3B Q4 pp4096 d=0                   | 733.7               | **892.4**          | **+22 %**         |
| 35B-A3B Q4 tg128 d=0                    | 51.93               | 54.11              | +4 %              |
| 35B-A3B Q4 pp4096 d=32 768              | 593.7               | 619.7              | +4 %              |
| 35B-A3B Q8 pp4096 d=0                   | 705.8               | 871.7              | **+23 %**         |
| 35B-A3B Q8 tg128 d=0                    | 42.29               | 42.48              | tie               |

Mesa 25 is a **clear pp win** on dense Q8 (+15 %) and on both MoE quants (+22–23 %). tg is unchanged
because tg is bandwidth-bound, not driver-bound.

### Crash classes shifted

Tested with fresh reboots between crashes; raw data in `/tmp/fb_mesa25.log`,
`/tmp/fb_mesa25_clean.log`, `/tmp/fb_mesa25_depths.log`, `/tmp/fb_27b_depth.log` on `frmk-bsd`.

| Config                                       | Mesa 24.1.7          | Mesa 25.2.8                |
|----------------------------------------------|----------------------|----------------------------|
| First-run-after-boot **without** zerovram    | crashes reliably     | **runs cleanly**           |
| `RADV_DEBUG=zerovram` standard config        | required, ~1.5 % pp cost | **CRASHES** — actively harmful |
| 27B Q4 `-fa 0`                               | crashes              | (not retested — safer to keep `-fa 1`) |
| 27B Q4 `-fa 1 --no-host 1`                   | crashes              | crashes                    |
| 27B Q8 `-fa 1 --no-host 1`                   | works                | **crashes** (regression)   |
| 35B-A3B Q4 `-fa 1 --no-host 1`               | works                | works                      |
| 35B-A3B Q8 `-fa 1 --no-host 1`               | crashes              | works (post-warm-up)       |
| 35B-A3B Q8 first run after fresh boot        | unreliable           | **runs cleanly** (871/42)  |
| 27B Q4/Q8 reload after a crash recovery      | unreliable           | unreliable (reboot to be safe) |

The exact crash signature is unchanged: `vk::DeviceLostError` in `ggml_vk_buffer_write_2d` with
`radv/amdgpu: The CS has been cancelled because the context is lost.` The `GPU reset(N) succeeded!`
auto-recovery still works — but as before, userspace Vulkan state degrades after recovery and a
reboot is the only reliable path back to clean operation.

### Revised FreeBSD recipe (Mesa 25.2.8)

```sh
# No env prefix — RADV_DEBUG=zerovram is now harmful on Mesa 25.
llama-server \
  -hf unsloth/Qwen3.6-35B-A3B-GGUF:UD-Q4_K_XL \
  --device Vulkan0 \
  --flash-attn on \
  --no-host \
  --batch-size 2048 --ubatch-size 512 \
  --ctx-size 65536 --parallel 1 \
  --no-mmproj --jinja
```

`--no-host 1` is now safe with **MoE** (Q4 and Q8). For the dense **27B** model, drop `--no-host` —
both Q4 and Q8 still crash with it on Mesa 25.

### How the Mesa upgrade was verified

```sh
pkg info mesa-libs mesa-dri mesa-libgallium  # 25.2.8 across the board
ldd ~/llama.cpp/build/bin/libggml-vulkan.so.0 | grep vulkan
#   libvulkan.so.1 => /usr/local/lib/libvulkan.so.1
```

`libggml-vulkan.so.0` only links `libvulkan.so.1` (the loader). The RADV ICD
(`/usr/local/share/vulkan/icd.d/radeon_icd.x86_64.json` → `libvulkan_radeon.so`) is loaded by
`vulkan-loader` at runtime via `dlopen()`, which is why a Mesa-only upgrade does **not** require
rebuilding llama.cpp.

### Practical takeaway

If you're on FreeBSD/`drm-latest-kmod` for Strix Halo, **upgrade Mesa to 25.2.8**. It removes the
`RADV_DEBUG=zerovram` workaround (which itself was now causing crashes), buys ~15–23 % pp on
dense Q8 and MoE, and fixes the 35B-A3B Q8 `--no-host` crash. The 27B dense `--no-host` crash class
remains. Plan reboots between heavy config switches — same as before.
