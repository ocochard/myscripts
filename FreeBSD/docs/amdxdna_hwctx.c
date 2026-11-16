/*-
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright (c) 2026 Olivier Cochard <olivier@FreeBSD.org>
 *
 * Create and destroy an AMD XDNA hardware context.  Steps:
 *   1. allocate a device heap buffer (AMDXDNA_BO_DEV_HEAP, 64 MB),
 *   2. mmap it and write/read a pattern from the CPU,
 *   3. create a hardware context of one column (the firmware gets the
 *      heap address and maps it for the NPU),
 *   4. destroy the context and the buffer.
 * Builds on Linux and FreeBSD, like amdxdna_query.c.
 */

#include <sys/ioctl.h>
#include <sys/mman.h>

#include <err.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include <drm.h>
#include <drm/amdxdna_accel.h>

#define	HEAP_SIZE	(64UL << 20)

int
main(int argc, char **argv)
{
	struct amdxdna_drm_create_bo cbo, dbo;
	struct amdxdna_drm_get_bo_info info;
	struct amdxdna_drm_create_hwctx ctx;
	struct amdxdna_drm_destroy_hwctx dctx;
	struct amdxdna_qos_info qos;
	struct drm_gem_close gclose;
	const char *path;
	uint32_t *p;
	uintptr_t aligned, expect;
	uint64_t heap_xdna;
	void *resv;
	size_t i, bad;
	int fd;

	path = argc > 1 ? argv[1] : "/dev/accel/accel0";
	if ((fd = open(path, O_RDWR)) < 0)
		err(1, "open %s", path);

	memset(&cbo, 0, sizeof(cbo));
	cbo.type = AMDXDNA_BO_DEV_HEAP;
	cbo.size = HEAP_SIZE;
	if (ioctl(fd, DRM_IOCTL_AMDXDNA_CREATE_BO, &cbo) != 0)
		err(1, "CREATE_BO dev heap");
	printf("heap: handle %u\n", cbo.handle);

	memset(&info, 0, sizeof(info));
	info.handle = cbo.handle;
	if (ioctl(fd, DRM_IOCTL_AMDXDNA_GET_BO_INFO, &info) != 0)
		err(1, "GET_BO_INFO");
	printf("heap: map_offset 0x%llx xdna_addr 0x%llx\n",
	    (unsigned long long)info.map_offset,
	    (unsigned long long)info.xdna_addr);

	/*
	 * The heap must sit at a HEAP_SIZE aligned address: reserve twice
	 * the size, then map the heap over the aligned part.
	 */
	resv = mmap(NULL, 2 * HEAP_SIZE, PROT_NONE, MAP_PRIVATE | MAP_ANON,
	    -1, 0);
	if (resv == MAP_FAILED)
		err(1, "mmap reserve");
	aligned = ((uintptr_t)resv + HEAP_SIZE - 1) & ~(HEAP_SIZE - 1);
	p = mmap((void *)aligned, HEAP_SIZE, PROT_READ | PROT_WRITE,
	    MAP_SHARED | MAP_FIXED, fd, info.map_offset);
	if (p == MAP_FAILED)
		err(1, "mmap heap");
	for (i = 0; i < HEAP_SIZE / sizeof(*p); i++)
		p[i] = (uint32_t)i ^ 0x5a5a5a5a;
	for (i = 0, bad = 0; i < HEAP_SIZE / sizeof(*p); i++)
		if (p[i] != ((uint32_t)i ^ 0x5a5a5a5a))
			bad++;
	printf("heap: mapped at %p, pattern check %zu bad words\n",
	    (void *)p, bad);

	/* The kernel must report the address the heap is mapped at. */
	memset(&info, 0, sizeof(info));
	info.handle = cbo.handle;
	if (ioctl(fd, DRM_IOCTL_AMDXDNA_GET_BO_INFO, &info) != 0)
		err(1, "GET_BO_INFO heap");
	printf("heap: kernel vaddr 0x%llx %s\n", (unsigned long long)info.vaddr,
	    info.vaddr == (uintptr_t)p ? "matches" : "MISMATCH");
	heap_xdna = info.xdna_addr;

	/* A device BO lives inside the heap: its vaddr is heap + offset. */
	memset(&dbo, 0, sizeof(dbo));
	dbo.type = AMDXDNA_BO_DEV;
	dbo.size = 4096;
	if (ioctl(fd, DRM_IOCTL_AMDXDNA_CREATE_BO, &dbo) != 0)
		err(1, "CREATE_BO dev");
	memset(&info, 0, sizeof(info));
	info.handle = dbo.handle;
	if (ioctl(fd, DRM_IOCTL_AMDXDNA_GET_BO_INFO, &info) != 0)
		err(1, "GET_BO_INFO dev");
	expect = (uintptr_t)p + (info.xdna_addr - heap_xdna);
	printf("dev bo: xdna_addr 0x%llx vaddr 0x%llx %s\n",
	    (unsigned long long)info.xdna_addr, (unsigned long long)info.vaddr,
	    info.vaddr == expect ? "matches heap mapping" : "MISMATCH");
	if (info.vaddr == expect) {
		*(volatile uint32_t *)(uintptr_t)info.vaddr = 0xc0ffee;
		printf("dev bo: write through vaddr seen in heap: %s\n",
		    p[(expect - (uintptr_t)p) / 4] == 0xc0ffee ? "yes" : "NO");
	}

	memset(&qos, 0, sizeof(qos));
	memset(&ctx, 0, sizeof(ctx));
	ctx.qos_p = (uintptr_t)&qos;
	ctx.num_tiles = 4;		/* one column of 4 core tiles */
	ctx.max_opc = 0x800;
	if (ioctl(fd, DRM_IOCTL_AMDXDNA_CREATE_HWCTX, &ctx) != 0)
		err(1, "CREATE_HWCTX");
	printf("hwctx: handle %u syncobj %u\n", ctx.handle,
	    ctx.syncobj_handle);

	memset(&dctx, 0, sizeof(dctx));
	dctx.handle = ctx.handle;
	if (ioctl(fd, DRM_IOCTL_AMDXDNA_DESTROY_HWCTX, &dctx) != 0)
		err(1, "DESTROY_HWCTX");
	printf("hwctx: destroyed\n");

	munmap(p, HEAP_SIZE);
	memset(&gclose, 0, sizeof(gclose));
	gclose.handle = cbo.handle;
	if (ioctl(fd, DRM_IOCTL_GEM_CLOSE, &gclose) != 0)
		warn("GEM_CLOSE");
	close(fd);
	return (0);
}
