# FrameWork Desktop with amdgpu support

Use case: Local LLM with Vulkan backend

## FreeBSD main

First, need a FreeBSD main at:
`git: 36fe65cc7a31 - main - Bump __FreeBSD_version to 1600015 after linuxkpi changes for DRM 6.11`

## Install latest drm-kmod from github

Install latest drm-kmod:
```
$ git clone --single-branch --branch strix https://github.com/ocochard/drm-kmod/
$ cd drm-kmod
$ make -j$(nproc) DEBUG_FLAGS=-g SYSDIR=/usr/src/sys
$ sudo make install DEBUG_FLAGS=-g SYSDIR=/usr/src/sys KMODDIR=/boot/modules
$ cd
```

## Install latest AMD firmwares

```
$ git clone --single-branch --depth 1 --branch strix-halo https://github.com/ocochard/freebsd-ports.git
$ cd freebsd-ports/graphics/gpu-firmware-amd-kmod
$ for f in dcn_3_5_1 gc_11_5_1 psp_14_0_1 sdma_6_1_1
vcn_4_0_6 vcn_4_0_6_1 vpe_6_1_1; do make FLAVOR=$f; done
$ sudo find work-* -name "*.ko" -exec cp {} /boot/modules/ \;
$ ls /boot/modules/
amdgpu.ko                       amdgpu_gc_11_5_1_pfp_bin.ko     amdgpu_vpe_6_1_1_bin.ko
amdgpu_dcn_3_5_1_dmcub_bin.ko   amdgpu_gc_11_5_1_rlc_bin.ko     dmabuf.ko
amdgpu_gc_11_5_1_imu_bin.ko     amdgpu_psp_14_0_1_ta_bin.ko     drm.ko
amdgpu_gc_11_5_1_me_bin.ko      amdgpu_psp_14_0_1_toc_bin.ko    i915kms.ko
amdgpu_gc_11_5_1_mec_bin.ko     amdgpu_sdma_6_1_1_bin.ko        linker.hints
amdgpu_gc_11_5_1_mes1_bin.ko    amdgpu_vcn_4_0_6_1_bin.ko       radeonkms.ko
amdgpu_gc_11_5_1_mes_2_bin.ko   amdgpu_vcn_4_0_6_bin.ko         ttm.ko
$ kldload amdgpu

framework kernel: [drm] amdgpu kernel modesetting enabled.
framework kernel: drmn0: <drmn> on vgapci0
framework kernel: vgapci0: child drmn0 requested pci_enable_io
framework syslogd: last message repeated 1 times
framework kernel: [drm] initializing kernel modesetting (IP DISCOVERY 0x1002:0x1586 0xF111:0x000A 0xC1).
framework kernel: [drm] register mmio base: 0xB0400000
framework kernel: [drm] register mmio size: 1048576
framework kernel: [drm] add ip block number 0 <soc21_common>
framework kernel: [drm] add ip block number 1 <gmc_v11_0>
framework kernel: [drm] add ip block number 2 <ih_v6_1>
framework kernel: [drm] add ip block number 3 <psp>
framework kernel: [drm] add ip block number 4 <smu>
framework kernel: [drm] add ip block number 5 <dm>
framework kernel: [drm] add ip block number 6 <gfx_v11_0>
framework kernel: [drm] add ip block number 7 <sdma_v6_0>
framework kernel: [drm] add ip block number 8 <vcn_v4_0_5>
framework kernel: [drm] add ip block number 9 <jpeg_v4_0_5>
framework kernel: [drm] add ip block number 10 <mes_v11_0>
framework kernel: [drm] add ip block number 11 <vpe_v6_1>
framework kernel: drmn0: Fetched VBIOS from VFCT
framework kernel: amdgpu: ATOM BIOS: 113-STRXLGEN-001
framework kernel: drmn0: successfully loaded firmware image 'amdgpu/psp_14_0_1_toc.bin'
framework kernel: drmn0: successfully loaded firmware image 'amdgpu/psp_14_0_1_ta.bin'
framework kernel: drmn0: successfully loaded firmware image 'amdgpu/dcn_3_5_1_dmcub.bin'
framework kernel: drmn0: successfully loaded firmware image 'amdgpu/gc_11_5_1_pfp.bin'
framework kernel: drmn0: successfully loaded firmware image 'amdgpu/gc_11_5_1_me.bin'
framework kernel: drmn0: successfully loaded firmware image 'amdgpu/gc_11_5_1_rlc.bin'
framework kernel: drmn0: successfully loaded firmware image 'amdgpu/gc_11_5_1_mec.bin'
framework kernel: drmn0: successfully loaded firmware image 'amdgpu/gc_11_5_1_imu.bin'
framework kernel: drmn0: successfully loaded firmware image 'amdgpu/sdma_6_1_1.bin'
framework kernel: [drm] VCN(0) encode/decode are enabled in VM mode
framework kernel: [drm] VCN(1) encode/decode are enabled in VM mode
framework kernel: drmn0: successfully loaded firmware image 'amdgpu/vcn_4_0_6.bin'
framework kernel: drmn0: successfully loaded firmware image 'amdgpu/vcn_4_0_6_1.bin'
framework kernel: drmn0: [drm] jpeg_v4_0_5_set_dec_ring_funcsdrmn0: [drm] jpeg_v4_0_5_set_dec_ring_funcsdrmn0: successfully loaded firmware image 'amdgpu/gc_11_5_1_mes_2.bin'
framework kernel: drmn0: successfully loaded firmware image 'amdgpu/gc_11_5_1_mes1.bin'
framework kernel: drmn0: VPE: collaborate mode truedrmn0: Trusted Memory Zone (TMZ) feature disabled as experimental (default)
framework kernel: drmn0: PCIE atomic ops is not supported
framework kernel: [drm] vm size is 262144 GB, 4 levels, block size is 9-bit, fragment size is 9-bit
framework kernel: drmn0: VRAM: 512M 0x0000008000000000 - 0x000000801FFFFFFF (512M used)
framework kernel: drmn0: GART: 512M 0x00007FFF00000000 - 0x00007FFF1FFFFFFF
framework kernel: [drm] Detected VRAM RAM=512M, BAR=512M
framework kernel: [drm] RAM width 256bits LPDDR5
framework kernel: [drm] amdgpu: 512M of VRAM memory ready
framework kernel: [drm] amdgpu: 65149M of GTT memory ready.
framework kernel: [drm] GART: num cpu pages 131072, num gpu pages 131072
framework kernel: [drm] PCIE GART of 512M enabled (table at 0x000000801FB00000).
framework kernel: [drm] Loading DMUB firmware via PSP: version=0x09004100
framework kernel: [drm] Found VCN firmware Version ENC: 1.24 DEC: 9 VEP: 0 Revision: 16
framework kernel: drmn0: Will use PSP to load VCN firmware
framework kernel: drmn0: successfully loaded firmware image 'amdgpu/vpe_6_1_1.bin'
framework kernel: drmn0: reserve 0x8c00000 from 0x8010000000 for PSP TMR
framework kernel: drmn0: RAS: optional ras ta ucode is not available
framework kernel: drmn0: RAP: optional rap ta ucode is not available
framework kernel: drmn0: SECUREDISPLAY: securedisplay ta ucode is not available
framework kernel: drmn0: SMU is initialized successfully!
framework kernel: [drm] Seamless boot condition check passed
framework kernel: [drm] Display Core v3.2.281 initialized on DCN 3.5.1
framework kernel: [drm] DP-HDMI FRL PCON supported
framework kernel: [drm] DMUB hardware initialized: version=0x09004100
```

