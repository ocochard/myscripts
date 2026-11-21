# Which GPU gets the console with two GPUs

How FreeBSD decides which GPU shows the boot screen and the vt(4) console when a machine has more than one,
and what can be changed.
Sources: FreeBSD main (`sys/dev/vt/vt_core.c`, `sys/dev/pci/vga_pci.c`, `sys/kern/subr_bus.c`),
drm-kmod 6.12.85 (`drivers/gpu/drm/linux_fb.c`, `vt_drmfb.c`).
Measured on bigone and carbon (both FreeBSD main-n291299, 2026-11-17 kernel) on 2026-11-21.

## Four layers, four choices

| Stage | Who decides | How to control it |
|---|---|---|
| Firmware, loader, early console (efifb) | UEFI: the GPU whose GOP driver it uses | BIOS setup (onboard or add-in display), and which output the monitor is on |
| vt console after a DRM driver loads | The first DRM driver that registers a framebuffer | Attach order, `hw.dri.fbdev_emulation=0`, or not loading the DRM driver |
| `/dev/dri/cardN` numbering | Attach order (`drmn0`, `drmn1`) | Same |
| X, Wayland, Vulkan, CUDA | Userland | `BusID` in xorg.conf, compositor device option, `--device VulkanN`, `MESA_VK_DEVICE_SELECT`, `CUDA_VISIBLE_DEVICES` |

### vt(4): the first DRM framebuffer wins

`vt_allocate()` (`vt_core.c`) replaces the current console driver only if the new one has a higher priority:

```c
if (drv->vd_priority <= main_vd->vd_driver->vd_priority) {
	printf("VT: Driver priority %d too low. Current %d\n ", ...);
	return (EEXIST);
}
```

`efifb` has `VD_PRIORITY_GENERIC + 1`; drm-kmod's `vt_drmfb` has `VD_PRIORITY_GENERIC + 20`.
So the first DRM driver to register a framebuffer takes the console from efifb,
and the second one gets `EEXIST` and logs "not attached to vt(4) console; another device has precedence" (`linux_fb.c`).
DRM drivers attach in newbus order, which follows PCI enumeration: a GPU behind a lower-numbered root port usually comes first.

### What does not choose the console

`hw.pci.default_vgapci_unit` (`vga_pci.c`) sets the "boot display" seen by `vga_pci_is_boot_display()`.
Nothing in drm-kmod calls it.
It only decides whether the video BIOS is read from the 0xC0000 shadow copy and whether `vgapci` prints "Boot video device".
Without the tunable, a GPU counts as boot display only if its Command register decodes I/O and memory
and its parent bridge has VGA Enable (Bridge Control bit 3) set.
On UEFI without CSM, bridges usually leave VGA Enable clear, so no GPU qualifies.

There is no per-device blacklist for a DRM driver and no equivalent of Linux's `boot_vga`.

### What does work

- `hint.vgapci.N.disabled=1` in `/boot/loader.conf`: `device_attach()` (`subr_bus.c`) skips that `vgapci`,
  so no driver attaches to that GPU at all, compute included. Only useful to hide a GPU.
- `hw.dri.fbdev_emulation=0`: no DRM framebuffer on any GPU, so the console stays on efifb, the GPU the firmware picked.
  Global, not per GPU.
- Not loading the DRM driver for a GPU that should not take the console.

## bigone: ASPEED BMC and NVIDIA GT 1030

| pciconf | Address | Device | Behind |
|---|---|---|---|
| vgapci0 | `pci0:1:0:0` | NVIDIA GT 1030 (10de:1d01), `nvidia0` | root port `0:1:1` |
| vgapci1 | `pci0:3:0:0` | ASPEED BMC display (1a03:2000) | ASPEED bridge `2:0:0`, root port `0:3:1` |

### The firmware picked the BMC

Framebuffer base of the live console, read with `kgdb /boot/kernel/kernel /dev/mem`:

```
(kgdb) p/x local_info.fb_pbase
$1 = 0xf9000000
(kgdb) p main_vd->vd_driver->vd_name
$4 = "efifb"
```

`0xf9000000` is ASPEED BAR 0 (`vgapci1: ... mem 0xf9000000-0xf9ffffff`).
The console is the UEFI framebuffer on the BMC, seen through the BMC KVM, plus the serial console (`console="eficom,efi"`).
The 800x600 resolution (`VT(efifb): resolution 800x600`) is the mode the firmware set on the ASPEED.
The loader has `efi_max_resolution="1x1"`: `gop_autoresize()` (`stand/efi/loader/framebuffer.c`) finds no GOP mode that fits,
so it calls no `SetMode()` and keeps the firmware's mode. It does not ask for the smallest mode.

### FreeBSD's boot display test picks neither

| Register | Device | Value | Meaning |
|---|---|---|---|
| Command (0x04) | NVIDIA `1:0:0` | 0x0407 | I/O and memory decoding on |
| Command (0x04) | ASPEED `3:0:0` | 0x0003 | I/O and memory decoding on |
| Bridge Control (0x3e) | root port `0:1:1` | 0x0012 | VGA Enable off |
| Bridge Control (0x3e) | root port `0:3:1` | 0x0012 | VGA Enable off |
| Bridge Control (0x3e) | ASPEED bridge `2:0:0` | 0x0010 | VGA Enable off |

No bridge forwards legacy VGA, so `hw.pci.default_vgapci_unit` stays -1 and `dmesg` has no "Boot video device" line.

### The NVIDIA never takes the console

`kld_list` loads `nvidia-modeset`, which pulls in `nvidia`; neither registers a framebuffer, so efifb keeps vt.
Loading `nvidia-drm` with modeset and fbdev enabled should move the console to the GT 1030 outputs
through the same `vt_allocate()` priority rule. Not tested.

### Xorg

`/usr/local/etc/X11/xorg.conf.d/device-nvidia.conf` (2021) pointed at an RTX 3070 with `BusID "PCI:193:0:0"`;
the GT 1030 is at `PCI:1:0:0`. Fixed on 2026-11-21 (old file kept as `device-nvidia.conf.2021`).
Xorg needs the explicit `BusID` here: without it the server may pick the ASPEED.
Not tested: Xorg does not run on bigone at the moment.

## carbon: one Intel GPU, for comparison

ThinkPad X1 Carbon, Meteor Lake-P iGPU (8086:7d45) at `vgapci0`, `pci0:0:2:0`, directly on the root bus.

| Check | Result |
|---|---|
| `dmesg` | `vgapci0: Boot video device`, `VT(efifb): resolution 2880x1800` |
| `hw.pci.default_vgapci_unit` | 0 (set by the boot display test, not by a tunable) |
| Command register | 0x0007: I/O and memory decoding on |
| `kgdb`: `local_info.fb_pbase`, `main_vd->vd_driver->vd_name` | 0x90800000, `efifb` |

The boot display test passes here: the GPU decodes I/O and memory, and it sits on bus 0, so no bridge VGA Enable bit is needed.
The same `efi_max_resolution="1x1"` gives 2880x1800: the firmware had set the panel's native mode, and the loader kept it.

The framebuffer base is not in a `vgapci0` BAR (0x4000000000 and 0x4058000000):
the Intel GOP scans out of stolen system memory. Matching `fb_pbase` against BARs identifies the GPU only for cards that scan out of their own VRAM, as the ASPEED does.

`i915kms` is not loaded now (commented out in `kld_list`).
When it was loaded on 2026-11-17, `/var/log/messages` shows the vt rule at work:

```
kernel: [drm] Initialized i915 1.6.0 for drmn0 on minor 0
kernel: VT: Replacing driver "efifb" with new "drmfb".
```
