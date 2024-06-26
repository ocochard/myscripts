# llama.cpp

## Generic install

```
git clone https://github.com/ggerganov/llama.cpp.git
cd llama.cpp
make (Linux & MacOS) or gmake (FreeBSD)
```

## Usage

### Start Web UI with specific model

Download a model then instruct llama to start using that model.
To find what is the up-to-date efficient model try the [https://huggingface.co/spaces/open-llm-leaderboard/open_llm_leaderboard](Open LLM Leaderboard)

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
./llama-cli --temp 0.0 --top_p 0.0 --top_k 1.0 -n -1 -f prompt.txt -m models/Mixtral-8x22B-v0.1.IQ1_S.gguf

```

## Specific AMD GPU with Unified Memory Architecture (Work-in-progress)

The RAM is shared by GPU, which mean the GPU could use all the RAM for its usage.
This feature is now called Unified Memory Architecture (UMA).
Example on an APU (AMD Ryzen 7 7735HS with Radeon Graphics) with 64GB RAM:
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

Then check rocminfo is able to detect your GPU:
```
$ rocminfo | grep '^  Name:'
  Name:                    AMD Ryzen 7 7735HS with Radeon Graphics
  Name:                    gfx1035
```

To compile llama.cpp to support this feature, you need:
- Official AMD ROCm drivers and libraries (here: 6.1.0) using Ubuntu (here: 22.04 LTS);
- Instruct llama.cpp to use the BLAS acceleration on HIP-supported AMD GPUs;
- enable HIP UMA (LLAMA_HIP_UMA).

This mobile GPU (gfx1035) is not officialy supported by available ROCm libraries:
There is no file /opt/rocm-6.1.0/lib/rocblas/library/ for gfx1035 as example.
So we need to trick it to use same library as the closest GPU which is the gfx1030.
And the gfx1030 is from Navi 21 family, which belongs to RNDA 2.0 architecture.

So wee need to:
1. During compilation time, force GPU target to gfx1030 (AMDGPU_TARGETS=gfx1030)
1. During compilation AND run time force ROCm to use Navi21 binary (HSA_OVERRIDE_GFX_VERSION=10.3.0)

```
$ HSA_OVERRIDE_GFX_VERSION=10.3.0 make -j$(nproc) LLAMA_HIPBLAS=1 LLAMA_HIP_UMA=1 AMDGPU_TARGETS=gfx1030
```

Then it should be able to detect the GPU and running:
```
$ HSA_OVERRIDE_GFX_VERSION=10.3.0 ./main -m models/mixtral-8x7b-v0.1.Q5_K_M.gguf ...
(etc.)
llm_load_print_meta: model type       = 8x7B
llm_load_print_meta: model ftype      = Q5_K - Medium
llm_load_print_meta: model params     = 46.70 B
llm_load_print_meta: model size       = 30.02 GiB (5.52 BPW)
llm_load_print_meta: general.name     = mistralai_mixtral-8x7b-v0.1
(etc.)
ggml_cuda_init: CUDA_USE_TENSOR_CORES: yes                                                                                ggml_cuda_init: found 1 ROCm devices:
  Device 0: AMD Radeon Graphics, compute capability 10.3, VMM: no
llm_load_tensors: ggml ctx size =    0.42 MiB
llm_load_tensors: offloading 0 repeating layers to GPU
llm_load_tensors: offloaded 0/33 layers to GPU                                                                            llm_load_tensors:  ROCm_Host buffer size = 30735.49 MiB
(etc.)
llama_print_timings:        load time =   41353.87 ms
llama_print_timings:      sample time =      14.11 ms /   400 runs   (    0.04 ms per token, 28344.67 tokens per second)
llama_print_timings: prompt eval time =    1451.22 ms /    19 tokens (   76.38 ms per token,    13.09 tokens per second)
llama_print_timings:        eval time =   74833.32 ms /   399 runs   (  187.55 ms per token,     5.33 tokens per second)
llama_print_timings:       total time =   76376.50 ms /   418 tokens
Log end
```

ntop, radeontop and rocm-smi demonstrate my system is still using only its CPU, and GPU VRAM/GTT are not used!
Notice this important line in the llama.cpp log:
```
llm_load_tensors: offloading 0 repeating layers to GPU
```

llama.cpp doesn’t offload to the GPU, so let’s force offloading all 33 layers
by adding `--n-gpu-layers 33` option to the command line:
```
$ sudo HSA_OVERRIDE_GFX_VERSION=10.3.0 build/bin/main -ngl 33 -m models/mixtral-8x7b-v0.1.Q5_K_M.gguf ...
(etc.)
gml_cuda_init: found 1 ROCm devices:
  Device 0: AMD Radeon Graphics, compute capability 10.3, VMM: no
llm_load_tensors: ggml ctx size =    0.83 MiB
llm_load_tensors: offloading 32 repeating layers to GPU
llm_load_tensors: offloading non-repeating layers to GPU
llm_load_tensors: offloaded 33/33 layers to GPU
llm_load_tensors:      ROCm0 buffer size = 30649.55 MiB
llm_load_tensors:  ROCm_Host buffer size =    85.94 MiB
(etc.)
llama_print_timings:        load time =  108333.74 ms
llama_print_timings:      sample time =      11.83 ms /   400 runs   (    0.03 ms per token, 33826.64 tokens per second)
llama_print_timings: prompt eval time =    3029.96 ms /    19 tokens (  159.47 ms per token,     6.27 tokens per second)
llama_print_timings:        eval time =  151965.13 ms /   399 runs   (  380.86 ms per token,     2.63 tokens per second)
llama_print_timings:       total time =  155113.16 ms /   418 tokens
```

Now the GPU compute power is used (rocm-smi is reporting a 100% utilization) but
the performance was worse with the GPU: From 5.33 tokens per second it lower down to 2.63.
And the VRAM and GTT are still not used!
With an idle desktop environment running on the background the VRAM usage was 214MB, GTT 29MB and RAM available about 60GB.
While llama.cpp was running only VRAM usage increased a little (arround 250MB), but I was
expecting the full 30GB of this model loaded in VRAM+GTT section (and not in RAM):
```
$ echo VRAM used in MB: $(( $(cat /sys/class/drm/card0/device/mem_info_vram_used) / 1024 / 1024 ))
VRAM used in MB: 583
$ echo GTT used in MB: $(( $(cat /sys/class/drm/card0/device/mem_info_gtt_used) / 1024 / 1024 ))
GTT used in MB: 29
$ grep MemAvail /proc/meminfo
MemAvailable:   28255772 kB
```

Let’s try with different value of n-gpu-layers with the same model:
- 0 (CPU only): 5.33 tokens per second
- 1: 4.57 tokens per second
- 8: 3.63 tokens per second
- 16: 3.26 tokens per second
- 33: 2.63 tokens per second

Performance with a smaller model like mistral-7b-instruct-v0.1.Q5_K_M.gguf:
- 0 (CPU only): 9.20 tokens per second
- 33: 4.63 tokens per second
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