## llama.cpp with Vulkan backend

```
$ sudo pkg install -y vulkan-headers vulkan-loader glslang shaderc cmake curl
$ git clone https://github.com/ggerganov/llama.cpp.git
$ cd llama.cpp
$ cmake -S . --fresh -B build -DGGML_VULKAN=ON
$ cmake --build build --config Release -- -j $(nproc)
```

### Recommended `llama-server` config for coding (build `9d34231bb` / 8929)

Two modes, both wrapped by `~/llmsrv.sh` on the framework. Tuned via
`llama-bench` and validated end-to-end with `tools/bench_model.py`. Full
sweep, per-flag rationale, and crash signatures are in
[llama-bench-framework-results.md](llama-bench-framework-results.md).

```sh
~/llmsrv.sh            # default: thinking-coder mode
MODE=fast ~/llmsrv.sh  # non-thinking, ~8x faster on simple tasks
```

#### Mode `coder` (default) — full thinking, best quality

```sh
RADV_DEBUG=zerovram build/bin/llama-server \
  -hf unsloth/Qwen3.6-27B-GGUF:UD-Q4_K_XL \
  --no-mmproj \
  --alias qwen36-coder \
  --device Vulkan0 \
  --temp 0.6 --top-p 0.95 --top-k 20 --min-p 0.00 \
  --flash-attn on \
  --no-host \
  --batch-size 2048 --ubatch-size 512 \
  --ctx-size 65536 --parallel 1 \
  --host 127.0.0.1 --port 8080
```

