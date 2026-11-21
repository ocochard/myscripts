i915: enable the Meteor Lake media GT on FreeBSD 1600032 and later

Commit 5c341599a7a2 (#418) skips GT1, the standalone media GT, because its
GuC failed authentication. The cause is not the missing MEI driver:
LinuxKPI vmap() ignored the pgprot, so the write-combined mappings i915
uses for the media GT (Wa_22016122933, the media GT does not snoop the
CPU caches) were cached, and the GuC BootROM read a stale firmware
signature (BootROM = 0x50, RSA_FAILED).

FreeBSD fixes vmap() in <review link> (__FreeBSD_version 1600032). This
keeps the skip only for older kernels. Without MEI, i915 already gives up
cleanly on the GSC proxy, and HDCP stays disabled by is_hdcp2_supported().

Tested on a ThinkPad X1 Carbon Gen 12 (8086:7d45), hw.i915kms.enable_guc=3:

- GT1 GuC submission enabled, HuC authenticated for all workloads
- video engines exposed (VCS0, VCS1, VECS0)
- VA-API (libva-intel-media-driver): H.264 decode bit-exact with software;
  H.264, HEVC, AV1 encode work
- same after a suspend_bounce cycle

Not available without MEI: PXP (protected playback) and HDCP.

Write-up: https://github.com/ocochard/myscripts/blob/master/FreeBSD/docs/mtl_media_gt.md
