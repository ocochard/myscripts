# LinuxKPI: binary sysfs attributes are cut at the first NUL byte

Patch: [linuxkpi_sysfs_binary_attr.patch](linuxkpi_sysfs_binary_attr.patch),
branch [`olivier-lkpi-sysfs-binary`](https://github.com/ocochard/freebsd-src/compare/main...olivier-lkpi-sysfs-binary).
Found while measuring the AMD XDNA NPU against the iGPU
([amdxdna_npu.md](amdxdna_npu.md), section 5). Line numbers are
`sys/compat/linuxkpi/common/include/linux/sysfs.h` on main 611046b15dbb.

## 1. Background

**sysfs attributes.** A Linux driver publishes values as files under
`/sys`. Each file is an *attribute* with a `show()` callback that fills a
page-sized buffer and returns the number of bytes written. Most
attributes are text (`"1800\n"`), but a few are binary structures. The
`show()` contract is the same for both: a buffer and a length.

**LinuxKPI maps them to sysctls.** FreeBSD has no sysfs. LinuxKPI turns
each attribute into a sysctl node (`sys.device.<name>.<attribute>`),
handled by `sysctl_handle_attr()` (line 129). Reading the sysctl calls
`show()`, removes the trailing newline and returns the buffer with
`sysctl_handle_string()` (line 167). Writing calls `store()`.

**amdgpu gpu_metrics.** amdgpu exports the SMU's metrics table as the
binary attribute `gpu_metrics`: `struct gpu_metrics_v3_0` on Strix
Point/Halo (`drivers/gpu/drm/amd/include/kgd_pp_interface.h` in
drm-kmod), 264 bytes. It holds the SMU's power readings: socket (the PPT
that Linux hwmon shows as `power1_input`), NPU (`average_ipu_power`),
GFX, per CPU core, plus clocks, temperatures and DRAM bandwidth.
drm-kmod has no hwmon, so on FreeBSD this attribute is the only way to
get these powers.

## 2. The problem

`sysctl_handle_string()` returns the string up to its first NUL byte. The
gpu_metrics header is `structure_size` (264, `08 01`), then
`format_revision` 3 and `content_revision` 0, so the fifth byte is 0:

```
$ sysctl -b sys.device.drmn0.gpu_metrics | od -A d -t x1
0000000    08  01  03  00
0000004
```

On Linux the same file is 264 bytes. Every binary attribute is affected;
the handler also overwrites the last byte while trimming a newline that
binary data does not have.

## 3. The fix

```c
		} else if (len > 0 && memchr(buf, '\0', MIN(len, PAGE_SIZE))) {
			/* Binary attribute, such as amdgpu gpu_metrics. */
			if (req->newptr != NULL)
				error = EPERM;
			else
				error = SYSCTL_OUT(req, buf, MIN(len, PAGE_SIZE));
			goto out;
		} else if (len) {
```

A text attribute never has a NUL byte inside the length `show()`
returned, so a NUL marks binary data. Then the handler returns the
bytes as they are, with no newline trimming. A write to such a node is
refused: `store()` expects text and the handler cannot tell what the
binary layout would be.

`sysctl_handle_attr()` is `static inline` in a header, so it is compiled
into each module that creates attributes. Only those modules need a
rebuild (here `amdgpu.ko` from drm-kmod), not the kernel.

Alternatives:

- Mark binary attributes when they are created. Linux has
  `bin_attribute` for real binary files, but amdgpu declares gpu_metrics
  as a normal `device_attribute`, so there is no flag to test.
- A per-attribute sysctl type ("S" or opaque) chosen at creation time.
  The type is only known after the first `show()`.

Not changed: text attributes behave as before, including the newline
trimming and the writable path.

## 4. Tested

frwk-bsd (Framework Desktop, Strix Halo), kernel main 6871285f194d plus
the NPU branches, `amdgpu.ko` rebuilt from drm-kmod `drm_v6.12.85_3` with
the graphics/drm-latest-kmod patches, against the patched header.

| Test | Before | After |
|---|---|---|
| `sysctl -b sys.device.drmn0.gpu_metrics \| wc -c` | 4 | 264 (as Linux) |
| Decoded with [../npu/gpu_metrics.py](../npu/gpu_metrics.py) | fails (short) | v3.0; socket 16.1 W just after boot |
| Socket power against RAPL package energy over 10 s idle | | 18.2 W against 17.0 W (Linux: 9.8 against 9.4) |
| Text attributes (`sys.device.drmn0.vbios_version`, `fw_version.*`) | text | same text |
| Writing a binary attribute | untested | untested |
