03e4f31f69e049c55cee05641e59a35f038772b8 ("linuxkpi: Let a killed process leave a retried fault")

PR: https://ron-dev.freebsd.org/FreeBSD/src/pulls/131 (opened 2026-11-23, rebased on 0df9a2d94988).
Local branch olivier-lkpi-fault-killable: 67983f3451e2 = the pushed commit + `Pull Request:` trailer (not pushed yet).
Tutorial: ../linuxkpi_fault_killable.md. Test kit: ../linuxkpi_fault_repro/.

Status 2026-11-26: redesigned as kib suggested (comment 1766): the retries are bounded in time, as
vm_fault does for page allocation, with no signal or flag check. Local commit 70e3488d070b
("linuxkpi: Bound the retries of a fault handler that inserts no page"), tested; to push with
`git pr main -f`, and the PR title and description to replace in the web UI (linuxkpi_fault_killable.pr.md).

## Review thread

- imp (2026-11-23): "seems reasonable to me, but I'd like to see what others think."
- kib (1714): suggested `P_KILLED(p) || (p->p_flag & P_WEXIT) != 0`.
  Answered with the kgdb flags of the hung case (tutorial section 3): after kill -9, P_WKILLED=0, P_WEXIT=0,
  P2_WEXIT=1, SIGKILL already taken. Mistake in that answer: offered P_SINGLE_EXIT as an exit flag.
- kib (1719): "P_SINGLE_EXIT is wrong, it is not for exit at all. P2_WEXIT instead of P_WEXIT is fine.
  One of my points is that you should not check signals in the queue, only p_flag and p_flag2."
  No reason given. My guess from the code (not his argument): under ptrace, sigprocess() sends SIGKILL
  through ptracestop() and the debugger can discard it.
- Answered with the spin measurement below and asked for his reason.
- kib (1723): "It is (almost) never correct to check the signal queue anywhere but in kern_sig.c. The signal
  delivery might find a lot of reasons to ignore or block signal, or take some action not related to killing.
  So the real bug there is spinning in kernel, and perhaps the problem is that when the page cannot be inserted
  into the object queue, then some other error should be returned that does not re-enter the populate handler."

## Measurement: exit conditions against kill -9

bhyve guest, lkpi_fault.ko mode 3 (handler returns VM_FAULT_NOPAGE, inserts nothing), spin_test, one run per
case; kernels = 6dc19a71f70c + the condition only.

| kill -9 while spinning | stock | queue + P2_WEXIT (PR) | P_KILLED or P2_WEXIT | + untraced curproc_sigkilled() |
|---|---|---|---|---|
| single-threaded | alive | gone 1 s | alive | gone 1 s |
| 2 threads, worker spins | alive | gone 1 s | gone 1 s | gone 1 s |
| 2 threads, main spins | alive | gone 1 s | alive | gone 1 s |

A plain kill -9 sets no p_flag/p_flag2 bit (tdsendsignal() queues and calls tdsigwakeup() on the sigtd() thread);
when that thread is the spinning one nothing reaches sigexit(), so P2_WEXIT never comes. Flags only cannot
cover it; the last column reads the queue, which kib's rule excludes.

## Redesign asked by kib: fail the refusal

- lkpi_vmf_insert_pfn_prot_locked(): on "page rename failed: page is mapped", record the refusal and return
  an error instead of VM_FAULT_NOPAGE.
- linux_cdev_pager_populate(): stop retrying when the refusal is recorded, release the pages inserted in this
  fault, return VM_PAGER_ERROR (SIGSEGV). Drop the P2_WEXIT / fatal_signal_pending() test.
- A channel beside the return code is needed: TTM turns an insert error on the faulting page into
  VM_FAULT_NOPAGE (ttm_bo_vm_fault_reserved(), as Linux does), so the error alone would still loop.
  Candidate: a field at the end of struct vm_area_struct. Populate only sees vmas LinuxKPI allocates, but
  drm-kmod builds one on the stack in dma_buf_mmap_fileops(): ask kib which channel he wants.
