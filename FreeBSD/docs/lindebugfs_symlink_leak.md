# lindebugfs: debugfs symlinks leak their memory on removal

Patch: [lindebugfs_symlink_leak.patch](lindebugfs_symlink_leak.patch),
branch [`olivier-lindebugfs-symlink`](https://github.com/ocochard/freebsd-src/compare/main...olivier-lindebugfs-symlink).
Found while porting the AMD XDNA NPU driver ([amdxdna_npu.md](amdxdna_npu.md)).
Line numbers are `sys/compat/lindebugfs/lindebugfs.c` on main 611046b15dbb.

## 1. Background

**debugfs.** Linux drivers publish debugging files in debugfs. On
FreeBSD, `lindebugfs.ko` implements the Linux debugfs API on top of
pseudofs (`sys/fs/pseudofs`), a framework for synthetic file systems
like procfs. It is mounted with `mount -t lindebugfs lindebugfs <dir>`.

**pseudofs nodes and their destroy callback.** Each file, directory or
symlink is a `struct pfs_node`, created with `pfs_create_file()`,
`pfs_create_dir()` or `pfs_create_link()`. The last-but-one argument is
a *destroy* callback that pseudofs calls when the node is removed, so
that the creator can free its own data attached to the node.

**lindebugfs metadata.** For each node lindebugfs allocates a `struct
dentry_meta` (type `M_DFSINT`, "debugfsint" in `vmstat -m`). A symlink
also gets a copy of its target string (`strdup_flags()`).
`debugfs_destroy()` (line 103) frees both: the target when the node is a
`DM_SYMLINK`, then the metadata.

## 2. The problem

`debugfs_create_file()` (line 238) and `debugfs_create_dir()` (line
318) pass `debugfs_destroy` to pseudofs. `debugfs_create_symlink()`
passes `NULL`, so removing a symlink frees the pseudofs node but leaks
its two allocations.

DRM creates symlinks in debugfs for each device minor (`dri/128`,
`dri/1`, pointing at the device directory). Measured on frwk-bsd with
the amdxdna module, while amdgpu keeps lindebugfs loaded:

```
# vmstat -m | grep debugfsint      (amdxdna loaded)
      debugfsint  479 29552  524 16,64
# kldunload amdxdna
      debugfsint  474 29232  524 16,64
# kldload amdxdna.ko
      debugfsint  483 29712  533 16,64
```

The unload freed 5 allocations of the 9 the load made: 4 leak per
cycle, which is 2 symlinks of 2 allocations each. When nothing else
holds lindebugfs, unloading it reports what was left:
`Warning: memory type debugfsint leaked memory on destroy (6
allocations, 240 bytes leaked).`

## 3. The fix

```c
	pfs_create_link(pnode, &dnode->d_pfs_node, name, &debugfs_fill_data,
	    NULL, NULL, debugfs_destroy, PFS_NOWAIT);
```

`debugfs_destroy()` already handles `DM_SYMLINK`; it was just never
called for one. The bug dates from the import of lindebugfs
(3f6cab079cb2, 2019).

Alternative: free the metadata in `debugfs_remove()`. That would miss
nodes removed by their parent (`debugfs_remove_recursive()` and
pseudofs teardown), which only the destroy callback sees.

## 4. Tested

frwk-bsd, kernel `olivier-npu-n291242-854a0944970d` (main 611046b15dbb
plus the NPU branches), lindebugfs held by amdgpu.

| Test | Before | After |
|---|---|---|
| `debugfsint` allocations after 3 amdxdna reload cycles | +4 per cycle | 443 before, 443 after |
| lindebugfs unload after amdxdna unload | `leaked memory on destroy (6 allocations, 240 bytes)` | untested (amdgpu keeps it loaded) |
| Other debugfs users (drm, amdgpu) | | untested |
