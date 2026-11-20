# FreeBSD development notes and tutorials

Write-ups produced while fixing or investigating FreeBSD. Most are written
for a reader new to the subsystem. Patches and helper scripts sit next to the
document that explains them.

## Kernel patch tutorials

- [DEBUGNET_if_rge.md](DEBUGNET_if_rge.md): adding debugnet/netdump support to a NIC driver, using rge(4). Patch: [rge.debugnet.patch](rge.debugnet.patch)
- [IPMI_SSIF.md](IPMI_SSIF.md): writing an IPMI SSIF driver on top of iicbus. Patch: [ipmi.ssif.patch](ipmi.ssif.patch), test script: [test_i2c.sh](test_i2c.sh) (Ampere Altra)
- [hidraw_kqueue_evfilt_write.md](hidraw_kqueue_evfilt_write.md): adding `EVFILT_WRITE` to hidraw(4), and why tokio programs could not open HID devices. Userland backend: [../async-hid/](../async-hid/)
- [amdgpu_map_cost_linear_scans.md](amdgpu_map_cost_linear_scans.md): why a game was slow on amdgpu: three linear scans in the kernel, replaced by hash tables and a tree search. Patch: [amdgpu_map_cost_linear_scans.patch](amdgpu_map_cost_linear_scans.patch), reproducer: [amdgpu_bo_scale.c](amdgpu_bo_scale.c), profiler: [amdgpu_map_cost_profile.sh](amdgpu_map_cost_profile.sh)
- [ithwm_amdpower.md](ithwm_amdpower.md): `ithwm(4)` (ITE IT87xx) and `amdpower(4)` sensor drivers for the NAS
- [x86_gpio_intr_mtl.md](x86_gpio_intr_mtl.md): GPIO interrupts on x86 (Meteor Lake GPIO driver, x86 GPIO pseudo-PIC, ACPI GpioInt for I2C HID) so the X1 Carbon touchpad stops polling. Patch: [x86_gpio_intr_mtl.patch](x86_gpio_intr_mtl.patch)
- [acpi_ibm_pnp_info.md](acpi_ibm_pnp_info.md): how devmatch(8) picks kernel modules from device IDs, and the one line that makes it load `acpi_ibm` on ThinkPads. Patch: [acpi_ibm_pnp_info.patch](acpi_ibm_pnp_info.patch)
- [tun_destroy_deadlock_case_study.md](tun_destroy_deadlock_case_study.md): `tun_destroy()` parking a global sx-lock, from reproduction to fix. Patch: [tun_destroy_ebusy.patch](tun_destroy_ebusy.patch)
- [tcp_sent_too_much_rxtshift.md](tcp_sent_too_much_rxtshift.md): `panic: tcp_do_segment: sent too much` (PR 282605) after an RTO, from a kernel dump to a packetdrill reproducer: the limited transmit KASSERT assumed a cwnd reset that does not happen while `t_rxtshift > 0`. Patch: [tcp_sent_too_much_rxtshift.patch](tcp_sent_too_much_rxtshift.patch), reproducer: [tcp_sent_too_much_rxtshift.pkt](tcp_sent_too_much_rxtshift.pkt)
- [mroute_m_pullup_shared_header.md](mroute_m_pullup_shared_header.md): forwarded multicast fragments corrupted because `m_pullup()` stopped copying a contiguous header, so `ip_reass()` rewrote the copy waiting in the NIC queue; fixed with `m_copyup()`. Patch: [mroute_m_pullup_shared_header.patch](mroute_m_pullup_shared_header.patch), IPv6 reproducer: [mroute6_wrongmif_tclass.c](mroute6_wrongmif_tclass.c)
- [kevent_filter_zero_guard.md](kevent_filter_zero_guard.md): the one-line filter-zero guard in kevent(2) that prevents an out-of-bounds read
- [bugreport_tpm_crb_back_to_back_eio.md](bugreport_tpm_crb_back_to_back_eio.md): tpm_crb returns `EIO` on back-to-back commands on a Pluton TPM (Framework Desktop), because it doesn't wait for idle or the locality release. Patches: [tpm_crb_settle_before_next_command.patch](tpm_crb_settle_before_next_command.patch), [tpm_crb_pluton_no_locality.patch](tpm_crb_pluton_no_locality.patch), reproducer: [tpm_crb_sweep.py](tpm_crb_sweep.py)
- [tpm_crb_acpi_start_method.md](tpm_crb_acpi_start_method.md): how `tpm_crb` works, and adding TPM2 start method 2 (ACPI start) so the AMD fTPM on ser6 gets a driver. Patch: [tpm_crb_acpi_start_method.patch](tpm_crb_acpi_start_method.patch), long-command timer: [tpm_crb_long_command.py](tpm_crb_long_command.py), stall probe: [tpm_stall_probe.c](tpm_stall_probe.c) with [tpm_stall_analyze.py](tpm_stall_analyze.py) and its data in [tpm_stall_data/](tpm_stall_data/)
- [cs35l54_speaker_amp.md](cs35l54_speaker_amp.md): a driver for the Cirrus Logic CS35L54 smart speaker amplifiers (HP ZBook Ultra G1a): firmware download, factory calibration, an hdaa event to follow the speaker stream, and ACPI support in fwget(8). Patch: [cs35l54_speaker_amp.patch](cs35l54_speaker_amp.patch)
- [snd_acp_dmic.md](snd_acp_dmic.md): `snd_acp`, recording from the built-in digital microphones of an AMD laptop. Patch: [snd_acp_dmic.patch](snd_acp_dmic.patch), raw ACPI/Linux captures: [acp/](acp/README.md)
- [amdgpio_intr.md](amdgpio_intr.md): GPIO interrupts on AMD, so the ZBook touchpad stops polling. Patch: [amdgpio_intr.patch](amdgpio_intr.patch)
- [devmatch_hostb.md](devmatch_hostb.md): devmatch(8) autoloads the drivers that live under hostb and vgapci (amdsmu, amdtemp). Patch: [devmatch_hostb.patch](devmatch_hostb.patch)
- [evdev_hp_keys.md](evdev_hp_keys.md): evdev mapping for the HP mic mute and programmable keys. Patch: [evdev_hp_keys.patch](evdev_hp_keys.patch)
- [pci_d3hot.md](pci_d3hot.md): PCI devices that ask for D3hot never leave D0. Patch: [pci_d3hot.patch](pci_d3hot.patch)
- [vnode_pager_getpages_async_completion.md](vnode_pager_getpages_async_completion.md): how a CBMC proof led to a wrong VM patch, and what the getpages completion path really does

