# fwget(8) does not detect Intel Bluetooth adapters that need iwmbt-firmware

```
Category:  bin
Component: bin
Version:   16.0-CURRENT
```

Patch: [`fwget_usb_intel_bluetooth.patch`](fwget_usb_intel_bluetooth.patch)
(`usr.sbin/fwget/usb/usb`, `usr.sbin/fwget/usb/usb_intel`, `usr.sbin/fwget/usb/Makefile`).
Background for readers new to this code: [`fwget_usb_intel_bluetooth.md`](fwget_usb_intel_bluetooth.md).

**Summary.** Intel USB Bluetooth adapters (vendor 0x8087) need firmware from the
`comms/iwmbt-firmware` package before any driver attaches.
`fwget -n` does not list that package, and nothing else tells the user it is missing.
The patch adds a `usb_intel` script to fwget that maps the product IDs from
`iwmbtfw.conf` to `iwmbt-firmware`.

## How to repeat

Machine: Beelink SER6, Intel AX200 Wi-Fi + Bluetooth (Bluetooth part is USB 8087:0029).
FreeBSD 16.0-CURRENT main-n290674, `iwmbt-firmware` not installed.

```
$ usbconfig
ugen1.3: <AX200 Bluetooth Intel Corp.> at usbus1, cfg=0 md=HOST spd=FULL (12Mbps) pwr=ON (100mA)
$ devinfo | grep -c ubt
0
$ fwget -n -v
Trying to match device 0x8125 in class network and vendor realtek with pci_network_realtek
Trying to match device 0x2723 in class network and vendor intel with pci_network_intel
Trying to match device 0x1681 in class video and vendor amd with pci_video_amd
Needed firmware packages: 'wifi-firmware-iwlwifi-kmod-22000 gpu-firmware-amd-kmod-yellow-carp'
```

fwget finds the Wi-Fi firmware for the PCI side of the same card, but not the Bluetooth firmware.
The USB part of fwget knows only one vendor, Ralink (`usr.sbin/fwget/usb/usb_ralink`).

## Why the user gets no other hint

- `ng_ubt_intel` rejects the adapter in bootloader mode with `ENXIO` and prints nothing.
- devd runs `iwmbtfw -d $cdev -f /usr/local/share/iwmbt-firmware` (`iwmbtfw.conf`),
  but iwmbtfw reports the missing file on stderr, which devd sends to `/dev/null`.
  `grep -c iwmbtfw /var/log/messages` gives 0. A separate report covers that (iwmbtfw: log errors to syslog).
- The package name appears only in `iwmbtfw(8)`.

The only visible symptom is a `ugen` device with no driver and no Bluetooth.

## Fix

- `usr.sbin/fwget/usb/usb`: `usb_get_vendor()` maps 0x8087 to `intel`.
- New `usr.sbin/fwget/usb/usb_intel`: the 12 product IDs of `iwmbtfw.conf`
  (0x07dc 0x0a2a 0x0aa7 0x0a2b 0x0aaa 0x0025 0x0026 0x0029 0x0032 0x0033 0x0035 0x0036)
  call `addpkg "iwmbt-firmware"`. One case line per ID, like `usb_ralink` and the PCI tables.
  The list matches the `ng_ubt_intel` ID table.
- `usr.sbin/fwget/usb/Makefile`: install `usb_intel`.

bsdinstall's firmware step runs `fwget -q -n` (`usr.sbin/bsdinstall/scripts/firmware`),
so new installs get the package offered too.

Limits:

- The ID list now exists in two places, `iwmbtfw.conf` and `usb_intel`; a comment in `usb_intel` says to keep them in sync.
- After installing the package, the firmware loads only on the next USB attach:
  reboot, or run `iwmbtfw -d ugenX.Y -f /usr/local/share/iwmbt-firmware`.
  On the test machine a warm reboot and `shutdown -p` both kept the adapter powered,
  so it stayed as it was; only removing mains power reset it.

## Tested

Beelink SER6, 2026-11-16. Patched scripts run from a temporary directory with `LIBEXEC_PATH` set (fwget.sh honors it).

| Test | Result |
|---|---|
| stock `fwget -n -v usb` | `No firmware packages to install.` |
| patched `fwget.sh -n -v usb` | `Trying to match device 0x0029 and vendor intel with usb_intel`, `Needed firmware packages: 'iwmbt-firmware'` |
| patched `fwget.sh -n`, all subsystems | `wifi-firmware-iwlwifi-kmod-22000 gpu-firmware-amd-kmod-yellow-carp iwmbt-firmware` |
| `usb_intel` alone, IDs 0x0029, 0x0036, 0x07dc, 0x0a2b | package added, return 1 |
| `usb_intel` alone, IDs 0x0aa8, 0x1234 | nothing added, return 0 |
| `make -n install` in `usr.sbin/fwget/usb` | installs `usb_intel` next to `usb_ralink` |
| `pkg install iwmbt-firmware`, `iwmbtfw -d ugen1.3` | `Firmware download is successful!`, `ubt0` attaches, `hccontrol -n ubt0hci read_bd_addr` answers |

Not tested:

- `fwget` without `-n` (the `pkg install` path).
- The bsdinstall firmware step.
- Adapters of the 7260, 8260 and 9260 families: no hardware.
