linuxkpi: Bound the retries of a fault handler that inserts no page

linux_cdev_pager_populate() calls the driver's fault handler again for as
long as it returns VM_FAULT_NOPAGE without inserting a page. When the page
can never be inserted, the thread loops in the kernel forever and kill -9
cannot end the process; only a reboot recovers.

Seen with i915 on Raptor Lake (Iris Xe 8086:a7a0, drm-612-kmod 6.12.110):
the Intel media driver maps one buffer object both WB and WC during an
h264_vaapi encode. A page has one owner object, so
lkpi_vmf_insert_pfn_prot_locked() refuses to move it into the second
mapping ("page rename failed: page is mapped") and returns
VM_FAULT_NOPAGE: about 450,000 handler calls per second, forever. Xorg
prints the same message in drm-kmod#481.

As suggested in review, the retries are now bounded in time, like the
vm_fault OOM handling (vm.pfault_oom_attempts x vm.pfault_oom_wait): after
compat.linuxkpi.fault_retry_timeout seconds the fault fails and the
thread gets SIGSEGV. The first retry yields as before, later ones sleep a
tick. 0 fails at once, -1 retries forever. No signal or process state is
examined.

Why 30 s by default:
- Retries are rare: DTrace counting handler calls per fault under VA-API,
  vkmark and llama.cpp loads, alone and concurrent, found no retry in
  389,768 faults on i915 (Raptor Lake, Meteor Lake) and amdgpu (Strix
  Halo). The deadline does not affect normal operation.
- The longest legitimate retry: TTM waits for buffer moves interruptibly
  and returns VM_FAULT_NOPAGE while a signal is pending, so a retry can
  last until the move ends. A hung move ends at amdgpu's 10 s kernel job
  timeout plus a reset whose length I could not measure. 3 x 10 s, the
  same total as vm_fault's OOM give-up.

Tested (each kernel = the machine's running source plus this patch):
- LinuxKPI test module in a bhyve guest (NODEBUG and INVARIANTS/WITNESS):
  a handler that never inserts ends with SIGSEGV at the deadline, 0% CPU
  while waiting; kill -9 takes effect at the deadline for single- and
  multithreaded processes (stock: never); a handler that refuses 50 times
  then inserts succeeds.
- Raptor Lake NUC (i915, WITNESS kernel): the stuck encode gets SIGSEGV
  after 30 s instead of looping forever; kill -9 works at the deadline;
  no lock order reversal.
- Meteor Lake X1 Carbon (i915) and Strix Halo ZBook (amdgpu): VA-API
  decode bit-exact, H.264/HEVC encodes, vkmark, and a llama.cpp Vulkan
  load (ZBook) unchanged against the unpatched kernels.

Not covered: the cause on Raptor Lake (one page in two mappings), so that
encode now fails after 30 s instead of hanging (-low_power 1 works); a
handler's VM_FAULT_SIGBUS still gives a zero-filled page (separate patch).

Write-up and test module:
https://github.com/ocochard/myscripts/blob/master/FreeBSD/docs/linuxkpi_fault_killable.md
