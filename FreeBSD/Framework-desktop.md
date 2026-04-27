# Framework Desktop with amdgpu support

Use case: Local LLM with Vulkan backend on the Radeon 8060S iGPU (Strix Halo).

## FreeBSD main

Requires FreeBSD main at least at:
`git: 36fe65cc7a31 - main - Bump __FreeBSD_version to 1600015 after linuxkpi changes for DRM 6.11`

## Install latest drm-kmod from github

```
$ git clone --single-branch --branch strix https://github.com/ocochard/drm-kmod/
$ cd drm-kmod
$ make -j$(nproc) DEBUG_FLAGS=-g SYSDIR=/usr/src/sys
$ sudo make install DEBUG_FLAGS=-g SYSDIR=/usr/src/sys KMODDIR=/boot/modules
```

## Install latest AMD firmwares

```
$ git clone --single-branch --depth 1 --branch strix-halo https://github.com/ocochard/freebsd-ports.git
$ cd freebsd-ports/graphics/gpu-firmware-amd-kmod
$ for f in dcn_3_5_1 gc_11_5_1 psp_14_0_1 sdma_6_1_1 vcn_4_0_6 vcn_4_0_6_1 vpe_6_1_1; do
    make FLAVOR=$f
  done
$ sudo find work-* -name "*.ko" -exec cp {} /boot/modules/ \;
$ kldload amdgpu
```

Expected kernel messages on successful load:

```
framework kernel: [drm] amdgpu kernel modesetting enabled.
framework kernel: drmn0: <drmn> on vgapci0
framework kernel: vgapci0: child drmn0 requested pci_enable_io
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

## Build llama.cpp with Vulkan backend

```
$ sudo pkg install -y vulkan-headers vulkan-loader glslang shaderc cmake curl
$ git clone https://github.com/ggerganov/llama.cpp.git
$ cd llama.cpp
$ cmake -S . --fresh -B build -DGGML_VULKAN=ON
$ cmake --build build --config Release -- -j $(nproc)
```

## Run llama-server (coding setup)

Default model: **Qwen3.6-35B-A3B** (MoE, Q4_K_XL). Coder mode (full thinking, best quality):

```sh
RADV_DEBUG=zerovram build/bin/llama-server \
  -m ~/.cache/huggingface/hub/models--unsloth--Qwen3.6-35B-A3B-GGUF/blobs/Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf \
  --no-mmproj \
  --no-warmup \
  --alias qwen36-coder \
  --device Vulkan0 \
  --temp 0.6 --top-p 0.95 --top-k 20 --min-p 0.00 \
  --flash-attn on \
  --no-host \
  --batch-size 2048 --ubatch-size 512 \
  --ctx-size 131072 --parallel 1 \
  --host 127.0.0.1 --port 8080
```

For `fast` mode add:

```sh
  --temp 0.7 --top-p 0.80 --top-k 20 --min-p 0.0 --presence-penalty 1.5 \
  --reasoning-budget 0