## AMD IOMMU

- [amdiommu_ser6.md](amdiommu_ser6.md): bringing up `amdiommu` on the Beelink SER6, test log and patch set
- [bugreport_amdiommu_ir_only_loop.md](bugreport_amdiommu_ir_only_loop.md): `hw.amdiommu.enable=1` alone breaks DMA of every MSI device. Patch: [iommu_idmap_when_dma_disabled.patch](iommu_idmap_when_dma_disabled.patch)
- [bugreport_amdiommu_map_invalidation.md](bugreport_amdiommu_map_invalidation.md): every DMA map waits for an IOTLB invalidation. Patch: [amdiommu_skip_map_invalidation.patch](amdiommu_skip_map_invalidation.patch)
- [amdiommu_irte_free.md](amdiommu_irte_free.md): MSI interrupt remap entries are never freed, nor aligned. Patch: [amdiommu_irte_free.patch](amdiommu_irte_free.patch)

## LinuxKPI

- [linuxkpi_srcu_per_struct.md](linuxkpi_srcu_per_struct.md): one grace period per `srcu_struct`. Patch: [linuxkpi_srcu_per_struct.patch](linuxkpi_srcu_per_struct.patch), test module: [lkpi_srcu_test/](lkpi_srcu_test/)
- [linuxkpi_pcim_iomap_release.md](linuxkpi_pcim_iomap_release.md): `pcim_iomap()` leaks every BAR it maps. Patch: [linuxkpi_pcim_iomap_release.patch](linuxkpi_pcim_iomap_release.patch)
- [linuxkpi_sysfs_binary_attr.md](linuxkpi_sysfs_binary_attr.md): binary sysfs attributes are cut at the first NUL byte. Patch: [linuxkpi_sysfs_binary_attr.patch](linuxkpi_sysfs_binary_attr.patch)
- [lindebugfs_symlink_leak.md](lindebugfs_symlink_leak.md): debugfs symlinks leak their memory on removal. Patch: [lindebugfs_symlink_leak.patch](lindebugfs_symlink_leak.patch)

## Bluetooth

- [fwget_usb_intel_bluetooth.md](fwget_usb_intel_bluetooth.md): fwget(8) detects Intel Bluetooth adapters that need iwmbt-firmware. Patch: [fwget_usb_intel_bluetooth.patch](fwget_usb_intel_bluetooth.patch), bug report: [bugreport_fwget_usb_intel_bluetooth.md](bugreport_fwget_usb_intel_bluetooth.md)
- [iwmbtfw_syslog.md](iwmbtfw_syslog.md): iwmbtfw(8) logs its errors to syslog when devd runs it. Patch: [iwmbtfw_syslog.patch](iwmbtfw_syslog.patch), bug report: [bugreport_iwmbtfw_syslog.md](bugreport_iwmbtfw_syslog.md)
- [rtlbtfw_syslog.md](rtlbtfw_syslog.md): same fix for rtlbtfw(8). Patch: [rtlbtfw_syslog.patch](rtlbtfw_syslog.patch), bug report: [bugreport_rtlbtfw_syslog.md](bugreport_rtlbtfw_syslog.md)
- [ng_ubt_sco_on_demand.md](ng_ubt_sco_on_demand.md): ng_ubt runs SCO transfers only while a SCO link is open (idle adapter caused about 1100 interrupts per second). Patch: [ng_ubt_sco_on_demand.patch](ng_ubt_sco_on_demand.patch), bug report: [bugreport_ng_ubt_idle_isoc.md](bugreport_ng_ubt_idle_isoc.md)

