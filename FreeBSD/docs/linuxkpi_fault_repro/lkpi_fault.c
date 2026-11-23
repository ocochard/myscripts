/*
 * lkpi_fault: a LinuxKPI character device whose mmap fault handler does what
 * a test asks, to observe how linux_cdev_pager_populate() handles it.
 *
 * debug.lkpi_fault.mode, read at each fault:
 *   0  insert the faulting page (control)
 *   1  return VM_FAULT_SIGBUS without inserting anything
 *   2  insert pages 0 .. partial-1, then return VM_FAULT_SIGBUS
 *
 * Inserted pages are filled with 0xa5, so a zero-filled page is visible.
 * Pages are never freed by the module: the VM object owns them once inserted.
 * Test code only: not for a production kernel.
 */
#include <sys/param.h>
#include <sys/kernel.h>
#include <sys/module.h>
#include <sys/sysctl.h>

#include <vm/vm.h>
#include <vm/vm_object.h>
#include <vm/vm_page.h>

#include <linux/module.h>
#include <linux/fs.h>
#include <linux/cdev.h>
#include <linux/mm.h>
#include <linux/gfp.h>
#include <linux/slab.h>

static int lf_mode;
static int lf_partial = 2;

static SYSCTL_NODE(_debug, OID_AUTO, lkpi_fault, CTLFLAG_RW | CTLFLAG_MPSAFE, 0,
    "LinuxKPI fault test device");
SYSCTL_INT(_debug_lkpi_fault, OID_AUTO, mode, CTLFLAG_RW, &lf_mode, 0,
    "0 insert, 1 SIGBUS, 2 partial insert then SIGBUS");
SYSCTL_INT(_debug_lkpi_fault, OID_AUTO, partial, CTLFLAG_RW, &lf_partial, 0,
    "pages inserted before SIGBUS in mode 2");

static struct linux_cdev *lf_cdev;

static vm_fault_t
lf_insert(struct vm_area_struct *vma, unsigned long addr)
{
	struct page *p;

	p = alloc_page(GFP_KERNEL);
	if (p == NULL)
		return (VM_FAULT_OOM);
	memset(page_address(p), 0xa5, PAGE_SIZE);
	/* As TTM does: the device pager wants managed pages. */
	p->oflags &= ~VPO_UNMANAGED;
	return (lkpi_vmf_insert_pfn_prot_locked(vma, addr, page_to_pfn(p),
	    vma->vm_page_prot));
}

static int
lf_fault(struct vm_fault *vmf)
{
	struct vm_area_struct *vma = vmf->vma;
	unsigned long addr = (unsigned long)vmf->virtual_address;
	vm_fault_t ret;
	int i, mode;

	mode = lf_mode;
	printf("lkpi_fault: fault at page %lu, mode %d\n", addr / PAGE_SIZE, mode);
	switch (mode) {
	case 1:
		return (VM_FAULT_SIGBUS);
	case 2:
		VM_OBJECT_WLOCK(vma->vm_obj);
		for (i = 0; i < lf_partial; i++) {
			ret = lf_insert(vma, (unsigned long)i * PAGE_SIZE);
			if (ret != VM_FAULT_NOPAGE)
				break;
		}
		VM_OBJECT_WUNLOCK(vma->vm_obj);
		printf("lkpi_fault: inserted %d page(s), returning SIGBUS\n",
		    vma->vm_pfn_count);
		return (VM_FAULT_SIGBUS);
	default:
		VM_OBJECT_WLOCK(vma->vm_obj);
		ret = lf_insert(vma, addr);
		VM_OBJECT_WUNLOCK(vma->vm_obj);
		return (ret);
	}
}

static void
lf_open(struct vm_area_struct *vma)
{
}

static void
lf_close(struct vm_area_struct *vma)
{
}

static const struct vm_operations_struct lf_vm_ops = {
	.open = lf_open,
	.close = lf_close,
	.fault = lf_fault,
};

static int
lf_mmap(struct linux_file *filp, struct vm_area_struct *vma)
{
	/* One VM object per mmap: a fresh cookie each time (leaked). */
	vma->vm_private_data = kzalloc(1, GFP_KERNEL);
	vma->vm_ops = &lf_vm_ops;
	return (0);
}

static const struct file_operations lf_fops = {
	.owner = THIS_MODULE,
	.mmap = lf_mmap,
};

static int __init
lf_init(void)
{
	int error;

	lf_cdev = cdev_alloc();
	if (lf_cdev == NULL)
		return (-ENOMEM);
	lf_cdev->ops = &lf_fops;
	kobject_set_name(&lf_cdev->kobj, "lkpi_fault");
	error = cdev_add(lf_cdev, makedev(0, 0), 1);
	if (error != 0)
		cdev_del(lf_cdev);
	return (error);
}

static void __exit
lf_exit(void)
{
	cdev_del(lf_cdev);
}

module_init(lf_init);
module_exit(lf_exit);
MODULE_DEPEND(lkpi_fault, linuxkpi, 1, 1, 1);
