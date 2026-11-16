# AMD XDNA 2 NPU (Strix Halo) on FreeBSD: the amdxdna port

Goal: run [FastFlowLM](https://fastflowlm.com/) on the NPU of a Strix Halo
machine under FreeBSD. Status (2026-11-16): the driver attaches, loads the
NPU firmware, answers queries, and creates and destroys hardware contexts.
Running a job, XRT and FastFlowLM are not done yet.

Code:

- drm-kmod branch [`olivier-amdxdna`](https://github.com/ocochard/drm-kmod/compare/drm_v6.12.85_3...olivier-amdxdna)
  on tag `drm_v6.12.85_3` (the graphics/drm-latest-kmod port): the Linux
  driver imported unmodified, a drm fix, then the FreeBSD port.
- freebsd-src branch [`olivier-lkpi-srcu`](https://github.com/ocochard/freebsd-src/compare/main...olivier-lkpi-srcu):
  per-struct LinuxKPI SRCU, needed to destroy a hardware context
  ([linuxkpi_srcu_per_struct.md](linuxkpi_srcu_per_struct.md)).
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

1. Kernel with the LinuxKPI SRCU fix (branch `olivier-lkpi-srcu`), or at
   least main with 71d26da7e43d (devres release on PCI detach; without it
   kldunload leaks the device and the next kldload spins).
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
4. Load, with the carveout size in MB:

   ```
   kenv hw.amdxdna.carveout_mb=1024
   kldload ./amdxdna.ko
   ```

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

The heap must be mapped at a 64 MB aligned user address
(`AIE2_DEVM_SIZE`); Linux rejects an unaligned one too
(`command opcode 0x106 failed, status 0x4000003`), so this is a property of
the firmware interface, not of the port.

## 4. Tested

frwk-bsd: kernel main-n291187-6871285f194d with the SRCU patch, drm-kmod
`drm_v6.12.85_3` plus the branch, carveout 1024 MB. frwk-linux: Ubuntu
kernel 7.0.0-43, stock `amdxdna` 0.7.0.

| Test | frwk-linux | frwk-bsd |
|---|---|---|
| `amdxdna_query`: firmware version | 1.1.2.65 | 1.1.2.65 |
| AIE geometry | 1.1, 8 cols x 6 rows, col_size 0x1f8, 4 core rows, 1 mem row | same |
| Clocks | MP-NPU 1267 MHz, H 1800 MHz | same |
| `amdxdna_hwctx`: 64 MB device heap, mmap, 16 Mi words written and read back | 0 bad words | 0 bad words |
| Heap `vaddr` reported by the kernel equals the mapping | matches | matches |
| Device BO address inside the heap mapping, write visible through the heap | yes | yes |
| Hardware context create and destroy | OK | OK, 5 runs in a row |
| kldload / kldunload cycles | | 3 cycles with queries, clean |
| amdgpu next to it (`vulkaninfo --summary`) | | RADV STRIX_HALO |

Not done: command submission (needs an NPU program, an xclbin, and XRT's
command format), XRT and FastFlowLM, userptr BOs (`amdxdna_ubuf.c` returns
`EOPNOTSUPP`), suspend, the ZBook itself.
