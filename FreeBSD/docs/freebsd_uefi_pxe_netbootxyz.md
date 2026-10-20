# Booting FreeBSD via PXE on UEFI systems (netboot.xyz)


## To read:

after many hours of trial and error this is now working:
debug=“yes"
loader="uefi"
uefi_vars="yes"
cpu=2
memory=32G
virt_random="yes"
network0_type="virtio-net"
network0_switch="public"
disk0_type="virtio-blk"
disk0_name="/dev/zvol/h/bhv-02"
disk0_dev="custom"
uuid="86b8741f-7764-11f1-8266-b8ca3aee713a"
network0_mac="58:9c:fc:00:6c:88"
graphics="yes"
graphics_res="1024x768"
grafics_wait="yes"
graphics_listen="0.0.0.0:5901”

and changing the filename in my dhcp i can boot diskless or local root.
the efi partition is empty, so it’s getting the bootrom from /usr/local/share/…

from the logs:
2026-07-04T16:54:49+03:00: restarting
2026-07-04T16:54:49+03:00:  [bhyve options: -c 2 -m 32G -AHPw -l bootrom,/usr/local/share/uefi-firmware/BHYVE_UEFI.fd,/h/vm/bhv-02/uefi-vars.fd -U 86b8741f-7764-11f1-8266-b8ca3aee713a -u]
2026-07-04T16:54:49+03:00:  [bhyve devices: -s 0,hostbridge -s 31,lpc -s 0:4:0,virtio-blk,/dev/zvol/h/bhv-02 -s 0:5:0,virtio-net,tap0,mac=58:9c:fc:00:6c:88 -s 0:6:0,virtio-rnd -s 0:7:0,fbuf,tcp=0.0.0.0:5901:5900,w=1024,h=768]
2026-07-04T16:54:49+03:00:  [bhyve console: -l com1,/dev/nmdm-bhv-02.1A]
2026-07-04T16:54:49+03:00: starting bhyve (run 2)

im still baffled,

thanks,
        danny



## Status

netboot.xyz can boot FreeBSD only on **BIOS/legacy** firmware today. On UEFI
clients, selecting FreeBSD from the menu reaches the chain step and fails
silently.

## Root cause

`roles/netbootxyz/templates/menu/freebsd.ipxe.j2:36`:

```ipxe
initrd ${live_endpoint}${ver}${type}
chain ${memdisk} harddisk raw
```

`memdisk` is a SYSLINUX component that boots a raw disk image by emulating BIOS
`int 13h` calls. There is no UEFI equivalent — SYSLINUX never ported memdisk to
EFI. Any iPXE menu ending in `chain ${memdisk} ...` is BIOS-only by
construction.

The FreeBSD asset itself is a raw mfsbsd disk image:

`endpoints.yml:1125-1131`

```yaml
mfsbsd-14:
  path: /asset-mirror/releases/download/14.2-f360f980/
  files:
  - default.img
  - special-edition.img
  os: freebsd
  version: '14'
```

Note: the menu is already **exposed** under UEFI — `boot.cfg.j2:89` sets
`menu_bsd 1` in the `:efi` block. Only the chain step fails.

## Options to add UEFI support

### Option A — `sanboot` the raw image (menu-side change)

iPXE under UEFI can boot a raw disk image with `sanboot` **iff** the image
carries an EFI System Partition (ESP). FreeBSD's official `memstick.img`
(13.1+) is hybrid BIOS/UEFI and contains an ESP. mfsbsd's stock `default.img`
does **not**.

Menu patch (once the asset is UEFI-capable):

```diff
--- a/roles/netbootxyz/templates/menu/freebsd.ipxe.j2
+++ b/roles/netbootxyz/templates/menu/freebsd.ipxe.j2
@@
-initrd ${live_endpoint}${ver}${type}
-chain ${memdisk} harddisk raw
+sanboot --no-describe ${live_endpoint}${ver}${type}
```

