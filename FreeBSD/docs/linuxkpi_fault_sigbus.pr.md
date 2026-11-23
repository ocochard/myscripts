linuxkpi: Make a fault handler's SIGBUS fail the fault

linux_cdev_pager_populate() translates a driver's VM_FAULT_SIGBUS to
VM_PAGER_BAD, which vm_fault_populate() takes as a request for normal
fault handling. The LinuxKPI pager has no cdev_pg_fault method, so the
normal path zero-fills a page: the process reads zeros where the driver
refused the access, and gets no signal.

Pages the handler inserted before failing stay exclusive-busy, because
vm_fault_populate() returns at once on a populate failure. The next
fault on one of them sleeps in vm_page_busy_sleep forever, and kill -9
cannot end the process.

The patch translates VM_FAULT_SIGBUS to VM_PAGER_ERROR, so the access
fails (the process gets SIGSEGV; a real SIGBUS would need a populate
status that maps to KERN_OUT_OF_BOUNDS). On any populate failure it
removes the pages the handler inserted in this fault, as
cdev_mgtdev_pager_free_page() does: pmap_remove_all() for managed pages,
then vm_page_remove(). Removing rather than only unbusying them makes
the next fault ask the driver again; a kept page would be mapped
unchecked, which for an i915 GTT mapping that failed part way could be
an aperture slot i915 has since given to another buffer.

Shown with a LinuxKPI test module whose fault handler inserts, returns
VM_FAULT_SIGBUS, or inserts two pages then returns VM_FAULT_SIGBUS
(bhyve guest):
- stock: zero page and no signal; after the partial insert, the next
  access to an inserted page hangs and survives SIGKILL.
- patched (GENERIC-NODEBUG and GENERIC with INVARIANTS/WITNESS):
  SIGSEGV; the next access calls the driver again and gets its page.
  No assertion, no lock order reversal.

Regression on hardware (each kernel = the machine's running source plus
this patch): Raptor Lake NUC (i915, WITNESS kernel), Meteor Lake
X1 Carbon (i915) and Strix Halo ZBook (amdgpu): VA-API decode bit-exact,
H.264/HEVC encodes, vkmark, and a llama.cpp Vulkan load (ZBook), all
unchanged against the unpatched kernels.

Behaviour change: a driver's VM_FAULT_SIGBUS now fails the access, as on
Linux, instead of giving zeros; for example a read of an i915 buffer the
driver purged now stops the program. Not covered: a handler that leaves
a gap in its inserts (an insert refused with "page rename failed: page
is mapped" is not counted) can leave a page above the counted range
busy; the success path has the same assumption.

Independent of "linuxkpi: Let a killed process leave a retried fault"
(same function, either order).

Write-up and reproducer:
https://github.com/ocochard/myscripts/blob/master/FreeBSD/docs/linuxkpi_fault_sigbus.md
