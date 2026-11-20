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

Use [../LLM/llmsrv.sh](../LLM/llmsrv.sh): it holds the tuned recipe per model
and OS. Default slot is `flashnext`:

```sh
./LLM/llmsrv.sh                  # default: flashnext (= USAGE=coding)
MODEL=qwen38-mtp ./LLM/llmsrv.sh # Qwen3.8-27B dense Q8_0 + Q8_0 MTP head
MODEL=qwen38-q8 ./LLM/llmsrv.sh  # Qwen3.8-27B dense Q8_K_XL, spec-off fallback (= USAGE=doc)
MODEL=flashnext-abl ./LLM/llmsrv.sh  # flashnext + abliteration LoRA (uncensored)
```

Default model: **Qwen3.8-Flash-Next** (125B/6B-active MoE, `UD-IQ3_XXS`, 82 GB)
plus the self-contained Q8_0 MTP draft head at N=2. On llama.cpp v1.0.0:
38-40 t/s decode, draft acceptance 0.61-0.70. Equivalent command on FreeBSD:

```sh
hub=~/.cache/huggingface/hub/models--unsloth--Qwen3.8-Flash-Next-GGUF/snapshots/*
build/bin/llama-server \
  --model $hub/UD-IQ3_XXS/Qwen3.8-Flash-Next-UD-IQ3_XXS-00001-of-00003.gguf \
  --model-draft $hub/MTP/mtp-Qwen3.8-Flash-Next-Q8_0.gguf \
  --spec-type draft-mtp --spec-draft-n-max 2 \
  --no-mmproj \
  --alias Qwen3.8-Flash-Next-UD-IQ3_XXS-MTP \
  --device Vulkan0 \
  --metrics \
  --flash-attn on \
  --temperature 0.6 --top-p 0.95 --top-k 20 --min-p 0.0 \
  --jinja \
  --batch-size 2048 --ubatch-size 512 \
  --ctx-size 131072 --parallel 1 \
  --host 127.0.0.1 --port 8080
```

Hard requirements for this slot (all fail at load time if unmet):

- Use the **self-contained** MTP head re-uploaded 2026-10-05, not the `shared-`
  one. Mainline cannot borrow the main model's embedding
  (`tensor 'token_embd.weight' not found`). The pre-2026-10-05 upload aborts
  with `GGML_ASSERT(buffer) failed`.
- Stay on **UD-IQ3_XXS**. With UD-IQ4_XS (93.7 GB) the draft head cannot load
  at any `--ctx-size` (`radv/amdgpu: Not enough memory for command submission`).
  On Linux, the bigger GTT aperture IQ4_XS needs panicked the kernel.
- The full 131072 context fits with MTP on. The model declares 262144 natively.

MTP is flaky on FreeBSD (Mesa 26 RADV), not unusable. Some cold starts hit a
GPUVM fault (`[gfxhub] page fault`, client ID CPC (0x5),
`ring comp_1.1.0 timeout`). Check the server log for
`draft acceptance = 0.xxxxx` on each cold start. If it reads `0.00000`, the
head is dead: restart, or fall back to `MODEL=qwen38-q8`.

### Uncensored variant (`flashnext-abl`)

`MODEL=flashnext-abl` is the same recipe plus mrfakename's rank-1
abliteration LoRA (`abliteration-lora.gguf`, 2.3 MB), applied at load with
`--lora`. It reuses the cached IQ3_XXS shards and MTP head, so no second 82 GB
download. The LoRA projects one refusal direction out of `o_proj`,
`linear_attn.out_proj` and `shared_expert.down_proj` in all 48 layers. Routed
experts, embeddings and the MTP layer are untouched. Author's measurement on
Q8_0: refusals 99 to 7 per 100, harmless KL 0.068. On llama.cpp v1.0.0
(framework, 2026-11-19, A/B via the per-request LoRA scale, thinking off) it
loads on IQ3_XXS + Vulkan with MTP on. Two refusal prompts were refused at
scale 0 and answered at scale 1. Decode and draft acceptance did not change:
38.5-40.1 vs 39.5-40.2 t/s and 0.64-0.68 vs 0.65-0.68 on prose, 45.0 vs
46.4 t/s and 0.84 vs 0.86 on a C coding prompt. One sample per cell, so
quality is not measured. Alias:
`Qwen3.8-Flash-Next-UD-IQ3_XXS-abliterated-MTP`.

Fetch the LoRA once (`llmsrv.sh` prints this command when it is missing):

```sh
d=~/.cache/huggingface/hub/models--mrfakename--Qwen3.8-Flash-Next-abliterated-GGUF/snapshots/main
mkdir -p $d && curl -fL -o $d/abliteration-lora.gguf \
  https://huggingface.co/mrfakename/Qwen3.8-Flash-Next-abliterated-GGUF/resolve/main/abliteration-lora.gguf
```

For an A/B on one server, send `"lora":[{"id":0,"scale":0}]` in a request to
turn the LoRA off for that request.

### Parameters

