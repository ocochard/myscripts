/*
 * Measure how the cost of amdgpu buffer objects grows with their number.
 *
 * Each batch allocates small buffer objects, maps them in the GPU address
 * space and mmap(2)s them, as Vulkan drivers do for games that use many small
 * buffers.  The cost per operation should stay flat: a value growing with the
 * object count means the kernel is doing a linear scan.
 *
 * Needs libdrm and read/write access to the render node (video group), and
 * uses count * 4 kB of GTT memory.  Nothing is drawn on screen.
 *
 * cc -O2 -Wall -I/usr/local/include -I/usr/local/include/libdrm \
 *     -L/usr/local/lib amdgpu_bo_scale.c -ldrm_amdgpu -o amdgpu_bo_scale
 * ./amdgpu_bo_scale [count [batch [render node]]]
 * ./amdgpu_bo_scale -h
 */

#include <err.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <amdgpu.h>
#include <amdgpu_drm.h>

#define	BO_SIZE		4096u
#define	VA_STRIDE	(2 * BO_SIZE)
/* Largest last/first ratio called flat: x1.3 and x12.5 were measured */
#define	GROWTH_LIMIT	3.0
/*
 * With fewer result lines the growth is not meaningful, and neither is it with
 * small batches: on a fixed kernel, the cost still rises x3 up to 3000 objects
 * before staying flat from 10000 objects on.
 */
#define	MIN_LINES	3
#define	MIN_BATCH	10000

struct timer {
	double	start;
	double	total;
};

static double
now(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (ts.tv_sec + ts.tv_nsec / 1e9);
}

static void
timer_start(struct timer *t)
{

	t->start = now();
}

static void
timer_stop(struct timer *t)
{

	t->total += now() - t->start;
}

static void
explain(void)
{

	printf(
	    "Cost of one operation, in microseconds, as the number of buffer "
	    "objects\ngrows.  Each value should stay about the same.  A value "
	    "that keeps growing\nmeans the kernel is searching a list one item "
	    "at a time (a linear scan).\n"
	    "Run this on an idle machine: other load adds noise to the values.\n"
	    "\n"
	    "  objects     number of buffer objects created so far\n"
	    "  bo_alloc    create a buffer object\n"
	    "  gpu_va_map  give it a GPU address (known scan: interval tree)\n"
	    "  cpu_mmap    map it for the CPU (known scans: device pager, VMA list)\n"
	    "\n");
}

static void
print_growth(const char *name, double first, double last)
{
	double ratio;

	ratio = first > 0 ? last / first : 0;
	printf("  %-10s  x%.1f  %s\n", name, ratio,
	    ratio > GROWTH_LIMIT ? "growing" : "flat");
}

