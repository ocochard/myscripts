# amdiommu: hw.amdiommu.enable=1 alone breaks DMA of every MSI device

```
Category:  kern
Component: kern
Version:   16.0-CURRENT
```

Patch: [`iommu_idmap_when_dma_disabled.patch`](iommu_idmap_when_dma_disabled.patch) (`sys/dev/iommu/busdma_iommu.c`).
Commit `iommu: Identity-map contexts when DMA remapping is disabled` on FreeBSD main 02e1b1cd1fb1, first commit of
[#113](https://ron-dev.freebsd.org/FreeBSD/src/pulls/113), with the map-invalidation commit.
Background for readers new to this code: [`amdiommu_ser6.md`](amdiommu_ser6.md), sections 1 and 3.1.

**Summary.** Setting only `hw.amdiommu.enable=1` leaves DMA remapping off (`hw.iommu.dma=0`) and interrupt remapping on (`hw.iommu.ir=1`).
In that mix, each device that sets up MSI gets a Device Table Entry that translates through an empty I/O page table,
while busdma keeps giving the device physical addresses. All its DMA is blocked.
On a Ryzen 7 7735HS the USB devices attach again and again, and the machine never reaches a usable shell.
The patch gives such contexts the identity mapping.
This mode matters on Strix Halo: the AMD XDNA NPU firmware answers about 1000 times slower with the IOMMU unit off,
and `hw.amdiommu.enable=1` alone, with this patch, is enough to fix it (see Tested).

## How to repeat

Machine: Beelink SER6, AMD Ryzen 7 7735HS (IOMMU 1022:14b6 at 0:0:2), FreeBSD 16.0-CURRENT main-n290674 (7806832f23fb), GENERIC-NODEBUG.

```
# nextboot -e hw.amdiommu.enable=1 -e boot_verbose=YES
# shutdown -r now
```

The kernel boots, then USB devices attach in an endless loop on the console. No shell is reachable; only a power cycle recovers.

With `hw.iommu.dma=1` added, the same machine boots and works, so the IOMMU itself is functional.

## Cause

1. `iommu_init_busdma()` sets `unit->dma_enabled` from `hw.iommu.dma`, default 0.
   `iommu_get_dev_ctx()` then returns NULL, and busdma hands out physical addresses.
2. `amdiommu_init_irt()` enables interrupt remapping by default.
   When a driver allocates MSI, `amdiommu_ir_find()` (`sys/x86/iommu/amd_intrmap.c`) calls `iommu_instantiate_ctx(unit, src, false)`.
3. `iommu_instantiate_ctx()` requests an identity mapping only when the device is disabled with a `hw.busdma.pciD.B.S.F` tunable.
   Otherwise `amdiommu_get_ctx_for_dev()` allocates a translating domain (`id_mapped=false`) whose page table is empty.
4. `dte_entry_init_one()` writes V=1, TV=1 and that page table root into the device's DTE.
5. The device's DMA to physical addresses hits unmapped IOVAs and is blocked. xHCI controllers fail and reset; their devices re-attach.

Intel VT-d keeps interrupt remapping apart from DMA contexts, so the same defaults work there. On AMD both live in one DTE.

The bug is in the first version of the driver: `amdiommu_ir_find()` passed `false /* XXXKIB */` for `id_mapped`.
35170408a7b8 moved the call to `iommu_instantiate_ctx()` and kept the behavior.

## Fix

```c
	disabled = !unit->dma_enabled ||
	    iommu_bus_dma_is_dev_disabled(pci_get_domain(requester),
	    pci_get_bus(requester), pci_get_slot(requester),
	    pci_get_function(requester));
```

A unit with DMA remapping off is handled like a device with remapping off: the context gets the identity mapping (DTE mode 0),
and its interrupt remapping table still works.

Other users of `iommu_instantiate_ctx()` are not affected:
`iommu_get_dev_ctx()` calls it only after its own `dma_enabled` check,
and Intel's `dmar_instantiate_rmrr_ctxs()` runs only from `iommu_get_dev_ctx()` through `unit_pre_instantiate_ctx`.

Fixes: 0f5116d7efe3 ("AMD IOMMU driver").

## Tested

Beelink SER6, 2026-11-16, one-shot `nextboot` settings, `boot_verbose`.

| Kernel | Tunables | Result |
|---|---|---|
| stock | `hw.amdiommu.enable=1` | USB devices attach in an endless loop; no shell; power cycle needed |
| patched | `hw.amdiommu.enable=1` | boots normally; all 11 contexts "id-mapped", none "re-mapped"; `dev.amdiommu.0.ir: 1`, `dev.amdiommu.0.dma: 0`; USB enumerated once (8 devices); no IOMMU event; Ethernet up |
| patched | `hw.amdiommu.enable=1 hw.iommu.dma=1` | contexts "re-mapped", as before the patch; works (tested together with the map-invalidation patch) |

HP ZBook Ultra G1a, 2026-11-16: AMD Ryzen AI Max+ PRO 395 (Strix Halo), IOMMU 1022:1508 at 0:0:2,
capability header `0x190b640f`; kernels from FreeBSD main 46ce9acd6d15 plus the laptop's branch `zbook`, one-shot `nextboot` settings.

| Kernel | Tunables | Result |
|---|---|---|
| stock | `hw.amdiommu.enable=1` | USB driver attach loop during boot, as on the SER6; forced power off |
| patched | `hw.amdiommu.enable=1` | boots; `dev.amdiommu.0.ir: 1`, `dev.amdiommu.0.dma: 0`; all 11 contexts "id-mapped" (bridges 0:1:1 and 0:1:2, NVMe, GPU and its other functions, Wi-Fi, xHCI), none "re-mapped"; NVMe, USB, Wi-Fi, keyboard (IOAPIC IRQ 1) and I2C (IRQs 3, 4, 6) all get their interrupts and work; no IOMMU event; with `boot_verbose`, amdgpu's SMU hangs in about half the boots (below) |
| patched | `hw.amdiommu.enable=1 hw.iommu.dma=1` | boots; no IOMMU event; no display error |

The context count needs `kern.msgbufsize=4194304`: with `boot_verbose` the default message buffer overflows before syslog starts.

A separate problem shows on this laptop with the patch and interrupt remapping alone (`hw.amdiommu.enable=1`, contexts id-mapped):
in about half the boots with `boot_verbose`, amdgpu's SMU firmware stops answering, and the display follows.
The first error comes right after amdgpu initializes and the console moves to `drmfb`:

```
drmn0: SMU: I'm not done with your previous command: SMN_C2PMSG_66:0x00000032 SMN_C2PMSG_82:0x00000000
drmn0: Failed to power gate VPE!
[drm ERROR :amdgpu_dpm_enable_vpe] Dpm disable vpe failed, ret = -60.
```

`0x32` is `PPSMC_MSG_PowerDownVpe` (`smu_v14_0_0_ppsmc.h`): the SMU took the request to power down the VPE (video processing engine)
and never completed it. Every later SMU request times out (VCN and JPEG power gating fail the same way),
the display's clock manager warns (`dcn35_smu.c:175`), and page flips time out (`flip_done timed out`, `pflip_status != AMDGPU_FLIP_NONE`,
`DMCUB error`): the console redraws only every few seconds and the boot takes about 3 minutes instead of 20 s.
Up to that point amdgpu's messages are the same in good and bad boots; no IOMMU event is logged.

