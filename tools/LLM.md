# llama.cpp

## Generic build instructions (CPU only: no backend)

[Official doc is very good for that](https://github.com/ggerganov/llama.cpp/blob/master/docs/build.md).
```
git clone https://github.com/ggerganov/llama.cpp.git
cd llama.cpp
```

Then build it using cmake:
```
which -s apt && sudo apt install -y build-essential cmake libcurl4-openssl-dev
test $(uname)=FreeBSD && sudo pkg install -y cmake
test $(uname)=Darwin && alias nproc="sysctl -n hw.physicalcpu"
cmake --fresh -B build
cmake --build build --config Release -- -j $(nproc)
```

## Usage

### Start Web UI with specific model

Download a model then instruct llama to start using that model.
To find what is the up-to-date efficient model, check the latest [Open LLM Leaderboard](https://huggingface.co/spaces/open-llm-leaderboard/open_llm_leaderboard) benchmarks.

And choose weighted/imatrix quants (should have `-i1` in filename) over [static quants files](https://newsletter.maartengrootendorst.com/p/a-visual-guide-to-quantization).

```
curl --output-dir models -LO -C - https://huggingface.co/TheBloke/Starling-LM-7B-alpha-GGUF/resolve/main/starling-lm-7b-alpha.Q4_K_M.gguf
./llama-server --host 0.0.0.0 --model models/starling-lm-7b-alpha.Q4_K_M.gguf
```

For big (32G) model (large context size):
```
curl --output-dir models -LO -C - https://huggingface.co/MaziyarPanahi/Mixtral-8x22B-v0.1-GGUF/resolve/main/Mixtral-8x22B-v0.1.IQ1_S.gguf
```

If builded with curl support, simply instruct it to download model, example with gpt-oss-20b:
```
lama-server --host 0.0.0.0 -hf ggml-org/gpt-oss-20b-GGUF --ctx-size 0 --jinja -ub 2048 -b 2048 -ngl 99 --flash-attn on
```

[Offical tips to run gpt-oss](https://github.com/ggml-org/llama.cpp/discussions/15396)

### Using prompt for text summarization

Text summarization, by using long text input like 1 hour conference transcription as example, need a model supporting large (16K or 32k context size).
Here I’m using a Mixtral-8x22B model (up to 64K context for this one).
```
cat <<'EOF' >prompt.txt
### Instruction:

Below is an instruction that describes a task. Write a response that appropriately completes the request.

Write a detailed summary of the presentation in the input.

### Input:
EOF

cat ../Foundation.Update.May.2024.FreeBSD.Developer.Summit.wav.txt  >> prompt.txt
cat <<EOF >>prompt.txt

### Response:
EOF
build/bin/llama-cli --temp 0.0 --top_p 0.0 --top_k 1.0 -n -1 -f prompt.txt -m models/Mixtral-8x22B-v0.1.IQ1_S.gguf

```

### Coding with vim, vs-code, etc.

Example using a [llama.vim](https://github.com/ggml-org/llama.vim/tree/master) or a [vs-code](https://marketplace.visualstudio.com/items?itemName=ggml-org.llama-vscode):
First download the model and start the llama server using the [model’s instruction](https://unsloth.ai/docs/models/qwen3.6)
```
build/bin/llama-server \
  -hf unsloth/Qwen3.6-27B-GGUF:UD-Q4_K_XL
  --alias qwen36-coder \
  --device Vulkan0 \
  --temp 0.6 \
  --top-p 0.95 \
  --top-k 20 \
  --min-p 0.00 \
  --flash-attn on \
  --no-host \
  --kv-unified \
  --batch-size 4096 \
  --ubatch-size 1024 \
  --ctx-size 131072
```

Then run a [qwen-code](https://qwen.ai/qwencode) as example:

```
cat <<EOF > .env
export OPENAI_BASE_URL=http://127.0.0.1:8080/v1
export OPENAI_API_KEY=not-needed
export OPENAI_MODEL=qwen36-coder
EOF
qwen
```

## Unified Memory Architecture with AMD iGPU

Laptops and miniPC are using APU (SoC that include CPU and iGPU with RAM shared between both).
This feature is called Unified Memory Architecture (UMA).

Example on an APU (AMD Ryzen AI MAX+ Pro 395 with Radeon 8060S) with 128GB RAM and Ubuntu 24.04.3 LTS:
```
$ grep MemTotal /proc/meminfo
MemTotal:       98634464 kB
$ echo VRAM total in MB: $(( $(cat /sys/class/drm/card*/device/mem_info_vram_total) / 1024 / 1024 ))
VRAM total in MB: 32768
$ echo GTT total in MB:  $(( $(cat /sys/class/drm/card*/device/mem_info_gtt_total) / 1024 / 1024 ))
GTT total in MB: 48161
```
Here, the system reserved 32GB for GPU usage (default value allowed in the EFI settings of this computer)
but it allows to use about 48GB of RAM for GPU usage in case of need by the system.

To compile llama.cpp to support this feature, you need:
- [Official AMD ROCm drivers and libraries](https://rocm.docs.amd.com/projects/install-on-linux/en/latest/install/quick-start.html) (version 7.2 used here that fix AMD Strix Halo stability);
- [Configure GPU access for your user](https://rocm.docs.amd.com/projects/install-on-linux/en/latest/install/prerequisites.html#group-permissions)
- Instruct llama.cpp to use the BLAS acceleration on HIP-supported AMD GPUs;
- Enable HIP UMA (LLAMA_HIP_UMA).

Once rocm installed, check if correcly install by displaying your GPU detected:
```
$ rocminfo | grep '^  Name:'
  Name:                    AMD RYZEN AI MAX+ PRO 395 w/ Radeon 8060S
  Name:                    gfx1151
```

If using older GPU, like an iGPU (gfx1035) is not officialy supported by the ROCm libraries:
There is no file /opt/rocm/lib/rocblas/library/ for gfx1035 as example.
So we need to trick it to use same library as the closest GPU which is the gfx1030.
And the gfx1030 is from Navi 21 family, which belongs to RNDA 2.0 architecture.

So in this special case you will have to:
1. During compilation time, force GPU target to gfx1030 (AMDGPU_TARGETS=gfx1030)
1. During compilation AND run time force ROCm to use Navi21 binary (HSA_OVERRIDE_GFX_VERSION=10.3.0)

But this isn’t the case here here with the gfx1151,
So to compile llama.cpp with:
- HIP support (AMD ROCM)
- Enhance flash attention performance on RDNA3+ (Strix Halo)
- Unified memory (Strix Halo)
- CPU support (DGGML_USE_CPU for bench comparison later using the CPU only)
- SSL support (mandatory to download model from hg as example)

If you’ve installed the Vulcan SDK, you can add "-DGGML_VULKAN=ON"
```
sudo apt install -y libcurl4-gnutls-dev libssl-dev
HIPCXX="$(hipconfig -l)/clang" HIP_PATH="$(hipconfig -R)" \
    GGML_CUDA_ENABLE_UNIFIED_MEMORY=1 \
    cmake -S . --fresh -B build -DGGML_HIP=ON -DGPU_TARGETS=gfx1151 \
    -DGGML_HIP_ROCWMMA_FATTN=ON -DGGML_USE_CPU=ON -DCMAKE_BUILD_TYPE=Release \
    && cmake --build build --config Release -- -j $(nproc)
```

Once builded you can instruct it to display all detected devices (here it correctly shows the ROCm and Vulkan):
```
$ build/bin/llama-cli --list-devices
ggml_cuda_init: found 1 ROCm devices:
  Device 0: AMD Radeon Graphics, gfx1151 (0x1151), VMM: no, Wave Size: 32
ggml_vulkan: Found 1 Vulkan devices:
ggml_vulkan: 0 = AMD Radeon Graphics (RADV GFX1151) (radv) | uma: 1 | fp16: 1 | bf16: 0 | warp size: 64 | shared memory: 65536 | int dot: 1 | matrix cores: KHR_coopmat
Available devices:
ggml_backend_cuda_get_available_uma_memory: final available_memory_kb: 61262128
  ROCm0: AMD Radeon Graphics (65536 MiB, 59826 MiB free)
  Vulkan0: AMD Radeon Graphics (RADV GFX1151) (97568 MiB, 97227 MiB free)
```

Then force usage of UMA with the env var `GGML_CUDA_ENABLE_UNIFIED_MEMORY=1` when starting llama.
And run a quick test using the big Qwen3.5-397B-A17B:UD-IQ2_XXS model:

-hf unsloth/Qwen3.5-397B-A17B:UD-IQ2_XXS

```
GGML_CUDA_ENABLE_UNIFIED_MEMORY=1 build/bin/llama-cli -hf Qwen3.5-397B-A17B-GGUF:UD-IQ2_XXS --flash-attn on --ctx-size 0 --jinja -ub 2048 -b 2048 -p "I believe the meaning of life is" -n 128 -ngl 99 -no-cnv
```

Log should have this output:
```
ggml_cuda_init: found 1 ROCm devices:
  Device 0: AMD Radeon Graphics, gfx1151 (0x1151), VMM: no, Wave Size: 32
(...)
llama_model_load_from_file_impl: using device ROCm0 (AMD Radeon Graphics) (0000:c3:00.0) - 47985 MiB free
llama_model_loader: loaded meta data with 35 key-value pairs and 459 tensors from /home/olivier/.cache/llama.cpp/
ggml-org_gpt-oss-20b-GGUF_gpt-oss-20b-mxfp4.gguf (version GGUF V3 (latest))
(...)
load_tensors: offloading 24 repeating layers to GPU
load_tensors: offloading output layer to GPU
load_tensors: offloaded 25/25 layers to GPU
load_tensors:        ROCm0 model buffer size = 10949.38 MiB
load_tensors:   CPU_Mapped model buffer size =   586.82 MiB
(...)
system_info: n_threads = 16 (n_threads_batch = 16) / 32 | ROCm : NO_VMM = 1 | PEER_MAX_BATCH_SIZE = 128 | CPU : SSE3 = 1 | SSSE3 = 1 | AVX = 1 | AVX_VNNI = 1 | AVX2 = 1 | F16C = 1 | FMA = 1 | BMI2 = 1 | AVX512 = 1 | AVX512_VBMI = 1 | AVX512_VNNI = 1 | AVX512_BF16 = 1 | LLAMAFILE = 1 | OPENMP = 1 | REPACK = 1 |
(...)
```

Some benches (notice the llama-bench is using -ngl 99 by default) with 2 models and with different backend (ROCM, Vulkan, CPU):
  - enables Flash Attention, an optimized algorithm designed to speed up the "Attention" mechanism—the most computationally expensive part of a Transformer model.
  - enables memory mapping, to tells the OS to map the model file directly into the process's virtual address space
  - Use 16 threads (=number of physical cores)
  - Display Token Generation (decoding) speeds (n-gen 128), line tg128 in the result
  - enables Unified Memory Management (no-host), on APU the GPU can access the model data directly without needing a redundant copy in host-managed memory
  - Enable performance mode with the Linux governor
```
echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
build/bin/llama-bench \
  -m ~/.cache/llama.cpp/ggml-org_gpt-oss-20b-GGUF_gpt-oss-20b-mxfp4.gguf,\
~/.cache/llama.cpp/unsloth_Qwen3.5-27B-GGUF_Qwen3.5-27B-UD-Q4_K_XL.gguf,\
~/.cache/llama.cpp/unsloth_Qwen3-Next-80B-A3B-Instruct-GGUF_Qwen3-Next-80B-A3B-Instruct-Q4_K_M.gguf \
  --device none,ROCm0,Vulkan0 \
  --flash-attn 0,1 \
  --batch-size 2048 \
  --ubatch-size 512 \
  --n-prompt 2048,8192,16384 \
  --n-gen 128 \
  --mmap 1 \
  --threads 16 \
  --no-host 1 \
  --n-gen 128 \
  --repetitions 5

ggml_cuda_init: found 1 ROCm devices:
  Device 0: AMD Radeon Graphics, gfx1151 (0x1151), VMM: no, Wave Size: 32
ggml_vulkan: Found 1 Vulkan devices:
ggml_vulkan: 0 = AMD Radeon Graphics (RADV GFX1151) (radv) | uma: 1 | fp16: 1 | bf16: 0 | warp size: 64 |
shared memory: 65536 | int dot: 1 | matrix cores: KHR_coopmat | ngl: 99 | mmap: 1 | noh: 1
| model                    |      size |  params | backend     | dev     | fa |    test |             t/s |
| ------------------------ | --------: | ------: | ----------- | ------- | -: | ------: | --------------: |
| gpt-oss 20B MXFP4 MoE    | 11.27 GiB | 20.91 B | ROCm,Vulkan | none    |  1 |  pp2048 |  168.64 ± 3.37  |
| gpt-oss 20B MXFP4 MoE    | 11.27 GiB | 20.91 B | ROCm,Vulkan | none    |  1 |  pp8192 |  146.99 ± 0.28  |
| gpt-oss 20B MXFP4 MoE    | 11.27 GiB | 20.91 B | ROCm,Vulkan | none    |  1 | pp16384 |  121.09 ± 0.24  |
| gpt-oss 20B MXFP4 MoE    | 11.27 GiB | 20.91 B | ROCm,Vulkan | none    |  1 |   tg128 |   34.03 ± 0.06  |
| gpt-oss 20B MXFP4 MoE    | 11.27 GiB | 20.91 B | ROCm,Vulkan | ROCm0   |  1 |  pp2048 |  507.51 ± 4.11  |
| gpt-oss 20B MXFP4 MoE    | 11.27 GiB | 20.91 B | ROCm,Vulkan | ROCm0   |  1 |  pp8192 |  476.48 ± 1.95  |
| gpt-oss 20B MXFP4 MoE    | 11.27 GiB | 20.91 B | ROCm,Vulkan | ROCm0   |  1 | pp16384 |  430.54 ± 1.00  |
| gpt-oss 20B MXFP4 MoE    | 11.27 GiB | 20.91 B | ROCm,Vulkan | ROCm0   |  1 |   tg128 |   68.27 ± 0.25  |
| gpt-oss 20B MXFP4 MoE    | 11.27 GiB | 20.91 B | ROCm,Vulkan | ROCm0   |  0 |  pp2048 |  470.19 ± 1.02  |
| gpt-oss 20B MXFP4 MoE    | 11.27 GiB | 20.91 B | ROCm,Vulkan | ROCm0   |  0 |  pp8192 |  405.49 ± 0.90  |
| gpt-oss 20B MXFP4 MoE    | 11.27 GiB | 20.91 B | ROCm,Vulkan | ROCm0   |  0 | pp16384 |  339.08 ± 1.39  |
| gpt-oss 20B MXFP4 MoE    | 11.27 GiB | 20.91 B | ROCm,Vulkan | ROCm0   |  0 |   tg128 |   64.50 ± 1.48  |
| gpt-oss 20B MXFP4 MoE    | 11.27 GiB | 20.91 B | ROCm,Vulkan | Vulkan0 |  1 |  pp2048 | 1057.21 ± 3.79  |
| gpt-oss 20B MXFP4 MoE    | 11.27 GiB | 20.91 B | ROCm,Vulkan | Vulkan0 |  1 |  pp8192 |  958.72 ± 1.26  |
| gpt-oss 20B MXFP4 MoE    | 11.27 GiB | 20.91 B | ROCm,Vulkan | Vulkan0 |  1 | pp16384 |  823.88 ± 0.89  |
| gpt-oss 20B MXFP4 MoE    | 11.27 GiB | 20.91 B | ROCm,Vulkan | Vulkan0 |  1 |   tg128 |   74.15 ± 0.03  |
| gpt-oss 20B MXFP4 MoE    | 11.27 GiB | 20.91 B | ROCm,Vulkan | Vulkan0 |  0 |  pp2048 |  932.91 ± 4.12  |
| gpt-oss 20B MXFP4 MoE    | 11.27 GiB | 20.91 B | ROCm,Vulkan | Vulkan0 |  0 |  pp8192 |  779.61 ± 1.01  |
| gpt-oss 20B MXFP4 MoE    | 11.27 GiB | 20.91 B | ROCm,Vulkan | Vulkan0 |  0 | pp16384 |  608.28 ± 0.55  |
| gpt-oss 20B MXFP4 MoE    | 11.27 GiB | 20.91 B | ROCm,Vulkan | Vulkan0 |  0 |   tg128 |   72.79 ± 0.02  |
| qwen35 27B Q4_K - Medium | 16.40 GiB | 26.90 B | ROCm,Vulkan | none    |  1 |  pp2048 |   24.88 ± 0.03  |
| qwen35 27B Q4_K - Medium | 16.40 GiB | 26.90 B | ROCm,Vulkan | none    |  1 |  pp8192 |   23.78 ± 0.02  |
| qwen35 27B Q4_K - Medium | 16.40 GiB | 26.90 B | ROCm,Vulkan | none    |  1 | pp16384 |   22.30 ± 0.02  |
| qwen35 27B Q4_K - Medium | 16.40 GiB | 26.90 B | ROCm,Vulkan | none    |  1 |   tg128 |    4.94 ± 0.00  |
| qwen35 27B Q4_K - Medium | 16.40 GiB | 26.90 B | ROCm,Vulkan | ROCm0   |  1 |  pp2048 |  209.71 ± 0.07  |
| qwen35 27B Q4_K - Medium | 16.40 GiB | 26.90 B | ROCm,Vulkan | ROCm0   |  1 |  pp8192 |  160.12 ± 0.52  |
| qwen35 27B Q4_K - Medium | 16.40 GiB | 26.90 B | ROCm,Vulkan | ROCm0   |  1 | pp16384 |  120.56 ± 0.82  |
| qwen35 27B Q4_K - Medium | 16.40 GiB | 26.90 B | ROCm,Vulkan | ROCm0   |  1 |   tg128 |   10.56 ± 0.00  |
| qwen35 27B Q4_K - Medium | 16.40 GiB | 26.90 B | ROCm,Vulkan | ROCm0   |  0 |  pp2048 |  236.14 ± 1.41  |
| qwen35 27B Q4_K - Medium | 16.40 GiB | 26.90 B | ROCm,Vulkan | ROCm0   |  0 |  pp8192 |  220.67 ± 0.19  |
| qwen35 27B Q4_K - Medium | 16.40 GiB | 26.90 B | ROCm,Vulkan | ROCm0   |  0 | pp16384 |  202.07 ± 0.51  |
| qwen35 27B Q4_K - Medium | 16.40 GiB | 26.90 B | ROCm,Vulkan | ROCm0   |  0 |   tg128 |   10.51 ± 0.00  |
| qwen35 27B Q4_K - Medium | 16.40 GiB | 26.90 B | ROCm,Vulkan | Vulkan0 |  1 |  pp2048 |  201.06 ± 0.06  |
| qwen35 27B Q4_K - Medium | 16.40 GiB | 26.90 B | ROCm,Vulkan | Vulkan0 |  1 |  pp8192 |  193.04 ± 0.10  |
| qwen35 27B Q4_K - Medium | 16.40 GiB | 26.90 B | ROCm,Vulkan | Vulkan0 |  1 | pp16384 |  181.31 ± 1.34  |
| qwen35 27B Q4_K - Medium | 16.40 GiB | 26.90 B | ROCm,Vulkan | Vulkan0 |  1 |   tg128 |   10.48 ± 0.01  |
| qwen35 27B Q4_K - Medium | 16.40 GiB | 26.90 B | ROCm,Vulkan | Vulkan0 |  0 |  pp2048 |  198.40 ± 0.10  |
| qwen35 27B Q4_K - Medium | 16.40 GiB | 26.90 B | ROCm,Vulkan | Vulkan0 |  0 |  pp8192 |  192.44 ± 0.13  |
| qwen35 27B Q4_K - Medium | 16.40 GiB | 26.90 B | ROCm,Vulkan | Vulkan0 |  0 | pp16384 |  182.08 ± 1.50  |
| qwen35 27B Q4_K - Medium | 16.40 GiB | 26.90 B | ROCm,Vulkan | Vulkan0 |  0 |   tg128 |   10.48 ± 0.00  |
| qwen3next 80B.A3B Q4_K   | 45.17 GiB | 79.67 B | ROCm,Vulkan | none    |  0 |  pp2048 |   96.59 ± 1.30  |
| qwen3next 80B.A3B Q4_K   | 45.17 GiB | 79.67 B | ROCm,Vulkan | none    |  0 |  pp8192 |   94.81 ± 0.39  |
| qwen3next 80B.A3B Q4_K   | 45.17 GiB | 79.67 B | ROCm,Vulkan | none    |  0 | pp16384 |   90.03 ± 0.19  |
| qwen3next 80B.A3B Q4_K   | 45.17 GiB | 79.67 B | ROCm,Vulkan | none    |  0 |   tg128 |   23.48 ± 0.15  |
| qwen3next 80B.A3B Q4_K   | 45.17 GiB | 79.67 B | ROCm,Vulkan | ROCm0   |  0 |  pp2048 |  517.19 ± 3.27  |
| qwen3next 80B.A3B Q4_K   | 45.17 GiB | 79.67 B | ROCm,Vulkan | ROCm0   |  0 |  pp8192 |  481.88 ± 0.97  |
| qwen3next 80B.A3B Q4_K   | 45.17 GiB | 79.67 B | ROCm,Vulkan | ROCm0   |  0 | pp16384 |  436.78 ± 6.83  |
| qwen3next 80B.A3B Q4_K   | 45.17 GiB | 79.67 B | ROCm,Vulkan | ROCm0   |  0 |   tg128 |   38.66 ± 0.22  |
| qwen3next 80B.A3B Q4_K   | 45.17 GiB | 79.67 B | ROCm,Vulkan | ROCm0   |  1 |  pp2048 |  455.70 ± 2.26  |
| qwen3next 80B.A3B Q4_K   | 45.17 GiB | 79.67 B | ROCm,Vulkan | ROCm0   |  1 |  pp8192 |  341.23 ± 1.65  |
| qwen3next 80B.A3B Q4_K   | 45.17 GiB | 79.67 B | ROCm,Vulkan | ROCm0   |  1 | pp16384 |  254.38 ± 1.02  |
| qwen3next 80B.A3B Q4_K   | 45.17 GiB | 79.67 B | ROCm,Vulkan | ROCm0   |  1 |   tg128 |   38.58 ± 0.14  |
| qwen3next 80B.A3B Q4_K   | 45.17 GiB | 79.67 B | ROCm,Vulkan | Vulkan0 |  0 |  pp2048 |  450.33 ± 8.52  |
| qwen3next 80B.A3B Q4_K   | 45.17 GiB | 79.67 B | ROCm,Vulkan | Vulkan0 |  0 |  pp8192 |  430.85 ± 1.63  |
| qwen3next 80B.A3B Q4_K   | 45.17 GiB | 79.67 B | ROCm,Vulkan | Vulkan0 |  0 | pp16384 |  404.22 ± 5.23  |
| qwen3next 80B.A3B Q4_K   | 45.17 GiB | 79.67 B | ROCm,Vulkan | Vulkan0 |  0 |   tg128 |   38.77 ± 0.02  |
| qwen3next 80B.A3B Q4_K   | 45.17 GiB | 79.67 B | ROCm,Vulkan | Vulkan0 |  1 |  pp2048 |  427.86 ± 33.08 |
| qwen3next 80B.A3B Q4_K   | 45.17 GiB | 79.67 B | ROCm,Vulkan | Vulkan0 |  1 |  pp8192 |  429.70 ± 20.43 |
| qwen3next 80B.A3B Q4_K   | 45.17 GiB | 79.67 B | ROCm,Vulkan | Vulkan0 |  1 | pp16384 |  422.36 ± 7.85  |
| qwen3next 80B.A3B Q4_K   | 45.17 GiB | 79.67 B | ROCm,Vulkan | Vulkan0 |  1 |   tg128 |   38.92 ± 0.08  |


build: 451ef0843 (8243)
```

While running, system usage:
```
$ rocm-smi

WARNING: AMD GPU device(s) is/are in a low-power state. Check power control/runtime_status

======================================= ROCm System Management Interface =======================================
================================================= Concise Info =================================================
Device  Node  IDs              Temp    Power     Partitions          SCLK  MCLK     Fan  Perf  PwrCap  VRAM%  GPU%
              (DID,     GUID)  (Edge)  (Socket)  (Mem, Compute, ID)
================================================================================================================
0       1     0x1586,   42721  68.0°C  59.098W   N/A, N/A, 0         N/A   1000Mhz  0%   auto  N/A     33%    100%
================================================================================================================
============================================= End of ROCm SMI Log ==============================================
```

Conclusion: It is indeed able to load big model and using the iGPU, but more important, Vulkan
is twice faster than ROCm 7.2.

## Intel iGPU (Arc graphics)

Doing the same as with AMD iGPU is doable on on Intel iGPU.

Testing on Intel NUC 165H with this SOC:
- Intel Core Ultra 7 165H (6 Pcores, 8 Ecores, 22 threads)
- Intel Arc graphics
- Intel AI Boost NPU (didn’t use need)

Backend supported for Intel GPU support are:
- BLAS
- BLIS
- SYSCL
- Vulkan

[Some benches seems to show that SYSCL performs better than Vulkan](https://www.reddit.com/r/IntelArc/comments/1enunga/llamacpp_benchmarks_of_llama318b_on_arc_a770/) so let’t try the [SYSCL backend](https://github.com/ggerganov/llama.cpp/blob/master/docs/backend/SYCL.md).

First step is to [install OneAPI on Ubntu](https://www.intel.com/content/www/us/en/developer/tools/oneapi/base-toolkit-download.html?operatingsystem=linux&linux-install-type=apt).
Follows instructions and check it works, sycl-ls need to report one "level_zero:gpu":
```
$ sycl-ls
[opencl:cpu][opencl:0] Intel(R) OpenCL, Intel(R) Core(TM) Ultra 7 165H OpenCL 3.0 (Build 0) [2024.18.7.0.11_160000]
[opencl:gpu][opencl:1] Intel(R) OpenCL Graphics, Intel(R) Graphics [0x7d55] OpenCL 3.0 NEO  [23.43.027642]
[level_zero:gpu][level_zero:0] Intel(R) Level-Zero, Intel(R) Graphics [0x7d55] 1.3 [1.3.27642]
```

Then build llamacpp using SYSCL and check it detects your GPU:
```
~/llama.cpp$ ./examples/sycl/build.sh
```

And start a bench (remember to load OneAPI vars for each new session), and with 96MB of RAM, we could try big models:
```
~/llama.cpp$ source /opt/intel/oneapi/setvars.sh
~/llama.cpp$ build/bin/llama-bench -m models/starling-lm-7b-alpha.Q4_K_M.gguf \
-m models/mixtral-8x7b-v0.1.Q5_K_M.gguf \
-m models/calme-2.4-rys-78b.i1-Q4_K_S.gguf
ggml_sycl_init: GGML_SYCL_FORCE_MMQ:   no
ggml_sycl_init: SYCL_USE_XMX: yes
found 1 SYCL devices:
|  |                   |                        |       |Max    |        |Max  |Global |               |
|  |                   |                        |       |compute|Max work|sub  |mem    |               |
|ID|        Device Type|                    Name|Version|units  |group   |group|size   | Driver version|
|--|-------------------|------------------------|-------|-------|--------|-----|-------|---------------|
| 0| [level_zero:gpu:0]| Intel Graphics [0x7d55]|    1.3|    128|    1024|   32| 94336M|      1.3.27642|
[SYCL] call ggml_check_sycl
get_memory_info: [warning] ext_intel_free_memory is not supported (export/set ZES_ENABLE_SYSMAN=1 to support), use total memory as free memory
ggml_check_sycl: GGML_SYCL_DEBUG: 0
ggml_check_sycl: GGML_SYCL_F16: yes
| model                    |      size |  params | backend | ngl |  test |           t/s |
| ------------------------ | --------: | ------: | ------- | --: | ----: |-------------: |
| llama 7B Q4_K - Medium   |  4.07 GiB |  7.24 B | SYCL    |  99 | pp512 | 204.51 ± 5.79 |
| llama 7B Q4_K - Medium   |  4.07 GiB |  7.24 B | SYCL    |  99 | tg128 |   6.13 ± 0.02 |
| llama 8x7B Q5_K - Medium | 58.89 GiB | 91.80 B | SYCL    |  99 | pp512 |  59.67 ± 0.19 |
| llama 8x7B Q5_K - Medium | 58.89 GiB | 91.80 B | SYCL    |  99 | tg128 |   2.42 ± 0.01 |
| qwen2 ?B Q4_K - Small    | 43.72 GiB | 77.97 B | SYCL    |  99 | pp512 |  15.47 ± 0.15 |
| qwen2 ?B Q4_K - Small    | 43.72 GiB | 77.97 B | SYCL    |  99 | tg128 |   0.60 ± 0.01 |

build: d5cb8684 (3891)
```

To be compared with CPU only usage:
```
~/llama.cpp$ build/bin/llama-bench -t $(nproc) -m models/starling-lm-7b-alpha.Q4_K_M.gguf \
 -m models/mixtral-8x7b-v0.1.Q5_K_M.gguf
| model                    |      size |  params | backend | threads |  test |          t/s |
| ------------------------ | --------: | ------: | --------| ------: | ----: | -----------: |
| llama 7B Q4_K - Medium   |  4.07 GiB |  7.24 B | CPU     |      22 | pp512 | 24.47 ± 0.49 |
| llama 7B Q4_K - Medium   |  4.07 GiB |  7.24 B | CPU     |      22 | tg128 |  9.22 ± 0.07 |
| llama 8x7B Q5_K - Medium | 58.89 GiB | 91.80 B | CPU     |      22 | pp512 | 10.11 ± 0.02 |
| llama 8x7B Q5_K - Medium | 58.89 GiB | 91.80 B | CPU     |      22 | tg128 |  4.51 ± 0.01 |
| qwen2 ?B Q4_K - Small    | 43.72 GiB | 77.97 B | CPU     |      22 | pp512 |  1.97 ± 0.02 |
| qwen2 ?B Q4_K - Small    | 43.72 GiB | 77.97 B | CPU     |      22 | tg128 |  1.19 ± 0.00 |

build: d5cb8684 (3891)
```
### Vulkan

[Getting started to Vulkan](https://vulkan.lunarg.com/doc/sdk/1.4.341.1/windows/getting_started.html)

```
sudo apt install xz-utils libxcb-xinput0 libxcb-xinerama0 libxcb-cursor-dev
mkdir ~/vulkan
cd ~/vulkan
wget https://sdk.lunarg.com/sdk/download/1.4.341.1/linux/vulkansdk-linux-x86_64-1.4.341.1.tar.xz
tar xf vulkansdk-linux-x86_64-1.*.tar.xz
rm vulkansdk-linux-x86_64-1.4.341.1.tar.xz
source ~/vulkan/1.*/setup-env.sh
```

To install Vulkan headers and compilers on FreeBSD:
```
sudo pkg install -y vulkan-headers vulkan-loader glslang shaderc
```

Then compile llama.cpp with `-DGGML_VULKAN=ON`.

llama.cpp starting with vulkan backend should display something like:
```
ggml_vulkan: Found 1 Vulkan devices:
ggml_vulkan: 0 = AMD Radeon Graphics (RADV GFX1151) (radv) | uma: 1 | fp16: 1 | bf16: 0 | warp size: 64 | shared
memory: 65536 | int dot: 1 | matrix cores: KHR_coopmat
```

## Vision

Reading picture:
```
$ curl --output /tmp/fbsd.png  https://www.freebsd.org/images/banner-red.png
$ build/bin/llama-mtmd-cli -hf ggml-org/gemma-3-4b-it-GGUF --image /tmp/fbsd.png -p "Describe this image"
(etc..)
$ build/bin/llama-mtmd-cli -hf ggml-org/gemma-3-4b-it-GGUF --image ~/Downloads/iKVM_capture_dump.jpg -p "you are an OCR machine, write text on the picture"
```

# whisper.cpp (Voice to text)

[More details in the official readme](https://github.com/ggml-org/whisper.cpp/blob/master/README.md)

## Generic install

A simple install on FreeBSD with no special backend, only CPU:
```
git clone https://github.com/ggerganov/whisper.cpp.git
cd whisper.cpp
cmake --fresh -B build
cmake --build build --config Release -j $(nproc)
```

## Advanced install

Here an exmple with:
- ffmpeg for embedded audio file conversion
- Using the Vulkan library as backend for AMD GPU acceleration (HIP seems not available)
- SDL2 for real-time (stream mode)

```
source ~/vulkan/*/setup-env.sh
sudo apt install -y libsdl2-dev libavcodec-dev libavformat-dev libavutil-dev
cmake --fresh -B build -DGGML_VULKAN=1 -DWHISPER_FFMPEG=yes
cmake --build build --config Release -j $(nproc)
```

## Usage

### One speaker only

Download a model:
```
sh ./models/download-ggml-model.sh base.en
```

Transcode your mp3 in wav with ffmpeg (if compiled without ffmpeg):
```
ffmpeg -i FreeBSD\ Foundation\ Update\ -\ May\ 2024\ FreeBSD\ Developer\ Summit.mp3  -ar 16000 -ac 1 -c:a pcm_s16le FreeBSD.Foundation.Update.May.2024.FreeBSD.Developer.Summit.wav
```

Generate a txt file (-otxt) or other like srt (-osrt):
```
build/bin/whisper-cli -t 16 -otxt ../FreeBSD.Foundation.Update.May.2024.FreeBSD.Developer.Summit.wav
  8
  9 [00:00:00.000 --> 00:00:10.000]   [BLANK_AUDIO]
 10 [00:00:10.000 --> 00:00:14.440]   Hi everyone, I'm Deb Goodkin, and I'm the Executive Director of
 11 [00:00:14.440 --> 00:00:16.520]   the Free BFC Foundation.
 12 [00:00:16.520 --> 00:00:22.960]   And welcome everyone, it's so nice to get out of my home office.
 13 [00:00:22.960 --> 00:00:26.360]   I mean, I love my home office, but it's great to get out and
 14 [00:00:26.360 --> 00:00:30.940]   be with our community and see people in person.
(etc.)
```

While using larger model, it could repeats same sentence multiple times: Increase entropy threshold ,`-et 2.8` to reduce this problem.

### Multi speakers (Speaker diarization)

There are 2 methods:
- Stereo diarization (-di), adding '(speaker ?)' in front of each sentence, need a stereo source (so use '-ac 2' with ffmpeg)
- And simple tinydiarization (-trdz), that adds [SPEAKER_TURN] after each speaker turn
Need a stereo source (so with ffmpeg use -ac 2) and a tdrz model:

Example with stereo mode:
```
ffmpeg -i BSDNow.558.Worlds.of.telnet.mp3 -ar 16000 -ac 2 -c:a pcm_s16le BSDNow.558.Worlds.of.telnet.wav
cd whisper
sh ./models/download-ggml-model.sh small.en-tdrz
build/bin/whisper-cli -t 16 -m models/ggml-small.en-tdrz.bin -otxt -np -di ../BSDNow.558.Worlds.of.telnet.wav
(etc.)
[00:00:00.640 --> 00:00:29.620]  (speaker ?) This week on the show we cover NetBSD 9.4 and what's exciting in that release. Then we have free B_S_D_'s S_S_T_F_ attestation to support the cyber security compliance. The lost worlds of Telnet are interesting for the nostalgics among us. How to alter file ownership and permissions with feedback Parallel. raw I_P_ input coming to Open B_S_D_. Open B_S_D_ routers on ALI express mini P_C_s and free B_S_D_ for devs in this week's episode of B_S_D_.
[00:00:30.020 --> 00:00:30.580]  (speaker ?) Now.
[00:00:47.280 --> 00:01:17.280]  (speaker ?) B_S_D_ now, episode five hundred fifty eight, Worlds of Telnet. Recorded on the first of May twenty twenty four. There was something on that special date, I don't know what. This episode of B_S_D_ now was made possible because of you. Thank you for supporting B_S_D_ now Um. hi, I'm your host Eric Greuschling. Hello, welcome to this week's episode. We hope you have a nice day so far and we hope that we can make it a bit interesting, a bit more interesting than it already
[00:01:17.280 --> 00:01:33.240]  (speaker ?) is with some news from the B_S_D_ space and uh starting off with headlines of course, like always like all the other five hundred fifty eight or fifty seven uh episodes started before, let B_S_D_ nine dot four is it this time.
(etc.)
```

### Stream mode

When compiled with SDL2, the whisper-stream is available, here is how to transcribe audio from your microphone:
```
build/bin/whisper-stream -m models/ggml-large-v3-turbo-q8_0.bin
```
