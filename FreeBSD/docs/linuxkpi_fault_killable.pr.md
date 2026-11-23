linuxkpi: Let a killed process leave a retried fault

linux_cdev_pager_populate() calls the driver's fault handler again for as
long as it returns VM_FAULT_NOPAGE without inserting a page. When the page
can never be inserted, the thread spins in the kernel forever and kill -9
cannot end the process: the thread that takes SIGKILL waits in exit1() for
the spinning one. Only a reboot recovers.

Seen with i915 on Raptor Lake (Iris Xe 8086:a7a0, drm-612-kmod 6.12.110):
the Intel media driver maps one buffer object both WB and WC during an
h264_vaapi encode. A page has one owner object, so
lkpi_vmf_insert_pfn_prot_locked() refuses to move it into the second
mapping ("page rename failed: page is mapped") and returns
VM_FAULT_NOPAGE, forever. Xorg prints the same message in drm-kmod#481.
This patch does not fix the double mapping; it makes the process
killable. (PR 296195 is a different hang in the same function, a sleep
in vm_page_busy_acquire(), which this patch does not change.)

The loop now gives up, and fails the fault, once SIGKILL is pending
(fatal_signal_pending(current) reads the process queue as well as the
thread's) or the process has started to exit (P2_WEXIT: another thread
took the signal and is waiting in exit1() or sigexit()). Nothing changes
for a process that is not dying: transient retries (TTM lock contention)
and non-fatal signals behave as before. Failing on any signal would turn
SIGALRM into SIGSEGV, since a FreeBSD fault cannot be retried after a
signal handler the way Linux returns to user space.

Tested (each kernel = the machine's running source plus this patch):
- Raptor Lake NUC, i915: the stuck encode is gone 1 s after kill -9
  (before: survives it until reboot), also on GENERIC with INVARIANTS and
  WITNESS (no lock order reversal).
- Meteor Lake X1 Carbon (i915) and Strix Halo ZBook (amdgpu): VA-API
  decode bit-exact, H.264/HEVC encodes, vkmark, and a llama.cpp Vulkan
  load (ZBook) unchanged against the unpatched kernel.

Not covered, unchanged by this patch: SIGKILL sent to a single thread
blocked on the mmap_sem the spinning thread holds, SIGSTOP or a
multithreaded execve while a thread spins, and an aio daemon faulting on
the requester's memory.

Write-up: https://github.com/ocochard/myscripts/blob/master/FreeBSD/docs/linuxkpi_fault_killable.md
