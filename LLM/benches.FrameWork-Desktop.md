# llama.cpp on Framework Desktop (Strix Halo): FreeBSD vs Ubuntu

Hardware: AMD Ryzen AI MAX+ 395 (Strix Halo) + Radeon 8060S iGPU (gfx1151),
128 GB LPDDR5x UMA (Unified Memory Architecture). Backend: Vulkan (Mesa RADV,
the open-source Vulkan driver for AMD Radeon). Same silicon in both hosts:
`frwk-bsd` (FreeBSD 16-CURRENT) and `frwk-linux` (Ubuntu 26.04).

**All speed measurements: llama.cpp v1.0.0 (build 12359, `b1b770d90`),
2026-11-14/15, same build on both hosts, no `--no-host` flag (A/B proved it is a no-op on this
stack, see "The `--no-host` non-finding" below).** Served through
`LLM/llmsrv.sh`. The Flash-Next OS comparison was re-run on 2026-11-26 with
the same build; see
[FreeBSD vs Ubuntu, 2026-11-26](#freebsd-vs-ubuntu-2026-11-26-flashnext-only).

> New to these numbers? **[Concepts](#concepts-what-the-numbers-in-this-document-mean)**
> defines PP / TG / TTFT / Total TPS, what MTP draft *acceptance* is and whether
> a high value is good, and the UMA/GTT/KV memory terms.

## TL;DR

- **Recommended: `MODEL=flashnext`**, Qwen3.8-Flash-Next (125B/6B-active MoE)
  at UD-IQ3_XXS (82 GB) + self-contained Q8_0 MTP head at N=2: 35-39 t/s
  decode on both hosts at `--ctx-size 131072`, draft acceptance 0.61-0.70.
- **Dense alternatives: Qwen3.8-27B.** `qwen38-mtp` (Q8_0 + sidecar MTP head)
  decodes at ~17 t/s; `qwen38-q8` (UD-Q8_K_XL, no MTP) at ~7 t/s and is the
  DaemonDocs doc-accuracy recipe and the no-MTP fallback.
- **Warm, the two OSes are equal.** On Flash-Next, PP and TG are within 3 %
  on FreeBSD and Ubuntu at every depth (FreeBSD slightly ahead).
- **FreeBSD halves Flash-Next PP from a cold start.** The 27.5 GB n-gram
  embedding table stays in the mmap'd file and is paged in during prefill;
  on FreeBSD + ZFS those page faults starve the GPU until the pages are
  resident (PP 255 cold vs 530 warm at d=0). Ubuntu loses only 3 %.
  `--load-mode none --lazy-mode off` reads the table into RAM at load and
  fixes it: cold FreeBSD then reaches 569 PP / 31.7 TG, ~8 % / ~5 % above
  Ubuntu with the same flags. `llmsrv.sh` sets them for `flashnext` /
  `flashnext-abl` on FreeBSD only (cold llama-server test: 39.6 Total TPS at
  ~4 k, 0 GPU faults).
- **ROCm is dead on gfx1151** (MES, MicroEngine Scheduler, 0x83 firmware
  bug). Vulkan-only.
- **The GTT aperture, not installed RAM, caps model size.** One quant step
  above IQ3_XXS needs a raised aperture, and on Linux that aperture
  **panicked the kernel**.

## Which recipe to use

Decode t/s on one coding prompt, llama.cpp v1.0.0, `llmsrv.sh` defaults
(`--ctx-size 131072 --parallel 1`), formatted `frwk-bsd / frwk-linux`.

| Recipe (`MODEL=`)  | Model                                      | Decode t/s       | Draft acceptance | Notes |
|--------------------|--------------------------------------------|-----------------:|-----------------:|-------|
| **`flashnext`** ★  | Qwen3.8-Flash-Next UD-IQ3_XXS + MTP N=2    | **38.2-38.6 / 35.4-38.9** | 0.61-0.70 | 125B `qwen4exp`, 82 GB. Fastest recipe here. `llmsrv.sh` default and `USAGE=coding`. |
| `qwen38-mtp`       | Qwen3.8-27B Q8_0 + sidecar MTP Q8_0 head   | 17.0 / 17.4      | 405/774, 411/749 | Dense. |
| `qwen38-q8`        | Qwen3.8-27B UD-Q8_K_XL, no MTP             |  7.3 / 7.2       | n/a              | DaemonDocs doc-accuracy recipe; fallback when MTP misbehaves. `USAGE=doc`. |
| `flashnext-gsq`    | Flash-Next GSQ-RCO Coder IQ1_M + borrowed MTP N=2 | 41.7 (total TPS) / not run | 0.81 | 58 GB, half the experts pruned. Faster, scores 9/15 vs 12/15 on `fbsd-quality`. Experimental. |
| _(no slot)_        | Qwen3.8-Flash-Next UD-IQ4_XS               | n/a              | n/a              | 93.7 GB. Loads only with a raised GTT aperture; on Linux that aperture panicked the kernel. Use IQ3_XXS. |

★ = recommended and the `llmsrv.sh` default; `USAGE=coding` → `flashnext`,
`USAGE=doc` → `qwen38-q8`.

Agentic quality (`fbsd-quality`, run `v41`): Flash-Next on v1.0.0 scored
11/15 (t1 2/3, t2 2/3, t3 3/3, t4 3/3, t5 1/3), median `model_s` 1 777. 26 %
of its steps were lost to a harness bug since fixed, so this understates the
model; details in [fbsd-quality/README.md](fbsd-quality/README.md).

## Recommended runtime config

`LLM/llmsrv.sh` auto-detects OS/model. What `MODEL=flashnext` runs, with the
files from `unsloth/Qwen3.8-Flash-Next-GGUF`:

```sh
llama-server \
  -m UD-IQ3_XXS/Qwen3.8-Flash-Next-UD-IQ3_XXS-00001-of-00003.gguf \
  --model-draft MTP/mtp-Qwen3.8-Flash-Next-Q8_0.gguf \
  --spec-type draft-mtp --spec-draft-n-max 2 \
  --device Vulkan0 --flash-attn on --no-mmproj --metrics --jinja \
  --batch-size 2048 --ubatch-size 512 \
  --ctx-size 131072 --parallel 1
```

**Footnotes**:
- **FreeBSD adds `--load-mode none --lazy-mode off`** (`llmsrv.sh` does it).
  Without them the 27 GB n-gram table is paged in from ZFS during prefill
  and PP runs at half speed until it is resident; see
  [FreeBSD vs Ubuntu, 2026-11-26](#freebsd-vs-ubuntu-2026-11-26-flashnext-only).
- **No `--no-host` flag.** Direct A/B on `frwk-linux` showed it is a no-op
  with a small BIOS UMA carve-out (which both hosts use). It is still worth
  passing if you have a large "dedicated VRAM" carve-out; see the BIOS
  section below.
- FreeBSD post-boot: `sudo kldload amdgpu` (not autoloaded).
- Pass shard `00001` only; llama.cpp opens the rest of a sharded GGUF.
- Flash-Next native context is 262 144 tokens. `--ctx-size 131072` loads
  with MTP on; `llmsrv.sh` warns past 262144. A large context costs KV
  memory up front even when unused, and cold prefill grows faster than
  linearly with filled depth.
- `qwen38-mtp` passes the sidecar head with `--model-draft`, `--jinja`,
  `--spec-draft-n-max 4 --spec-draft-sampling probabilistic`.
- `--batch-size 2048 --ubatch-size 512` is the default in every slot.

## Hardware, software, and install

Same silicon (Ryzen AI MAX+ 395 + 128 GB LPDDR5x-8000 UMA).

| Component       | `frwk-bsd`                                              | `frwk-linux`                            |
|-----------------|---------------------------------------------------------|-----------------------------------------|
| OS              | FreeBSD 16.0-CURRENT                                    | Ubuntu 26.04.1                          |
| Kernel          | FreeBSD kernel + drm-kmod (`drm-latest-kmod` 6.12.x)    | Linux 7.0.0-43-generic (7.0.0-44 from 2026-11-26) |
| GPU driver      | [`ocochard/drm-kmod` `strix` branch](https://github.com/ocochard/drm-kmod/tree/strix) | amdgpu in-tree |
| GPU firmware    | `gpu-firmware-amd-kmod-*`                               | linux-firmware (distro)                 |
| Mesa            | 26.2.x ([FreeBSD bug 294948](https://bugs.freebsd.org/bugzilla/show_bug.cgi?id=294948), `mesa-dri` ships the RADV ICD, Installable Client Driver) | 26.0.8 |
| Compiler        | Clang (base system)                                     | GCC 15.2.0                              |
| CPU governor    | `powerd` adaptive                                       | `performance` (2026-11-26: `powersave`, amd-pstate-epp, EPP `balance_performance`) |
| llama.cpp       | v1.0.0 (`b1b770d90`)                                    | v1.0.0 (`b1b770d90`)                    |

### Installing on FreeBSD

1. Build+install `strix`-branch drm-kmod from
   [github.com/ocochard/drm-kmod](https://github.com/ocochard/drm-kmod/tree/strix).
   Pull matching `gpu-firmware-amd-kmod-*` ports (dcn-3-1-5, dcn-3-5-1,
   gc-11-5-1, psp-14-0-1, sdma-6-1-1, vcn-4-0-6, vcn-4-0-6-1, vpe-6-1-1).
2. Install Mesa 26 (see [FreeBSD PR 294948](https://bugs.freebsd.org/bugzilla/show_bug.cgi?id=294948)).
   Verify: `pkg info mesa-libs mesa-dri` and `vulkaninfo --summary` reports
   `driverName = radv`.
3. After every reboot: `sudo kldload amdgpu`. Verify with
   `~/llama.cpp/build/bin/llama-bench --list-devices`.
4. Build llama.cpp with `-DGGML_VULKAN=ON`. Runtime ICD `libvulkan_radeon.so`
   ships in `mesa-dri` (the `mesa-libgallium` package is OpenGL-only and not
   used by llama.cpp's Vulkan backend).

## Concepts: what the numbers in this document mean

Skip if you already know. Every term below appears unexplained in the tables.

### The two phases of a request

A request has two distinct phases with completely different performance
characteristics, which is why they are reported separately:

- **PP: Prompt Processing**, a.k.a. *prefill*. The model reads your whole
  prompt and builds the KV cache. All tokens are processed **in parallel**, so
  this is compute/bandwidth-rich and hits hundreds of tokens/s. Cost scales with
  prompt length, and worse than linearly: attention is O(n²), which is why
  `pp4096` at `d=32768` is far below `pp4096` at `d=0`.
- **TG: Token Generation**, a.k.a. *decode*. The model emits the answer **one
  token at a time**, and each token must re-read the active weights from
  memory. It is therefore **memory-bandwidth-bound**, not compute-bound, and
  lands at single-digit-to-tens of tokens/s. This is why TG is nearly identical
  between FreeBSD and Ubuntu while PP can differ: you cannot compile your way
  past a bandwidth wall.

Derived figures:

- **TTFT (Time To First Token)**: wall-clock until the first token appears.
  Dominated by prefill on a cold cache. At ~32 k this is minutes on this
  hardware, which is a usability problem even when throughput looks fine.
- **`d=N` / depth**: how many tokens are *already* in the KV cache before the
  measurement. `d=0` is a cold cache; `d=32768` simulates a long conversation.
- **Total TPS**: `(prompt_tokens + generated_tokens) / wall_clock`. The
  end-to-end number, because it includes both phases as a user actually
  experiences them. The current tables report **decode t/s** instead (TG
  only), so do not compare them with a Total TPS figure.

### MTP / speculative decoding, and what "acceptance" measures

TG is slow because each token needs a full pass over the model. Speculative
decoding attacks that: a small, cheap **draft model** (here an **MTP**,
Multi-Token Prediction, head: ~4.1 GB beside Flash-Next's 82 GB) guesses the
next few tokens, and the big model then **verifies them all in a single pass**.
`--spec-draft-n-max N` sets how many tokens it may guess ahead.

The trick is that verification is *exact*: the main model checks each guess
against what it would have produced itself, and discards from the first
mismatch onward. **The output is the same as running without MTP**; only the
speed changes. There is no quality tradeoff to weigh.

**Draft acceptance % = accepted draft tokens / total draft tokens.** It is the
guesser's hit rate.

- **Higher is better.** Each accepted token was produced for the price of a
  cheap draft step instead of a full model pass. ~0.66 means 2 of 3 guesses
  survive.
- **Low acceptance is worse than useless**, because rejected guesses still cost
  verify compute: a weak head can make throughput *slower* than
  speculation-off. **0.00000 means a dead draft head**; the throughput number
  that accompanies it is void, not merely poor. That is the single value to
  watch on a cold start.
- **But acceptance is not the goal, speed is.** Acceptance is a diagnostic
  for *why* a recipe is fast or slow, not a score to maximise. Never pick a
  recipe on acceptance alone.
- Acceptance is **prompt-dependent** (coding prompts score higher than
  throwaway ones), so quote it against a stated prompt.

**Mean accepted length (`len`)**: how many tokens were accepted per draft
*attempt*, and the figure that converts into speed. It sets the useful
ceiling on `N`: drafting far past it only produces tokens that get discarded.
The two MTP recipes here show acceptance alone does not predict the gain:

| recipe       | accept       | `len` | decode vs spec-off |
|--------------|-------------:|------:|-------------------:|
| `flashnext`  | 0.66         |  2.31 | 1.29× (40.3 vs 31.3) |
| `qwen38-mtp` | 0.52-0.55    |  n/a  | ~2.3-2.4× (17.0 vs 7.3 `qwen38-q8`) |

The dense model has *lower* acceptance yet the bigger speedup. (Its spec-off
reference is `qwen38-q8`, a different file of similar size, so the ratio is
approximate.) **Read acceptance alongside `len` and the measured speedup;
none of them alone tells you whether MTP is worth enabling.**

### Memory terms

- **UMA (Unified Memory Architecture)**: CPU and GPU share one pool of RAM;
  there is no separate video memory to copy into.
- **GTT (Graphics Translation Table)**: the aperture through which the GPU
  addresses system RAM. With a 512 M VRAM carve-out, **model weights live in
  GTT**, so the GTT size is the real ceiling on model size, *not* installed RAM.
  See the aperture discussion in the Flash-Next section: a 66 GB GTT on a
  128 GB machine is what blocked a 93.7 GB model.
- **KV cache**: per-token attention state kept for the whole context.
  `--ctx-size` reserves it up front, so a large context costs memory even when
  unused.

### Quantization quality: KLD, Δp, PPL

Speed tables say how fast a quant is. These figures say how much the smaller
file changed the model's answers. They come from `llama-perplexity
--kl-divergence`, which runs the same text through a **reference** (the
unquantized BF16 model) and the **quant**, and compares, at every token
position, the probability each one gives to every possible next token.

- **KLD (Kullback-Leibler divergence)**: one number per token position for
  how different the two probability distributions are. 0 means identical.
  Lower is better. It sees changes that do not yet flip the chosen word, so it
  is the most sensitive of these figures.
  - **Mean KLD** is the headline. Rough scale on Qwen3.8-27B: ~0.0007 is
    near-lossless (Q8), ~0.005 is a good 4-bit quant.
  - **Median / 99.0 % / 99.9 % / Max KLD**: the distribution of the per-token
    values. Median is the typical token; 99 % and 99.9 % are the worst 1 in
    100 and 1 in 1000 tokens, where a quant goes off the rails; Max is the
    single worst token and is noisy.
- **Same top token %**: how often the quant's most likely next token is the
  reference's most likely token. 96.6 % means about 1 token in 30 would come
  out differently under greedy decoding. Higher is better.
- **Δp (delta p)**: for the token that actually comes next in the text, the
  quant's probability minus the reference's. **RMS Δp** (root mean square)
  is its typical size ignoring sign: 2 % means the quant is usually about 2
  percentage points more or less confident than the reference.
- **PPL (perplexity)**: how surprised the model is by the text; lower means it
  predicted the text better. **PPL(Q)/PPL(base)** is the quant's perplexity
  divided by the reference's. 1.000 is no change. A value *below* 1.000 does
  **not** mean the quant is better than the original; it is noise, because
  errors that raise and lower confidence cancel out in the average. Rank
  quants on KLD, not PPL.
- **`±` values** are standard errors. A gap smaller than about 2× the
  combined error is not a real difference.

## Methodology

- **Current numbers**: one coding prompt per slot through `llama-server`
  (`llmsrv.sh` or the same flags); Flash-Next at temp 0.6. Decode t/s is generation speed
  only, excluding prefill. Draft acceptance is scraped from `--metrics`
  (`llamacpp:spec_decode_num_{draft,accepted}_tokens_total`), not the log.
- **`LLM/bench-all.sh`** drives the full harness for new sweeps:
  - **`llama-bench`**: raw kernel throughput, `pp4096 + tg128` at d=0, 8192,
    32768, fa=1, b=2048, ub=512, r=2, no `--no-host`.
  - **`llama-server` + `bench_model.py -t 256 -r 2`**: real client-server
    load at `LLM/coding_prompt.txt` (4 004 tok) and
    `LLM/coding_prompt_32k.txt` (32 919 tok), reporting Total TPS.
  - **MTP sweep**: `--spec-draft-n-max N ∈ {2, 3, 4, 5, 8, 16}` at ~4 k
    prompt for MTP-capable slots.

## Qwen3.8-Flash-Next: 125B MoE on 128 GB UMA

Scope: **`unsloth/Qwen3.8-Flash-Next-GGUF`**, both hosts, mainline llama.cpp
v1.0.0 (`qwen4exp` MTP support from #30097).

A new architecture, not a Qwen3.x repack: arch `qwen4exp`, 125B total / 6B
active, 512 experts (10 routed + 1 shared), 48 layers of
`3 × (Gated DeltaNet → MoE) → 1 × (Qwen Sparse Attention → MoE)`, plus a 20 M-entry
n-gram embedding (51B params alone). Native context 262 144.

### Verdict: use UD-IQ3_XXS (82 GB) + MTP at N=2. Nothing larger is worth it.

`llmsrv.sh` slot: **`MODEL=flashnext`**. It is the fastest recipe in this
document and the only way to run a 125B model here at usable speed.

Two head traps on mainline:

- It cannot use the `shared-` MTP heads (`tensor 'token_embd.weight' not
  found`; no cross-model embedding borrowing).
- The pre-2026-10-05 upload of the self-contained
  `mtp-Qwen3.8-Flash-Next-Q8_0.gguf` aborts with `GGML_ASSERT(buffer) failed`.
  The re-uploaded self-contained Q8_0 head (4 137 429 120 B, md5
  `06f833bea518d9e7e4050d47806a42fa`) works.

Decode on one 800-token coding prompt, IQ3_XXS, temp 0.6, frwk-bsd:

| config                         |    ctx | decode t/s  | acceptance | mean len |
|--------------------------------|-------:|------------:|-----------:|---------:|
| spec-off                       |  32768 | 31.3        | n/a        | n/a      |
| MTP N=2, self-contained Q8_0   |  32768 | 40.3        | 0.66       | 2.31     |
| MTP N=2, self-contained Q8_0   | 131072 | 39.6 / 40.0 | 0.65       | 2.30     |

Through `llmsrv.sh MODEL=flashnext` (ctx 131072): 38.6 / 38.2 t/s on
frwk-bsd, 38.9 / 35.4 on frwk-linux, acceptance 0.61-0.70. These are decode
rates, not Total TPS. N=2 has not been re-swept on v1.0.0.

Agentic quality on v1.0.0: `fbsd-quality` run `v41` scored 11/15 (see
[Which recipe to use](#which-recipe-to-use) and
[fbsd-quality/README.md](fbsd-quality/README.md)).

Quant selection is forced by memory, and the ceiling is **the GTT aperture, not
total RAM**:

| quant        |   size | verdict                                             |
|--------------|-------:|-----------------------------------------------------|
| Q8_0         | 192 GB | never fits 128 GB                                   |
| UD-Q6_K_XL   | 169 GB | never fits                                          |
| UD-Q5_K_XL   | 158 GB | never fits                                          |
| UD-Q4_K_XL   | 111 GB | upstream's own recommended pairing; does not fit here |
| UD-IQ4_XS    | 93.7 GB| loads, but **not worth using**, see below           |
| **UD-IQ3_XXS**| **82 GB** | **the recipe**                                   |

### FreeBSD vs Ubuntu, 2026-11-26 (`flashnext` only)

Same llama.cpp v1.0.0 (`b1b770d90`, the peeled `v1.0.0` tag) on both hosts,
`bench-all.sh ONLY=flashnext-iq3`, plus targeted llama-bench reruns. GPU stack
unchanged on both (Mesa 26.2.2 / 26.0.8, same firmware); Ubuntu was on kernel
7.0.0-44 and freshly rebooted. FreeBSD ran the NPU-branch `GENERIC-NODEBUG`
kernel (amdiommu on) for the bench-all run, and stock main n291187
`GENERIC-NODEBUG` with `hw.amdiommu.enable=0` for the cold-boot tests; the
cold result is the same on both kernels.

**llama-bench, pp4096 / tg128, fa=1, b=2048, ub=512, r=2:**

| depth | FreeBSD cold (NPU kernel) | FreeBSD cold (stock) | FreeBSD cold, `-lzm off` | FreeBSD cold, `-lm none -lzm off` | FreeBSD warm | Ubuntu after reboot | Ubuntu warm | Ubuntu `-lm none -lzm off` |
|------:|------------:|------------:|------------:|------------:|------------:|------------:|------------:|------------:|
| PP 0     | 235.3 ± 8.5 | 254.7 ± 8.6 | 272.4 ± 23.6 | **569.3** ± 2.2 | 529.7 ± 1.6 | 522.6 ± 4.3 | 524.8 ± 5.4 | 528.4 ± 5.9 |
| PP 8192  | 251.3 ± 3.9 | 263.9 ± 0.2 | 340.4 ± 11.8 | **483.5** ± 0.1 | 461.2 ± 1.7 | 448.7 ± 0.6 | 446.1 ± 0.4 | 449.9 ± 0.4 |
| PP 32768 | 254.1 ± 4.9 | 264.2 ± 7.3 | 326.7 ± 5.3  | **356.9** ± 0.8 | 335.3 ± 2.1 | 328.8 ± 2.0 | 328.7 ± 2.6 | 329.3 ± 2.0 |
| TG 0     | 26.44 | 27.51 | 28.07 | **31.71** | 30.89 | 29.92 | 29.78 | 30.20 |
| TG 8192  | 26.04 | 26.77 | 27.51 | **30.77** | 29.93 | 28.62 | 29.02 | 29.34 |
| TG 32768 | 24.91 | 25.71 | 27.43 | **29.17** | 28.28 | 27.50 | 27.82 | 27.74 |

"Cold" is the first llama-bench stage after boot (each depth is a new
process); "warm" is the same command after the model has run once. All
columns use `--load-mode mmap` (lazy mode auto) except where flags are
shown; `-lm none -lzm off` is `--load-mode none --lazy-mode off`. Ubuntu
with its page cache dropped (`echo 3 > /proc/sys/vm/drop_caches`) gave
pp4096 510.4 vs 528.4 warm; only the load got slower (70 s vs 23 s).

**`llama-server` + `bench_model.py`, spec-off, Total TPS** (FreeBSD was warm
by this stage):

| host    | ~4 k TTFT | ~4 k Total TPS | ~32 k TTFT | ~32 k Total TPS |
|---------|----------:|---------------:|-----------:|----------------:|
| FreeBSD |  8 589 ms | 29.4 | 82 790 ms | 27.6 |
| Ubuntu  |  8 894 ms | 28.5 | 86 238 ms | 26.7 |

**MTP `--spec-draft-n-max` sweep at ~4 k, Total TPS (draft acceptance):**

| N   | FreeBSD | Ubuntu |
|----:|--------:|-------:|
| off | 29.2 | 28.5 |
| 2   | **38.9** (0.72) | 36.3 (0.73) |
| 3   | server failed (CPC fault) | **37.9** (0.67) |
| 4   | 38.7 (0.60) | 34.9 (0.57) |
| 5   | 32.9 (0.51) | 30.2 (0.46) |
| 8   | 19.3 (0.37) | 17.3 (0.32) |
| 16  | 13.0 (0.20) | 13.3 (0.19) |

N=2 stays the recipe. On FreeBSD the Mesa-26 CPC fault (`Faulty UTCL2 client
ID: CPC (0x5)`, then `ring comp_1.2.0 timeout`) killed two of eight MTP
server starts (N=5 in the on/off summary, N=3 in the sweep); Ubuntu had
none. One prompt, 2 reps, MTP nondeterministic: read gaps under ~5 % as noise.

#### Why FreeBSD PP is halved from a cold start

llama.cpp keeps Flash-Next's `token_embd.weight` (q6_K, the n-gram table,
27 466 MiB) on the CPU as a **lazy-read** tensor
(`LLAMA_LAZY_MODE_AUTO`: tensors over 4 GiB). It stays in the mmap'd GGUF
with `POSIX_MADV_RANDOM`, and prefill faults its rows in on demand. The
Vulkan buffer holds the other 50 191 MiB.

- On FreeBSD each fault is a ZFS read (`recordsize=128K`, compression on,
  ARC capped at 8 GiB here). During a cold pp4096 the GPU is starved:
  `gpu_busy_percent` 21-67 % and sclk 1 000-1 950 MHz, against ~87 % and
  ~2 650 MHz in the TG phase. Once the pages are resident in the VM page
  cache, PP is full speed and stays so across processes.
- On Ubuntu (ext4) the same faults are cheap enough that the cold run loses 3 %.
- `--lazy-mode off` alone does not fix it under `--load-mode mmap`: the table
  is still mapped from the file, only the madvise changes, and FreeBSD's
  `MADV_WILLNEED` maps resident pages without starting I/O
  (`vm_map_madvise` → `vm_map_pmap_enter`). llama.cpp's `MAP_POPULATE` is
  `#ifdef __linux__`.
- **`--load-mode none --lazy-mode off` fixes it.** The table is read into
  RAM at load, prefill faults nothing, and a cold FreeBSD run is at full
  speed (d=0 wall time 74 s including load; 0 GPU faults in dmesg). It even
  beats warm mmap by 5-7 %, while Ubuntu gains nothing from the same flags.
  Why warm mmap still costs FreeBSD 5-7 % is not measured.
- **Served the same way** (`llmsrv.sh MODEL=flashnext`, MTP N=2, cold
  boot, page cache never touched): ~4 k prompt TTFT 8 719 ms, 39.6 Total TPS,
  acceptance 0.72; ~32 k TTFT 85 179 ms, 39.9 Total TPS, acceptance 0.77.
  0 GPU faults; server RSS 32.7 GB (the table, now anonymous memory). The
  mmap N=2 sweep above (warm) gave 9 095 ms and 38.9.
- **What a cold ZFS prefill costs (measured, 2026-11-26).** Two cold boots
  (stock kernel, IOMMU off), default mmap, one llama-bench pp4096 (warmup +
  1 rep = 8 192 prefill tokens). DTrace on `zfs_freebsd_getpages`, disk
  bytes from `zpool iostat -Hp 1`, ARC from `kstat.zfs.misc.arcstats`:

  | prefill window          | ARC max 8 GiB (default) | ARC max 40 GiB |
  |-------------------------|------------------------:|---------------:|
  | pp4096                  | 247.9 | 278.6 |
  | `zfs_getpages` calls    | 142 619 | 143 374 |
  | pages installed         | 365 772 (1 429 MiB), 2.56/call | 385 661 (1 506 MiB), 2.69/call |
  | disk read               | 14 478 MiB, 116 530 ops of 127 KiB | 13 557 MiB, 109 196 ops of 127 KiB |
  | disk bytes / bytes installed | **10.1×** | **9.0×** |
  | ARC demand-data hit rate | 20.4 % | 27.4 % |
  | time in `zfs_getpages`  | 32.8 s of a 36 s window, 230 µs/call | 31.5 s of 35 s, 220 µs/call |
  | GPU busy, mean          | 38 % | 41 % |

  During load the same calls install 31.8 pages each (full 128 KiB
  records), because those mappings are not `MADV_RANDOM`. During prefill,
  with `MADV_RANDOM`, the fault handler asks for no read-behind or
  read-ahead (`vm_fault.c`, `behind = 0; ahead = 0`), and `zfs_getpages`
  reads the whole 128 KiB record to install ~2.6 pages of it.

  What this shows:
  - The amplification is ~10×, and it is **first-touch, not ARC
    thrashing**: a 40 GiB ARC barely changes it (9.0×, PP +12 %). One
    prefill touches ~110 000 different records and uses ~10 KiB of each.
  - The cost that matters is latency, not bytes: page-in time equals the
    wall time, so faults resolve one at a time (~220 µs each, bimodal
    16-31 µs ARC hits / 64-511 µs disk reads) and the GPU waits.
  - One-at-a-time is llama.cpp's choice, not FreeBSD's: ggml runs
    `GGML_OP_GET_ROWS` with `n_tasks = 1` (`ggml-cpu.c`, a FIXME says extra
    threads cost more than they gain under GPU offload). Both OSes therefore
    fault the table from a single thread.
  - Ubuntu, same cold run (page cache dropped, `/proc/vmstat` +
    `/proc/diskstats`): pp4096 525.4, prefill window 15 s, **845 MiB** read in
    125 213 ops of **6.9 KiB**, 1 888 major faults. About the same number of
    reads as FreeBSD (one per row touched), but ext4 reads a few KiB where
    ZFS must read and verify a whole 128 KiB record: 17× fewer bytes. Why so
    few of Ubuntu's reads count as major faults (i.e. block the thread) is
    not measured.
  - Verdict: no correctness bug. ZFS cannot read less than a record (the
    checksum and compression are per record), so random 4 KiB access to a
    file stored in 128 KiB records costs ~10× the bytes and a ~220 µs page-in
    each. A possible improvement, untested: `zfs_getpages` could install the
    rest of a record it has already read even under `MADV_RANDOM`, so later
    prefills warm faster. Practical levers: `--load-mode none`
    (what `llmsrv.sh` does) or a smaller `recordsize` on the model dataset
    (untested; costs sequential load throughput).

Ruled out as causes: the 2026-11-26 userland `pkg upgrade` (no GPU package;
the 2026-11-22 numbers below were already cold-slow), the NPU kernel and
amdiommu (same on stock with `hw.amdiommu.enable=0`), shader paths and CPU
threads (below).

Warm FreeBSD pp4096 d=0, one rep each, toggling Vulkan paths: baseline 498,
`GGML_VK_DISABLE_DOT2=1` 537, `GGML_VK_DISABLE_INTEGER_DOT_PRODUCT=1` 511,
`GGML_VK_DISABLE_F16=1` 444, `GGML_VK_DISABLE_COOPMAT=1` 396. CPU threads:
`--threads 32` (what `bench-all.sh` passes, `nproc`) 515 PP / 29.3 TG,
16 (llama-bench default) 533 / 30.9, 8 534 / 30.9.

### GSQ-RCO Coder (58 GB): faster, scores lower (`flashnext-gsq`)

`ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-Coder-GGUF` prunes half the routed
experts (256 of 512 per layer, still 10 active) with a KL search calibrated on
code, agentic and vision data, and stores the rest at ~3.5 bpw. Two shards,
58.4 GB: 29.6 GB of transformer and the 28.8 GB n-gram table (IQ4_NL,
unpruned). The repo ships no MTP head; the unsloth self-contained head loads
beside it and accepts **more** drafts than on IQ3_XXS. Loads in ~24 s.

frwk-bsd, v1.0.0 (`b1b770d90`), 2026-11-22, both models in one `bench-all.sh`
session. llama-bench, spec-off. The PP columns are FreeBSD cold-start
numbers (warm IQ3_XXS is ~530 at d=0, see the 2026-11-26 section), so
compare the two models with each other, not with other tables:

| depth | IQ3_XXS pp4096 | GSQ pp4096 | IQ3_XXS tg128 | GSQ tg128 |
|------:|---------------:|-----------:|--------------:|----------:|
| 0     | 235.6 | 236.3 | 26.57 | 24.79 |
| 8192  | 249.1 | 247.6 | 25.82 | 24.00 |
| 32768 | 248.2 | 250.1 | 25.00 | 23.17 |

`bench_model.py` on the ~4 k coding prompt, Total TPS (acceptance):

| config        | IQ3_XXS        | GSQ            |
|---------------|---------------:|---------------:|
| spec-off      | 29.3           | 27.0           |
| MTP N=2       | 38.6 (0.72)    | 41.7 (0.81)    |
| MTP N=3       | (server failed)| **43.8** (0.76)|
| MTP N=4       | 38.0 (0.60)    | 40.4 (0.69)    |
| MTP N=5       | 33.3 (0.51)    | 39.9 (0.62)    |
| MTP N=5, ~32 k| 39.8 (0.56)    | 35.3 (0.60)    |

Spec-off decode is ~7 % slower (more bits per active weight); with MTP it is
8-13 % faster at ~4 k and slower at ~32 k. One prompt, 2 reps, and MTP is
nondeterministic. The IQ3_XXS N=3 failure is the Mesa-26 CPC fault
(`Faulty UTCL2 client ID: CPC (0x5)`), not the model.

Quality decides it: `fbsd-quality` `v45` scored **9/15** against IQ3_XXS's
12/15, every failure a model that found the API and never wrote the file
(details in [fbsd-quality/README.md](fbsd-quality/README.md)). Keep
`flashnext` as the default; `flashnext-gsq` is for when 24 GB of headroom or
the Linux default GTT aperture matters more than agentic reliability.

### Why not IQ4_XS (93.7 GB)

It loads on both hosts *if* the GTT aperture is large enough, but it is not
worth using, and on Linux it is dangerous:

- **frwk-bsd:** loads and serves (HTTP 200, 0 GPU faults) but takes many
  minutes to load and prefills a 4 k prompt in minutes.
- **frwk-linux:** at the driver-default 65.9 GB aperture the draft head cannot
  load at **any** `--ctx-size` (32768/16384/8192 all fail ~20 s in with
  `radv/amdgpu: Not enough memory for command submission` →
  `vk::Queue::submit: ErrorDeviceLost`). Raising `amdgpu.gttsize` to 120000 makes
  it load and serve, **and that configuration kernel-panicked the host** (next
  subsection).

Ruled out as causes of the aperture failure, so they need not be re-tested: our
own flags (upstream's bare recipe fails identically), head choice (`shared-Q8_0`
and self-contained `Q8_0` both fail), and the Mesa-26 CPC fault (**0** dmesg
faults; it reproduces on Mesa 25 too).

### DANGER: `gttsize=120000` panicked the Linux kernel

```
BUG: unable to handle page fault for address: 0000000000004008
Oops: 0000 [#1] SMP NOPTI
CPU: 17 UID: 1000 PID: 15762 Comm: llama-server  Kdump: loaded  Tainted: G W
Hardware name: Framework Desktop (AMD Ryzen AI Max 300 Series)/FRANMFCP06, BIOS 03.06
RIP: 0010:ttm_resource_manager_next+0x130/0x370 [ttm]
kernel 7.0.0-31-generic
```

A near-NULL read inside **TTM's GTT resource-manager walk**, from `llama-server`,
at 6144 s uptime with ~70 GB of GTT resident while running IQ4_XS + MTP. The host
went down hard (ping answered; every userspace port closed). A userspace process
must not be able to panic the kernel: this is an amdgpu/TTM bug. The crash dump
(dmesg + memory image) is preserved on the host.

frwk-linux was recovered by upgrading to Ubuntu 26.04.1 and now **boots and runs
clean on the same kernel 7.0.0-31 with `gttsize=120000` still set**, so neither
the kernel version nor the aperture alone is sufficient: the panic needed the
~94 GB workload. IQ3_XXS peaks at ~54 GB of GTT, comfortably inside the safe
envelope.

Notably **frwk-bsd also loads `ttm.ko`**, ran the identical IQ4_XS + MTP workload
at the identical `gttsize=120000`, and served for over an hour with 0 faults, so
a 120 GB aperture is not inherently unsafe; the fault is in the Linux TTM path.

### Aperture and the "RAM consumed" numbers

The hosts are the *same* machine (8 × 16 GB = 128 GB installed on both; FreeBSD's
`hw.physmem` 136.6 GB vs Linux's `MemTotal` 122.8 GB is a measurement-basis plus
`crashkernel=…128G-:4096M` difference, not less RAM). VRAM is 512 M on both, so
**all weights live in GTT, which is system RAM mapped for the GPU**:

| host                    | GTT aperture | observed while loaded | reading |
|-------------------------|-------------:|----------------------:|---------|
| frwk-linux (default)    |      65.9 GB |            **66.4 GB**| pinned at the ceiling, starved |
| frwk-bsd                |     120000 MB|            **110 GB+**| allocated what the model wanted |
| frwk-linux (gttsize set)|     120000 MB|              69.6 GB  | free to allocate past the old ceiling |

`llama-server`'s own RSS is **0.5 GB** while GTT-used is 69.6 GB and `free`
reports 67 GB used: GTT is billed to the *GPU driver*, not the process, so
`htop` shows tens of GB with nothing to attribute them to. The aperture is not
pre-reserved: with no server running frwk-bsd reports `11G Wired, 69G Free`
despite `gttsize: 120000`. So frwk-bsd's larger figure was always the correct
one, and `66.4 GB` sitting a hair above a 65.9 GB aperture is the entire IQ4_XS
failure in one number.

Linux config (frwk-bsd needs nothing, `hw.amdgpu.gttsize=120000` already):

```sh
# /etc/modprobe.d/amdgpu-gtt.conf      (CONFIG_DRM_AMDGPU=m, so modprobe.d is
options amdgpu gttsize=120000          #  correct; needs a reboot to take)
```

Both hosts then log `amdgpu: 120000M of GTT memory ready`; **that dmesg line is
the figure to quote.** `mem_info_gtt_total` says 125.8 GB and
`llama-bench --list-devices` says 120512 MiB for the same aperture.

### Method notes

- **On FreeBSD, warm the model before llama-bench.** `bench-all.sh` runs
  llama-bench first, so after a boot its FreeBSD PP is the cold-start
  figure (half of warm) while the later server stages are warm. Pass
  `--load-mode none --lazy-mode off`, run one throwaway pp4096 first, or
  report the stage as cold.
- **`bench_model.py`'s `PP t/s` is not a prefill rate.** It is
  `prompt_tokens / ttft`, a TTFT derivative including request overhead, and it
  can rank the hosts opposite to `llama-bench`. Use `llama-bench pp4096` for
  prefill claims.
- **Mesa `fp16: dot2` is a minor-version gate, not "Mesa 26".** Mesa 26.2.x on
  frwk-bsd exposes `shaderMixedFloatDotProductFloat16AccFloat32` and takes
  different SPIR-V matmul/flash-attn shaders (`device->dot2_f16` in
  `ggml-vulkan.cpp`); frwk-linux on **26.0.8** reports `fp16: 1`. Check
  `llama-bench --list-devices` before blaming the OS for a PP gap.
- **This model loads slowly and logs nothing while doing it.** IQ3_XXS takes
  tens of seconds; IQ4_XS takes many minutes at ~98 % CPU with no output.
  `llama-server` binds its port and answers **HTTP 503 long before init
  completes**, so 503 proves only that the process is alive. Wait for 200 or for
  process death; never infer failure from silence.
- **After a kernel panic, the first console output you see is the *next* boot
  failing, not the crash.** Scroll to the lowest timestamp; the `Comm:` and
  `RIP:` lines on the original Oops name the culprit.
- **Draft acceptance must come from `--metrics`, not the log.** Scrape
  `llamacpp:spec_decode_num_{draft,accepted}_tokens_total` (and
  `..._per_pos_total`). The server's log line ends with `mean len = N`, so a
  naive `$NF` parse silently reports mean length as the acceptance ratio.

## Qwen3.8-27B: `qwen38-mtp` and `qwen38-q8`

Two dense slots on the same base model:

- **`qwen38-mtp`**: `ggml-org/Qwen3.8-27B-GGUF` Q8_0 target + the sidecar
  `mtp-Qwen3.8-27B-Q8_0.gguf` draft head, passed via `--model-draft` (not
  embedded), `--spec-draft-n-max 4 --spec-draft-sampling probabilistic`.
- **`qwen38-q8`**: `unsloth/Qwen3.8-27B-GGUF` UD-Q8_K_XL, no MTP. A different
  repo and quant from `qwen38-mtp`. It is the DaemonDocs doc-accuracy recipe
  (`benches.DaemonDocs-model-quality.md`) and the one-variable fallback when
  the MTP path dead-loads. `USAGE=doc`.

One coding prompt (600 tokens), llama.cpp v1.0.0, both hosts:

| slot         | frwk-bsd decode t/s | frwk-linux decode t/s | drafts accepted (bsd / linux) |
|--------------|--------------------:|----------------------:|------------------------------:|
| `qwen38-mtp` |                17.0 |                  17.4 | 405/774 / 411/749             |
| `qwen38-q8`  |                 7.3 |                   7.2 | n/a                           |

No device-lost errors on either host. MTP is worth ~2.3-2.4× decode over the
spec-off slot. The `--spec-draft-n-max 4` pin has not been re-swept on
v1.0.0.

### Mesa-26 RADV compute-write fault (FreeBSD, MTP draft path)

The MTP draft dispatch has hit a RADV fault on frwk-bsd under Mesa 26 that the
same binary and GGUF never hit on Ubuntu. dmesg fingerprint: `[gfxhub] page
fault`, `Faulty UTCL2 client ID: CPC (0x5)`, `PERMISSION_FAULTS 0x5`, `RW 0x1`
(a compute-queue write-permission fault), followed by `ring comp_1.x.0
timeout` and `vk::Queue::submit: ErrorDeviceLost`. No GPU reset line; each
faulting process dies and the next starts fresh. A faulting cold start reads
draft acceptance 0.00000 and decodes *below* spec-off. This is DISTINCT from
the ROCm CPF/MES-0x83 firmware bug (that one is `CPF (0x4) / WALKER_ERROR
0x1`); do not conflate them.

The v1.0.0 runs above (both `qwen38-mtp` and `flashnext` on frwk-bsd) showed
no device-lost errors. Still watch acceptance on every cold start; if it reads
0.00000, restart, or use `qwen38-q8` / a spec-off run.

### Unsloth Dynamic V3.1 vs V3: Q4_K_XL (2026-11-12)

Scope: `frwk-bsd` only, Mesa 26.2.2.
`unsloth/Qwen3.8-27B-GGUF` re-uploaded its 2-6 bit quants as "Unsloth Dynamic
V3.1" on 2026-11-10/11, claiming "5-10% accuracy at the same size". The test
compares the same-name file from both uploads:

| File | HF revision | Size |
|---|---|---:|
| UD3 `UD-Q4_K_XL` | `4ca720788` (2026-08-20) | 17 559 178 144 B |
| UD3.1 `UD-Q4_K_XL` | `acb953b12` (2026-11-11) | 17 659 407 264 B |

#### KL-divergence vs BF16

Metric definitions: see [Quantization quality: KLD, Δp,
PPL](#quantization-quality-kld-δp-ppl). Lower KLD is better.

```sh
llama-perplexity -m <BF16> -f wiki.test.raw --device Vulkan0 -fa on \
  -b 2048 -ub 512 -c 512 --chunks 100 --kl-divergence-base bf16.kld
llama-perplexity -m <quant> --device Vulkan0 -fa on -b 2048 -ub 512 \
  -c 512 --chunks 100 --kl-divergence-base bf16.kld --kl-divergence
```

wikitext-2 test (md5 `7c0137fc034ddbc56a296bce31b4f7fb`), 100 chunks × 512
tokens. Reference: Unsloth BF16 (2 shards, 54.7 GB), PPL 6.7440 ± 0.10317.
`bf16.kld` is 12.7 GB.

| vs BF16 | Q8_K_XL | UD3 Q4_K_XL | UD3.1 Q4_K_XL |
|---|---:|---:|---:|
| Mean KLD | 0.000689 ± 0.000065 | **0.005053 ± 0.000090** | 0.005750 ± 0.000204 |
| Median KLD | 0.000228 | 0.002129 | 0.002256 |
| 99.0 % KLD | 0.005666 | 0.051480 | 0.056007 |
| 99.9 % KLD | 0.031785 | 0.190578 | 0.233276 |
| Max KLD | 1.416482 | 0.824358 | 4.133566 |
| Same top token | 98.941 ± 0.064 % | **96.863 ± 0.109 %** | 96.604 ± 0.113 % |
| RMS Δp | 0.800 ± 0.096 % | 2.072 ± 0.058 % | 2.126 ± 0.073 % |
| PPL(Q)/PPL(base) | 1.000965 | 1.000056 | 0.998721 |

A first pass against `UD-Q8_K_XL` as reference gave the same ranking (mean
KLD 0.005441 UD3 vs 0.005970 UD3.1). It was re-run on BF16 because the Q8 file
comes from the same UD3 pipeline, which could favour UD3. The BF16 run rules
that out: Q8_K_XL is 7× closer to BF16 than either Q4.

#### Verdict

- **On this test UD3.1 is worse, not better.** Mean KLD is 14 % higher (about
  3 standard errors); same-top-token is 0.26 points lower (about 1.6 standard
  errors, not significant).
- UD3.1's max KLD of 4.13 is one outlier token, not a trend: its median and
  99 % KLD are only 5-9 % above UD3.
- PPL below the BF16 reference is noise, not quality; read KLD instead.
- **Limits:** English prose at 512 context. Unsloth's claim is about agentic and
  coding benchmarks at 128K-256K context, which this does not test. The
  `fbsd-quality` run (`fbsd-quality/README.md`, run-id `v38-q38-ud31-q4`)
  covers the agentic side.
- If running Q4_K_XL, the August UD3 file is the safer choice until a
  long-context test says otherwise.

## Memory-bandwidth math

Bandwidth ceiling: 256-bit LPDDR5x-8000 ≈ 256 GB/s.

```
qwen38-q8 tg (UD-Q8_K_XL, 29.29 GiB ≈ 31.4 GB, dense: every weight per token):
  7.3 t/s × 31.4 GB ≈ 229 GB/s → ~90 % of the ceiling
qwen38-mtp tg (Q8_0, ~8.5 bits/weight ≈ 29 GB for 27B):
  17.0 t/s × ~29 GB ≈ 490 GB/s → above the ceiling
```

Decode without MTP sits just under the memory-bandwidth ceiling. MTP breaks
the ceiling by getting multiple accepted tokens per weight read. A MoE such as
Flash-Next reads only its active experts per token, which is why a 125B model
decodes faster than a dense 27B. PP is compute-shaped (matmul-heavy); warm,
it is equal on both OSes, and the one OS-visible PP gap measured so far is the
FreeBSD cold-start page-fault cost on Flash-Next's lazy n-gram table.

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

| BIOS UMA setting          | VRAM total | GTT total | MoE PP at d≈4 k | TG        |
|---------------------------|-----------:|----------:|----------------:|-----------|
| Large (64 GiB carve-out)  |     64 GiB |   93.7 GiB| baseline        | unchanged |
| Small / Auto (512 MiB)    |    512 MiB |   93.7 GiB| **+31 %**       | unchanged |

Measured on HP ZBook (Ryzen AI MAX+ PRO 395) with a 4-bit MoE model.
**Set UMA Frame Buffer to the smallest value** (512 MiB or "Auto"). Large
carve-outs only help legacy code that hardcodes VRAM.

## Firmware power cap (`platform_profile` on laptops)

HP firmware caps GPU PPT (Package Power Tracking, the SoC-wide power budget)
based on ACPI (Advanced Configuration and Power Interface)
`platform_profile`; Framework Desktop does not.

| Host / profile        | PPT avg | PPT p95 | PPT max | GPU max freq |
|-----------------------|--------:|--------:|--------:|-------------:|
| zbook `balanced`      |  40 W   |  40 W   |  59 W   | 2070 MHz     |
| zbook `performance`   |  69 W   |  70 W   |  70 W   | 2898 MHz     |
| frwk-linux `balanced` |  83 W   | 110 W   | 113 W   | 2900 MHz     |

On the zbook, `performance` gave +43 % PP over `balanced`. p95 = max on zbook
is a firmware cap, not thermal throttling. **For laptops, switch to
`performance`** before heavy PP:

```sh
echo performance | sudo tee /sys/firmware/acpi/platform_profile
for c in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
  echo performance | sudo tee "$c" > /dev/null
done
```

Revert to `balanced` when done: 70 W sustained on a laptop spins fans up and
kills battery. TG is unaffected (memory-bound).

## Known crash signatures (FreeBSD `frwk-bsd`)

- **Dense 27B with `-fa 1 --no-host 1`**: crashed on Mesa 25.2.8
  (`vk::DeviceLostError` in `ggml_vk_buffer_write_2d`). Fixed on Mesa 26; the
  default recipe drops `--no-host` entirely, and `llmsrv.sh` never sets it for
  dense slots on FreeBSD.
- **Q8 dense cold-start GTT OOM** (Mesa 26): first Q8 llama-bench or
  llama-server startup after boot occasionally fails with
  `vk::Device::allocateMemory: ErrorOutOfDeviceMemory` even though the model
  fits well inside the 120 GiB GTT pool. Retry once: the arena warms up and
  subsequent starts succeed. `bench-all.sh` retries llama-bench
  automatically; llama-server needs a manual restart if it hits this.
- **MTP draft path CPC write fault** (Mesa 26): see
  [Mesa-26 RADV compute-write fault](#mesa-26-radv-compute-write-fault-freebsd-mtp-draft-path).
- **`RADV_DEBUG=zerovram` on Mesa 25**: actively crashes runs that succeed
  without it. Do not set. (Was required on Mesa 24; the flag is still not
  needed on Mesa 26.)
- **Multi-value `llama-bench` sweeps** (e.g. `-fa 0,1`): crash on graph
  variant 2/3 on Mesa 25, not retested on Mesa 26. Run one invocation per
  (model, config) pair to stay safe.
- **Reload after crash recovery**: on Mesa 25, subsequent benches often
  crashed even on configs that just succeeded. If you see this on Mesa 26,
  reboot rather than `kldunload amdgpu` + `kldload amdgpu`: the userspace
  Vulkan state does not fully recover from a driver reload.

## The `--no-host` non-finding

A direct A/B on `frwk-linux` (2026-07-10, 3 reps each, a dense 27B and a MoE
at d=0 and d=32k) showed `--no-host 1` vs `--no-host 0` diverges by ≤ 0.6 % on
every workload: the flag is a **no-op** on this stack when the BIOS UMA
carve-out is small.

The real UMA-GTT finding is the carve-out size (see the BIOS section):
`--no-host` matters only if that carve-out is large enough to force the
staging path. With a small carve-out, the driver keeps everything in GTT
regardless of the flag. The default recipe drops `--no-host` accordingly.

## Pitfalls

- **`--cache-reuse N`** silently disabled on Qwen3-family models (M-RoPE KV
  cache can't be position-shifted). Not a regression: the default prompt
  cache still gives a large warm-reuse speedup.
- **`-hf` auto-loads the multimodal projector** for VL-derived Qwen weights.
  Pass `--no-mmproj` for text-only.
- **`--reasoning-budget 0`** disables `<think>...</think>` for short mechanical
  tasks. Use `/no_think` inline instead when the savings are small.
- **`bench_model.py` warm-up populates the server prompt cache**: per-run
  TTFT is for cached re-eval. For cold prefill, hit `/v1/chat/completions`
  with curl and read `timings.prompt_n` / `timings.prompt_per_second`.

## Reproducing

```sh
# On each host (frwk-bsd, frwk-linux):
git clone https://github.com/ggml-org/llama.cpp && cd llama.cpp
git checkout v1.0.0
cmake -B build -DGGML_VULKAN=ON && cmake --build build --config Release
# Then, from LLM/:
MODEL=flashnext sh llmsrv.sh   # or qwen38-mtp / qwen38-q8
sh bench-all.sh                # full sweep; produces /tmp/bench-all.md + .jsonl
```

Model registry for `bench-all.sh` lives at the top of the script; add slots
there to bench new GGUFs.

### Harness features

`bench-all.sh` has a registry field (`ctx`) for per-slot `--ctx-size`
(**server stages only**: `llama-bench` has no such flag and prints usage,
reporting `crash` at every depth), sharded-GGUF support (pass shard `00001`,
llama.cpp opens the rest), `--metrics` plus `spec_metrics()` so a dead draft
head reads `0.00000` instead of passing as a merely-slow row, a quant-column
regex that handles `UD-IQ4_XS`-style names, and `--load-mode mmap` for
llama-bench (current llama-bench rejects `--mmap 1`). Start it from a script
file rather than `ssh host 'STAGES=llama-bench sh bench-all.sh'`: the
stray-process guard (`pgrep -f 'llama-(server|cli|bench)'`) also matches a
launching shell whose command line holds `STAGES=llama-bench`.

`llmsrv.sh MODEL=flashnext` uses the full `CTX=131072` (loads with MTP on),
warns past the model's native 262144, and pins `--spec-draft-n-max 2`.
