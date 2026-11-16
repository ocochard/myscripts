Draft: issue for github.com/freebsd/drm-kmod-firmware

Title: Tag 20260519 ships an old isp_4_1_1.bin (and 27 other files behind linux-firmware 20260519)

The `20260519` tag (2c12915, "Update firmwares for DRM drivers",
2026-04-09) does not match linux-firmware tag `20260519`: 28 files under
`amdgpukmsfw-files/` differ, among them `isp_4_1_1.bin`, the firmware of
the AMD ISP 4.1 camera processor on Strix Halo. graphics/gpu-firmware-amd-kmod
uses this tag, so FreeBSD users get firmware the PORTVERSION does not
suggest.

`isp_4_1_1.bin`:

| Source | Size | md5 | Build string in the blob |
|---|---|---|---|
| drm-kmod-firmware tag 20260519 | 6083536 | 6032620024ffecee4fb92eecc66a85ee | `210721_SMDK 2025/02/14 06:51 E9925 7a54a07e` |
| linux-firmware (last ISP change a89515d3, 2025-08-25, "amdgpu: Update ISP FW for isp v4.1.1") | 3859408 | c872d1bafabd9a274487d00c76bda924 | `210721_SMDK 2025/08/22 04:18 E9925 ccb1f23` |

Impact, measured on an HP ZBook Ultra G1a (Ryzen AI Max+ PRO 395, Strix
Halo, OmniVision OV05C camera module): with the February 2025 firmware the
ISP boots and accepts the stream set-up, but never talks to the sensor (it
reads I2C address 0x50 instead of the sensor at 0x10) and answers
START_STREAM with an error notification, so no frame ever arrives. With the
August 2025 firmware (the linux-firmware file, also what Ubuntu ships in
linux-firmware-amd-graphics 20260319) the same driver streams correct
frames. No FreeBSD driver uses the ISP yet (a test driver does, see
https://github.com/ocochard/myscripts/blob/master/FreeBSD/docs/amd_isp_camera.md),
but any future one needs the current file.

The 28 files that differ from linux-firmware 20260519:

- added in linux-firmware, missing from the tag: gc_12_0_1_imu_kicker.bin,
  gc_12_0_1_rlc_kicker.bin, psp_14_0_3_sos_kicker.bin,
  psp_14_0_3_ta_kicker.bin, smu_14_0_3_kicker.bin, vce_1_0_0.bin
- older in the tag: dcn_3_6_dmcub.bin, gc_11_5_3_imu.bin, gc_11_5_3_me.bin,
  gc_11_5_3_mec.bin, gc_11_5_3_mes1.bin, gc_11_5_3_mes_2.bin,
  gc_11_5_3_pfp.bin, gc_11_5_3_rlc.bin, gc_9_5_0_mec.bin, gc_9_5_0_rlc.bin,
  gc_9_5_0_sjt_mec.bin, isp_4_1_1.bin, psp_13_0_0_ta_kicker.bin,
  psp_13_0_12_sos.bin, psp_13_0_12_ta.bin, psp_13_0_5_asd.bin,
  psp_14_0_5_ta.bin, psp_14_0_5_toc.bin, renoir_mec2.bin, sdma_4_4_4.bin,
  sdma_6_1_3.bin, vcn_5_0_1.bin

A sync of all amdgpu files to linux-firmware 20260519 (copy the `.bin`
files, run `amdgpukmsfw/gen-makefiles`) is in
https://github.com/ocochard/drm-kmod-firmware/commit/5997c08
(branch `sync-linux-firmware-20260519`), if it helps. The ISP file has not
changed in linux-firmware since 2025-08-25, so a newer tag gives the same
ISP firmware.
