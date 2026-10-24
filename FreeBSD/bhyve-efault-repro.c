/*
 * Standalone regression test for: bhyve dies with "vm_run error -1, errno 14"
 * when a guest writes to a read-only devmem mapping (the VM Generation
 * Counter page that bhyve maps at guest physical 0xff000000).
 *
 * No guest OS, no disk image, no bhyve(8).  It creates a VM, reproduces the
 * mapping vmgenc_init()/bootrom_alloc() makes, drops a vCPU into flat 32-bit
 * protected mode and reports what VM_RUN did.
 *
 * Two cases are run so the test validates itself:
 *   control - the guest only reads the page, then halts.  Must pass.
 *   test    - the guest reads, then writes the page, then halts.
 *
 * Build and run as root:
 *     cc -o bhyve-efault-repro bhyve-efault-repro.c -lvmmapi
 *     ./bhyve-efault-repro
 *
 * Broken (current) behaviour:
 *     control  PASS: reached the hlt at rip 0x1006, exitcode 14
 *     test     FAIL: vm_run() failed: Bad address (this is what kills bhyve(8))
 *
 * The control case proves the vCPU setup is sound and that *reading* the
 * read-only page is fine; only adding the write breaks it.  (exitcode 14 is
 * VM_EXITCODE_SUSPENDED: the guest halts with interrupts disabled.)
 *
 * Fixed behaviour: both cases reach the hlt.  A guest write to a read-only
 * guest-physical mapping must never turn into EFAULT out of VM_RUN.
 */

#include <sys/param.h>
#include <sys/cpuset.h>
#include <sys/mman.h>

#include <machine/vmm.h>
#include <machine/vmm_dev.h>
#include <dev/vmm/vmm_mem.h>

#include <err.h>
#include <errno.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <vmmapi.h>

#define	VMNAME		"efault-repro"
#define	MEMSIZE		(128 * 1024 * 1024)
#define	BOOTROM_SIZE	(16 * 1024 * 1024)	/* as in usr.sbin/bhyve/bootrom.c */
#define	CODE_GPA	0x1000
#define	STACK_GPA	0x8000

/* Flat 32-bit protected mode, no paging. */
#define	CR0_PE		0x00000001
#define	CR0_NE		0x00000020
#define	DESC_CODE32	0xc09b		/* G=1 D=1 P=1 S=1 type=exec/read */
#define	DESC_DATA32	0xc093		/* G=1 B=1 P=1 S=1 type=read/write */

/* mov eax, [0xff000000] / mov [0xff000000], eax / hlt */
static const uint8_t insn_read[]  = { 0xa1, 0x00, 0x00, 0x00, 0xff };
static const uint8_t insn_write[] = { 0xa3, 0x00, 0x00, 0x00, 0xff };
static const uint8_t insn_hlt[]   = { 0xf4 };

static void
set_flat_segment(struct vcpu *vcpu, int reg, uint16_t sel, uint32_t access)
{
	if (vm_set_desc(vcpu, reg, 0, 0xffffffff, access) != 0)
		err(1, "vm_set_desc(reg %d)", reg);
	if (vm_set_register(vcpu, reg, sel) != 0)
		err(1, "vm_set_register(reg %d)", reg);
}

/*
 * Returns 0 if the vCPU reached the hlt, 1 if VM_RUN failed.
 */