`sanboot` works in both BIOS and UEFI iPXE, so the branch below is optional.

### Option B — Chainload `loader.efi` (proper netboot)

Skip disk images entirely: iPXE fetches FreeBSD's `loader.efi`, then loader
fetches kernel + modules over HTTP/TFTP.

Requires mirroring `boot/`, `kernel/`, and modules — heavier asset-mirror work
than Option A. Reserve for a real netboot installer path, not a memstick
wrapper.

### Option C — Firmware-conditional branch (recommended pairing with A)

Keep memdisk for BIOS, add sanboot for UEFI:

```ipxe
:boot_freebsd
iseq ${platform} efi && goto boot_freebsd_uefi ||
imgfree
initrd ${live_endpoint}${ver}${type}
chain ${memdisk} harddisk raw
exit

:boot_freebsd_uefi
sanboot --no-describe ${live_endpoint}${ver}${type}
exit
```

## Recommended path

Option A + Option C. Cheapest change that actually works, preserves BIOS
behavior.

## Work remaining (to continue later)

1. **Verify current asset.** Download
   `https://github.com/netbootxyz/asset-mirror/releases/download/14.2-f360f980/default.img`
   and inspect:
   ```sh
   file default.img
   mdconfig -a -t vnode -f default.img
   gpart show md0
   ```
   Confirm hypothesis: no ESP => memdisk-only.

2. **Pick a UEFI-capable source image.** Candidates:
   - FreeBSD official `FreeBSD-14.x-RELEASE-amd64-memstick.img` (hybrid).
   - Rebuild mfsbsd with an ESP added (upstream mfsbsd doesn't ship one; would
     need a fork or a wrapper script that grafts an ESP with `loader.efi`
     onto the mfsbsd image).

3. **Test sanboot locally** before touching netboot.xyz:
   - Boot iPXE under OVMF (QEMU UEFI).
   - `sanboot --no-describe http://.../memstick.img`.
   - Confirm FreeBSD installer starts.

4. **Update `endpoints.yml`.** Either:
   - Add a new endpoint `mfsbsd-14-uefi` pointing at the UEFI-capable image,
     keep `mfsbsd-14` for BIOS, and branch in the menu on `${platform}`, OR
   - Replace `default.img` in the existing `mfsbsd-14` endpoint (single asset
     works for both firmwares via sanboot — simpler).

5. **Patch the menu.**
   `roles/netbootxyz/templates/menu/freebsd.ipxe.j2` — apply Option A (or A+C
   if keeping a BIOS-only fallback for the current mfsbsd asset).

6. **Regression test.** Boot the menu under:
   - BIOS iPXE (legacy VM) — existing path must still work.
   - UEFI iPXE (OVMF) — new path boots FreeBSD.

7. **Upstream.** Open a PR against `netbootxyz/netboot.xyz` (development
   branch). Reference the memdisk/UEFI limitation in the description.

## Reference files in this repo

- `roles/netbootxyz/templates/menu/freebsd.ipxe.j2` — the menu with the
  memdisk chain.
- `roles/netbootxyz/templates/menu/boot.cfg.j2:47-90` — architecture gates;
  `menu_bsd` is already 1 under `:efi`.
- `endpoints.yml:1125-1131` — mfsbsd-14 endpoint definition.
- Other memdisk consumers (all BIOS-only for the same reason):
  `utils-pcbios-64.ipxe.j2`, `utils-pcbios-32.ipxe.j2`, `openbsd.ipxe.j2`,
  `freedos.ipxe.j2`.

## Open questions

- Does upstream mfsbsd have any interest in producing a hybrid image? Check
  `mfsbsd.vx.sk` and its git repo before forking.
- Is netboot.xyz upstream open to a `${platform}`-branched menu, or do they
  prefer a single sanboot path? Check `CONTRIBUTING.md` and recent PRs
  touching `*.ipxe.j2`.