#### Mode `fast` — non-thinking, for routine edits / agent loops

Same launcher with `MODE=fast`, which adds `--reasoning-budget 0` and
swaps to the non-thinking sampler preset:

```sh
  --temp 0.7 --top-p 0.80 --top-k 20 --min-p 0.0 --presence-penalty 1.5 \
  --reasoning-budget 0
```

Measured on a "write `is_prime(n)`" task: `coder` 109 s / 1277 tokens vs
`fast` 12.7 s / 139 tokens — same correctness, **8.6× faster**. Quality
drops on hard reasoning; fall back to `coder` for those.

What each option does:

| Option | What it does |
| --- | --- |
| `RADV_DEBUG=zerovram` | Mesa/RADV env var. Forces the driver to zero-initialize every newly allocated VRAM buffer before the GPU can read it. Hides bugs where a shader reads uninitialized device memory. |
| `-hf <repo>:<quant>` | Pulls the GGUF from Hugging Face (`unsloth/Qwen3.6-27B-GGUF`, file `UD-Q4_K_XL`) into `~/.cache/huggingface/...` and loads it. Equivalent to downloading manually then passing `-m`. |
| `--no-mmproj` | This `-hf` repo also ships a vision projector (qwen-vl). Skip it for text-only coding so the server doesn't load multimodal context (which also disables some optimizations). |
| `--alias qwen36-coder` | Name the model is advertised as in the OpenAI-compatible API (`/v1/models`, `model` field in completion responses). Cosmetic; lets clients pin a stable name independent of the GGUF filename. |
| `--device Vulkan0` | Restrict offload to the named ggml device. `llama-bench`/`llama-server` enumerate `Vulkan0`, `Vulkan1`, … On this box there is one iGPU, so `Vulkan0` is the Radeon 8060S. |
| `--temp 0.6` | Sampling temperature. Scales logits before softmax; lower = more deterministic. 0.6 is Qwen3's recommended value for coding (thinking mode). |
| `--top-p 0.95` | Nucleus sampling: keep the smallest set of tokens whose cumulative probability ≥ 0.95, sample from those. |
| `--top-k 20` | Keep only the 20 highest-probability tokens at each step (applied before top-p). |
| `--min-p 0.00` | Drop tokens whose probability is below `min_p × max_token_prob`. `0.00` disables it (top-p/top-k do the filtering). |
| `--flash-attn on` | Use the fused Flash-Attention kernel instead of the default attention path. Cheaper memory traffic; `auto` lets llama.cpp pick, `on` forces it. |
| `--no-host` | Don't pin a CPU-side mirror of the model weights. On a UMA iGPU (system RAM == VRAM) this mirror is wasted; saves RAM and reduces copy traffic. On a dGPU you'd want it on. |
| `--batch-size 2048` | Logical batch (`n_batch`): max prompt tokens grouped into one decode call. Bigger = better PP throughput up to a point, more KV scratch memory. |
| `--ubatch-size 512` | Physical microbatch (`n_ubatch`): how many tokens of that batch are actually fed to the GPU per kernel launch. Must divide `--batch-size`. Tunes occupancy vs. launch overhead. |
| `--ctx-size 65536` | Maximum context window (KV cache size in tokens). Memory cost is roughly linear in this value × layers × heads × kv-dtype-bytes. |
| `--reasoning-budget N` *(fast mode)* | Hard cap on `<think>...</think>` tokens. `0` disables thinking entirely; `>0` truncates mid-thought. Default `-1` = unlimited. Qwen3.6 spends 800–3000 reasoning tokens on every reply by default. |
| `--presence-penalty 1.5` *(fast mode)* | Per Qwen3's non-thinking preset: penalizes already-emitted tokens to keep brief answers from repeating. |

