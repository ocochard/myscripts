# FreeBSD kernel facts verified in past work

Facts that cost a measurement or a reviewer's correction to get right. Each
has its source and how it was verified. Re-check against the current tree
before relying on one (line numbers drift): these were read on main
d34baf1b5ca0 (2026-11). Add a fact only once it is proven by code reading
plus a measurement or a reviewer's statement, and say which.

## Process exit and signals

Use when kernel code must decide that a process is dying, e.g. to leave a
retry loop.

Reviewer rules (kib, PR 131):
- "It is (almost) never correct to check the signal queue anywhere but in
  kern_sig.c. The signal delivery might find a lot of reasons to ignore or
  block signal, or take some action not related to killing." Decide from
  p_flag/p_flag2 only; this rules out `curproc_sigkilled()` and LinuxKPI's
  `fatal_signal_pending()` outside kern_sig.c too.
- "The real bug there is spinning in kernel": when a kernel loop cannot make
  progress, make the failing operation return an error that ends the loop,
  rather than adding an escape condition to the loop.

| Fact | Source | Verified by |
|---|---|---|
| `exit1()` sets `P2_WEXIT` (`proc_set_p2_wexit()`) first, then `thread_single(p, SINGLE_EXIT)`, and `P_WEXIT` only after the other threads have exited | kern/kern_exit.c | kgdb on a hung process: `P2_WEXIT=1 P_WEXIT=0` while the exiting thread waits in `thread_single()` |
| `sigexit()` also sets `P2_WEXIT`, before a core dump single-threads the process | kern/kern_ucoredump.c | code |
| Once `P2_WEXIT` is set, `sigprocess()` ignores every signal ("no sense in delivering any signal to usermode") | kern/kern_sig.c | code |
| `P_WKILLED` (`P_KILLED()`) is set only by `proc_wkilled()`: from `killproc()` (OOM, rlimit) and `ptrace(PT_KILL)`. A plain `kill -9` never sets it | kern/kern_sig.c, kern/sys_process.c | kgdb: `P_WKILLED=0` after `kill -9` |
| `P_SINGLE_EXIT` is not an exit indicator; do not test it for "dying" | kib, PR 131 | reviewer |
| A plain `kill -9` changes no process flag: `tdsendsignal()` queues SIGKILL and calls `tdsigwakeup()` on one thread, chosen by `sigtd()` (curthread if in the process, else the first thread not masking it, usually the main thread) | kern/kern_sig.c | code + VM test below |
| `tdsigwakeup()` interrupts only a thread sleeping interruptibly (`TDF_SINTR`); a running or uninterruptibly sleeping thread sees the signal at its next user boundary | kern/kern_sig.c | code |
| A queued SIGKILL is not final for a traced process: `sigprocess()` sends every signal, SIGKILL included, through `ptracestop()`, and the debugger can discard it | kern/kern_sig.c | code |
| `curproc_sigkilled()` (kib, 2021) checks SIGKILL in the thread and process queues, only when the current thread has `TDA_SIG` pending; the core dump writer uses it to stop its `vm_fault()` loop | kern/kern_sig.c, kern/kern_exec.c | code |
| Consequence: a kernel loop that tests only `P_KILLED() || P2_WEXIT` stays unkillable when SIGKILL lands on the looping thread itself (single-threaded process, or the main thread looping) | | VM test: LinuxKPI test module, `FreeBSD/docs/linuxkpi_fault_repro/` (mode 3, spin_test) |

## VM fault path and device pagers

| Fact | Source | Verified by |
|---|---|---|
| A pager's populate method answers `VM_PAGER_OK` (pages inserted and exclusive-busy, the VM maps and unbusies them), `VM_PAGER_BAD` ("request normal fault handling") or anything else (fault fails: `FAULT_FAILURE`, user gets SIGSEGV `SEGV_MAPERR`) | vm/vm_fault.c `vm_fault_populate()` | code |
| On a populate failure `vm_fault_populate()` returns at once: pages the pager busied are never released by the VM | vm/vm_fault.c | VM test: next fault sleeps forever, survives SIGKILL |
| Only `KERN_OUT_OF_BOUNDS` and `KERN_RESOURCE_SHORTAGE` become SIGBUS; a populate failure cannot give SIGBUS without a VM change | vm/vm_fault.c `vm_fault_trap()` | code |
| `OBJT_DEVICE` and `OBJT_MGTDEVICE` objects get `OBJ_FICTITIOUS`; the ELF core dump skips such mappings | vm/vm_object.c, kern/imgact_elf.c | code |
| Fictitious pages are `VPO_UNMANAGED` (`vm_page_initfake()`); `pmap_remove_all()` asserts on unmanaged pages | vm/vm_page.c, amd64/amd64/pmap.c | code |
| `vm_page_remove()` needs the object lock and the page exclusive-busy, and releases the busy state itself | vm/vm_page.c | code |
| A page belongs to one VM object only (`m->object`); the same page cannot be in two mappings' objects | vm/vm_page.h | kgdb: one GEM object mapped WB and WC, second fault loops |