Patched kernel, `hw.amdiommu.enable=1 boot_verbose=YES kern.msgbufsize=4194304`, VPE switched off or not with amdgpu's
`hw.amdgpu.ip_block_mask` (VPE is IP block 11, `vpe_v6_1`, so `0xfffff7ff`), one boot at a time, alternating:

| VPE | Boots | SMU hang | First SMU failure |
|---|---|---|---|
| on (default) | 9 | 5 | `0x32` (`PowerDownVpe`) in every hang inspected |
| off (`hw.amdgpu.ip_block_mask=0xfffff7ff`) | 5 | 0 | none |

The hangs came in runs (four in a row, then four good boots, then one), so the rate is uneven;
at the overall rate, 5 good boots in a row with VPE off would happen by chance about 2% of the time.
Not seen: without `boot_verbose` (one boot, typing at the console included), without any IOMMU (one boot with `boot_verbose`),
or with DMA remapping on as well (`hw.iommu.dma=1`, two boots, both without `boot_verbose`). A kernel with a debug log in `amdiommu_map_msi_intr()`
did not hang in 4 boots, so timing matters. Not known: why powering down the VPE hangs the SMU only with id-mapped contexts.
Workaround: `hw.amdgpu.ip_block_mask=0xfffff7ff`; the VPE is a video post-processing engine, and nothing that uses it on FreeBSD is known.

Framework Desktop, 2026-11-16: AMD Ryzen AI Max+ 395 (Strix Halo), IOMMU 1022:1508 at 0:0:2, capability header `0x190b640f`,
NPU 1022:17f0 at pci0:194:0:1 with the amdxdna port (drm-kmod branch `olivier-amdxdna`, "carveout" mode: NPU buffers in one physically contiguous region,
firmware DMA by physical address). Kernel 6871285f194d plus both amdiommu patches and a LinuxKPI SRCU patch; no display attached.

| Kernel | Tunables | NPU firmware round trips (CREATE_CONTEXT / MAP_HOST_BUFFER / DESTROY_CONTEXT) | `xrt-smi validate` | Other |
|---|---|---|---|---|
| stock, IOMMU off | none | about 141 ms / 142 ms / 142 ms (476 us for the first CREATE_CONTEXT only) | latency test about 95 ms per job | |
| patched | `hw.amdiommu.enable=1` | 169 us / 73 us / 119 us | gemm 51.0 TOPS, latency 49.0 us, throughput 93777 ops/s, all PASSED | all contexts "id-mapped", e.g. `amdxdna0: amdiommu0 pci0:194:0:1 rid c201 domain 11 id-mapped`; 0 IOMMU events; amdgpu loads |
| patched | `hw.amdiommu.enable=1 hw.iommu.dma=1 hw.busdma.pci0.194.0.1=bounce hw.busdma.pci0.193.0.0=bounce` | 160-224 us / 91-110 us / 130-134 us | gemm 51.0 TOPS, latency 47.0 us, throughput 93807 ops/s, all PASSED | NPU and GPU pass-through, other devices "re-mapped"; 0 IOMMU events |

The NPU firmware only needs the IOMMU unit on; its own DTE is in pass-through (mode 0) in both patched boots.
Upstream Linux refuses to run amdxdna without an IOMMU (a8878e19d2f5, "The AIE2 device firmware requires IOMMU on").
Why the firmware is slow with the unit off is not known.
The stock kernel with `hw.amdiommu.enable=1` was not booted on this machine; the loop is expected, as on the SER6 and the ZBook.

Not tested:

- The event log in the failing case: the console was unusable, and no capture could be saved.
- Intel, arm64 and riscv machines (code path not reached there, see Fix).
- bhyve passthrough, suspend and resume.