Flags deliberately **omitted** here:

| Option | What it does | Why it's off |
| --- | --- | --- |
| `--no-mmap` / `-mmp 0` | Read weights via `read(2)` into anonymous memory instead of `mmap`-ing the GGUF. Forces the whole model resident up front. | Wedges the GPU on this stack; needs a reboot. |
| `--direct-io` | Open the GGUF with `O_DIRECT` (bypass the page cache). Intended for fast NVMe + cold cache. | Same GPU wedge as `--no-mmap`. |
| `--kv-unified` | One contiguous KV buffer shared across parallel decoding slots, instead of one per slot. | No measurable effect for single-client coding; relevant only with `--parallel N>1`. |
| `--cache-reuse N` | Reuse cached KV across non-prefix matches by shifting positions. Looks ideal for qwen-code-style modified-prefix prompts. | **Architecturally unsupported here.** Qwen3 uses M-RoPE; `llama_memory_can_shift()` returns false → server logs `cache_reuse is not supported by this context, it will be disabled`. The default prompt cache + context checkpoints (already on) handle exact-prefix reuse very well anyway (warm exact-prefix: 1.6 s for a 30 k-token prompt). |
| `--ctk` / `--ctv` (e.g. `q8_0`) | Quantize the K / V cache. Halves KV memory, lets you push `--ctx-size` higher. | `q8_0` KV crashes Vulkan on this driver/build. |
| `--ctx-size > 65536` | Larger context window. Driver-stable up to at least 114 k. | Usability collapses past ~30 k: TTFT ~16 min at d=91 k, ~26 min at d=114 k. Bump only for a specific deep session. |

Why these specific values (vs. neighbouring tunings):

- `RADV_DEBUG=zerovram` — required workaround for a RADV / GFX1151 bug
  that reads uninitialized VRAM and causes `vk::DeviceLostError`. ~1.5%
  pp cost; without it the server crashes on the first request. Drop
  this if/when mesa fixes the upstream bug.
- `--flash-attn on` — +2.8 % pp at d=0, free.
- `--no-host` — +0.8 % pp on this UMA system; reduces host memory
  pressure.
- `--batch-size 2048 --ubatch-size 512` (defaults) — `4096/1024` is
  ~3 % **slower** under the current dense-model detection.
- `--ctx-size 65536` — interactive sweet spot. 131 k loads but TTFT
  becomes minutes; for qwen-code, configure the agent to summarize/drop
  earlier turns rather than push past 65 k.
- f16 KV cache (default) — `q8_0` KV crashes Vulkan on this stack.

Expected throughput, validated against `tools/bench_model.py`:

| Prompt | TTFT     | PP TPS | Token gen |
| ------ | -------- | -----: | --------- |
| ~4 k   |   14.4 s |  285.6 | 11.7 t/s  |
| ~12 k  |   47.0 s |  265.3 | 11.4 t/s  |
| ~36 k  |  202.7 s |  190.5 | 10.4 t/s  |
| ~91 k  |   16 min |   93.1 |  9.1 t/s  |
| ~114 k |   26 min |   73.7 |  8.5 t/s  |