## Driver ports, plans and studies

- [cs35l54_speaker_amp_plan.md](cs35l54_speaker_amp_plan.md): plan for a driver for the Cirrus CS35L54 speaker amplifiers of the HP ZBook Ultra G1a (silent speakers). Userland tool that makes them play: [cs35l54_tool.c](cs35l54_tool.c), read-only probe: [cs35l54_probe.c](cs35l54_probe.c), Linux I2C trace: [cs35l54_linux_i2c_trace_amp1.txt](cs35l54_linux_i2c_trace_amp1.txt) and its decoder [cs35l54_i2c_trace_decode.awk](cs35l54_i2c_trace_decode.awk), Linux data collector: [zbook_collect_linux.sh](zbook_collect_linux.sh)
- [amdxdna_npu.md](amdxdna_npu.md): port of the AMD XDNA 2 NPU driver (Strix Halo) to run FastFlowLM. Test programs: [amdxdna_query.c](amdxdna_query.c), [amdxdna_hwctx.c](amdxdna_hwctx.c)
- [mt7925_wifi.md](mt7925_wifi.md): MediaTek MT7925 Wi-Fi (HP ZBook Ultra G1a), status and test log. Patch series: [mt7925/](mt7925/) and [mt7925_wifi_series.patch](mt7925_wifi_series.patch), firmware port: [mt7925_wifi_firmware_port.patch](mt7925_wifi_firmware_port.patch), experiment: [mt7925_aql_experiment.patch](mt7925_aql_experiment.patch)
- [amdsmu_strix_halo.md](amdsmu_strix_halo.md): amdsmu(4) and suspend-to-idle on Strix Halo. Patch series and Linux reference logs: [amdsmu/](amdsmu/), draft mail to the amdsmu author: [amdsmu_strix_halo_obiwac.md](amdsmu_strix_halo_obiwac.md)
- [amd_isp_camera.md](amd_isp_camera.md): how the ZBook built-in camera (AMD ISP 4.1) works, and what FreeBSD needs. Linux captures and tools: [amd_isp/](amd_isp/), draft drm-kmod-firmware issue: [drm_kmod_firmware_isp_report.md](drm_kmod_firmware_isp_report.md)

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
- [loader_memdisk_zstd_fini.md](loader_memdisk_zstd_fini.md): `memdisk=` frees the zstd stream twice on a failed download. Patch: [loader_memdisk_zstd_fini.patch](loader_memdisk_zstd_fini.patch), test: [loader_memdisk_zstd_fini_test.sh](loader_memdisk_zstd_fini_test.sh)
- [md_preload_len.md](md_preload_len.md): md(4) truncates preloaded ram disks of 4 GiB or more. Patch: [md_preload_len.patch](md_preload_len.patch)
- [ubldr_loaderdev_parsedev.md](ubldr_loaderdev_parsedev.md): ubldr ignores `loaderdev=mmc0p2` (needs the `disk_parsedev()` fix first). Patch: [ubldr_loaderdev_parsedev.patch](ubldr_loaderdev_parsedev.patch), test: [ubldr_loaderdev_parsedev_test.sh](ubldr_loaderdev_parsedev_test.sh)
- [beinstall_etcupdate_destdir.md](beinstall_etcupdate_destdir.md): beinstall.sh post-world etcupdate merges into the running system instead of the new boot environment. Patch: [beinstall_etcupdate_destdir.patch](beinstall_etcupdate_destdir.patch)
- [bugreport_mkimg_size_offset.md](bugreport_mkimg_size_offset.md): mkimg(1) ignored the offset in the `::size` form (unbootable 16.0 ISOs)
- [bmake_meta_mode_relative_writes.md](bmake_meta_mode_relative_writes.md): bmake META_MODE drops relative-path writes (zoneinfo installworld failure). Patch: [bmake_meta_relwrites.patch](bmake_meta_relwrites.patch), test: [bmake_meta_relwrites_test.sh](bmake_meta_relwrites_test.sh)
- [freebsd_uefi_pxe_netbootxyz.md](freebsd_uefi_pxe_netbootxyz.md): booting FreeBSD over UEFI PXE with netboot.xyz

