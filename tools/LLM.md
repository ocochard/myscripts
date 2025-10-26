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

Example using a [llama.vim](https://github.com/ggml-org/llama.vim/tree/master) or a [vs-code[(https://marketplace.visualstudio.com/items?itemName=ggml-org.llama-vscode):
First download the model and start the llama server
```
llama-server \
    --models/qwen2.5-coder-7b-q8_0.gguf \
    --port 8012 -ngl 99 -fa -ub 1024 -b 1024 \
    --ctx-size 0 --cache-reuse 256
```

Then install the plugin and start coding :-)

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
- [Official AMD ROCm drivers and libraries](https://rocm.docs.amd.com/projects/install-on-linux/en/latest/install/quick-start.html) (version 7.0.2 used here);
- [Configure GPU access for your user](https://rocm.docs.amd.com/projects/install-on-linux/en/latest/install/prerequisites.html#group-permissions)
- Instruct llama.cpp to use the BLAS acceleration on HIP-supported AMD GPUs;
- Enable HIP UMA (LLAMA_HIP_UMA).

Once rocm installed, check if your GPU correctly detected:
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
So to compile llama.cpp with HIP support (here we enable DGGML_USE_CPU for bench comparison later using the CPU only):

```
sudo apt install -y libcurl4-gnutls-dev
HIPCXX="$(hipconfig -l)/clang" HIP_PATH="$(hipconfig -R)" \
    cmake -S . --fresh -B build -DGGML_HIP=ON -DGPU_TARGETS=gfx1151 \
    -DGGML_HIP_ROCWMMA_FATTN=ON -DGGML_USE_CPU=ON -DCMAKE_BUILD_TYPE=Release \
    && cmake --build build --config Release -- -j $(nproc)
```
Then force usage of UMA with the env var `GGML_CUDA_ENABLE_UNIFIED_MEMORY=1` when starting llama.
And run a quick test using the gpt-oss-20b model:
```
GGML_CUDA_ENABLE_UNIFIED_MEMORY=1 build/bin/llama-cli -hf ggml-org/gpt-oss-20b-GGUF --flash-attn on --ctx-size 0 --jinja -ub 2048 -b 2048 -p "I believe the meaning of life is" -n 128 -no-cnv
```

Log should have those data:
```
ggml_cuda_init: GGML_CUDA_FORCE_MMQ:    no
ggml_cuda_init: GGML_CUDA_FORCE_CUBLAS: no
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

Some benches (notice the llama-bench is using -ngl 99 by default) with 2 models:
```
$ GGML_CUDA_ENABLE_UNIFIED_MEMORY=1 build/bin/llama-bench -m ~/.cache/llama.cpp/ggml-org_gpt-oss-20b-GGUF_gpt-oss-20b-mxfp4.gguf --threads 1 --flash-attn 1 --batch-size 2048 --ubatch-size 2048 --n-prompt 2048,8192,16384,32768
(...)
ggml_cuda_init: found 1 ROCm devices:
  Device 0: AMD Radeon Graphics, gfx1151 (0x1151), VMM: no, Wave Size: 32
| model                 |      size |  params | back | ngl | thre | n_ubatch | fa |  test   |     t/s       |
|                       |           |         | end  |     | ads  |          |    |         |               |
| --------------------- | --------: | ------: | ---- | --: | ---: | -------: | -: | ------: | ------------: |
| gpt-oss 20B MXFP4 MoE | 11.27 GiB | 20.91 B | ROCm |  99 |    1 |     2048 |  1 | pp2048  | 514.35 ± 5.57 |
| gpt-oss 20B MXFP4 MoE | 11.27 GiB | 20.91 B | ROCm |  99 |    1 |     2048 |  1 | pp8192  | 455.70 ± 0.38 |
| gpt-oss 20B MXFP4 MoE | 11.27 GiB | 20.91 B | ROCm |  99 |    1 |     2048 |  1 | pp16384 | 388.89 ± 0.84 |
| gpt-oss 20B MXFP4 MoE | 11.27 GiB | 20.91 B | ROCm |  99 |    1 |     2048 |  1 | pp32768 | 297.21 ± 1.37 |
| gpt-oss 20B MXFP4 MoE | 11.27 GiB | 20.91 B | ROCm |  99 |    1 |     2048 |  1 |   tg128 |  54.52 ± 0.32 |

build: 8d8862829 (6842)
```

Comparing to CPU backend:
```
$ build/bin/llama-bench -m ~/.cache/llama.cpp/ggml-org_gpt-oss-20b-GGUF_gpt-oss-20b-mxfp4.gguf  --device none --threads $(nproc) --flash-attn 1 --batch-size 2048 --ubatch-size 2048 --n-prompt 2048,8192,16384,32768
| model                 |      size |  params | back | thre | n_ubatch | fa |   test  |       t/s       |
|                       |           |         | end  | ads  |          |    |         |                 |
| --------------------- | --------: | ------: | ---- | ---: | -------: | -: | ------: | --------------: |
| gpt-oss 20B MXFP4 MoE | 11.27 GiB | 20.91 B | CPU  |   32 |     2048 |  1 |  pp2048 |   112.79 ± 0.41 |
| gpt-oss 20B MXFP4 MoE | 11.27 GiB | 20.91 B | CPU  |   32 |     2048 |  1 |  pp8192 |    86.62 ± 0.15 |
| gpt-oss 20B MXFP4 MoE | 11.27 GiB | 20.91 B | CPU  |   32 |     2048 |  1 | pp16384 |    64.52 ± 0.57 |
| gpt-oss 20B MXFP4 MoE | 11.27 GiB | 20.91 B | CPU  |   32 |     2048 |  1 |   tg128 |    30.45 ± 0.14 |

build: 8d8862829 (6842)
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
mkdir ~/vulkan
cd ~/vulkan
wget https://sdk.lunarg.com/sdk/download/1.4.321.1/linux/vulkansdk-linux-x86_64-1.4.321.1.tar.xz
tar -xvf vulkansdk-linux-x86_64-1.4.321.1.tar.xz
source ~/vulkan/1.4.321.1/setup-env.sh
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