- The error must fail the fault and release busied pages: that is olivier-lkpi-fault-sigbus (2ab5dfbba783,
  ../linuxkpi_fault_sigbus.md). It becomes a prerequisite or merges into this PR.
- Lost: the generic escape for a dying process. A handler that returns NOPAGE forever without trying an
  insert would again be unkillable; no such permanent case is known (i915 -EBUSY/-EAGAIN and TTM lock
  contention are transient).

## Is the refusal transient?

Yes, in the code. The page frees itself when:
1. the other mapping is unmapped (munmap, exit): vm_map_delete() removes pmap entries before the entry and
   object go; linux_cdev_pager_dtor() then needs the faulting process's mmap_sem, but the page is already
   unmapped, so the loop ends first (no deadlock);
2. the driver revokes it: i915 __i915_gem_object_put_pages() -> i915_gem_object_release_mmap_offset() ->
   unmap_mapping_range() -> cdev_mgtdev_pager_free_pages() (shrink, evict, purge, when unpinned;
   vm_fault_cpu() unpins between retries), object free; TTM on a move.
Another source of refusals: the legacy I915_GEM_MMAP ioctl maps the shmem object directly
(i915_gem_mman.c:162); a GEM mmap_offset fault on a page it maps is refused while it lives.

So failing at once changes behaviour: a fault that today succeeds after spinning (short-lived other mapping)
would get SIGSEGV. In the measured case (Intel media driver, Raptor Lake) the other mapping lives as long as
the surface, so it never frees. Frequency of the short-lived case: unknown, no workload found.

Options for kib: fail at once, or retry for a bounded time then fail (still spins briefly; needs a limit).

- Posted the transient-conflict caveat (1724) and asked: fail at once or bounded retry?
- kib (1766): "Might be look at the oom handling in vm_fault.c (vm_pfault_oom_attempts and vm_pfault_oom_wait)
  as an inspiration? Looping in kernel relying on userspace to do some action is basically a user-controlled
  livelock."

## Bounded retry (implemented)

- compat.linuxkpi.fault_retry_timeout (seconds, CTLFLAG_RWTUN): 0 fails at once, -1 retries forever.
- First retry yields, later retries pause one tick; at the deadline the fault fails (VM_PAGER_ERROR, SIGSEGV)
  with one rate-limited log line.
- Default 30 s, justified in the tutorial section 3.1: no retry in 389,768 faults on three GPUs (DTrace), so
  normal use is unaffected; the longest legitimate wait is a TTM buffer move, ended by amdgpu's 10 s kernel
  job timeout plus an unmeasured reset; 3 x 10 s, as vm_fault's OOM give-up.
- Tests (tutorial section 5): VM reproducer NODEBUG and WITNESS; NUC (WITNESS) stuck encode -> SIGSEGV after
  31 s, kill -9 effective at the deadline, 0 LOR; Carbon and ZBook regression unchanged.

## Earlier draft reply (superseded)

> Thanks, understood: no queue checks outside kern_sig.c. I'll drop the P2_WEXIT/signal test and make the
> refusal fatal instead: when lkpi_vmf_insert_pfn_prot_locked() cannot move a page mapped by another object,
> it records that in the vma and returns an error, and linux_cdev_pager_populate() stops retrying when it sees
> it, releases the pages inserted in this fault, and fails the fault (VM_PAGER_ERROR). A flag is needed
> because TTM turns an insert error on the faulting page into VM_FAULT_NOPAGE, so the return code alone would
> still loop. Is a field at the end of struct vm_area_struct acceptable for that, or would you prefer another
> channel?
>
> One caveat on failing immediately: the refusal is not always permanent. The page frees itself when the other
> mapping is unmapped (vm_map_delete() removes the pmap entries before dropping the object) or when the driver
> revokes it (i915 put_pages -> release_mmap_offset -> cdev_mgtdev_pager_free_pages(); TTM on a move), and none
> of these waits on the faulting thread. Today such a fault succeeds after spinning; with an immediate error it
> would get SIGSEGV. In the case I hit the other mapping lives as long as the surface, so it never frees.
> Would you accept failing at once, or prefer a bounded retry before failing?
