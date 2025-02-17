# llama.cpp

## Generic build instructions

[Official doc is very good for that](https://github.com/ggerganov/llama.cpp/blob/master/docs/build.md).
```
git clone https://github.com/ggerganov/llama.cpp.git
cd llama.cpp
```

Then build it using cmake:
```
which -s apt && sudo apt install -y build-essential cmake
test $(uname)=FreeBSD && sudo pkg install -y cmake
test $(uname)=Darwin && alias nproc="sysctl -n hw.physicalcpu"
cmake -B build
cmake --build build --config Release -- -j $(nproc)
```

## Usage

### Start Web UI with specific model

Download a model then instruct llama to start using that model.
To find what is the up-to-date efficient model, check the latest [Open LLM Leaderboard](https://huggingface.co/spaces/open-llm-leaderboard/open_llm_leaderboard) benchmarks.

And choose weighted/imatrix quants (should have `-i1` in filename) over [static quants files](https://newsletter.maartengrootendorst.com/p/a-visual-guide-to-quantization).

```
curl --output-dir models -LO -C - https://huggingface.co/TheBloke/Starling-LM-7B-alpha-GGUF/resolve/main/starling-lm-7b-alpha.Q4_K_M.gguf
./llama-server --model models/starling-lm-7b-alpha.Q4_K_M.gguf
```

For big (32G) model (large context size):
```
curl --output-dir models -LO -C - https://huggingface.co/MaziyarPanahi/Mixtral-8x22B-v0.1-GGUF/resolve/main/Mixtral-8x22B-v0.1.IQ1_S.gguf
```

### Using prompt for text summarization

Text summarization, by using long text input like 1 hour conference transcription as example, need a model supporting large (16K or 32k context size).
Here I’m using a Mixtral-8x22B model (up to 64K context for this one).
```
cat <<EOF >prompt.txt
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

Example using a [llama.vim](https://github.com/ggml-org/llama.vim/tree/master) or a [vs-code[(https://marketplace.visualstudio.com/items?itemName=ggml-org.llama-vscode):
First start the llama server
```
llama-server \
    -hf ggml-org/Qwen2.5-Coder-7B-Q8_0-GGUF \
    --port 8012 -ngl 99 -fa -ub 1024 -b 1024 \
    --ctx-size 0 --cache-reuse 256
```

Then install the plugin and start coding :-)

## Unified Memory Architecture with AMD iGPU

Laptops and miniPC are using APU (SoC that include CPU and iGPU with RAM shared between both).
This feature is called Unified Memory Architecture (UMA).
Does it mean we could load big models and using the iGPU ?

Example on an APU (AMD Ryzen 7 7735HS with Radeon Graphics) with 64GB RAM and Ubuntu 24.04.1 LTS:
```
$ grep MemTotal /proc/meminfo
MemTotal:       61439400 kB
$ echo VRAM total in MB: $(( $(cat /sys/class/drm/card0/device/mem_info_vram_total) / 1024 / 1024 ))
VRAM total in MB: 4096
$ echo GTT total in MB:  $(( $(cat /sys/class/drm/card0/device/mem_info_gtt_total) / 1024 / 1024 ))
GTT total in MB: 29999
```
Here, the system reserved 4GB for GPU usage (this is the maximum value allowed in the EFI settings of
this computer) but it allows to use about 30GB of RAM for GPU usage in case of need by the system.

To compile llama.cpp to support this feature, you need:
- [Official AMD ROCm drivers and libraries](https://rocm.docs.amd.com/projects/install-on-linux/en/latest/install/native-install/ubuntu.html) (version 6.2.2 used here);
- Instruct llama.cpp to use the BLAS acceleration on HIP-supported AMD GPUs;
- Enable HIP UMA (LLAMA_HIP_UMA).

This iGPU (gfx1035) is not officialy supported by the ROCm libraries:
There is no file /opt/rocm/lib/rocblas/library/ for gfx1035 as example.
So we need to trick it to use same library as the closest GPU which is the gfx1030.
And the gfx1030 is from Navi 21 family, which belongs to RNDA 2.0 architecture.

So wee need to:
1. During compilation time, force GPU target to gfx1030 (AMDGPU_TARGETS=gfx1030)
1. During compilation AND run time force ROCm to use Navi21 binary (HSA_OVERRIDE_GFX_VERSION=10.3.0)

Once rocm installed, check your GPU correctly detected:
```
$ rocminfo | grep '^  Name:'
  Name:                    AMD Ryzen 7 7735HS with Radeon Graphics
  Name:                    gfx1035
```

Then compile llama.cpp, example using make:
```
$ HSA_OVERRIDE_GFX_VERSION=10.3.0 make -j$(nproc) LLAMA_HIPBLAS=1 LLAMA_HIP_UMA=1 AMDGPU_TARGETS=gfx1030
```

or with cmake:
```
HIPCXX="$(hipconfig -l)/clang" HIP_PATH="$(hipconfig -R)" HSA_OVERRIDE_GFX_VERSION=10.3.0\
    cmake -S . -B build -DGGML_HIPBLAS=ON -DGGML_HIP_UMA=ON -DAMDGPU_TARGETS=gfx1030 -DCMAKE_BUILD_TYPE=Release \
    && cmake --build build --config Release -- -j $(nproc)

```
Then it should be able to detect the iGPU by this test:
```
~/llama.cpp$ HSA_OVERRIDE_GFX_VERSION=10.3.0 build/bin/llama-cli -m models/starling-lm-7b-alpha.Q4_K_M.gguf \
-p "I believe the meaning of life is" -n 128
(...)
ggml_cuda_init: GGML_CUDA_FORCE_MMQ:    no
ggml_cuda_init: GGML_CUDA_FORCE_CUBLAS: no
ggml_cuda_init: found 1 ROCm devices:
  Device 0: AMD Radeon Graphics, compute capability 10.3, VMM: no
(...)
llm_load_tensors: ggml ctx size =    0.14 MiB
llm_load_tensors: offloading 0 repeating layers to GPU
llm_load_tensors: offloaded 0/33 layers to GPU
llm_load_tensors:        CPU buffer size =  4165.38 MiB
(...)
llama_perf_sampler_print:    sampling time =       4.35 ms /   136 runs   (    0.03 ms per token, 31285.94 tokens per second)
llama_perf_context_print:        load time =     882.78 ms
llama_perf_context_print: prompt eval time =     241.44 ms /     8 tokens (   30.18 ms per token,    33.13 tokens per second)
llama_perf_context_print:        eval time =   11283.17 ms /   127 runs   (   88.84 ms per token,    11.26 tokens per second)
llama_perf_context_print:       total time =   11533.05 ms /   135 tokens
```

This first output shows some ROCm usage, BUT ntop, radeontop and rocm-smi demonstrate my system is still using only its CPU, and GPU VRAM/GTT are not used!
Notice this important line in the llama.cpp log:
```
llm_load_tensors: offloading 0 repeating layers to GPU
```

llama.cpp doesn’t offload to the GPU, so let’s force offloading all layers
by adding `--n-gpu-layers 99` option to the command line:
```
$ sudo HSA_OVERRIDE_GFX_VERSION=10.3.0 build/bin/main -ngl 99 -m models/starling-lm-7b-alpha.Q4_K_M.gguf...
(...)
llm_load_tensors: offloading 32 repeating layers to GPU
llm_load_tensors: offloading non-repeating layers to GPU
llm_load_tensors: offloaded 33/33 layers to GPU
llm_load_tensors:      ROCm0 buffer size =  4095.06 MiB
llm_load_tensors:        CPU buffer size =    70.32 MiB
(...)
llama_perf_sampler_print:    sampling time =       4.40 ms /   136 runs   (    0.03 ms per token, 30944.25 tokens per second)
llama_perf_context_print:        load time =    2143.15 ms
llama_perf_context_print: prompt eval time =     272.94 ms /     8 tokens (   34.12 ms per token,    29.31 tokens per second) llama_perf_context_print:        eval time =    9983.51 ms /   127 runs   (   78.61 ms per token,    12.72 tokens per second)
llama_perf_context_print:       total time =   10263.81 ms /   135 tokens
```

Now the GPU compute power is used (rocm-smi is reporting a 100% utilization).
VRAM and GTT counters still doesn’t increase, but this is peraps due to the awarness of HIP UMA.

Some benches (notice the llama-bench is using -ngl 99 by default) with 2 models:
```
/llama.cpp$ HSA_OVERRIDE_GFX_VERSION=10.3.0 build/bin/llama-bench \
-m models/starling-lm-7b-alpha.Q4_K_M.gguf \
-m models/mixtral-8x7b-v0.1.Q5_K_M.gguf
(...)
ggml_cuda_init: found 1 ROCm devices:
  Device 0: AMD Radeon Graphics, compute capability 10.3, VMM: no
| model                    |      size |  params | backend | ngl |   test |           t/s |
| ------------------------ | --------: | ------: | ------- | --: | -----: | ------------: |
| llama 7B Q4_K - Medium   | 4.07 GiB  |  7.24 B | CUDA    |  99 |  pp512 | 168.60 ± 0.51 |
| llama 7B Q4_K - Medium   | 4.07 GiB  |  7.24 B | CUDA    |  99 |  tg128 |  12.47 ± 0.07 |
| llama 8x7B Q5_K - Medium | 58.89 GiB | 91.80 B | CUDA    |  99 |  pp512 |  90.47 ± 0.60 |
| llama 8x7B Q5_K - Medium | 58.89 GiB | 91.80 B | CUDA    |  99 |  tg128 |   5.96 ± 0.01 |

build: d5cb8684 (3891)
```

Comparing to CPU backend:
```
/llama.cpp$ build/bin/llama-bench -t $(nproc) \
-m models/starling-lm-7b-alpha.Q4_K_M.gguf \
-m models/mixtral-8x7b-v0.1.Q5_K_M.gguf
(...)
| model                    |      size |  params | backend | threads |  test |          t/s |
| ------------------------ | --------: | ------: | ------- | ------: | ----: | -----------: |
| llama 7B Q4_K - Medium   |  4.07 GiB |  7.24 B | CPU     |      16 | pp512 | 32.15 ± 0.07 |
| llama 7B Q4_K - Medium   |  4.07 GiB |  7.24 B | CPU     |      16 | tg128 | 10.97 ± 0.10 |
| llama 8x7B Q5_K - Medium | 58.89 GiB | 91.80 B | CPU     |      16 | pp512 | 13.19 ± 0.00 |
| llama 8x7B Q5_K - Medium | 58.89 GiB | 91.80 B | CPU     |      16 | tg128 |  5.29 ± 0.01 |

build: d5cb8684 (3891)
```

Conclusion: It is indeed able to load big model and using the iGPU

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

# whisper.cpp

## Generic install

```
git clone https://github.com/ggerganov/whisper.cpp.git
cd whisper.cpp
cmake -D WHISPER_SUPPORT_SDL2=ON .
make
```

## Usage

### One speaker only

Download a model:
```
bash ./models/download-ggml-model.sh base.en
```

Transcode your mp3 in wav:
```
ffmpeg -i FreeBSD\ Foundation\ Update\ -\ May\ 2024\ FreeBSD\ Developer\ Summit.mp3  -ar 16000 -ac 1 -c:a pcm_s16le FreeBSD.Foundation.Update.May.2024.FreeBSD.Developer.Summit.wav
```

Generate a txt file (-otxt) or other like srt (-osrt):

```
bin/main -t 16 -otxt -f ../FreeBSD.Foundation.Update.May.2024.FreeBSD.Developer.Summit.wav
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
bash ./models/download-ggml-model.sh small.en-tdrz
bin/main -t 16 -m models/ggml-small.en-tdrz.bin -otxt -np -di -f ../BSDNow.558.Worlds.of.telnet.wav
(etc.)
[00:00:00.640 --> 00:00:29.620]  (speaker ?) This week on the show we cover NetBSD 9.4 and what's exciting in that release. Then we have free B_S_D_'s S_S_T_F_ attestation to support the cyber security compliance. The lost worlds of Telnet are interesting for the nostalgics among us. How to alter file ownership and permissions with feedback Parallel. raw I_P_ input coming to Open B_S_D_. Open B_S_D_ routers on ALI express mini P_C_s and free B_S_D_ for devs in this week's episode of B_S_D_.
[00:00:30.020 --> 00:00:30.580]  (speaker ?) Now.
[00:00:47.280 --> 00:01:17.280]  (speaker ?) B_S_D_ now, episode five hundred fifty eight, Worlds of Telnet. Recorded on the first of May twenty twenty four. There was something on that special date, I don't know what. This episode of B_S_D_ now was made possible because of you. Thank you for supporting B_S_D_ now Um. hi, I'm your host Eric Greuschling. Hello, welcome to this week's episode. We hope you have a nice day so far and we hope that we can make it a bit interesting, a bit more interesting than it already
[00:01:17.280 --> 00:01:33.240]  (speaker ?) is with some news from the B_S_D_ space and uh starting off with headlines of course, like always like all the other five hundred fifty eight or fifty seven uh episodes started before, let B_S_D_ nine dot four is it this time.
(etc.)
```
