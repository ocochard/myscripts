# FrameWork Desktop with amdgpu support

Use case: Local LLM with Vulkan backend

## FreeBSD main

First, need a FreeBSD main at:
`git: 36fe65cc7a31 - main - Bump __FreeBSD_version to 1600015 after linuxkpi changes for DRM 6.11`

## Install latest drm-kmod from github

Install latest drm-kmod:
```
$ git clone https://github.com/freebsd/drm-kmod/
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

And run a big model (for coding):
```
build/bin/llama-server \
  -hf unsloth/Qwen3.6-27B-GGUF:UD-Q4_K_XL \
  --alias qwen36-coder \
  --device Vulkan0 \
  --temp 0.6 \
  --top-p 0.95 \
  --top-k 20 \
  --min-p 0.00 \
  --flash-attn on \
  --no-host \
  --kv-unified \
  --batch-size 4096 --ubatch-size 1024 \
  --ctx-size 131072
```

Or run a benchmark (once the model downloaded with previous example):
```
$ build/bin/llama-bench \
  -m ~/.cache/huggingface/hub/models--unsloth--Qwen3.5-35B-A3B-GGUF/snapshots/bc014a17be43adabd7066b7a86075ff935c6a4e2/Qwen3.5-35B-A3B-UD-Q4_K_XL.gguf \
  --device Vulkan0 \
  --batch-size 2048 \
  --ubatch-size 512 \
  --n-prompt 2048,8192,16384 \
  --n-gen 128 \
  --mmap 1 \
  --threads 16 \
  --no-host 1 \
  --n-gen 128 \
  --repetitions

ggml_vulkan: Found 1 Vulkan devices:
ggml_vulkan: 0 = Radeon 8060S Graphics (RADV GFX1151) (radv) | uma: 1 | fp16: 1 | bf16: 0 | warp size: 64 | shared memory: 65536 | int dot: 1 | matrix cores: KHR_coopmat
| model                           |      size |  params | backend| ngl|    dev  |noh|    test |            t/s |
| ------------------------------- | --------: | ------: | ------ | -: | ------- | -:| ------: | -------------: |
| qwen35moe 35B.A3B Q4_K - Medium | 20.70 GiB | 34.66 B | Vulkan | 99 | Vulkan0 | 1 |  pp2048 | 865.89 ± 30.21 |
| qwen35moe 35B.A3B Q4_K - Medium | 20.70 GiB | 34.66 B | Vulkan | 99 | Vulkan0 | 1 |  pp8192 | 869.87 ± 3.97  |
| qwen35moe 35B.A3B Q4_K - Medium | 20.70 GiB | 34.66 B | Vulkan | 99 | Vulkan0 | 1 | pp16384 | 787.75 ± 3.65  |
| qwen35moe 35B.A3B Q4_K - Medium | 20.70 GiB | 34.66 B | Vulkan | 99 | Vulkan0 | 1 |   tg128 |  50.38 ± 1.90  |
| qwen35moe 35B.A3B Q4_K - Medium | 20.70 GiB | 34.66 B | Vulkan | 99 | Vulkan0 | 1 |   tg128 |  52.62 ± 0.75  |

build: 94ca829b6 (8679)
```