### Benchmark commands

```sh
# Decode-rate sweep (pp/tg at various depths)
RADV_DEBUG=zerovram build/bin/llama-bench \
  -m ~/.cache/huggingface/hub/models--unsloth--Qwen3.6-27B-GGUF/snapshots/82d411acf4a06cfb8d9b073a5211bf410bfc29bf/Qwen3.6-27B-UD-Q4_K_XL.gguf \
  --device Vulkan0 \
  -p 4096 -n 128 -d 0 -fa 1 --no-host 1 -r 2

# End-to-end OpenAI-style streaming bench (TTFT + PP TPS + tg + ITL P95)
# requires llama-server running with the config above
python3 tools/bench_model.py -u http://127.0.0.1:8080 \
  --prompt-file /tmp/coding_prompt.txt -t 256 -r 3
```

## qwen-code (CLI agent)

Once `llama-server` is running with the config above, install the
qwen-code CLI to use it as a coding agent:

```sh
sudo pkg install qwen-code
```

qwen-code is OpenAI-API compatible — point it at the local
`llama-server` via the standard `OPENAI_*` environment variables. Add
to `~/.profile`:

```sh
OPENAI_BASE_URL="http://127.0.0.1:8080/v1"; export OPENAI_BASE_URL
OPENAI_API_KEY="not-needed";                export OPENAI_API_KEY
OPENAI_MODEL="qwen36-coder";                export OPENAI_MODEL
```

`OPENAI_API_KEY` must be set (the SDK refuses to start without one) but
its value is ignored — `llama-server` doesn't check auth. `OPENAI_MODEL`
matches the `--alias` passed to llama-server (`qwen36-coder` for the
default thinking-coder mode, `qwen36-coder-fast` if you launched with
`MODE=fast ./llmsrv.sh`).

### Settings (`~/.qwen/settings.json`)

The default qwen-code request timeout is short (≤64 s in older
releases) — too short for cold prefill of the kind of large prompts
the agent assembles (50–60 k tokens of repo context is normal). Hitting
the timeout makes qwen-code cancel mid-prefill and immediately retry
the same prompt; the server then has to redo the prefill (the prompt
cache helps but each retry still costs seconds), so the user sees
nothing happen for minutes. Bump the timeout in `~/.qwen/settings.json`:

```json
{
  "model": {
    "generationConfig": {
      "timeout": 600000,
      "maxRetries": 1
    }
  },
  "$version": 3
}
```

- `timeout: 600000` — 10 minutes in ms. Covers cold prefill at any
  realistic depth on this hardware (60 k prompt at ~410 t/s ≈ 2.5 min;
  10 min leaves headroom for the deeper / slower depths).
- `maxRetries: 1` — don't pile up retries on a slow prefill. If the
  first attempt does time out, one extra try is enough; further retries
  just compound the work.

Restart qwen-code after editing — settings are read at startup, not
per-request.

### Diagnosing "qwen-code feels stuck"

If qwen-code appears to hang for a long time without printing tokens,
tail `/tmp/llmsrv.log` (or wherever you redirected llama-server output)
and look for the pattern:

```
slot update_slots: id 0 | task N  | new prompt, ... task.n_tokens = 60179
slot update_slots: id 0 | task N  | prompt processing progress, ...
srv          stop: cancel task, id_task = N
slot      release: id 0 | task N  | stop processing: n_tokens = 45056
slot update_slots: id 0 | task N+M | new prompt, ... task.n_tokens = 60179
```

Two `new prompt` lines for the same `task.n_tokens` separated by a
`cancel task` is the signature of the client timing out mid-prefill.
Bump `model.generationConfig.timeout` further if it keeps happening.

A normal slow prefill instead shows monotonic `progress = …` ticks
ending in a `prompt eval time = … ms / N tokens` summary, then
generation; no `cancel task` line.