```

### Parameters

| Option | What it does |
| --- | --- |
| `RADV_DEBUG=zerovram` | Forces RADV to zero-init VRAM buffers. Required workaround for a GFX1151 bug that otherwise crashes with `vk::DeviceLostError`. ~1.5% PP cost. |
| `-m <path>` | Path to local GGUF. (`-hf` shorthand currently 404s on the MoE filename, so download manually with curl.) |
| `--no-mmproj` | Skip the vision projector shipped in the repo (text-only coding). |
| `--no-warmup` | **Required for the MoE on this stack** — the warmup empty-batch decode crashes Vulkan. First real request acts as warmup. Dense 27B doesn't need it. |
| `--alias <name>` | Name advertised in the OpenAI-compatible API. |
| `--device Vulkan0` | Restrict offload to the named ggml device (the iGPU). |
| `--temp / --top-p / --top-k / --min-p` | Sampling. Values match Qwen3's recommended preset (thinking vs non-thinking). |
| `--flash-attn on` | Force fused Flash-Attention kernel. +2.8% PP, free. |
| `--no-host` | Don't keep a CPU-side mirror of weights. UMA iGPU = wasted copy. +0.8% PP, less RAM pressure. |
| `--batch-size 2048` | Logical batch (`n_batch`): max prompt tokens grouped per decode call. |
| `--ubatch-size 512` | Physical microbatch (`n_ubatch`): tokens per kernel launch. Must divide `--batch-size`. |
| `--ctx-size 131072` | Max context window. Qwen3.6's native max RoPE length. KV memory grows linearly. |
| `--parallel 1` | Single decoding slot (interactive single-client use). |
| `--reasoning-budget 0` *(fast)* | Hard cap on `<think>...</think>` tokens. `0` disables thinking. |
| `--presence-penalty 1.5` *(fast)* | Per Qwen3's non-thinking preset; avoids repetition in brief answers. |

### Flags deliberately omitted

| Option | Why it's off |
| --- | --- |
| `--no-mmap` / `-mmp 0` | Wedges the GPU on this stack; needs a reboot. |
| `--direct-io` | Same GPU wedge as `--no-mmap`. |
| `--kv-unified` | No effect for single-client coding (only relevant with `--parallel N>1`). |
| `--cache-reuse N` | Qwen3 uses M-RoPE; unsupported (`llama_memory_can_shift()` returns false). |
| `--ctk q8_0` / `--ctv q8_0` | Quantized KV cache crashes Vulkan on this driver/build. |
| `--ctx-size > 131072` | Beyond model's native max — needs RoPE scaling, degrades quality. |

## Benchmark commands

```sh
# MoE: only -d 0 works (deeper depths crash the empty-batch path).
RADV_DEBUG=zerovram build/bin/llama-bench \
  -m ~/.cache/huggingface/hub/models--unsloth--Qwen3.6-35B-A3B-GGUF/blobs/Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf \
  --device Vulkan0 \
  -p 4096 -n 128 -d 0 -fa 1 --no-host 1 -r 2

# Dense 27B (supports -d N>0):
RADV_DEBUG=zerovram build/bin/llama-bench \
  -m ~/.cache/huggingface/hub/models--unsloth--Qwen3.6-27B-GGUF/snapshots/82d411acf4a06cfb8d9b073a5211bf410bfc29bf/Qwen3.6-27B-UD-Q4_K_XL.gguf \
  --device Vulkan0 \
  -p 4096 -n 128 -d 0 -fa 1 --no-host 1 -r 2

# End-to-end OpenAI-style streaming bench (requires running llama-server):
python3 tools/bench_model.py -u http://127.0.0.1:8080 \
  --prompt-file /tmp/coding_prompt.txt -t 256 -r 3
```

Full sweep, per-flag rationale, and crash signatures are in
[llama-bench-framework-results.md](llama-bench-framework-results.md).

## qwen-code (CLI agent)

```sh
sudo pkg install qwen-code
```

Point it at local `llama-server` via the standard `OPENAI_*` env vars
(add to `~/.profile`):

```sh
OPENAI_BASE_URL="http://127.0.0.1:8080/v1"; export OPENAI_BASE_URL
OPENAI_API_KEY="not-needed";                export OPENAI_API_KEY
OPENAI_MODEL="qwen36-coder";                export OPENAI_MODEL
```

`OPENAI_API_KEY` must be set (SDK requires it) but the value is ignored.
`OPENAI_MODEL` matches the `--alias` passed to llama-server.

### Settings (`~/.qwen/settings.json`)

Bump the default request timeout — cold prefill of large repo prompts
(50–60 k tokens) can exceed the default ≤64 s and trigger retry storms:

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

- `timeout: 600000` — 10 min in ms. Covers cold prefill at realistic depths.
- `maxRetries: 1` — don't pile up retries on a slow prefill.

Restart qwen-code after editing (settings are read at startup).
