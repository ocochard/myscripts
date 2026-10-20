# Intel MTL (Meteor Lake) — ANV rejects GPU on FreeBSD (drm-latest-kmod-6.12)

Status: root cause identified in kernel (i915) UAPI. Userspace works, kernel needs fix.

## Symptom

On carbon (FreeBSD 16.0-CURRENT, X1 Carbon MTL, i915:8086:7d45):

- `vulkaninfo --summary` lists only `llvmpipe` (software).
- `vkcube` runs on llvmpipe (or fails when no DISPLAY).
- Mesa emits: `MESA: warning: Could not get intel_device_info.`
- Vulkan loader then: `Removing driver /usr/local/lib/libvulkan_intel.so due to not having any physical devices`.

## Environment

- Kernel: FreeBSD 16.0-CURRENT n286843-75aadc902298 (bigone-built GENERIC-NODEBUG, 2026-06-22).
- drm-latest-kmod-6.12 (`~/freebsd-ports/graphics/drm-latest-kmod/work/drm-kmod-drm_v6.12/`), loaded as `i915kms.ko` + `drm.ko`. `[drm] Initialized i915 1.6.0`.
- mesa-libs 26.0.6, vulkan-loader 1.4.354, vulkan-tools 1.4.354, `libvulkan_intel.so` (ANV) present, api 1.4.335.
- GPU init OK per dmesg: DMC v2.23, GuC 70.53.0 loaded, `GT0: GUC: submission enabled`, `GT0: GUC: SLPC enabled`, `GT0: GUC: RC enabled`.
- `/dev/dri/card0`, `/dev/dri/renderD128` present, mode 0660 root:video; user in `video` group; both readable/writable.
- `hw.dri.0.busid = pci:0000:00:02.0`, `hw.dri.0.name = i915 0x83`.

## Root cause

Kernel side: i915 does not expose any UABI engines to userspace on MTL.

Direct DRM_IOCTL_I915_QUERY probes against `/dev/dri/renderD128` (from `/tmp/qtopo.c` and `/tmp/qgeom.c` on carbon):

```
TOPOLOGY_INFO        ioctl=0 errno=0 item.length=85
ENGINE_INFO          ioctl=0 errno=0 item.length=16   # header only, num_engines=0
MEMORY_REGIONS       ioctl=0 errno=0 item.length=104
HWCONFIG_BLOB        ioctl=0 errno=0 item.length=752
GEOMETRY_SUBSLICES   ioctl=0 errno=0 item.length=-22  # -EINVAL for every class 0..5
GETPARAM CS_TIMESTAMP_FREQUENCY=0 (ret=0 errno=0)
```

`ENGINE_INFO` returning `num_engines=0` means `for_each_uabi_engine()` iterates zero items => `intel_engine_lookup_user()` in `query_geometry_subslices()` returns NULL for any (class,instance) => `-EINVAL`.

`CS_TIMESTAMP_FREQUENCY=0` is a secondary red flag (should be non-zero for MTL).

Chain in userspace (`mesa-26.0.6/src/intel/dev/i915/intel_device_info.c`):

- `intel_device_info_i915_get_info_from_fd()` at :547 calls `query_topology()` at :563.
- `query_topology()` at :298 requires `DRM_I915_QUERY_GEOMETRY_SUBSLICES` when `verx10 >= 125` (MTL is 12.70 => 127).
- `intel_i915_query_alloc()` returns NULL on `item.length < 0` (`src/intel/common/i915/intel_gem.h:82`).
- => `query_topology()` returns false => `_get_info_from_fd()` returns false at :566 => warning at `src/intel/dev/intel_device_info.c:1926`.
- ANV physical device init fails => loader removes ICD.

## What was ruled out

- Permissions: user has R/W on `/dev/dri/renderD128`.
- ICD/loader: `intel_icd.x86_64.json` present and found by loader (`VK_LOADER_DEBUG=driver` shows it loaded, then removed after no phys devs).
- libdrm enumeration: `drmGetDevices2` returns `pci vendor=8086 device=7d45`, nodes card0 + renderD128 — fine.
- PCI probe: `PCIOCGETCONF` succeeds; ktrace shows Mesa reads it OK.
- `INTEL_DEVID_OVERRIDE=0x7d45` — doesn't help (fails before the override path is reached).
- vkcube's `DISPLAY unset` message is a red herring — that's just the windowing layer. The real fault is Vulkan enumeration.

## Kernel side of things (drm-latest-kmod-6.12)

MTL device entry (`i915_pci.c:763-786`):
```
static const struct intel_device_info mtl_info = {
    XE_HP_FEATURES,
    .__runtime.graphics.ip.ver = 12,
    .__runtime.graphics.ip.rel = 70,
    ...
    .has_gmd_id = 1,
    .platform_engine_mask = BIT(RCS0) | BIT(BCS0) | BIT(CCS0),
    ...
};
```

