# AMD XDNA 2 NPU (Strix Halo) on FreeBSD: the amdxdna port

Goal: run [FastFlowLM](https://fastflowlm.com/) on the NPU of a Strix Halo
machine under FreeBSD. Status (2026-11-16): done on frwk-bsd. The driver
runs NPU jobs (`xrt-smi validate`: gemm 51 TOPS, latency 47 to 58 us)
through a native XRT port. FastFlowLM runs llama3.2:1b (65 tok/s decode)
and qwen3:8b (10.8 tok/s decode, 396 tok/s prefill on a 1246-token
prompt) under linuxlator, because its NPU engines are closed Linux
binaries. The driver reloads cleanly (6 kldload/kldunload cycles),
and survives suspend-to-idle on the HP ZBook Ultra G1a.
Power (section 5): the NPU draws about 2 W itself and the APU package
23 W, against 85 W on the iGPU, which is 3.9 times faster; energy per
token is about the same in the package, and 26% lower on the iGPU at the
wall (54 W against 147 W). With runtime PM the idle NPU costs nothing.

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
  - [`olivier-lindebugfs-symlink`](https://github.com/ocochard/freebsd-src/compare/main...olivier-lindebugfs-symlink):
    debugfs symlinks leaked on unload
    ([lindebugfs_symlink_leak.md](lindebugfs_symlink_leak.md)).
  - All of them on main, in one branch:
    [`olivier-npu`](https://github.com/ocochard/freebsd-src/compare/main...olivier-npu).
  - Optional, for power measurements:
    [`olivier-lkpi-sysfs-binary`](https://github.com/ocochard/freebsd-src/compare/main...olivier-lkpi-sysfs-binary),
    makes amdgpu `gpu_metrics` readable (rebuild `amdgpu.ko`)
    ([linuxkpi_sysfs_binary_attr.md](linuxkpi_sysfs_binary_attr.md)).
- freebsd-ports branch [`olivier-npu`](https://github.com/ocochard/freebsd-ports/compare/main...olivier-npu):
  graphics/amdxdna-kmod (the driver), graphics/npu-firmware-amd-kmod,
  devel/xrt (XRT plus the amdxdna plugin, NPU only), and two fixes in
  graphics/drm-latest-kmod.
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

1. Kernel from the fork branch
   [`olivier-npu`](https://github.com/ocochard/freebsd-src/compare/main...olivier-npu):
   main 611046b15dbb plus the kernel branches listed above, one commit
   each. Build and install it as usual (`buildkernel`, `installkernel`).
   Build the ports below against this source tree too: drm.ko embeds a
   `struct srcu_struct`, whose size the SRCU fix changes.
2. In `/boot/loader.conf`, the IOMMU (interrupt remapping only is
   enough) and the NPU carveout in MB (FastFlowLM needs several GB; 8192
   covers the 1B to 8B models):

   ```
   hw.amdiommu.enable="1"
   hw.amdxdna.carveout_mb="8192"
   ```

   `hw.iommu.dma=1` (DMA remapping too) also works, with
   `hw.busdma.pci0.194.0.1=bounce` for the NPU (carveout addresses are
   physical).
3. Ports, from the ports fork branch
   [`olivier-npu`](https://github.com/ocochard/freebsd-ports/compare/main...olivier-npu),
   built with poudriere in a jail whose `/usr/src` is the tree of step 1:

   | Port | Content |
   |---|---|
   | graphics/amdxdna-kmod | the driver, `/boot/modules/amdxdna.ko` |
   | graphics/npu-firmware-amd-kmod | NPU firmware from linux-firmware 20261019 in `/boot/firmware/amdnpu/` |
   | graphics/drm-latest-kmod | two fixes for reloading a DRM driver (PORTREVISION 1) |
   | devel/xrt | XRT and its amdxdna plugin: `xrt-smi examine`, `xrt-smi validate` |

   Then `sysrc kld_list+=amdxdna`. The NPU stays in D3 until a program
   uses it.
4. FastFlowLM, under linuxlator. Its per-model NPU engines and core
   libraries are closed Linux binaries that need glibc 2.38, newer than
   the linux_base ports, so it runs in an Ubuntu 26.04 userland with
   AMD's Linux XRT. [../npu/fastflowlm-setup.sh](../npu/fastflowlm-setup.sh)
   builds it in `/compat/ubuntu`; the rc.d script
   [../npu/fastflowlm.rc](../npu/fastflowlm.rc) mounts what it needs at
   boot and builds its `/sys` with
   [../npu/linux-xrt-sysfs.sh](../npu/linux-xrt-sysfs.sh):

   ```
   sh fastflowlm-setup.sh
   install -m 555 fastflowlm.rc /usr/local/etc/rc.d/fastflowlm
   install -m 555 linux-xrt-sysfs.sh /usr/local/libexec/
   sysrc fastflowlm_enable=YES
   service fastflowlm start
   chroot /compat/ubuntu flm run llama3.2:1b
   ```

   linsysfs has no `bus/pci/drivers/` and no NPU attributes, so
   `linux-xrt-sysfs.sh` mounts a tmpfs on `/compat/ubuntu/sys` and writes
   the entries XRT reads from the FreeBSD sysctls.

The scripts are in this repository, `FreeBSD/npu/`
(`git clone https://github.com/ocochard/myscripts`). All commands below
run as root.

### Quick start

Check that the driver attached and found the NPU:

```
# dmesg | grep -E '^amdxdna0: <|carveout'
amdxdna0: <amdxdna> mem 0xb0a00000-0xb0afffff,...,0xb0b02000-0xb0b02fff at device 0.1 on pci4
# ls /dev/accel
accel0
# xrt-smi examine
...
  NPU Firmware Version : 1.1.2.65
Device(s) Present
|BDF             |Name            |Architecture  |Topology  |
|[0000:c2:00.1]  |NPU Strix Halo  |aie2p         |6x8       |
```

Run AMD's self tests. They need a test archive that is not part of XRT
(devel/xrt's pkg-message gives the same command):

```
$ mkdir -p ~/.local/share/xrt/2.27.0/amdxdna/bins
$ fetch -o ~/.local/share/xrt/2.27.0/amdxdna/bins/ \
    https://raw.githubusercontent.com/Xilinx/VTD/main/archive/strx/xrt_smi_strx.a
$ xrt-smi validate
...
Test 1 [0000:c2:00.1]     : gemm
    Details               : TOPS: 51.0
    Test Status           : [PASSED]
Test 2 [0000:c2:00.1]     : latency
    Details               : Average latency: 46.0 us
    Test Status           : [PASSED]
```

FastFlowLM, once its userland is installed (step 4). `flm` runs inside
the Ubuntu userland, so each command goes through chroot(8). Models are
downloaded on first use into `/compat/ubuntu/root/.config/flm/models`
(1.3 GB for llama3.2:1b, 5.6 GB for qwen3:8b); `flm list` shows the
catalog, with a check mark on the downloaded ones:

```
# chroot /compat/ubuntu flm list
Models:
  ...
  - llama3.2:1b ✅
  - qwen3:8b ✅
# chroot /compat/ubuntu flm pull qwen3:8b
```

Chat in the terminal (`/?` for help, `/bye` to quit); a question can also
be piped in:

```
# echo "What is FreeBSD? Answer in one sentence." | \
    chroot /compat/ubuntu flm run llama3.2:1b
[FLM]  Model loaded in 1.48 s
[FLM]  Loading model: llama3.2:1b
...
FreeBSD is a free and open-source operating system (OS) that is designed
to be stable, secure, and reliable, ...
```

Or serve an OpenAI-compatible API, for any client that speaks it
(llama.cpp's web UI, Open WebUI, editors):

```
# chroot /compat/ubuntu /bin/sh -c 'cd /tmp; flm serve llama3.2:1b --port 52625' &
$ curl -s http://127.0.0.1:52625/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d '{"model": "llama3.2:1b", "max_tokens": 20,
         "messages": [{"role": "user", "content": "Name the capital of France in one word."}]}'
{... "content":"Paris" ... "decoding_speed_tps":111.9 ...}
```

The carveout (`hw.amdxdna.carveout_mb`) must hold the model: 8192 MB is
enough up to qwen3:8b. If `flm` cannot find the NPU, check that the
fastflowlm service runs (`service fastflowlm status`) and rerun
`service fastflowlm restart` after reloading amdxdna: its `/sys` entries
describe the loaded driver.

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
| LinuxKPI has no runtime PM core: `pm_runtime_*()` are no-ops | NPU stays in D0 with its firmware running when unused: idle 38.9 W at the wall, 16.7 W RAPL, against 35.3 and 14.7 W with the driver unloaded | runtime PM in the driver: count the users it already declares (`amdxdna_pm_resume_get()` / `_suspend_put()`), and 5 s after the last one run its suspend op and put the NPU in D3; wake on the next use (about 0.1 s), FastFlowLM contexts survive |
| System suspend with the NPU runtime-suspended: the driver's suspend op ran on stopped firmware, its resume op restarted it | after the wake (HP ZBook Ultra G1a): `smu cmd 4 failed, 0xff`, `aie2_hw_start: failed to init smu`, and even a fresh kldload fails until a reboot; a suspend with no driver loaded is fine | as the Linux PCI core does, the system sleep ops first wake a runtime-suspended NPU and hold a reference across the sleep |
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

HP ZBook Ultra G1a (same NPU, 1022:17f0 rev 0x11, at pci0:196:0:1),
2026-11-16: kernel `olivier-npu-n291242-854a0944970d` booted once with
`hw.amdiommu.enable=1 hw.amdgpu.ip_block_mask=0xfffff7ff
hw.amdxdna.carveout_mb=2048` (the mask avoids an amdgpu SMU hang of the
IR-only mode on this laptop, see the AMD IOMMU bug reports), with
drm.ko, amdgpu.ko and amdxdna.ko built against that tree in the kernel
directory, and the devel/xrt package:

| Test | Result |
|---|---|
| attach (devmatch loads it), firmware 1.1.2.65 | OK, then D3 after 5 s |
| `xrt-smi validate` gemm / latency / throughput | 51.0 TOPS / 53 to 82 us / 94554 ops/s, PASSED |
| suspend-to-idle, no driver loaded, then kldload | PASSED |
| suspend-to-idle with the NPU in D3, before the system sleep fix | NPU dead until reboot |
| same, with the fix | gemm 51.0 TOPS, latency 53 us, PASSED; back to D3 |
| suspend-to-idle right after a job (NPU in D0), with the fix | gemm 51.0 TOPS, latency 52 us, PASSED |

Not done: `xrt-smi validate` on frwk-linux, a native FastFlowLM (its NPU engines are closed Linux
libraries), models larger than 8B, userptr BOs (`amdxdna_ubuf.c` returns
`EOPNOTSUPP`), the NPU with a translated IOMMU domain, FastFlowLM on the
ZBook. The 240-byte debugfs leak per unload is fixed by
`olivier-lindebugfs-symlink`.

Install path, on frwk-bsd from a cold boot (2026-11-16): kernel
`olivier-npu-n291242-854a0944970d`, the four packages of section 2, amdxdna
in `kld_list`, `fastflowlm_enable=YES`. amdxdna attaches and suspends the
NPU to D3, the fastflowlm service mounts the Ubuntu userland and builds
its `/sys`, and `flm run llama3.2:1b` answers on the NPU; the packaged
amdgpu returns the whole `gpu_metrics` (264 bytes).

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
  token is 13 to 14% higher for both engines. Those runs predate the
  driver's runtime PM, which removes 1.8 W (RAPL) of the idle gap; the
  rest is virtual_oss and the CPPC default of frwk-bsd, plus the
  sampler's own cost (section 6).
- `-fa on` is faster than `-fa off` on both systems, although llama.cpp
  warns that one flash-attention operation runs on the CPU.

### Runtime power management (frwk-bsd)

The driver now suspends the NPU (firmware stopped, PCI D3) 5 s after its
last use and wakes it on the next one. Idle, 60 s, same boot, wall power
from a Shelly Plug S Gen3 between frwk-bsd and the mains:

| Driver | NPU state | Wall W | RAPL W | SMU socket W |
|---|---|---|---|---|
| without runtime PM | D0 | 38.9 | 16.7 | 18.2 |
| with runtime PM | D3 | 35.7 | 14.9 | 15.5 |
| unloaded | | 35.3 | 14.7 | 15.3 |

So the NPU costs nothing at idle now: 3.2 W saved at the wall. Waking
adds 30 to 150 ms to a request (FastFlowLM, one token, 3 pairs from D0 and
from D3). A FastFlowLM server that holds a hardware context also lets the
NPU suspend: the context is saved and restored by the driver's
`aie2_hwctx_suspend()` / `_resume()`, and later answers are correct at the
same speed. `xrt-smi validate` passes after a wake-up, and kldunload from
D3 is clean (4 cycles).

### Wall power (frwk-bsd)

The same runs as above with runtime PM and the Shelly plug, decode only
(prefill requests last 2 to 5 s, too short for a plug that updates about
once a second). Idle at the wall: 35.1 W. These are the plug's 1 s power
readings, which read about 3.5 W above its energy counter at idle
(section 6), and include the sampler's cost; the comparison between the
engines holds, the absolute watts are a few W high.

| Run | tok/s | Wall W | J/token at the wall | Above idle, J/token |
|---|---|---|---|---|
| NPU decode | 10.8 | 53.6 | 4.98 | 1.72 |
| iGPU decode, fa on | 40.0 | 147.1 | 3.68 | 2.80 |
| iGPU decode, fa off | 38.9 | 137.8 | 3.54 | 2.65 |

At the wall the 35 W the machine draws anyway dominates: the iGPU
finishes 3.7 times sooner, so for a batch job it uses 26% less energy per
token than the NPU. Counting only the power above idle, the NPU uses 39%
less (1.72 against 2.80 J). The NPU keeps the machine at 54 W instead of
147 W: less heat and fan, and the iGPU stays free.

Not measured: the ZBook on battery, larger or MoE models, wall power on
frwk-linux (no plug there).

## 6. The idle gap against Linux

frwk-bsd seemed to idle 5.5 W above frwk-linux. It is not the kernel:
it is two settings of frwk-bsd, plus a measurement artifact. Found on
2026-11-16 by comparing every `gpu_metrics` field of both machines at
idle ([../npu/gpu_metrics_idle.py](../npu/gpu_metrics_idle.py)): FreeBSD
had 10 times the DRAM reads (740 against 69 MB/s), a higher fabric clock
(1601 against 1416 MHz), CPU cores requested at 5150 MHz (Linux about
2000), and 935 interrupts a second from `hdac1`.

1. **virtual_oss** (`virtual_oss_enable="YES"`) streams `/dev/dsp4` in
   8 ms blocks all the time, even when nothing plays: 935 HDA interrupts
   a second keep the package out of deep idle. Most of them come from
   the permanent microphone recording: see [virtual_oss.md](virtual_oss.md).
2. **CPPC at maximum performance.** hwpstate_amd(4) sets EPP 0 and the
   highest requested performance at attach, on purpose (80d32a6b1d73,
   "Switch the default to maximum performance"); powerd cannot change it
   in CPPC mode (`hwpstate_set_cppc()` returns `EOPNOTSUPP`). Every
   wake-up then runs at 5.15 GHz. Linux amd-pstate-epp uses autonomous
   mode with EPP 128 ("balance_performance").
3. **The measurement itself.** The first sampler forked sysctl(8) five
   times a second to read `gpu_metrics`, which at 5.15 GHz cost about
   2.5 W; it now calls sysctlbyname(3) (0.2 W). The FreeBSD idle figures
   of section 5 (14.6 to 17.0 W RAPL) include that overhead.

Measured with nothing running between two RAPL MSR reads 60 s apart and
the plug's energy counter (its 1 s power readings read about 3.5 W high
at idle):

| frwk-bsd, idle 60 s | RAPL | Wall |
|---|---|---|
| as configured | 12.8 W | 24.7 W |
| CPPC: EPP 128, desired 0 (autonomous) | 12.2 W | 24.6 W |
| virtual_oss stopped | 3.97 W | 12.3 W |
| both | 3.44 W | 12.4 W |
| frwk-linux, as configured (docker running, EPP balance_performance) | 9.1 W | no plug |
| frwk-linux, docker and containerd stopped (timer interrupts 1200 to 208 a second) | 8.8 W | no plug |

So a quiet FreeBSD idles below this Linux setup. To get it: run
virtual_oss only when needed, and for CPPC, in `/boot/loader.conf`, for
each CPU N:

```
dev.hwpstate_amd.N.epp="128"
dev.hwpstate_amd.N.desired_performance="0"
```

The settings on frwk-bsd were put back as configured after the tests.
Not explained: on FreeBSD the SMU's socket power reads 2.5 W above RAPL
at idle (15.5 against 13.0 W), on Linux they match.

## 7. To do

- **SVA mode.** The driver runs in carveout mode only: FreeBSD's IOMMU
  driver has no PASID or shared virtual addressing. SVA would remove the
  carveout reservation and allow user-pointer buffers
  (`amdxdna_ubuf.c` returns `EOPNOTSUPP` until then).
- **Upstream.** The kernel branches (section "Code") are ready for
  review; each has a tutorial and was tested on frwk-bsd. The ports are
  on `olivier-npu` in the ports fork.
- **A native FastFlowLM.** Not possible while its NPU engines are closed
  Linux libraries.