## LinuxKPI mmap and faults

| Fact | Source | Verified by |
|---|---|---|
| A LinuxKPI mmap with a `fault` handler gets an `OBJT_MGTDEVICE` object; the driver's `mmap` must set `vm_ops` with `open`, `close` and a unique `vm_private_data` | compat/linuxkpi/common/src/linux_compat.c `linux_file_mmap_single()` | test module |
| `linux_cdev_pager_populate()` holds the LinuxKPI `mmap_sem` (sx, write) around the handler; the VM map lock is already dropped | linux_compat.c, vm/vm_fault.c | code + WITNESS run, no LOR |
| It retries the handler while it returns `VM_FAULT_NOPAGE` with nothing inserted (`vm_pfn_count == 0`), with `kern_yield()` and no signal check | linux_compat.c | measured: unkillable spin |
| It translated `VM_FAULT_SIGBUS` to `VM_PAGER_BAD`: the normal path then zero-fills a page (the LinuxKPI pager has no `cdev_pg_fault`) | linux_compat.c, vm/device_pager.c | VM test: reads `0x00`, no signal |
| `lkpi_vmf_insert_pfn_prot_locked()` moves a page out of its current object; if that object still maps it, it prints "page rename failed: page is mapped" and returns `VM_FAULT_NOPAGE` without counting the page | compat/linuxkpi/common/src/linux_page.c | measured (Intel media driver, Raptor Lake) |
| That refusal is not always permanent. It clears when the other mapping is unmapped (`vm_map_delete()` calls `pmap_map_delete()` before the entry and its object go, and object teardown is deferred until after the map lock is dropped) or when the driver revokes it (`unmap_mapping_range()` -> `cdev_mgtdev_pager_free_pages()`: i915 `__i915_gem_object_put_pages()` on shrink/evict/purge when unpinned, object free; TTM on a move). None of these waits on the faulting thread | vm/vm_map.c, linux_page.c, drm-kmod i915 gem/i915_gem_pages.c, gem/i915_gem_object.c | code |
| `linux_cdev_pager_dtor()` takes `down_write()` on the mapping owner's `mmap_sem`; a thread looping in populate holds that lock for its own process, but the dtor runs after the pages are unmapped, so the loop ends first | linux_compat.c | code |
| FreeBSD's legacy `I915_GEM_MMAP` ioctl maps the BO's shmem object directly (`vm_map_find(map, obj->base.filp->f_shmem, ...)`), so a shmem page can be mapped outside any device pager | drm-kmod gem/i915_gem_mman.c | code |
| drm-kmod builds its own `struct vm_area_struct` on the stack in `dma_buf_mmap_fileops()`: a field added to that struct is not always allocated by LinuxKPI (that vma never reaches the populate path) | drm-kmod drivers/dma-buf/dma-buf.c | code |
| TTM turns an insert error on the first page into `VM_FAULT_NOPAGE` ("Never error on prefaulted PTEs") | drm-kmod ttm/ttm_bo_vm.c | code |
| populate never sets `FAULT_FLAG_ALLOW_RETRY`, so TTM does not drop `mmap_sem` in its reserve path | drm-kmod ttm_bo_vm.c, linux/mm.h | code |
| i915 `vm_fault_gtt()`: a failed `remap_io_mapping()` unpins the GGTT vma without adding it to `userfault_list` | drm-kmod gem/i915_gem_mman.c | code (review finding) |

## Tools for this area

- `FreeBSD/docs/linuxkpi_fault_repro/`: LinuxKPI test module whose fault handler inserts, fails with SIGBUS, inserts then fails, or returns NOPAGE forever; `fault_test` and `spin_test` drive it in a bhyve guest (`FreeBSD/kern-test-vm`). Use it to measure any change to the LinuxKPI fault path before testing on GPU hardware.
- Reading live process flags: `kgdb /usr/lib/debug/boot/kernel/kernel.debug /dev/mem` with a script that walks `allproc` (see `FreeBSD/docs/linuxkpi_fault_killable.md`).
