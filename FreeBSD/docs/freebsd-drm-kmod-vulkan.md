# FreeBSD drm-kmod Vulkan — large-model load limit on Strix Halo

Investigation of a load-time hang when trying to run a 106 GB GGUF model
(`jedisct1/MiMo-V2.5-coder-Q2-v2`, 309 B params MoE, Q2_K_S) through
`llama-server --device Vulkan0` on FreeBSD 16.0-CURRENT with the
`ocochard/drm-kmod` `strix` branch and Mesa 25.2.8 RADV.

The host has 128 GB UMA LPDDR5x; the model is 106 GB on disk. Same hardware
running Ubuntu loads larger models without issue (see `MODEL=big` =
Qwen3.5-397B-A17B IQ2_XXS in `LLM/llmsrv.sh`). This document records what
went wrong on FreeBSD, how it was diagnosed, and the options for fixing or
working around it.

## Symptom

`llama-server` starts, prints the device-info banner, prints
`load_model: loading model …`, then **hangs at 99 % single-thread CPU with no
further log output**. Process stays alive indefinitely (observed past 16 min
CPU time in one run); port 8090 binds but never accepts. No error is emitted.

The same llama.cpp build (`b0df4c0cf`, version 9297) loads the
Qwen3.6-35B-A3B and Qwen3.6-27B models on the same host in seconds.

## Setup that triggered it

- Host: `framework` — Framework Desktop, AMD Ryzen AI MAX+ 395 (Strix Halo),
  Radeon 8060S iGPU (gfx1151), 128 GB LPDDR5x UMA.
- OS: FreeBSD 16.0-CURRENT (kernel `main-n285626-9c18d55a768a`).
- GPU stack: `ocochard/drm-kmod` `strix` branch, Mesa 25.2.8 RADV,
  vulkan-loader 1.4.349.
- llama.cpp: `b0df4c0cf` built with Clang 21.1.8.
- Model: `jedisct1/MiMo-V2.5-coder-Q2-v2` — 309 B params MoE, Q2_K_S quant,
  16-shard GGUF, 106 GB total.
- BIOS UMA frame buffer: small (~512 MiB) — i.e. the GPU sees ~120 GB of GTT.
- ZFS ARC: capped at 8 GB before the load attempt; `vmstat` showed
  110+ GB free at start.

Invocation (after a few iterations):

```sh
build/bin/llama-server \
  -hf jedisct1/MiMo-V2.5-coder-Q2-v2 \
  --fit off --no-mmproj --no-warmup \
  --device Vulkan0 --flash-attn on --jinja \
  --batch-size 2048 --ubatch-size 512 \
  --ctx-size 4096 --parallel 1 \
  --cache-type-k f16 --cache-type-v f16
```

`--fit on` was tried first and produced the same hang at the same point;
the fit step itself was not the bottleneck. Reducing `--ctx-size` from
32768 → 4096 made no difference either.

## Diagnosis

`procstat -k` on the busy thread revealed the kernel stack:

```
ttm_tt_swapout
ttm_bo_swapout
ttm_device_swapout
ttm_global_swapout
ttm_tt_populate
ttm_bo_vm_fault_reserved
amdgpu_gem_fault
linux_cdev_pager_populate
vm_fault_allocate
vm_fault
vm_fault_trap
trap_pfault
```

The working thread is page-faulting on a GPU buffer (`amdgpu_gem_fault`); to
satisfy the fault, TTM (the Linux GPU Translation Table Manager) evicts
another buffer via `ttm_*_swapout`; the just-evicted buffer is needed next,
so it faults back in. **An infinite TTM swap loop.**

Concurrent observations:

- `iostat`: bursty disk reads (~16 MB/s for ~1 s every few seconds, then
  idle) — consistent with the loop occasionally re-reading evicted weights
  from the GGUF, not a steady linear scan.
- `vmstat`: page-in rate ~2 MB/s sustained, free RAM oscillating
  2.8–3.4 GB. The system is paging continuously even though it has 100+ GB
  of nominally free RAM — TTM's working set is the constraint, not VM
  pressure.
- All other llama-server threads sleeping in `uwait`, waiting on the
  single thread that's stuck in the swap loop.

The 120 GB "free" reported by `llama-server --list-devices` is the
theoretical GTT max addressable through `amdgpu`; the actual TTM working
window appears far smaller.

## Why FreeBSD-specifically

drm-kmod is not a native FreeBSD driver — it's the Linux `amdgpu` and
`drm` code running on top of `LinuxKPI` (a Linux-API-emulation layer in the
FreeBSD kernel). For TTM specifically, the bridge is
`linux_shmem_read_mapping_page_gfp` and friends in LinuxKPI.

On Linux, `ttm_tt_swapout` evicts GPU buffers to a **shmem-backed swap
pool** (anonymous memory backed by tmpfs / swap). The pool is sized
dynamically based on system RAM and `vm.swappiness` policy. On FreeBSD,
this is emulated — the shmem layer is a thin shim over FreeBSD's VM
`vm_object` system, and the swappiness / pool-sizing knobs don't exist or
behave differently.