| Option | What it does |
| --- | --- |
| `--model <shard 00001>` | Sharded GGUF: pass shard 00001 (tensor-free header); llama.cpp opens 2/3. |
| `--model-draft` / `--spec-type draft-mtp` | MTP speculative decoding with the sidecar head. |
| `--spec-draft-n-max 2` | Tokens drafted per verify step. N=2 was the measured peak (not re-swept on v1.0.0). |
| `--no-mmproj` | Skip the vision projector shipped in the repo (text-only coding). |
| `--alias <name>` | Name advertised in the OpenAI-compatible API. |
| `--device Vulkan0` | Restrict offload to the named ggml device (the iGPU). |
| `--temperature / --top-p / --top-k / --min-p` | Sampling. Qwen3 thinking-coder preset. |
| `--jinja` | Use the GGUF's embedded chat template: `<think>` goes to `reasoning_content`, correct tool-call boundaries for agents. |
| `--flash-attn on` | Force fused Flash-Attention kernel. +2.8% PP, free. |
| `--batch-size 2048` | Logical batch (`n_batch`): max prompt tokens grouped per decode call. |
| `--ubatch-size 512` | Physical microbatch (`n_ubatch`): tokens per kernel launch. Must divide `--batch-size`. |
| `--ctx-size 131072` | Practical sweet spot, not a ceiling. Cost is cold prefill: ~40 s at 32k, ~5 min at 128k. |
| `--parallel 1` | Single decoding slot (interactive single-client use). |

`RADV_DEBUG=zerovram` is only for Mesa 24 (required there); on Mesa 25+ it
crashes runs. `llmsrv.sh` picks it from the installed `mesa-libs` version.

### Flags deliberately omitted

| Option | Why it's off |
| --- | --- |
| `--no-host` | Not A/B'd for flashnext on FreeBSD; crashes the dense 27B on FreeBSD. `llmsrv.sh` sets it only on Linux. |
| `--no-mmap` / `-mmp 0` | Wedges the GPU on this stack; needs a reboot. |
| `--direct-io` | Same GPU wedge as `--no-mmap`. |
| `--kv-unified` | No effect for single-client coding (only relevant with `--parallel N>1`). |
| `--cache-reuse N` | Qwen3 uses M-RoPE; unsupported (`llama_memory_can_shift()` returns false). |
| `--ctk q8_0` / `--ctv q8_0` | Quantized KV cache crashes Vulkan on this driver/build. |
| `--batch-size 4096 --ubatch-size 1024` | ~3% slower than 2048/512 on this build. |
| `--ctx-size > 262144` | Beyond the model's native context; needs RoPE scaling, untested. |

## Benchmark commands

```sh
# llama-bench has no MTP: this measures the spec-off target only.
build/bin/llama-bench \
  -m ~/.cache/huggingface/hub/models--unsloth--Qwen3.8-Flash-Next-GGUF/snapshots/*/UD-IQ3_XXS/Qwen3.8-Flash-Next-UD-IQ3_XXS-00001-of-00003.gguf \
  --device Vulkan0 \
  -p 4096 -n 128 -d 0 -fa 1 -r 2

# All llmsrv.sh slots, end to end with MTP:
./LLM/bench-all.sh

# End-to-end OpenAI-style streaming bench (requires running llama-server):
python3 LLM/bench_model.py -u http://127.0.0.1:8080 \
  --prompt-file /tmp/coding_prompt.txt -t 256 -r 3
```

Full sweep, per-flag rationale, crash signatures, and FreeBSD-vs-Ubuntu
cross-OS comparison are in
[../LLM/benches.FrameWork-Desktop.md](../LLM/benches.FrameWork-Desktop.md).

## qwen-code (CLI agent)

```sh
sudo pkg install qwen-code
```

Point it at local `llama-server` via the standard `OPENAI_*` env vars
(add to `~/.profile`):

```sh
OPENAI_BASE_URL="http://127.0.0.1:8080/v1"; export OPENAI_BASE_URL
OPENAI_API_KEY="not-needed";                export OPENAI_API_KEY
OPENAI_MODEL="Qwen3.8-Flash-Next-UD-IQ3_XXS-MTP"; export OPENAI_MODEL
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

## TPM

The Pluton TPM (`tpmcrb0`, `StartMethod=7`, firmware 10.6.0.4) works, but commands
sent back to back can fail with `EIO`. Patch and write-up are in `FreeBSD/docs/`:

| # | patch | component | defect | symptom without it | write-up | upstream |
|---|---|---|---|---|---|---|
| 1 | [`tpm_crb_settle_before_next_command.patch`](docs/tpm_crb_settle_before_next_command.patch) | kernel (`tpm_crb`) | `tpmcrb_transmit()` requests idle and releases the locality without waiting for either | 0.6% to 17.6% of no-gap commands per run fail with `EIO`, usually after 200 ms | [`bugreport_tpm_crb_back_to_back_eio.md`](docs/bugreport_tpm_crb_back_to_back_eio.md) | no |

With the patch: 0 failures in 71000 test commands, about 2 ms slower per command.
Reproducer: [`tpm_crb_sweep.py`](docs/tpm_crb_sweep.py). Tested on this machine
only, against `584f44221f45`.
