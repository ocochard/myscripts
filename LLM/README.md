# llama.cpp

## Generic build instructions with a Vulkan backend

[Official doc is very good for that](https://github.com/ggerganov/llama.cpp/blob/master/docs/build.md).
```
git clone https://github.com/ggerganov/llama.cpp.git
```

Install Vulkan headers on FreeBSD
```
sudo pkg install -y vulkan-headers vulkan-loader glslang shaderc spirv-headers
```

Or on Ubuntu:
```
sudo apt install xz-utils libxcb-xinput0 libxcb-xinerama0 libxcb-cursor-dev
mkdir ~/vulkan
cd ~/vulkan
wget https://sdk.lunarg.com/sdk/download/1.4.350.1/linux/vulkansdk-linux-x86_64-1.4.350.1.tar.xz
tar xf vulkansdk-linux-x86_64-1.*.tar.xz
rm vulkansdk-linux-x86_64-1.*.tar.xz
cd
source ~/vulkan/1.*/setup-env.sh
```

Then build it using cmake:
```
cd llama.cpp
which -s apt && sudo apt install -y build-essential cmake libcurl4-openssl-dev
test $(uname)=FreeBSD && sudo pkg install -y cmake curl
test $(uname)=Darwin && alias nproc="sysctl -n hw.physicalcpu"
cmake --fresh -B build -DGGML_VULKAN=ON
cmake --build build --config Release -- -j $(nproc)
```

Some llama fork need to add this to be compiled on FreeBSD:
```
-DCMAKE_MAKE_PROGRAM=/usr/local/bin/gmake
```

## Usage

### Start Web UI with specific model

Download a model then instruct llama to start using that model.
To find what is the up-to-date efficient model, check the latest [Open LLM Leaderboard](https://huggingface.co/spaces/open-llm-leaderboard/open_llm_leaderboard) benchmarks.

And choose weighted/imatrix quants (should have `-i1` in filename) over [static quants files](https://newsletter.maartengrootendorst.com/p/a-visual-guide-to-quantization).

If built with curl support, simply instruct it to download the model, example
with Qwen3.8-27B:
```
build/bin/llama-server --host 0.0.0.0 \
  -hf unsloth/Qwen3.8-27B-GGUF -hff Qwen3.8-27B-UD-Q8_K_XL.gguf \
  --ctx-size 131072 --flash-attn on --device Vulkan0
```

On the Strix Halo hosts, `llmsrv.sh` wraps the tuned recipes; pick a slot with
`MODEL=flashnext` (default), `MODEL=flashnext-abl`, `MODEL=qwen38-mtp` or
`MODEL=qwen38-q8`:
```
MODEL=qwen38-q8 HOST=0.0.0.0 ./llmsrv.sh
```

### Using prompt for text summarization

Text summarization, by using long text input like 1 hour conference transcription as example, needs a model supporting a large context (16K or 32K tokens at least).
Qwen3.8-27B declares a 262144-token context, so a full transcript fits.
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
build/bin/llama-cli --temp 0.0 --top-k 1 -n -1 -c 32768 -st -f prompt.txt \
  -hf unsloth/Qwen3.8-27B-GGUF -hff Qwen3.8-27B-UD-Q8_K_XL.gguf

```

`-st` (`--single-turn`) answers the prompt file once and exits instead of
staying in interactive chat.

### Coding with vim, vs-code, etc.

Example using a [llama.vim](https://github.com/ggml-org/llama.vim/tree/master) or a [vs-code](https://marketplace.visualstudio.com/items?itemName=ggml-org.llama-vscode):
First download the model and start the llama server with the sampling settings from the model card:
```
build/bin/llama-server \
  -hf unsloth/Qwen3.8-27B-GGUF -hff Qwen3.8-27B-UD-Q8_K_XL.gguf \
  --alias qwen38-coder \
  --device Vulkan0 \
  --temp 0.6 \
  --top-p 0.95 \
  --top-k 20 \
  --min-p 0.00 \
  --flash-attn on \
  --kv-unified \
  --batch-size 4096 \
  --ubatch-size 1024 \
  --ctx-size 131072
```

On the Strix Halo hosts, `USAGE=coding ./llmsrv.sh` (the default) starts the
`flashnext` slot with the same sampling plus MTP speculative decoding (see
below); `MODEL=qwen38-mtp` starts the dense 27B equivalent. Do not
add `--no-host` for the dense 27B on FreeBSD: it crashes there.

Then run a [qwen-code](https://qwen.ai/qwencode) as example:

```
cat <<EOF > ~/.env
export OPENAI_BASE_URL=http://127.0.0.1:8080/v1
export OPENAI_API_KEY=not-needed
export OPENAI_MODEL=qwen38-coder
EOF
qwen
```

### Speculative decoding with Multi-Token Prediction (MTP)

MTP is a form of speculative decoding where a small draft head, trained
alongside the main model, proposes the next few tokens and the main model
verifies them in one batch. It is enabled with `--spec-type draft-mtp`, and
`--spec-draft-n-max N` caps how many tokens are drafted per verify step (the
v1.0.0 default is 3; set it explicitly per model).

For the Qwen3.8 models the head ships as a separate GGUF passed with
`--model-draft`:

- **Qwen3.8-27B (`qwen38-mtp` slot)**: `ggml-org/Qwen3.8-27B-GGUF`, target
  `Qwen3.8-27B-Q8_0.gguf` plus the sidecar head `mtp-Qwen3.8-27B-Q8_0.gguf`
  from the same repo. The slot uses `--spec-draft-n-max 4` with
  `--spec-draft-sampling probabilistic`.
- **Qwen3.8-Flash-Next (`flashnext` slot)**: `unsloth/Qwen3.8-Flash-Next-GGUF`,
  the `UD-IQ3_XXS` shards plus `MTP/mtp-Qwen3.8-Flash-Next-Q8_0.gguf`, at
  `--spec-draft-n-max 2`. Mainline llama.cpp needs that self-contained head,
  re-uploaded 2026-10-05: the `shared-` heads fail because mainline cannot
  borrow the main model's embedding (`tensor 'token_embd.weight' not found`),
  and the pre-2026-10-05 upload of the self-contained head aborts with
  `GGML_ASSERT(buffer) failed`. Stay on IQ3_XXS: with IQ4_XS the draft head
  cannot load at any context size. On v1.0.0 (frwk-bsd, 2026-11-14) this gave
  40.3 t/s decode vs 31.3 t/s spec-off, acceptance 0.65.
- **Uncensored Flash-Next (`flashnext-abl` slot)**: the `flashnext` files plus
  `abliteration-lora.gguf` (2.3 MB) from
  `mrfakename/Qwen3.8-Flash-Next-abliterated-GGUF`, loaded with `--lora`. It is
  a rank-1 refusal-direction ablation, so no second 82 GB download. On v1.0.0
  (framework, 2026-11-19), A/B on the same server via the per-request `lora`
  scale, thinking off: two refusal prompts refused at scale 0 and answered at
  scale 1; decode and MTP acceptance unchanged (38.5-40.1 vs 39.5-40.2 t/s,
  0.64-0.68 vs 0.65-0.68 on prose; 45.0 vs 46.4 t/s, 0.84 vs 0.86 on a C
  coding prompt). One sample per cell, so quality is not measured.

Example for the dense model (download the head first; `-hf` does not fetch it):

```
build/bin/llama-server \
  -hf ggml-org/Qwen3.8-27B-GGUF -hff Qwen3.8-27B-Q8_0.gguf \
  --model-draft /path/to/mtp-Qwen3.8-27B-Q8_0.gguf \
  --device Vulkan0 \
  --flash-attn on \
  --ctx-size 131072 --parallel 1 \
  --spec-type draft-mtp \
  --spec-draft-n-max 4
```

`llmsrv.sh` resolves both files from the Hugging Face cache, so
`MODEL=qwen38-mtp ./llmsrv.sh` or `MODEL=flashnext ./llmsrv.sh` is the simpler
path.

Notes:
- `--spec-type` values in v1.0.0: `none, draft-simple, draft-eagle3, draft-mtp,
  draft-dflash, draft-dspark, ngram-simple, ngram-map-k, ngram-map-k4v,
  ngram-mod, ngram-cache`.
- The server prints `draft acceptance = 0.xxxxx (accepted / generated), mean
  len = N` per request. Acceptance alone is misleading: mean accepted length is
  what converts into throughput.
- A cold start that reports `draft acceptance = 0.00000` means a dead draft
  head; every drafted token is then wasted verify compute and decode falls
  below spec-off. On FreeBSD (Mesa 26 RADV) the draft-mtp path intermittently
  hits a GPUVM fault (`[gfxhub] page fault`, client ID CPC); restart, or drop
  `--spec-type` (or use `MODEL=qwen38-q8`) for a spec-off run.
- Chat responses expose `reasoning_content` (the `<think>…</think>` block) and
  `content` (final answer) as separate fields in `/v1/chat/completions`.
  `--jinja` is on by default.

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

Vulkan (RADV) is the backend to use on Strix Halo. ROCm is currently broken on
gfx1151: on current firmware (linux-firmware with MES 0x83, shipped by ROCm
7.2.x apt), every ROCm dispatch faults at model warmup with
`[gfxhub] page fault ... CPF (0x4) / WALKER_ERROR 0x1 / PERMISSION_FAULTS 0x3`.
This is an AMD firmware bug, not a llama.cpp one, tracked upstream in
[ROCm/ROCm#5890](https://github.com/ROCm/ROCm/issues/5890),
[#6186](https://github.com/ROCm/ROCm/issues/6186) and
[#5724](https://github.com/ROCm/ROCm/issues/5724). Vulkan on the same silicon is
unaffected; use `--device Vulkan0`. The ROCm build steps below are kept for
when AMD ships a fix, and for other AMD GPUs.

To compile llama.cpp with ROCm, you need:
- [Official AMD ROCm drivers and libraries](https://rocm.docs.amd.com/projects/install-on-linux/en/latest/install/quick-start.html);
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

Then force usage of UMA with the env var `GGML_CUDA_ENABLE_UNIFIED_MEMORY=1` when starting llama:
```
GGML_CUDA_ENABLE_UNIFIED_MEMORY=1 build/bin/llama-cli \
  -hf unsloth/Qwen3.8-27B-GGUF -hff Qwen3.8-27B-UD-Q8_K_XL.gguf \
  --device ROCm0 --flash-attn on -p "I believe the meaning of life is" -n 128 -st
```

The log should report `ggml_cuda_init: found 1 ROCm devices` and
`llama_model_load_from_file_impl: using device ROCm0`.

Warning: to be able to load large model, some kernel/amdgpu drivers tunning are mandatory
Example with AMD Strix Halo that only use half available (128GB shared RAM here):
Default values allows only using 64GB:
```
$ sudo dmesg | grep "amdgpu.*memory"
[    3.787124] amdgpu 0000:c2:00.0: amdgpu: amdgpu: 512M of VRAM memory ready
[    3.787128] amdgpu 0000:c2:00.0: amdgpu: amdgpu: 62892M of GTT memory ready.
```

So let’s update it to 120GB (8GB preserved for the OS), need to tune the TTM pages (expressed in 4 KB pages).
So we need to calculate ([size in GB] * 1024 * 1024) / 4096
Then adding "amdttm.pages_limit=32768000 amdttm.page_pool_size=32768000" in kernel cmd line grub config file:

```
$ sudo dmesg | grep "amdgpu.*memory"
[    3.884043] amdgpu 0000:c2:00.0: amdgpu: amdgpu: 512M of VRAM memory ready
[    3.884045] amdgpu 0000:c2:00.0: amdgpu: amdgpu: 120000M of GTT memory ready.
$ build/bin/llama-cli --list-devices
ggml_cuda_init: found 1 ROCm devices (Total VRAM: 120000 MiB):
  Device 0: AMD Radeon Graphics, gfx1151 (0x1151), VMM: no, Wave Size: 32, VRAM: 120000 MiB
Available devices:
  ROCm0: AMD Radeon Graphics (120000 MiB, 124096 MiB free)
```

A 120 GB aperture lets models load that leave the OS no headroom: on frwk-linux,
loading Flash-Next UD-IQ4_XS with its MTP head this way kernel-panicked the
host. See "DANGER: gttsize=120000 panicked the Linux kernel" in
[benches.FrameWork-Desktop.md](benches.FrameWork-Desktop.md).


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

And start a bench (remember to load OneAPI vars for each new session); with 96GB of RAM, big models fit.
The startup banner should list one `[level_zero:gpu:0]` SYCL device:
```
~/llama.cpp$ source /opt/intel/oneapi/setvars.sh
~/llama.cpp$ build/bin/llama-bench -m /path/to/Qwen3.8-27B-UD-Q8_K_XL.gguf
```

To be compared with CPU only usage:
```
~/llama.cpp$ build/bin/llama-bench -t $(nproc) -m /path/to/Qwen3.8-27B-UD-Q8_K_XL.gguf
```

## Vision

Reading picture needs a model that ships an mmproj (vision projector) file in
its repo; `-hf` downloads it automatically:
```
$ curl --output /tmp/fbsd.png  https://www.freebsd.org/images/banner-red.png
$ build/bin/llama-mtmd-cli -hf <vision-model-repo> --image /tmp/fbsd.png -p "Describe this image"
(etc..)
$ build/bin/llama-mtmd-cli -hf <vision-model-repo> --image ~/Downloads/iKVM_capture_dump.jpg -p "you are an OCR machine, write text on the picture"
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
