# amdiommu: hw.amdiommu.enable=1 alone breaks DMA of every MSI device

```
Category:  kern
Component: kern
Version:   16.0-CURRENT
```

Patch: [`iommu_idmap_when_dma_disabled.patch`](iommu_idmap_when_dma_disabled.patch) (`sys/dev/iommu/busdma_iommu.c`).
Branch: `olivier-amdiommu` on github.com/ocochard/freebsd-src.
Background for readers new to this code: [`amdiommu_ser6.md`](amdiommu_ser6.md), sections 1 and 3.1.

**Summary.** Setting only `hw.amdiommu.enable=1` leaves DMA remapping off (`hw.iommu.dma=0`) and interrupt remapping on (`hw.iommu.ir=1`).
In that mix, each device that sets up MSI gets a Device Table Entry that translates through an empty I/O page table,
while busdma keeps giving the device physical addresses. All its DMA is blocked.
On a Ryzen 7 7735HS the USB devices attach again and again, and the machine never reaches a usable shell.
The patch gives such contexts the identity mapping.

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
| patched | `hw.amdiommu.enable=1` (+ `boot_verbose`) | boots; `dev.amdiommu.0.ir: 1`, `dev.amdiommu.0.dma: 0`; GPU and Wi-Fi contexts "id-mapped"; NVMe, USB, Wi-Fi, keyboard (IOAPIC IRQ 1) and I2C (IRQs 3, 4, 6) all get their interrupts and work; no IOMMU event; but amdgpu's display stalls: repeated `flip_done timed out`, `commit wait timed out` and `DMCUB error`, the console redraws only every few seconds |
| patched | `hw.amdiommu.enable=1 hw.iommu.dma=1` | boots; no IOMMU event; no display error |

The display stall with interrupt remapping alone is a separate problem, not understood yet:
GPU interrupts do arrive (about 120/s on `vgapci0`), and the stall is gone once DMA remapping is on too.
The context count of the SER6 row could not be checked here: `boot_verbose` overflows the message buffer before syslog starts.

Not tested:

- The event log in the failing case: the console was unusable, and no capture could be saved.
- Intel, arm64 and riscv machines (code path not reached there, see Fix).
- bhyve passthrough, suspend and resume.