## Userland bug reports

- [bugreport_rpcbind_mergeaddr_wildcard.txt](bugreport_rpcbind_mergeaddr_wildcard.txt): rpcbind GETADDR returns the address of an unrelated interface. Patch: [rpcbind_mergeaddr_wildcard.patch](rpcbind_mergeaddr_wildcard.patch), reproducer: [rpcbind_getaddr_wildcard_repro.sh](rpcbind_getaddr_wildcard_repro.sh)
- [virtual_oss.md](virtual_oss.md): virtual_oss problems in one place: the default configuration records the microphone all the time (about 750 interrupts a second), its default 16 ms buffer is a third of a kernel device's (crackling under Wine), and Wine does not find its `/dev/dsp`. Recommended settings.
- [bugreport_ffmpeg_vaapi_x11.md](bugreport_ffmpeg_vaapi_x11.md): the default `multimedia/ffmpeg` build has no VA-API X11 backend (`--disable-xlib`), so moonlight-embedded decodes in software. Ports patch: [ffmpeg_vaapi_x11.patch](ffmpeg_vaapi_x11.patch)
- [bird3_freebsd_memory_madvise.md](bird3_freebsd_memory_madvise.md): bird3 memory reporting on FreeBSD vs Linux (`MADV_FREE` semantics). Script: [bird3_freebsd_memory_madvise.sh](bird3_freebsd_memory_madvise.sh)

## Debugging walkthroughs

- [i915kms_panic.md](i915kms_panic.md): debugging an i915kms kernel panic on the X1 Carbon (Meteor Lake)
- [freebsd-drm-kmod-vulkan.md](freebsd-drm-kmod-vulkan.md): drm-kmod Vulkan load hang with a 106 GB model on Strix Halo
- [mtl_anv_no_engines.md](mtl_anv_no_engines.md): Meteor Lake, ANV rejects the GPU with drm-latest-kmod 6.12 (i915 UAPI)
- [debug.openblas.md](debug.openblas.md): debugging a port build crash (`math/openblas` SIGBUS)
- [ACPI_AMW0_firmware_error.md](ACPI_AMW0_firmware_error.md): reading an ACPI firmware error with acpica-tools (`AMW0` / `EC0._REG`)
- [TPM_IRQ.md](TPM_IRQ.md): TPM TIS "Failed to switch to ready state" on ST33 chips
- [wine_direct_syscalls.md](wine_direct_syscalls.md): why Wine on FreeBSD cannot catch the Windows system calls a game makes itself (no seccomp equivalent), found with ktrace on a Denuvo game; fixed with syscall dispatch below, the Denuvo benchmark now runs. Wine patch: [wine-proton_syscall_dispatch.patch](wine-proton_syscall_dispatch.patch)
- [procctl_syscall_dispatch.md](procctl_syscall_dispatch.md): `PROC_SYSCALL_DISPATCH_CTL`, a kernel feature modelled on Linux's Syscall User Dispatch that lets a program handle the system calls made by part of its own code; used by Wine and by [../sudtrace](../sudtrace) (interposition that also sees Go programs). Kernel patch: [procctl_syscall_dispatch.patch](procctl_syscall_dispatch.patch), test: [procctl_syscall_dispatch_test.c](procctl_syscall_dispatch_test.c), syzkaller descriptions: [syzkaller_procctl_syscall_dispatch.patch](syzkaller_procctl_syscall_dispatch.patch)
- `vnet_jail_deadlock_*.txt`: raw evidence (dmesg, kgdb session, procstat, netstat, vmstat) for a VNET jail deadlock, no write-up yet

## Hardware bring-up and ports

- [netint_quadra.md](netint_quadra.md): NETINT Quadra T1U video card, which appears as an NVMe device. How libxcoder, FFmpeg, GStreamer, the AI filters and a firmware upgrade tool were ported to FreeBSD, with measured results. Port: `freebsd` branch of ocochard/netint_libxcoder. Live demo: [../netint_demo/](../netint_demo/)
- [xfpm_backlight9.md](xfpm_backlight9.md): `sysutils/xfce4-power-manager` sets the brightness through backlight(9). Ports patch: [xfpm_backlight9.patch](xfpm_backlight9.patch)

## Developer workflow

- [forgejo_ron_git_pr.md](forgejo_ron_git_pr.md): opening and updating pull requests on the ron-dev.freebsd.org Forgejo test instance with git-pr(1) (`devel/freebsd-git-pr`)

## Host operations

- [ser6fbsd_reclaim_ubuntu.md](ser6fbsd_reclaim_ubuntu.md): removing the Ubuntu partition on ser6 and growing the FreeBSD ZFS pool
