# FreeBSD development notes and tutorials

Write-ups produced while fixing or investigating FreeBSD. Most are written
for a reader new to the subsystem. Patches and helper scripts sit next to the
document that explains them.

## Kernel patch tutorials

- [DEBUGNET_if_rge.md](DEBUGNET_if_rge.md): adding debugnet/netdump support to a NIC driver, using rge(4). Patch: [rge.debugnet.patch](rge.debugnet.patch)
- [IPMI_SSIF.md](IPMI_SSIF.md): writing an IPMI SSIF driver on top of iicbus. Patch: [ipmi.ssif.patch](ipmi.ssif.patch), test script: [test_i2c.sh](test_i2c.sh) (Ampere Altra)
- [hidraw_kqueue_evfilt_write.md](hidraw_kqueue_evfilt_write.md): adding `EVFILT_WRITE` to hidraw(4), and why tokio programs could not open HID devices. Userland backend: [../async-hid/](../async-hid/)
- [ithwm_amdpower.md](ithwm_amdpower.md): `ithwm(4)` (ITE IT87xx) and `amdpower(4)` sensor drivers for the NAS
- [tun_destroy_deadlock_case_study.md](tun_destroy_deadlock_case_study.md): `tun_destroy()` parking a global sx-lock, from reproduction to fix. Patch: [tun_destroy_ebusy.patch](tun_destroy_ebusy.patch)
- [kevent_filter_zero_guard.md](kevent_filter_zero_guard.md): the one-line filter-zero guard in kevent(2) that prevents an out-of-bounds read
- [vnode_pager_getpages_async_completion.md](vnode_pager_getpages_async_completion.md): how a CBMC proof led to a wrong VM patch, and what the getpages completion path really does

## Kernel concepts

- [netisr_kernel_service.md](netisr_kernel_service.md): netisr(9), the deferred network dispatch service
- [RSS_kernel_option.md](RSS_kernel_option.md): what `options RSS` does, how it differs from NIC RSS, who uses it
- [iflib_tunables.md](iflib_tunables.md): reference for the `dev.<driver>.<unit>.iflib.*` and `net.iflib.*` sysctls
- [sensors.md](sensors.md): how hardware telemetry is exposed on FreeBSD compared to Linux

## Boot loader and build tools

The six loader/md(4) memdisk fixes are summarized in a table in
[../iPXE.md](../iPXE.md) (section "The fallback needed four fixes").

- [bugreport_loader_memdisk_memtype.md](bugreport_loader_memdisk_memtype.md): `memdisk=` ram disk reclaimed by the kernel (wrong EFI memory type) or out of the direct map. Patches: [loader_memdisk_memtype.patch](loader_memdisk_memtype.patch), [md_preload_mapdev.patch](md_preload_mapdev.patch)
- [bugreport_loader_md_no_partition_probe.md](bugreport_loader_md_no_partition_probe.md): loader md device never reads the partition table ("MD not present"). Patch: [loader_md_partition_probe.patch](loader_md_partition_probe.patch)
- [bugreport_loader_disk_parsedev_names.md](bugreport_loader_disk_parsedev_names.md): `disk_parsedev()` refuses device names it printed itself. Patch: [loader_disk_parsedev.patch](loader_disk_parsedev.patch)
- [bugreport_loader_set_currdev_devsw_undersized.md](bugreport_loader_set_currdev_devsw_undersized.md): `set_currdev_devsw()` passes a too-small struct to the name formatter. Patch: [loader_set_currdev_disk_devdesc.patch](loader_set_currdev_disk_devdesc.patch)
- [loader_memdisk_trim.md](loader_memdisk_trim.md): give back the unused tail of the decompression buffer. Patch: [loader_memdisk_trim.patch](loader_memdisk_trim.patch)
- [bugreport_mkimg_size_offset.md](bugreport_mkimg_size_offset.md): mkimg(1) ignored the offset in the `::size` form (unbootable 16.0 ISOs)
- [bmake_meta_mode_relative_writes.md](bmake_meta_mode_relative_writes.md): bmake META_MODE drops relative-path writes (zoneinfo installworld failure). Patch: [bmake_meta_relwrites.patch](bmake_meta_relwrites.patch), test: [bmake_meta_relwrites_test.sh](bmake_meta_relwrites_test.sh)
- [freebsd_uefi_pxe_netbootxyz.md](freebsd_uefi_pxe_netbootxyz.md): booting FreeBSD over UEFI PXE with netboot.xyz

## Userland bug reports

- [bugreport_rpcbind_mergeaddr_wildcard.txt](bugreport_rpcbind_mergeaddr_wildcard.txt): rpcbind GETADDR returns the address of an unrelated interface. Patch: [rpcbind_mergeaddr_wildcard.patch](rpcbind_mergeaddr_wildcard.patch), reproducer: [rpcbind_getaddr_wildcard_repro.sh](rpcbind_getaddr_wildcard_repro.sh)
- [bird3_freebsd_memory_madvise.md](bird3_freebsd_memory_madvise.md): bird3 memory reporting on FreeBSD vs Linux (`MADV_FREE` semantics). Script: [bird3_freebsd_memory_madvise.sh](bird3_freebsd_memory_madvise.sh)

## Debugging walkthroughs

- [i915kms_panic.md](i915kms_panic.md): debugging an i915kms kernel panic on the X1 Carbon (Meteor Lake)
- [freebsd-drm-kmod-vulkan.md](freebsd-drm-kmod-vulkan.md): drm-kmod Vulkan load hang with a 106 GB model on Strix Halo
- [mtl_anv_no_engines.md](mtl_anv_no_engines.md): Meteor Lake, ANV rejects the GPU with drm-latest-kmod 6.12 (i915 UAPI)
- [debug.openblas.md](debug.openblas.md): debugging a port build crash (`math/openblas` SIGBUS)
- [ACPI_AMW0_firmware_error.md](ACPI_AMW0_firmware_error.md): reading an ACPI firmware error with acpica-tools (`AMW0` / `EC0._REG`)
- [TPM_IRQ.md](TPM_IRQ.md): TPM TIS "Failed to switch to ready state" on ST33 chips
- `vnet_jail_deadlock_*.txt`: raw evidence (dmesg, kgdb session, procstat, netstat, vmstat) for a VNET jail deadlock, no write-up yet

## Host operations

- [ser6fbsd_reclaim_ubuntu.md](ser6fbsd_reclaim_ubuntu.md): removing the Ubuntu partition on ser6 and growing the FreeBSD ZFS pool