`query_geometry_subslices()` (`i915_query.c:101-125`):
- Guard `GRAPHICS_VER_FULL(i915) < IP_VER(12, 55)` — MTL is 12.70, passes.
- Calls `intel_engine_lookup_user(i915, class, instance)`; returns NULL => `-EINVAL`.

So the question is: why does `for_each_uabi_engine` yield nothing on MTL under this drm-kmod port?

Candidates to investigate next:
- Is `intel_engines_driver_register()` actually being called during i915 probe on FreeBSD? Grep for it in `drivers/gpu/drm/i915/gt/`.
- MTL uses GuC submission exclusively (`GT0: GUC: submission enabled` shown). Check if uabi-engine setup for GuC-submission-only platforms is stubbed/missing in the FreeBSD port.
- Compare Linux upstream vs `~/freebsd-ports/graphics/drm-latest-kmod/work/drm-kmod-drm_v6.12/drivers/gpu/drm/i915/gt/intel_engine_user.c` (or wherever `add_uabi_engine`/`sort_uabi_engines` lives) — see if any `#ifdef __linux__` fences drop the registration.
- Check `intel_ipver_early_init()` (`drivers/gpu/drm/i915/intel_device_info.c:324`) — did GMD_ID actually read back 12.70, or does something silently zero it?

## Reproduction (5 min)

On carbon:

```sh
# 1) Confirm ICD is loaded but returns no devices
VK_LOADER_DEBUG=driver vulkaninfo --summary 2>&1 | grep -iE "intel|removing driver"

# 2) Direct kernel probe (no Mesa)
cat > /tmp/qtopo.c <<'EOF'
#include <stdio.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <errno.h>
#include <stdint.h>
#include <libdrm/i915_drm.h>
int main(void) {
    int fd = open("/dev/dri/renderD128", O_RDWR|O_CLOEXEC);
    uint64_t ids[] = {
        DRM_I915_QUERY_TOPOLOGY_INFO, DRM_I915_QUERY_ENGINE_INFO,
        DRM_I915_QUERY_MEMORY_REGIONS, DRM_I915_QUERY_HWCONFIG_BLOB,
        DRM_I915_QUERY_GEOMETRY_SUBSLICES,
    };
    const char *n[] = { "TOPO","ENGINE","MEMREG","HWCONFIG","GEOM_SS" };
    for (int i = 0; i < 5; i++) {
        struct drm_i915_query_item it = { .query_id = ids[i] };
        struct drm_i915_query q = { .num_items = 1, .items_ptr = (uintptr_t)&it };
        int r = ioctl(fd, DRM_IOCTL_I915_QUERY, &q);
        printf("%-8s ret=%d errno=%d len=%d\n", n[i], r, errno, it.length);
    }
    return 0;
}
EOF
cc -I/usr/local/include -I/usr/local/include/libdrm /tmp/qtopo.c -o /tmp/qtopo && /tmp/qtopo
```

Expected (broken state): `ENGINE len=16` (header only), `GEOM_SS len=-22`.

## Next steps

1. Grep `intel_engine_user.c`, `intel_engines_driver_register()` call sites in drm-latest-kmod-6.12 for `__linux__` fences or missing calls.
2. Diff against Linux 6.12 upstream `drivers/gpu/drm/i915/gt/intel_engine_user.c` and `gt/intel_gt.c`.
3. Add a temporary `printk`/`drm_info` at engine registration to confirm whether it runs at all on MTL under this port.
4. If registration path runs but stops early, capture where.
5. Once engines surface, re-run `/tmp/qtopo` — `ENGINE num_engines > 0` and `GEOM_SS len > 0`, then `vulkaninfo` should list ANV / `Intel(R) Graphics (MTL)`.

## Artifacts

- `/tmp/qtopo.c`, `/tmp/qgeom.c` on carbon (both compile against `/usr/local/include/libdrm/i915_drm.h`).
- `/tmp/kt2.out` (ktrace of `vulkaninfo`), `/tmp/kdump.txt` (kdump text) on carbon.
- `/tmp/mesa-src/mesa-26.0.6/` on bigone (extracted `src/intel/`).

## Loose ends

- `CS_TIMESTAMP_FREQUENCY=0` from `DRM_IOCTL_I915_GETPARAM` — investigate whether MTL setup path in i915 (uncore/gt frequency init) sets `i915->gt->clock_frequency`. Distinct symptom, possibly same root (GT init incomplete for MTL under this port).
- vkcube's `DISPLAY unset` when run from ssh: unrelated. It only matters after ANV is fixed; then `DISPLAY=:0 vkcube` from an ssh shell (Xorg already running locally on carbon) should render on the Intel GPU.
