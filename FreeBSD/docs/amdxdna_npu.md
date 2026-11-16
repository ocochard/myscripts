# AMD XDNA 2 NPU (Strix Halo) on FreeBSD: the amdxdna port

Goal: run [FastFlowLM](https://fastflowlm.com/) on the NPU of a Strix Halo
machine under FreeBSD. Status (2026-11-16): done on frwk-bsd. The driver
runs NPU jobs (`xrt-smi validate`: gemm 51 TOPS, latency 47 to 58 us)
through a native XRT port. FastFlowLM runs llama3.2:1b (65 tok/s decode)
and qwen3:8b (10.8 tok/s decode, 396 tok/s prefill on a 1246-token
prompt) under linuxlator, because its NPU engines are closed Linux
binaries. The driver reloads cleanly (6 kldload/kldunload cycles).
Power (section 5): the NPU draws about 2 W itself and the APU package
23 W, against 85 W on the iGPU, which is 3.9 times faster; energy per
token is about the same.

Code:

- drm-kmod branch [`olivier-amdxdna`](https://github.com/ocochard/drm-kmod/compare/drm_v6.12.85_3...olivier-amdxdna)
  on tag `drm_v6.12.85_3` (the graphics/drm-latest-kmod port): the Linux
  driver imported unmodified, two drm fixes, then the FreeBSD port.
- freebsd-src branches, one fix each, all needed:
  - [`olivier-lkpi-srcu`](https://github.com/ocochard/freebsd-src/compare/main...olivier-lkpi-srcu):
    per-struct LinuxKPI SRCU, needed to destroy a hardware context
    ([linuxkpi_srcu_per_struct.md](linuxkpi_srcu_per_struct.md)).
  - [`olivier-amdiommu`](https://github.com/ocochard/freebsd-src/compare/main...olivier-amdiommu):
    boots with the AMD IOMMU on. The NPU firmware is about 1000 times
    slower with the IOMMU unit off ([amdiommu_ser6.md](amdiommu_ser6.md),
    section 5.1).
  - [`olivier-amdiommu-irte`](https://github.com/ocochard/freebsd-src/compare/main...olivier-amdiommu-irte):
    frees interrupt remapping entries; without it the second kldload
    fails ([amdiommu_irte_free.md](amdiommu_irte_free.md)).
  - [`olivier-lkpi-pcim-iomap`](https://github.com/ocochard/freebsd-src/compare/main...olivier-lkpi-pcim-iomap):
    LinuxKPI `pcim_iomap()` leaked every BAR on unload
    ([linuxkpi_pcim_iomap_release.md](linuxkpi_pcim_iomap_release.md)).
  - Optional, for power measurements:
    [`olivier-lkpi-sysfs-binary`](https://github.com/ocochard/freebsd-src/compare/main...olivier-lkpi-sysfs-binary),
    makes amdgpu `gpu_metrics` readable (rebuild `amdgpu.ko`)
    ([linuxkpi_sysfs_binary_attr.md](linuxkpi_sysfs_binary_attr.md)).
- freebsd-ports branch [`olivier-npu`](https://github.com/ocochard/freebsd-ports/compare/main...olivier-npu):
  new port devel/xrt (XRT plus the amdxdna plugin, NPU only).
- [../npu/linux-xrt-sysfs.sh](../npu/linux-xrt-sysfs.sh): builds the Linux
  `/sys` entries that Linux XRT and FastFlowLM read, for linuxlator.
- Test programs: [amdxdna_query.c](amdxdna_query.c) (firmware and hardware
  queries), [amdxdna_hwctx.c](amdxdna_hwctx.c) (device heap, user
  addresses, hardware context). Both build on Linux and FreeBSD.

Machines: frwk-bsd (FreeBSD) and frwk-linux (Ubuntu, kernel 7.0, stock
`amdxdna`), both Strix Halo, NPU PCI ID 1022:17f0 revision 0x11. The
ZBook Ultra G1a has the same NPU function; it was not tested there yet.

## 1. Background

### What the NPU is

The NPU is an array of AI Engine tiles (AIE2, "XDNA 2"): 8 columns of 6
rows on Strix Halo (4 rows of compute tiles, 1 row of memory tiles, 1
row of interface tiles). A small firmware processor inside the NPU
manages it. The host never programs the tiles directly: it sends
messages to the firmware.

### The Linux driver and its userspace

Linux has `amdxdna` in `drivers/accel/amdxdna` (13.6k lines, GPL-2.0).
Userspace is AMD's XRT library with its amdxdna plugin; FastFlowLM sits on
XRT. The driver exposes `/dev/accel/accel0`, a DRM "accel" device, with
ioctls to create buffers (BOs), hardware contexts and to submit commands.

### Bring-up steps the driver performs

1. Request the firmware file `amdnpu/17f0_11/npu_7.sbin` (falls back to
   `npu.sbin`).
2. Map the PCI BARs and hand the firmware to the platform security
   processor (PSP), which validates and starts it.
3. Talk to the firmware through a mailbox: ring buffers in NPU SRAM plus
   an MSI-X interrupt.
4. Query the firmware version and the AIE geometry.

### Memory the NPU can reach: SVA or carveout

On Linux the NPU normally shares the process page tables through the
IOMMU (SVA with a PASID): any user address is a device address. FreeBSD
has no SVA and no PASID support, and LinuxKPI exposes no IOMMU groups.
`amdxdna` has a second mode, *carveout*: one physically contiguous region
from which every BO is allocated, and the NPU uses physical addresses.
The FreeBSD port runs in carveout mode only.

Upstream refuses to run without an IOMMU (Linux a8878e19d2f5, "The AIE2
device firmware requires IOMMU on"). The bug behind it is s2idle failing
to reach hardware sleep on a laptop with `amd_iommu=off`, not a DMA
failure, so the port bypasses the check on FreeBSD and prints a warning.

## 2. Using it

1. Kernel with the four freebsd-src branches above (main has
   71d26da7e43d, devres release on PCI detach, since 2026-11-04), booted
   with the IOMMU on. Interrupt remapping only is enough:

   ```
   hw.amdiommu.enable=1
   ```

   `hw.iommu.dma=1` (DMA remapping too) also works, with
   `hw.busdma.pci0.194.0.1=bounce` for the NPU (carveout addresses are
   physical).
2. Firmware from linux-firmware, decompressed:
   `/boot/firmware/amdnpu/17f0_11/npu_7.sbin` (1.1.2.65, md5
   `4840b9b0d5966228f07686b62e8accba`) and `npu.sbin` (1.0.0.166). The
   drm-kmod-firmware ports do not ship `amdnpu/` yet.
3. Build `drm` and `amdxdna` from the drm-kmod branch against that kernel
   source and install the new `drm.ko` in `/boot/modules` (the drm fix
   below):

   ```
   cd drm-kmod/drm && make SYSDIR=<src>/sys
   cd ../amdxdna && make SYSDIR=<src>/sys
   ```
4. Load, with the carveout size in MB (FastFlowLM needs several GB; 8192
   for the 1B to 8B models):

   ```
   kenv hw.amdxdna.carveout_mb=8192
   kldload ./amdxdna.ko
   ```
5. Native XRT: build devel/xrt from the ports branch with poudriere, then
   `xrt-smi examine` and `xrt-smi validate`.
6. FastFlowLM, under linuxlator. Its per-model NPU engines and core
   libraries are closed Linux binaries that need glibc 2.38, newer than
   the linux_base ports, so it runs in an Ubuntu 26.04 chroot with AMD's
   packages:

   ```
   debootstrap --variant=minbase resolute /compat/ubuntu
   # in the chroot: add the lemonade PPA, then
   apt install libxrt-npu2 libxrt-utils-npu fastflowlm
   R=/compat/ubuntu
   mount -t linprocfs linprocfs $R/proc
   mount -t devfs devfs $R/dev
   mount -t tmpfs tmpfs $R/dev/shm
   mount -t fdescfs fdescfs $R/dev/fd
   sh linux-xrt-sysfs.sh $R      # after each amdxdna load
   chroot $R flm run llama3.2:1b
   ```

   linsysfs has no `bus/pci/drivers/` and no NPU attributes, so
   `linux-xrt-sysfs.sh` mounts a tmpfs on `$R/sys` and writes the entries
   XRT reads from the FreeBSD sysctls.

```
amdxdna0: <amdxdna> mem 0xb0a00000-0xb0afffff,... at device 0.1 on pci4
amdxdna0: [drm] aie2_init: Running without IOMMU, carveout memory only
amdxdna0: successfully loaded firmware image 'amdnpu/17f0_11/npu_7.sbin'
[drm] Initialized amdxdna_accel_driver 0.10.0 for amdxdna0 on minor 1
```

## 3. What the port had to change

drm-kmod is the drm core of Linux 6.12; the driver is Linux 7.2 code.
Interfaces missing on FreeBSD are shimmed in `amdxdna_freebsd.h`
(force-included), `amdxdna_freebsd.c` and `compat/linux/`; driver changes
are `#ifdef __linux__` blocks, most marked `XXX FreeBSD`.

| Problem found | Measured symptom | Change |
|---|---|---|
| Linux 7.x API on a 6.12 core (`drm_sched_init_args`, `kzalloc_obj`, `drm_gem_vmap`, xarray iterators, ...) | build errors | inline adapters in `amdxdna_freebsd.h` |
| `drm_gem_get_pages()` is Linux-only in drm-kmod | unresolved symbols | page array from the LinuxKPI shmem object, as i915 does |
| No IOMMU, SVA, HMM | `aie2_init: Running without IOMMU not supported`; open: `PASID unavailable and carveout not configured` | IOMMU and HMM stubs; carveout allocated at probe from `hw.amdxdna.carveout_mb` |
| FreeBSD `pci_alloc_msix()` needs the MSI-X table BAR active; npu5 maps BARs 0, 2, 4, 5, the table is in BAR 1 | `failed to alloc irq vectors, ret -22` | map the table and PBA BARs before allocating vectors |
| drm-kmod has no accel minor | no `/dev/accel` | render node plus a `/dev/accel/accelN` alias; ioctls flagged `DRM_RENDER_ALLOW` (render clients get `EACCES` otherwise) |
| `drm_dev_alias()` never destroys `/dev/dri/*` aliases | second kldload: `panic: make_dev_alias_v: bad si_name (error=17, si_name=dri/renderD129)` | drm fix: accept the existing alias (drm-kmod commit "drm: Tolerate an existing /dev/dri alias") |
| LinuxKPI `sysfs_remove_group()` with an unnamed group | unload: page fault in `strcmp()` from `sysctl_remove_name(name=0x0)` | already fixed in main by bf876046e4b1 |
| LinuxKPI moves an inserted page out of the object that owns it | (found reading `lkpi_vmf_insert_pfn_prot_locked()`) `contigmalloc` pages of the kernel object would have been taken from it | carveout from `vm_page_alloc_noobj_contig()`, wired pages with no object, as TTM does |
| LinuxKPI refuses a mapping whose `vm_ops` lacks `open`/`close` | `mmap heap: Invalid argument` | carveout `vm_ops` gain `open`/`close`; the mapping holds a dma-buf reference, as Linux `dma_buf_mmap()` does |
| LinuxKPI calls the driver mmap with `vm_start` 0 | kernel reported heap `vaddr` 0, device BO addresses wrong | look the address up in the process map (device pager object whose handle is the BO) |
| LinuxKPI SRCU is one global epoch | hardware context destroy spins forever in `ck_epoch_synchronize_wait()` | LinuxKPI fix, [linuxkpi_srcu_per_struct.md](linuxkpi_srcu_per_struct.md) |
| drm-kmod registers the static `hw.dri` node in the device sysctl context | after kldunload, `sysctl -a` panics on the freed `hw.dri` children | drm fix: keep `hw.dri` out of the device context |
| `drm_clflush_sg()` on a carveout BO, which has no page array | panic in `drm_clflush_sg()` at the first command | flush carveout BOs through their kernel mapping |
| XRT reads the PCI revision from sysfs to pick the device class | `xrt-smi`: `Unsupported hardware type` | publish `sys.device.amdxdnaN.revision` |
| NPU firmware with the IOMMU unit off | every firmware message about 141 ms, `xrt-smi validate` latency about 95 ms per job | boot with `hw.amdiommu.enable=1` ([amdiommu_ser6.md](amdiommu_ser6.md)) |
| amd_iommu never frees interrupt remapping entries; the NPU uses all 32 | second kldload: `failed to alloc irq vectors, ret -22` | amd_iommu fix, [amdiommu_irte_free.md](amdiommu_irte_free.md) |
| LinuxKPI `pcim_iomap()` stores a bus handle as a resource | kldunload: `driver did not clean up; leaking mmio resources` | LinuxKPI fix, [linuxkpi_pcim_iomap_release.md](linuxkpi_pcim_iomap_release.md) |

### XRT on FreeBSD (devel/xrt)

XRT is Linux-only upstream. The port builds the NPU part only, with the
amdxdna plugin in the XRT tree. Changes:

- Device discovery: Linux XRT walks `/sys/bus/pci/drivers/amdxdna`. The
  port reads `dev.amdxdna.N.%location` and `%pnpinfo`, and the driver
  attributes from `sys.device.amdxdnaN.*`.
- Linux headers (`linux/ioctl.h`, `asm/mman.h`, ...) come from small
  compat headers in `files/freebsd-compat`; `MAP_LOCKED` is 0 and
  `EKEYREJECTED` maps to `EAUTH`.
- XRT links with `-Bsymbolic`, so each library has its own copy of
  inline type information. libc++ compares `typeinfo` by address by
  default, and `std::any_cast` across libraries failed (`bad any cast`).
  `-D_LIBCPP_TYPEINFO_COMPARISON_IMPLEMENTATION=2` compares by name, as
  libstdc++ does.

The heap must be mapped at a 64 MB aligned user address
(`AIE2_DEVM_SIZE`); Linux rejects an unaligned one too
(`command opcode 0x106 failed, status 0x4000003`), so this is a property of
the firmware interface, not of the port.

## 4. Tested

frwk-bsd, final setup: kernel main-n291189-34d10ebaa57e (6871285f194d
plus `olivier-amdiommu`, `olivier-lkpi-srcu`, `olivier-amdiommu-irte`,
`olivier-lkpi-pcim-iomap`), GENERIC-NODEBUG, `hw.amdiommu.enable=1`,
drm-kmod `drm_v6.12.85_3` plus the branch, carveout 8192 MB. frwk-linux:
Ubuntu kernel 7.0.0-43, stock `amdxdna` 0.7.0.

| Test | frwk-linux | frwk-bsd |
|---|---|---|
| `amdxdna_query`: firmware version | 1.1.2.65 | 1.1.2.65 |
| AIE geometry | 1.1, 8 cols x 6 rows, col_size 0x1f8, 4 core rows, 1 mem row | same |
| Clocks | MP-NPU 1267 MHz, H 1800 MHz | same |
| `amdxdna_hwctx`: 64 MB device heap, mmap, 16 Mi words written and read back | 0 bad words | 0 bad words |
| Heap `vaddr` reported by the kernel equals the mapping | matches | matches |
| Device BO address inside the heap mapping, write visible through the heap | yes | yes |
| Hardware context create and destroy | OK | OK, 5 runs in a row |
| `xrt-smi validate` gemm (native devel/xrt) | not run | 51.0 TOPS, PASSED |
| `xrt-smi validate` latency | not run | 47 to 58 us, PASSED |
| Same without the IOMMU unit | | gemm 51 TOPS; latency about 95 ms per job |
| kldload / kldunload cycles | | 6 cycles, no leak message, NPU validates after them |
| FastFlowLM 1.0.13 llama3.2:1b, 51-token prompt: prefill / decode tok/s | 140.7 / 64.2 | 129.7 / 63.9 |
| llama3.2:1b, 1270-token prompt | 1803.1 / 60.8 | 1684.6 / 59.7 |
| qwen3:8b, 29-token prompt | 25.6 / 11.4 | 23.3 / 11.4 |
| qwen3:8b, 1251-token prompt | 393.0 / 10.7 | 396.0 / 10.7 |
| amdgpu next to it (`vulkaninfo --summary`) | | RADV STRIX_HALO |

FastFlowLM numbers are medians of 3 runs of
[../npu/flm-bench.py](../npu/flm-bench.py) (each run starts with a
different word to defeat the prefix cache), same FastFlowLM 1.0.13 and
XRT 2.25.0 on both systems; frwk-linux needs `prlimit --memlock=unlimited`
first (the 8 MB default fails with `mmap ... Resource temporarily
unavailable`). Decode is the same on both systems; FreeBSD prefill is
within 7%. So decode speed is set by the NPU and FastFlowLM, not by the
port: each token reads the whole model (5.6 GB for qwen3:8b), so 10.7
tok/s is about 60 GB/s of NPU memory reads. FastFlowLM's site gives
66 tok/s for llama3.2:1b on a Ryzen AI 7 HX 350.

FastFlowLM runs under linuxlator (Ubuntu 26.04 chroot). It logs
`SVA bind device failed` and `PASID not available` at open, as expected
in carveout mode, and works.

Not done: `xrt-smi validate` on frwk-linux, a native FastFlowLM (its NPU engines are closed Linux
libraries), models larger than 8B, userptr BOs (`amdxdna_ubuf.c` returns
`EOPNOTSUPP`), the NPU with a translated IOMMU domain, suspend, the ZBook
itself. Known leak: 240 bytes of debugfs memory per unload.

## 5. Power: NPU against iGPU

Same model, Qwen3-8B 4-bit: FastFlowLM `qwen3:8b` on the NPU, and
llama.cpp b1b770d90 (Vulkan, RADV) with `Qwen3-8B-Q4_1.gguf` (unsloth,
5.2 GB) fully offloaded to the iGPU, `-fa on` and `-fa off`. Measured
on 2026-11-16 with [../npu/npu-power-run.sh](../npu/npu-power-run.sh)
on both systems, median of 3 runs:

- *decode*: a story prompt of about 30 tokens, 768 tokens out
  (FastFlowLM stops at about 700);
- *prefill*: a 1242-token prompt and a one-sentence answer; tok/s is
  prompt tokens over the whole request, so it is lower than the prefill
  speed FastFlowLM reports alone.

Power sources: RAPL package energy (whole APU, energy per token is
computed from it), and the SMU's own averages from amdgpu `gpu_metrics`
(socket = the PPT Linux hwmon shows, NPU, GFX, CPU cores). On FreeBSD
`gpu_metrics` needs the LinuxKPI fix
[linuxkpi_sysfs_binary_attr.md](linuxkpi_sysfs_binary_attr.md); RAPL
is read through cpuctl(4). The SMU averages lag on the 2 s iGPU prefill
requests, so trust RAPL there.

Linux (frwk-linux), idle 9.1 W:

| Run | tok/s | RAPL W | J/token | SMU socket / NPU / GFX / cores W |
|---|---|---|---|---|
| NPU decode | 10.8 | 23.0 | 2.13 | 22.8 / 2.2 / 0.0 / 0.2 |
| iGPU decode, fa on | 41.8 | 89.1 | 2.15 | 85.1 / 0.0 / 29.1 / 0.5 |
| iGPU decode, fa off | 38.9 | 84.8 | 2.18 | 80.8 / 0.0 / 28.3 / 0.6 |
| NPU prefill | 257.8 | 24.4 | 0.095 | 22.3 / 1.4 / 0.0 / 0.4 |
| iGPU prefill, fa on | 678.6 | 99.9 | 0.147 | 56.9 / 0.0 / 23.7 / 0.3 |
| iGPU prefill, fa off | 511.2 | 86.7 | 0.171 | 56.5 / 0.0 / 21.9 / 0.3 |

FreeBSD (frwk-bsd), idle 17.0 W at the start, 14.6 W at the end:

| Run | tok/s | RAPL W | J/token | SMU socket / NPU / GFX / cores W |
|---|---|---|---|---|
| NPU decode | 10.8 | 26.1 | 2.43 | 27.5 / 1.8 / 0.0 / 0.9 |
| iGPU decode, fa on | 41.5 | 101.1 | 2.44 | 97.0 / 0.0 / 26.2 / 1.5 |
| iGPU decode, fa off | 38.8 | 96.8 | 2.49 | 93.1 / 0.0 / 26.0 / 1.6 |
| NPU prefill | 264.8 | 27.9 | 0.105 | 27.0 / 1.1 / 0.0 / 1.4 |
| iGPU prefill, fa on | 646.7 | 92.2 | 0.149 | 60.1 / 0.0 / 17.9 / 0.9 |
| iGPU prefill, fa off | 492.3 | 84.3 | 0.171 | 61.1 / 0.0 / 17.4 / 1.3 |

What it shows:

- The NPU block itself draws about 2 W, which is the "< 2 W" that
  FastFlowLM advertises. But the package goes from 9 to 23 W (Linux):
  streaming the 5.6 GB model 10.8 times a second keeps the memory
  controller and fabric busy. The iGPU block draws 26 to 29 W, the
  package 85 to 101 W.
- Decode: the iGPU is 3.9 times faster and draws 3.9 times the power,
  so the energy per token of the whole package is the same, 2.1 to
  2.2 J on Linux. Counting only the power above idle, the NPU costs
  1.29 J per token and the iGPU 1.92 J: one third less on the NPU.
- Prefill: the iGPU is 2.6 times faster; the NPU uses 35% less energy
  per prompt token (0.095 against 0.147 J).
- So the NPU wins when power or heat is the limit (laptop on battery,
  the iGPU busy with something else), not on speed or on total energy.
- FreeBSD: same speeds, but more power than Linux: 6 to 8 W at idle,
  3 W during NPU decode, 12 W during iGPU decode. Energy per decoded
  token is 13 to 14% higher for both engines. Of the
  idle gap, 2.7 W is the loaded amdxdna driver (FreeBSD keeps the NPU
  powered; Linux puts it in D3cold, measured by unloading the driver);
  the rest is a platform idle difference not studied here.
- `-fa on` is faster than `-fa off` on both systems, although llama.cpp
  warns that one flash-attention operation runs on the CPU.

Not measured: wall power (no meter), the ZBook on battery, larger or MoE
models, the NPU with the driver's runtime power management.