int
main(int argc, char **argv)
{
	double avg[3], first[3];
	struct amdgpu_bo_alloc_request req;
	struct timer alloc, map, cpu, unmap, cpuunmap, freebo;
	amdgpu_device_handle dev;
	amdgpu_va_handle va_handle;
	amdgpu_bo_handle *bo;
	const char *node;
	void *ptr;
	uint64_t va;
	uint32_t major, minor;
	int batch, count, done, fd, i, lines, r;

	if (argc > 1 && strcmp(argv[1], "-h") == 0) {
		printf("usage: %s [count [batch [render node]]]\n"
		    "Defaults: 30000 objects, one result line per 10000 objects, "
		    "/dev/dri/renderD128.\n\n", argv[0]);
		explain();
		printf("The last lines give each column's growth from the first "
		    "to the last result line:\n"
		    "\"growing\" is above x%.0f, \"flat\" is below.  This limit "
		    "is a rule of thumb.\n"
		    "The teardown line is the cost of freeing everything, "
		    "per object.\n", GROWTH_LIMIT);
		return (0);
	}
	count = argc > 1 ? atoi(argv[1]) : 30000;
	batch = argc > 2 ? atoi(argv[2]) : 10000;
	node = argc > 3 ? argv[3] : "/dev/dri/renderD128";
	if (count <= 0 || batch <= 0)
		errx(1, "usage: %s [count [batch [render node]]]", argv[0]);

	fd = open(node, O_RDWR);
	if (fd == -1)
		err(1, "%s", node);
	r = amdgpu_device_initialize(fd, &major, &minor, &dev);
	if (r != 0)
		errx(1, "amdgpu_device_initialize: %s", strerror(-r));
	r = amdgpu_va_range_alloc(dev, amdgpu_gpu_va_range_general,
	    (uint64_t)count * VA_STRIDE, BO_SIZE, 0, &va, &va_handle, 0);
	if (r != 0)
		errx(1, "amdgpu_va_range_alloc: %s", strerror(-r));
	bo = calloc(count, sizeof(*bo));
	if (bo == NULL)
		err(1, "calloc");

	memset(&req, 0, sizeof(req));
	req.alloc_size = BO_SIZE;
	req.phys_alignment = BO_SIZE;
	req.preferred_heap = AMDGPU_GEM_DOMAIN_GTT;

	explain();
	printf("%8s %10s %10s %10s\n", "objects", "bo_alloc", "gpu_va_map",
	    "cpu_mmap");
	lines = 0;
	for (done = 0; done < count; done += batch) {
		memset(&alloc, 0, sizeof(alloc));
		memset(&map, 0, sizeof(map));
		memset(&cpu, 0, sizeof(cpu));
		for (i = done; i < done + batch && i < count; i++) {
			timer_start(&alloc);
			r = amdgpu_bo_alloc(dev, &req, &bo[i]);
			timer_stop(&alloc);
			if (r != 0)
				errx(1, "amdgpu_bo_alloc %d: %s", i,
				    strerror(-r));
			timer_start(&map);
			r = amdgpu_bo_va_op(bo[i], 0, BO_SIZE,
			    va + (uint64_t)i * VA_STRIDE,
			    AMDGPU_VM_PAGE_READABLE | AMDGPU_VM_PAGE_WRITEABLE,
			    AMDGPU_VA_OP_MAP);
			timer_stop(&map);
			if (r != 0)
				errx(1, "amdgpu_bo_va_op %d: %s", i,
				    strerror(-r));
			timer_start(&cpu);
			r = amdgpu_bo_cpu_map(bo[i], &ptr);
			timer_stop(&cpu);
			if (r != 0)
				errx(1, "amdgpu_bo_cpu_map %d: %s", i,
				    strerror(-r));
		}
		avg[0] = alloc.total * 1e6 / (i - done);
		avg[1] = map.total * 1e6 / (i - done);
		avg[2] = cpu.total * 1e6 / (i - done);
		if (lines++ == 0)
			memcpy(first, avg, sizeof(first));
		printf("%8d %10.1f %10.1f %10.1f\n", i, avg[0], avg[1], avg[2]);
		fflush(stdout);
	}

	if (lines < MIN_LINES || batch < MIN_BATCH)
		printf("\nNo verdict: it needs at least %d result lines and a "
		    "batch of %d.\n", MIN_LINES, MIN_BATCH);
	else {
		printf("\ngrowth from first to last line:\n");
		print_growth("bo_alloc", first[0], avg[0]);
		print_growth("gpu_va_map", first[1], avg[1]);
		print_growth("cpu_mmap", first[2], avg[2]);
	}
	printf("\n");

	memset(&cpuunmap, 0, sizeof(cpuunmap));
	memset(&unmap, 0, sizeof(unmap));
	memset(&freebo, 0, sizeof(freebo));
	for (i = 0; i < count; i++) {
		timer_start(&cpuunmap);
		amdgpu_bo_cpu_unmap(bo[i]);
		timer_stop(&cpuunmap);
		timer_start(&unmap);
		amdgpu_bo_va_op(bo[i], 0, BO_SIZE, va + (uint64_t)i * VA_STRIDE,
		    0, AMDGPU_VA_OP_UNMAP);
		timer_stop(&unmap);
		timer_start(&freebo);
		amdgpu_bo_free(bo[i]);
		timer_stop(&freebo);
	}
	printf("teardown (freeing everything): cpu_munmap %.1f gpu_va_unmap %.1f "
	    "bo_free %.1f\n",
	    cpuunmap.total * 1e6 / count, unmap.total * 1e6 / count,
	    freebo.total * 1e6 / count);

	free(bo);
	amdgpu_va_range_free(va_handle);
	amdgpu_device_deinitialize(dev);
	close(fd);
	return (0);
}