static int
run_case(const char *label, bool do_write)
{
	struct vmctx *ctx;
	struct vcpu *vcpu;
	struct vm_run vmrun;
	struct vm_exit vmexit;
	cpuset_t cpuset;
	vm_paddr_t rogpa;
	uint8_t code[16], *guestmem;
	size_t n;
	int error;

	if ((ctx = vm_open(VMNAME)) != NULL)	/* leftover from a previous run */
		vm_destroy(ctx);
	if (vm_create(VMNAME) != 0)
		err(1, "vm_create");
	if ((ctx = vm_open(VMNAME)) == NULL)
		err(1, "vm_open");
	if (vm_setup_memory(ctx, MEMSIZE, VM_MMAP_ALL) != 0)
		err(1, "vm_setup_memory");

	/*
	 * Exactly what bhyve does with no bootrom in use: init_bootrom()
	 * reserves [highmem - 16M, highmem) and vmgenc_init() takes the first
	 * page of it read-only via bootrom_alloc(PAGE_SIZE, PROT_READ, 0, ...).
	 */
	if (vm_create_devmem(ctx, VM_BOOTROM, "bootrom", BOOTROM_SIZE) ==
	    MAP_FAILED)
		err(1, "vm_create_devmem");
	rogpa = vm_get_highmem_base(ctx) - BOOTROM_SIZE;
	if (vm_mmap_memseg(ctx, rogpa, VM_BOOTROM, 0, getpagesize(),
	    PROT_READ) != 0)
		err(1, "vm_mmap_memseg");

	n = 0;
	memcpy(code + n, insn_read, sizeof(insn_read)); n += sizeof(insn_read);
	if (do_write) {
		memcpy(code + n, insn_write, sizeof(insn_write));
		n += sizeof(insn_write);
	}
	memcpy(code + n, insn_hlt, sizeof(insn_hlt)); n += sizeof(insn_hlt);

	if ((guestmem = vm_map_gpa(ctx, CODE_GPA, n)) == NULL)
		err(1, "vm_map_gpa");
	memcpy(guestmem, code, n);

	if ((vcpu = vm_vcpu_open(ctx, 0)) == NULL)
		err(1, "vm_vcpu_open");
	if (vm_activate_cpu(vcpu) != 0)
		err(1, "vm_activate_cpu");

	/* So the trailing hlt gives us a clean VM_EXITCODE_HLT. */
	if (vm_set_capability(vcpu, VM_CAP_HALT_EXIT, 1) != 0)
		err(1, "VM_CAP_HALT_EXIT");
	/* Needed on Intel to run a guest without paging; absent on AMD. */
	(void)vm_set_capability(vcpu, VM_CAP_UNRESTRICTED_GUEST, 1);

	if (vm_set_register(vcpu, VM_REG_GUEST_CR0, CR0_PE | CR0_NE) != 0)
		err(1, "set CR0");
	if (vm_set_register(vcpu, VM_REG_GUEST_CR4, 0) != 0)
		err(1, "set CR4");
	if (vm_set_register(vcpu, VM_REG_GUEST_EFER, 0) != 0)
		err(1, "set EFER");
	set_flat_segment(vcpu, VM_REG_GUEST_CS, 0x08, DESC_CODE32);
	set_flat_segment(vcpu, VM_REG_GUEST_DS, 0x10, DESC_DATA32);
	set_flat_segment(vcpu, VM_REG_GUEST_ES, 0x10, DESC_DATA32);
	set_flat_segment(vcpu, VM_REG_GUEST_SS, 0x10, DESC_DATA32);
	if (vm_set_desc(vcpu, VM_REG_GUEST_GDTR, 0, 0xffff, 0) != 0)
		err(1, "set GDTR");
	if (vm_set_desc(vcpu, VM_REG_GUEST_IDTR, 0, 0xffff, 0) != 0)
		err(1, "set IDTR");
	if (vm_set_register(vcpu, VM_REG_GUEST_RFLAGS, 0x2) != 0)
		err(1, "set RFLAGS");
	if (vm_set_register(vcpu, VM_REG_GUEST_RSP, STACK_GPA) != 0)
		err(1, "set RSP");
	if (vm_set_register(vcpu, VM_REG_GUEST_RIP, CODE_GPA) != 0)
		err(1, "set RIP");

	CPU_ZERO(&cpuset);
	memset(&vmrun, 0, sizeof(vmrun));
	memset(&vmexit, 0, sizeof(vmexit));
	vmrun.vm_exit = &vmexit;
	vmrun.cpuset = &cpuset;
	vmrun.cpusetsize = sizeof(cpuset);

	printf("%-8s guest: read %#lx%s, hlt\n", label, (unsigned long)rogpa,
	    do_write ? ", write it" : "");

	/*
	 * Re-enter on spurious exits, the way bhyve's vm_loop() does, so the
	 * control case actually reaches the hlt instead of stopping on the
	 * first VM_EXITCODE_BOGUS.
	 */
	for (int i = 0; i < 100; i++) {
		error = vm_run(vcpu, &vmrun);
		if (error != 0)
			break;
		if (vmexit.exitcode != VM_EXITCODE_BOGUS &&
		    vmexit.exitcode != VM_EXITCODE_REQIDLE)
			break;
	}

	if (error != 0) {
		printf("%-8s FAIL: vm_run() failed: %s%s\n", label,
		    strerror(errno),
		    errno == EFAULT ? " (this is what kills bhyve(8))" : "");
		error = 1;
	} else if (vmexit.rip != CODE_GPA + n) {
		printf("%-8s FAIL: stopped at rip %#lx (expected %#lx), "
		    "exitcode %d - guest did not run to the hlt\n", label,
		    (unsigned long)vmexit.rip, (unsigned long)(CODE_GPA + n),
		    vmexit.exitcode);
		error = 1;
	} else {
		printf("%-8s PASS: reached the hlt at rip %#lx, exitcode %d\n",
		    label, (unsigned long)vmexit.rip, vmexit.exitcode);
		error = 0;
	}

	vm_destroy(ctx);
	return (error);
}

int
main(void)
{
	int ctl, tst;

	if (geteuid() != 0)
		errx(1, "must run as root");

	ctl = run_case("control", false);
	tst = run_case("test", true);

	printf("\n");
	if (ctl != 0) {
		printf("INCONCLUSIVE: the read-only control case failed too, "
		    "so the vcpu setup is wrong rather than the write being "
		    "the trigger\n");
		return (2);
	}
	if (tst != 0) {
		printf("BUG PRESENT: reading the read-only page is fine, "
		    "writing it makes VM_RUN return EFAULT\n");
		return (1);
	}
	printf("BUG FIXED: the guest write to a read-only mapping no longer "
	    "kills the VM\n");
	return (0);
}
