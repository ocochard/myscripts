# ng_ubt: idle USB Bluetooth adapter causes about 1100 interrupts per second

```
Category:  kern
Component: kern
Version:   16.0-CURRENT
```

Patch: [`ng_ubt_sco_on_demand.patch`](ng_ubt_sco_on_demand.patch)
(`sys/netgraph/bluetooth/drivers/ubt/ng_ubt.c`, `ng_ubt_var.h`, `sys/netgraph/bluetooth/include/ng_hci.h`).
Branch: `olivier-ubt-sco` on github.com/ocochard/freebsd-src.
Background for readers new to this code: [`ng_ubt_sco_on_demand.md`](ng_ubt_sco_on_demand.md).

**Summary.** `ng_ubt` starts its four SCO (voice) isochronous transfers as soon as `ng_hci` connects, and keeps them running whether or not a SCO link exists.
Each running isochronous transfer completes every USB frame, so an idle adapter keeps the xHCI controller interrupting about 1100 times per second.
The patch tracks SCO and eSCO links from the HCI events `ng_ubt` already receives, and runs the isochronous transfers only while a link is open.

## How to repeat

Machine: Beelink SER6, AMD Ryzen 7 7735HS, Intel AX200 Bluetooth (USB 8087:0029, firmware loaded by `iwmbtfw`),
FreeBSD 16.0-CURRENT main-n290674 (7806832f23fb). No Bluetooth connection, machine idle.

```
$ vmstat -i | grep xhci1          # twice, 10 s apart
# usbdump -i usbus1 -s 0          # for a few seconds
```

| State | `xhci1` interrupts/s |
|---|---|
| `ubt0` attached | 1083 to 1226 |
| `usbconfig -d ugen1.3 set_config 255` (adapter unconfigured) | 0 |
| `set_config 0` again | 1084 |
| `net.bluetooth.usb_isoc_enable=0`, adapter re-attached | 0 |

`usbdump` shows only the adapter (`usbus1.3`) on that bus, with nonstop isochronous transfers on endpoints 0x83 and 0x03, 32 frames each:

```
usbus1.3 SUBM-ISOC-EP=00000083,SPD=FULL,NFR=32,SLEN=0,IVAL=0
usbus1.3 DONE-ISOC-EP=00000083,SPD=FULL,NFR=32,SLEN=0,IVAL=0,ERR=0
usbus1.3 SUBM-ISOC-EP=00000003,SPD=FULL,NFR=32,SLEN=0,IVAL=0
usbus1.3 DONE-ISOC-EP=00000003,SPD=FULL,NFR=32,SLEN=0,IVAL=0,ERR=0
```

## Cause

- `ubt_attach()` selects the alternate setting of interface 1 with the largest packet size and sets up the four isochronous transfers.
- `ubt_task()`, on `UBT_FLAG_T_START_ALL`, starts them:
  "Start both read and write isoc. transfers by default. Get them going all the time even if we have nothing to send to avoid any delays."
- The only way to stop them is `net.bluetooth.usb_isoc_enable=0`, which also removes SCO support.

Linux `btusb` keeps isochronous traffic off (interface 1 on alternate setting 0) until a SCO connection exists.

## Fix

- `ng_hci.h`: `NG_HCI_EVENT_SYNC_CON_COMPL` (0x2C) and `ng_hci_sync_con_compl_ep`
  (Bluetooth Core Specification 5.x, Volume 4, Part E, 7.7.35; section number from memory).
- `ubt_sco_track()`, called from `ubt_intr_read_callback()` on each valid HCI event:
  - Connection Complete with link type SCO, or Synchronous Connection Complete (SCO and eSCO), with status 0: add the handle;
  - Disconnection Complete with status 0: remove the handle if tracked (the event carries no link type);
  - Command Complete for `HCI_Reset`: forget all links;
  - schedule the task only when the link count goes between 0 and 1 or more.
- `ng_ubt_var.h`: up to `UBT_SCO_MAX` (4) handles; links beyond it (BR/EDR allows 3) count separately and keep the transfers on until reset or detach.
- `ubt_task()`: on `UBT_FLAG_T_START_ALL` or the new `UBT_FLAG_T_ISOC`, start the four isochronous transfers if a link is open,
  else stop them and free the partial SCO reassembly buffer.
- `ng_ubt_disconnect()`: forget all links.

Tracking in `ng_ubt` needs no new message from `ng_hci`, and also sees links opened through a raw HCI socket.

Limits:

- The first milliseconds of SCO data after a link comes up can be lost, while the task starts the transfers.
- Interface 1 stays on the largest alternate setting; switching to setting 0 while idle, as Linux does, would also free the reserved bandwidth.

## Tested

Beelink SER6, 2026-11-16. Patched `ng_ubt.ko` built against the running kernel's source
(`sys/netgraph/bluetooth` is identical in 7806832f23fb and 563c2f27e0ff), swapped in with devd stopped so devmatch could not reload the stock module.

| Test | Result |
|---|---|
| module build | no warning |
| stock `ng_ubt`, idle | 1088 `xhci1` interrupts/s |
| patched, `service bluetooth onestart ubt0` | `hccontrol read_bd_addr` answers; 0 `xhci1` interrupts/s |
| patched, `hccontrol reset`, then `inquiry` | inquiry finds 2 devices; 0 `xhci1` interrupts/s |
| stock module loaded again | 1226 `xhci1` interrupts/s |

Not tested:

- A real SCO or eSCO call (no headset available): transfers starting on link setup, voice data, transfers stopping on disconnection.
- Several simultaneous SCO links.
- Other adapters (Realtek, MediaTek, Broadcom) and other host controllers.
- Power: the energy cost of the 1100 interrupts per second was not measured.
