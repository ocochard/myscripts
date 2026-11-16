/*-
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright (c) 2026 Olivier Cochard <olivier@FreeBSD.org>
 *
 * Query an AMD XDNA NPU through DRM_IOCTL_AMDXDNA_GET_INFO: firmware
 * version, AIE metadata and clocks.  Each answer is a firmware mailbox
 * round trip, so it proves the host to NPU path works.  Builds on Linux
 * and FreeBSD:
 *
 *   cc -I<drm-kmod>/include/uapi -I/usr/local/include/libdrm \
 *       -o amdxdna_query amdxdna_query.c
 *   ./amdxdna_query [/dev/accel/accel0]
 */

#include <sys/ioctl.h>

#include <err.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include <drm.h>
#include <drm/amdxdna_accel.h>

static int
get_info(int fd, uint32_t param, void *buf, uint32_t size)
{
	struct amdxdna_drm_get_info gi;

	memset(&gi, 0, sizeof(gi));
	gi.param = param;
	gi.buffer_size = size;
	gi.buffer = (uintptr_t)buf;
	return (ioctl(fd, DRM_IOCTL_AMDXDNA_GET_INFO, &gi));
}

int
main(int argc, char **argv)
{
	struct amdxdna_drm_query_firmware_version fw;
	struct amdxdna_drm_query_aie_metadata md;
	struct amdxdna_drm_query_clock_metadata clk;
	struct drm_version ver;
	const char *path;
	char name[64];
	int fd;

	path = argc > 1 ? argv[1] : "/dev/accel/accel0";
	if ((fd = open(path, O_RDWR)) < 0)
		err(1, "open %s", path);

	memset(&ver, 0, sizeof(ver));
	memset(name, 0, sizeof(name));
	ver.name = name;
	ver.name_len = sizeof(name) - 1;
	if (ioctl(fd, DRM_IOCTL_VERSION, &ver) != 0)
		err(1, "DRM_IOCTL_VERSION");
	printf("driver: %s %d.%d.%d\n", name, ver.version_major,
	    ver.version_minor, ver.version_patchlevel);

	memset(&fw, 0, sizeof(fw));
	if (get_info(fd, DRM_AMDXDNA_QUERY_FIRMWARE_VERSION, &fw,
	    sizeof(fw)) != 0)
		warn("QUERY_FIRMWARE_VERSION");
	else
		printf("firmware: %u.%u.%u.%u\n", fw.major, fw.minor,
		    fw.patch, fw.build);

	memset(&md, 0, sizeof(md));
	if (get_info(fd, DRM_AMDXDNA_QUERY_AIE_METADATA, &md,
	    sizeof(md)) != 0)
		warn("QUERY_AIE_METADATA");
	else
		printf("aie: version %u.%u, %u cols x %u rows, "
		    "col_size 0x%x, core rows %u, mem rows %u\n",
		    md.version.major, md.version.minor, md.cols, md.rows,
		    md.col_size, md.core.row_count, md.mem.row_count);

	memset(&clk, 0, sizeof(clk));
	if (get_info(fd, DRM_AMDXDNA_QUERY_CLOCK_METADATA, &clk,
	    sizeof(clk)) != 0)
		warn("QUERY_CLOCK_METADATA");
	else
		printf("clocks: %s %u MHz, %s %u MHz\n",
		    clk.mp_npu_clock.name, clk.mp_npu_clock.freq_mhz,
		    clk.h_clock.name, clk.h_clock.freq_mhz);

	close(fd);
	return (0);
}