When a model exceeds the *currently resident* GPU memory window, Linux
quietly grows the shmem swap pool and demand-pages weights. FreeBSD's shim
does not have the same elasticity — it tries to swap but the new
allocations contend with the eviction, creating a livelock.

This is consistent with the observation that smaller models (≤30 GB) load
fine on this exact stack, and that the same hardware running Ubuntu
(`framework2`) loads `MODEL=big` (Qwen3.5-397B-A17B, 130+ GB on disk) without
issue.

## What a fix would mean

There is no single bug to patch. The work needed is in roughly this order.

### 1. Confirm the diagnosis

- Reproduce on `framework2` (Ubuntu) to bound the problem. If Linux loads
  the same model on the same hardware, the bug is FreeBSD-specific (driver
  / LinuxKPI), not in llama.cpp or the GGUF.
- Add tracing to `ttm_global_swapout` in drm-kmod and count loop
  iterations. Truly infinite, or just slow?
- Rule out alternatives: TTM pool-size limit hit, GTT eviction priority
  inverted, LinuxKPI shmem allocator stalling under pressure.

### 2. Identify the actual upstream divergence

drm-kmod tracks Linux 6.12. Diff the relevant FreeBSD sources against
Linux mainline at that tag:

- `sys/compat/linuxkpi/common/src/linux_shmem.c` (FreeBSD base) vs.
  `mm/shmem.c` (Linux) for the shmem-backed swap behavior.
- `sys/dev/drm/ttm/ttm_tt.c` and `ttm_bo.c` in drm-kmod vs.
  `drivers/gpu/drm/ttm/ttm_tt.c` / `ttm_bo.c` in Linux 6.12.

Look for:

- Swap-out batching (Linux does N pages per call; FreeBSD might do 1).
- Watermarks / pool size caps (`ttm_global_state` fields).
- Eviction priority handling (`ttm_resource_manager` ordering).

### 3. Where a fix could land

- **LinuxKPI** in FreeBSD base (`sys/compat/linuxkpi/`) — if the shmem shim
  is the culprit. Patching this affects every drm-kmod consumer.
- **drm-kmod** TTM shim (the `freebsd/drm-kmod` or `ocochard/strix`
  repo) — if the divergence is TTM-internal.
- **FreeBSD VM** (`sys/vm/`) — if the underlying `vm_object` semantics are
  too rigid (e.g., no per-object reclaim priority).

### 4. Workarounds (easier than fixing)

- **CPU-only inference**: omit `--device Vulkan0`. The model loads via
  regular mmap; no TTM at all. Slow but proves the model itself is loadable
  on the host.
- **Stay within the working-set limit**: ≤30 GB models load fine on this
  stack. `MODEL=moe` / `moe-q8` in `LLM/llmsrv.sh` is the sweet spot.
- **Use Linux for the big models**: `framework2` already runs
  `MODEL=big` / `MODEL=med`. Use FreeBSD for what fits, Linux for what
  doesn't.
- **Larger BIOS UMA carve-out**: counterintuitive, but a *bigger* VRAM
  region gives TTM a real "VRAM" pool to fault into without going through
  GTT/shmem. The trade-off is severe: `LLM/benches.FrameWork-Desktop.md`
  shows a 64 GiB carve-out tanks PP by ~31 % on smaller models. Not
  recommended unless you really need this specific model on this OS.

## Recommended next steps

If you want this fixed upstream rather than worked around:

1. **Reproduce on `framework2`** to confirm the bug is FreeBSD-specific.
2. **File a drm-kmod bug** at https://github.com/freebsd/drm-kmod with the
   kernel stack and a minimal reproducer (the llama-server invocation and
   the model URL). The maintainers (e.g. Emmanuel Vadot, `manu@`) will know
   whether this is a known limitation or a fresh report.
3. **Cross-post / mailing list**: `freebsd-x11@` for drm-kmod,
   `freebsd-current@` for LinuxKPI issues.

Fixing it yourself is multi-week work in a tricky part of the kernel:
bisecting drm-kmod TTM against Linux mainline, writing a test case, and
convincing maintainers. Realistic only if you specifically want this
capability on FreeBSD.

## Pragmatic recommendation

The Framework Desktop's value on FreeBSD is the ~6–31 % PP speedup on
dense models that fit comfortably (per
`LLM/benches.FrameWork-Desktop.md`), not the ability to load
100+ GB models. For those, the same hardware running Ubuntu is the right
tool, and `LLM/llmsrv.sh` already auto-routes them there via
`MODEL=big` / `MODEL=med` which are gated to `OS = Linux`.

Treat ~30 GB as the comfortable upper bound for Vulkan models on
FreeBSD + drm-kmod until / unless this is fixed upstream.
