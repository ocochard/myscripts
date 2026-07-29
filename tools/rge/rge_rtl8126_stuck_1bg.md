# FreeBSD `rge(4)` RTL8126 stuck at 1000baseT: NOT a driver bug (confound resolved)

## TL;DR — final conclusion: framework's `0x64a` silicon is the fault (2026-07-29)

An onboard Realtek **RTL8126** (XID `0x64a`, "rev.b" / Linux `VER_66`) on a
Framework Desktop would only ever link at **1000baseT** under FreeBSD `rge(4)`;
forcing `2500Base-T` gave permanent `no carrier`.

**Root cause: framework's onboard RTL8126A (`0x64a`) cannot train 2.5GBASE-T. It
is a hardware fault, not a driver or cabling problem — no driver, FreeBSD or
Linux, can fix it.** Everything external to the chip has been proven good on the
*same physical path*:

- **Driver:** framework's `0x64a` fails 2.5G under FreeBSD `rge`, the FreeBSD
  Realtek vendor `if_re`, **and** rev.b-aware Linux 7.0 (`Link detected: no` when
  forced). Three independent drivers, same failure.
- **Switch port:** advertises `2500baseT/Full` + `5000baseT/Full` to framework.
- **Cable + port:** proven to carry a real **`2500Mb/s`** link — `framework2` was
  moved onto framework's exact former cable+port and negotiated 2.5G there
  (`Speed: 2500Mb/s, Link detected: yes`).

Since the cable, the switch port, and three drivers are all proven good, the only
remaining variable is framework's NIC silicon itself.

**This is NOT an `rge(4)` bug.** The decisive experiment finally ran on
2026-07-29: framework's *exact* `0x64a` chip was booted on **Ubuntu with a Linux
7.0.0-14 kernel** — an `r8169` that fully supports this stepping (`VER_66` was
added upstream in ~6.11; 7.0 is well past it). Result:

- Auto-negotiation settles at **`Speed: 1000Mb/s`** (same as FreeBSD).
- Forcing 2.5G (`ethtool -s enp191s0 autoneg on speed 2500 duplex full`) gives
  **`Speed: unknown`, `Link detected: no`** — the identical failure mode to
  FreeBSD's `no carrier` / `PHYSTAT` never reaching `0x0400`.

A mature, rev.b-aware Linux driver fails **exactly** the same way. Every
driver-writable candidate eliminated below was eliminated correctly — there was
never a software fix to find, because the reference implementation does not
succeed either. **The failure localizes to framework's NIC + its cable run, not
the driver.** The switch port is cleared: it advertises `2500baseT/Full` +
`5000baseT/Full` to framework (verified 2026-07-29), so the remaining suspects
are the cable run and the `0x64a` silicon/board. See "Confound resolved" below for
the corrected reasoning and the physical-layer test plan.

> **Why the earlier "it's a software bug" claim was wrong.** The whole
> investigation rested on "the same board trains 2.5G under Ubuntu." That was a
> **stepping confound**: the working 2.5G proof was on a *different* box
> (`framework2`, XID `0x649` / `VER_65`), never on framework's own `0x64a`
> silicon. Once framework's actual chip was booted under a rev.b-aware Linux, it
> failed too. The premise collapsed, and with it the "software problem, full
> stop" conclusion.

**Everything below is the elimination trail** — kept because it is *how* the
confound was cornered, and because every candidate it clears (PHY firmware,
MAC-MCU, init order, `0xe614`, the C-config block) is genuinely, verifiably not
the cause. Read it as "what a driver author can rule out," not as "steps toward a
fix." There is no driver fix.

## What "training" means here

"Link training" is the physical-layer handshake two Ethernet PHYs run over the
copper pair before any packets flow. It is *not* IP/DHCP/ARP and *not*
auto-negotiation of speed alone — it is the analog bring-up that happens after
both ends agree on a speed:

1. **Auto-negotiation (Clause 28 / Clause 73-style for multi-gig):** each PHY
   advertises the speeds it supports (for `rge`, the 2.5G/5G bits live in OCP
   register `0xa5d4`; the partner's advertised abilities are read back at
   `0xa5d6`). Both sides pick the highest common speed.

2. **PMA/PMD training (the part that fails here):** once 2.5GBASE-T is selected,
   the two PHYs run an equalizer/coefficient exchange to adapt to the specific
   cable — tuning the transmit pre-emphasis, receive equalizer taps, echo/NEXT
   cancellers, and timing recovery until the bit-error rate is low enough to
   declare the link "up." 2.5G/5GBASE-T (IEEE 802.3bz) and 10GBASE-T use a much
   more elaborate DSP-based training than 1000BASE-T; it leans on the PHY's
   analog front-end being correctly powered and initialized, which on Realtek
   multi-gig parts is set up by the on-chip **MCU firmware** and the
   power-up/reset sequence the MAC driver performs.

3. **Link-up:** training converges, the PHY asserts link, `PHYSTAT` (`0x006c`)
   reports the achieved speed (bit `0x0400` = 2500M).

"The driver trains 2.5G" is shorthand for: the driver initializes the PHY into a
state where step 2 can converge at 2.5GBASE-T. When step 2 *cannot* converge, the
PHY gives up on 2.5G, withdraws its 2.5G advertisement, and the pair falls back
to 1000BASE-T — whose older, simpler training (adaptive equalization without the
bz DSP machinery) still succeeds. That fallback is exactly the observed symptom:
link comes up, but only ever at 1G. When 2.5G is *forced* (advertise 2.5G only),
there is no 1G to fall back to, training never converges, and the result is a
permanent `no carrier`.

The whole investigation is therefore about *why step 2 fails to converge at 2.5G
on this board under `rge`*, given that auto-negotiation (step 1) demonstrably
works and the switch's own 2.5G training works against other hosts.

## The three drivers

| | driver | source | 2.5G on framework (a-3) |
|---|---|---|---|
| base | `rge(4)` | `sys/dev/rge/` (OpenBSD-derived, Kevin Lo; FreeBSD maintainer Adrian Chadd) | **NO** |
| vendor | `if_re` | Realtek `rtl_bsd_drv` out-of-tree | **NO** (also 1G only; see bisection) |
| Linux | `r8169` | `drivers/net/ethernet/realtek/` | **also fails on framework's `0x64a`** (kernel 7.0, forced 2.5G → `Link detected: no`); works on framework2's `0x649` |

**Every driver on framework's `0x64a` fails 2.5G — including a rev.b-aware Linux
7.0.** The only confirmed 2.5G success anywhere is Linux `r8169` on `framework2`,
a *different stepping* (`0x649`, see next section). When framework's own chip was
finally booted under a capable Linux (2026-07-29), it failed exactly like FreeBSD
— so there is no known-working 2.5G path for this specific board under any OS.
That retires the "it's a FreeBSD driver bug" hypothesis; see "Confound resolved."

## Two boards, two steppings (NOT the same silicon)

The reference host and the failing host share a PCI device ID and board vendor but
are **different chip steppings**. This matters: the a-2 and a-3 PHYs use different
firmware families (`rtl8126a-2.fw` vs `rtl8126a-3.fw`) and can have different
analog bring-up requirements, so "framework2 does 2.5G under Linux" does **not**
prove framework's chip can.

| | `framework` (fails 2.5G) | `framework2` (does 2.5G) |
|---|---|---|
| OS / driver | FreeBSD 16-CURRENT / `rge(4)` | Ubuntu (kernel 7.0.0-28) / `r8169` |
| PCI ID | `10ec:8126` rev `01`, subsys `f111:000a` | `10ec:8126` rev `01`, subsys `f111:000a` |
| **hwrev / XID** | **`0x64a`** (`0x64A00000`) | **`0x649`** |
| stepping | **a-3** (FreeBSD `MAC_R26_2`, vendor `MACFG_92` = "8126a_3") | **a-2** ("8126a_2") |
| PHY firmware family | `rtl8126a-3` | `rtl8126a-2_0.0.2 02/01/24` |
| MAC address | `9c:bf:0d:00:e4:ed` | `9c:bf:0d:00:e1:3b` |
| current 2.5G link | no (best 1000baseT) | **yes, 2500Mb/s full, flow control rx/tx** |

The XID is `(TxConfig >> 16) & 0xfcf`, decoded from the MAC's `TxConfig` hwrev
field, **not** from PCI revision (both are PCI rev `01`). The a-2/a-3 difference
only shows up in that field.

> **Authoritative naming (Realtek upstream commit 69cb89981c7a, "r8169: add
> support for RTL8126A rev.b", ChunHao Lin, Aug 2024).** Realtek calls **XID
> `0x64a` = "rev.b"**, VER_66, firmware `rtl8126a-3.fw`; and **XID `0x649` =** the
> original 8126A, VER_65, firmware `rtl8126a-2.fw`. So framework is the *rev.b*
> silicon whose firmware file is confusingly named `-3` (and whose blob version
> string self-labels "rev.c"). Elsewhere in this doc "a-3" is shorthand for
> framework's XID-0x64a chip / its `rtl8126a-3.fw` — not a claim about the
> silicon revision letter. **Consequence for the decisive test:** VER_66 was only
> *added to mainline r8169 by this very patch*. A Linux kernel older than ~6.11
> (or any distro lacking this backport) has **no `mac_info` entry for 0x64a** and
> cannot drive framework's chip correctly. The 2.5G-works confirmation was on
> framework2's **0x649 (VER_65)**, which has been supported far longer. So booting
> framework under Linux only proves anything if that Linux is new enough to carry
> VER_66 (mainline ≥6.11, or the OpenWrt `780-22-v6.12` backport). **This test was
> run on 2026-07-29 with kernel 7.0.0-14-generic (VER_66 present): framework's
> `0x64a` failed 2.5G under Linux too — `Link detected: no` when forced. That
> resolves the confound; see "Confound resolved."**
>
> **What the patch changes for 0x64a, and why none of it is new to `rge`:** the
> patch adds (1) the firmware file `rtl8126a-3.fw` — `rge` already embeds the
> dedicated `mac_r26_2_mcu[]` blob for `MAC_R26_2`, and we transplanted the exact
> `-3.fw` content (DISPROVEN #6); (2) the register writes in
> `rtl_hw_start_8125_common` — `0xD8 &= ~0x02`, `0xe614: 0x0700→0x0400`,
> `0xea1c: 0x0300→0` — all of which `rge` already performs for `MAC_R26_2`
> (`if_rge.c:1178`, `:1193`, `:1246` where `0x0304` = `0x0300|0x0004`), and
> `0xe614` was tested at both `0x0300` and `0x0400` (DISPROVEN #5); (3) enum /
> dispatch plumbing so an *unpatched* Linux recognizes 0x64a — `rge` already maps
> `0x64a00000 → MAC_R26_2` (`if_rge.c:426`) and routes it to `rtl8126_2_mac_bps`
> + `rge_phy_config_mac_r26_2`. **The patch therefore contains nothing `rge` is
> missing.** It is the mainline plumbing to make stock Linux do what `rge`
> already does — every substantive element is already implemented and tested on
> FreeBSD.

### How the identity data was extracted

**framework (FreeBSD):**
```sh
# PCI id + revision + subsystem
pciconf -lv rge0
#   rge0@pci0:191:0:0: class=0x020000 rev=0x01 hdr=0x00 vendor=0x10ec \
#     device=0x8126 subvendor=0xf111 subdevice=0x000a

# hwrev / stepping — from the kernel boot log (rge prints the decoded chip rev):
grep -i rge0 /var/run/dmesg.boot | grep -v linkdiag
#   rge0: <RTL8126> port 0x2000-0x20ff mem 0xb0d00000-... at device 0.0 on pci1
#   rge0: chip rev: RTL8126_2 (0x64a00000)   <-- hwrev; XID = (0x64a00000>>16)&0xfcf = 0x64a
#   rge0: Ethernet address: 9c:bf:0d:00:e4:ed
```
`0x64A00000` is `RGE_READ_4(RGE_TXCFG) & RGE_TXCFG_HWREV`; FreeBSD's chip-rev
table in `if_rge.c` decodes it to `MAC_R26_2`, and the vendor `if_re` table
decodes the same value to `MACFG_92` ("8126a_3").

**framework2 (Ubuntu/Linux):**
```sh
# PCI id + revision + subsystem
lspci -nn -d 10ec:                 # -> [10ec:8126] (rev 01)
lspci -vmmnn -s bf:00.0            # -> SVendor f111, SDevice 000a, Rev 01

# XID / stepping — r8169 prints it at probe:
sudo dmesg | grep -i r8169
#   r8169 0000:bf:00.0 eth0: RTL8126A, 9c:bf:0d:00:e1:3b, XID 649, IRQ 69

# live link speed + firmware family:
sudo ethtool enp191s0     | grep -iE "speed|duplex|link detected"   # Speed: 2500Mb/s
sudo ethtool -i enp191s0  | grep firmware   # firmware-version: rtl8126a-2_0.0.2 02/01/24
sudo dmesg | grep -i "Link is Up"           # Link is Up - 2.5Gbps/Full - flow control rx/tx
```

**Consequence for the fix:** the PHY-config functions still map 1:1
(`rge_phy_config_mac_r26_2` <-> `re_hw_phy_config_8126a_3`), so the `rge`-vs-vendor
comparison remains valid *within the a-3 stepping*. But the cross-check against
Linux assumes a-3 behaves like a-2, which is unproven. The decisive open test is
to boot framework's own a-3 chip under Linux `r8169`: if it trains 2.5G, the bug
is purely FreeBSD software; if it also fails, the limitation is
silicon/stepping-specific and no `rge` change will fix it.

## How the failure looked

- New cable, different switch port: still 1G.
- Link partner (switch) advertises `2500baseT/Full` (confirmed via `ethtool` on
  the Linux host on the same port): the switch offers 2.5G.
- `iperf3` on the 1G link: 941/942 Mbit/s, 0 errors. The link is healthy, just
  capped.
- Force `2500Base-T` (advertise 2.5G only): `no carrier`.
- Force `5000Base-T`: stays 1G.

## Diagnostic method (linkdiag)

The decisive step was instrumenting `rge_link_state()` to log, on every link
change, the raw PHY negotiation registers:

- **PHYSTAT** (`RGE_PHYSTAT` = `0x006c`): live link result. Bits:
  `0x0002`=LINK, `0x0001`=FDX, `0x0010`=1000M, `0x0400`=2500M, `0x1000`=5000M.
- **local advertisement** OCP `0xa5d4`: `0x0080`=2.5G, `0x0100`=5G, `0x1000`=10G.
- **link-partner ability** OCP `0xa5d6`: same bit layout, what the switch offers.
- **BMSR** autoneg-complete bit.

What it showed:
- Local `0xa5d4` = `0x0181` (2.5G + 5G advertised) — advertisement is correct.
- Partner `0xa5d6` shows the 2.5G-capable bit — the switch offers 2.5G.
- **BMSR autoneg-complete never sets at 2.5G**, and PHYSTAT never shows `0x0400`.
- In autoselect the PHY *withdraws* its own 2.5G advertisement (`0x0181` ->
  `0x0001`) and settles at 1G.
- Forced 2500: `0xa5d4`=`0x0081`, PHYSTAT=`0x0090` (no LINK bit) -> permanent
  no-carrier.

Conclusion from linkdiag: **both sides advertise 2.5G but the PHY cannot
complete 2.5G training.** This is a training/bring-up failure, not an
advertise-programming bug. That reframing is what redirected the hunt away from
the (correct) advertisement code and toward the init sequence.

## What was ruled out (all identical to the working vendor driver)

Each of these was diffed against the vendor `if_re` and found equivalent, so none
is the bug:

- **Advertisement path** `rge_ifmedia_upd` (`if_rge.c`): reads/writes OCP
  `0xa5d4`, sets 2.5G+5G for `IFM_AUTO`, then `BMCR_RESET|AUTOEN|STARTNEG`. Same
  register writes and same order as vendor `re_ifmedia`.
- **Post-MCU PHY config** `rge_phy_config_mac_r26_2` (`if_rge_hw.c`): verified
  byte-for-byte identical to vendor `re_hw_phy_config_8126a_3`.
- **PHY MCU RAM code** `mac_r26_2_mcu[]` (`if_rge_microcode.h`, 2449 writes):
  byte-for-byte identical to vendor `phy_mcu_ram_code_8126a_3_1`. (An earlier
  claim that this blob was truncated was a miscount and was retracted.)
- **PHY MCU load handshake** `rge_patch_phy_mcu`: identical (set `0xb820`
  BIT4, poll `0xb800` BIT6, clear on teardown).

The lesson: on a driver ported from another OS, the per-chip register tables and
firmware blobs are usually copied faithfully. The bugs hide in the *glue* — the
order in which those correct pieces are invoked.

## Bug #1: PHY MCU load gated behind an unreliable version stamp

`rge_phy_config_mcu()` (`if_rge_hw.c`) originally gated the entire PHY RAM-code
load behind a version check:

```c
if (sc->rge_rcodever != rcodever) {
        ... load mac_r26_2_mcu[] ...
        rge_write_phy_ocp(sc, 0xa436, 0x801e);   /* write version stamp */
        rge_write_phy_ocp(sc, 0xa438, rcodever);
}
```

`sc->rge_rcodever` is read from on-chip OCP `0x801e` *after* the PHY soft reset
in `rge_phy_config()`. On the RTL8126 that version-stamp register survives the
soft reset (and can be pre-set by UEFI), while the actual RAM code is not
functional. When the stamp already matched the expected value, the load was
skipped and the PHY ran base 1G logic that cannot train 2.5G.

Linux `r8169` never gates on an on-chip version stamp: `r8169_apply_firmware()`
writes the PHY firmware unconditionally whenever PHY config runs; the version
string is display-only. That is the correct model.

**Fix:** load the RAM code unconditionally, keep the stamp write for logging.
This was necessary but **not sufficient** — 2.5G still failed, which is what led
to bug #2.

## Hypothesis #2 (DISPROVEN): inverted init order

This was the leading hypothesis before hardware testing. It is documented in full
because the reasoning is sound and the vendor-alignment is worth keeping — but it
did **not** fix 2.5G (see *Verification*), and the vendor `if_re`, which already
uses this "correct" order, fails identically. So the init order is not the root
cause on this board.

**Vendor `re_hw_init()` (`rtl_bsd_drv/if_re.c`), key order:**

```
re_exit_oob(sc);
...
re_hw_mac_mcu_config(sc);   /* MAC MCU load        */
re_phy_power_up(sc);        /* PHY power-up (PMCH bits, BMCR_AUTOEN, wait UPS==3) */
re_hw_phy_config(sc);       /* PHY config + PHY MCU */
```

No MAC reset happens between PHY power-up and PHY config.

**FreeBSD (before fix) `rge_chipinit()` + `rge_init_locked()`:**

```
rge_exit_oob(sc);
rge_set_phy_power(sc, 1);   /* PHY up, wait UPS state==3   -- BEFORE MCU */
rge_hw_init(sc);            /*  -> MAC MCU load                          */
rge_hw_reset(sc);           /*  -> rge_reset() = RGE_CMD_RESET (full MAC soft reset) */
...                         /* chipinit returns */
rge_phy_config(sc);         /* PHY config, called later from init_locked */
```

Two inversions versus vendor, each able to break 2.5G while leaving 1G working:

1. **PHY is powered up before the MAC MCU is loaded** (vendor loads the MAC MCU
   first, powers the PHY up after).
2. **A full `RGE_CMD_RESET` fires after PHY power-up and before `rge_phy_config`**
   (`rge_reset()` writes `RGE_CMD_RESET` and waits for it to clear). The vendor
   never resets the MAC between power-up and phy_config.

Why this caps at 1G specifically: `rge_set_phy_power(on=1)` sets the PMCH power
bits, writes `BMCR_AUTOEN`, and spins until OCP `0xa420 & 7 == 3` (the resumed
"UPS state 3"). The subsequent MAC soft reset disturbs the MAC/PHY interface so
the PHY falls back out of that resumed state. `rge_phy_config()` then runs its
own `BMCR_RESET|AUTOEN|STARTNEG` but does **not** re-run the PMCH power-up or the
UPS-state-3 wait (that logic lives only in `rge_set_phy_power`). So the
MCU-assisted multi-gig analog bring-up executes against a PHY that is no longer
in the state it needs. The 2.5G/5G training loop never completes; the legacy
1000baseT (Clause-28) path does not depend on the UPS/MCU bring-up and still
links.

**Fix:** reorder `rge_chipinit` to mirror the vendor:

```c
if ((error = rge_exit_oob(sc)) != 0)
        return error;
rge_hw_init(sc);            /* MAC MCU load first          */
rge_hw_reset(sc);           /* MAC soft reset before PHY up */
rge_set_phy_power(sc, 1);   /* PHY power-up last, no reset after */
```

This leaves the PHY in its resumed state when `rge_phy_config()` runs, matching
the vendor's "MCU, then bring the PHY up clean" ordering.

## A secondary blob noted but not compared apples-to-apples

FreeBSD also carries a separate **MAC**-MCU image for this chip,
`rtl8126_2_mac_bps` (`if_rge_microcode.h`, 339 `{reg,val}` entries), distinct
from the **PHY** RAM code analyzed above. The vendor `if_re` builds its MAC MCU
(`mac_mcu_8126a_3`) partly through code rather than one static table, so a clean
byte-diff against FreeBSD's array is not straightforward and was not completed.
It is a lower-priority lever than the PHY firmware delta (the PHY is where 2.5G
training runs) and is noted here only for completeness. (An earlier version of
this doc mis-described this MAC-MCU array as the truncated blob and gave a "131
words" vendor figure; that conflated the MAC and PHY images and is retracted —
the PHY blob `mac_r26_2_mcu[]` is byte-identical to vendor, per the firmware
analysis above.)

## Verification

**Status: the init-order fix did NOT resolve 2.5G on this board.** Built,
installed, and cold-booted on the Framework Desktop (RTL8126_2). rge0 still comes
up `1000baseT`. linkdiag at link-up shows:

```
PHYSTAT=0x00f3  adv(0xa5d4)=0x0001  lpa(0xa5d6)=0x4420  BMSR=0x79ad  rcodever=0x0060
```

`lpa=0x4420` confirms the switch still offers 2.5G, but `adv(0xa5d4)=0x0001`
shows the local PHY has withdrawn its own 2.5G/5G advertisement by link-up time,
exactly as before the reorder. So neither the version-gate fix nor the init-order
fix changes the outcome: the RTL8126 PHY still fails to train 2.5G and falls back
to 1G. The reorder hypothesis is **disproven** as the root cause (kept only as a
correctness alignment with vendor, not as the fix).

The decisive partition test — does the Realtek vendor `if_re` driver train 2.5G
on this exact board? — is the remaining lever (see "Open thread" below).

Original target result (not yet achieved):

Test procedure:

1. `ifconfig rge0` -> expect `media: Ethernet autoselect (2500Base-T
   <full-duplex>)`, `status: active`.
2. `iperf3` to the 2.5G peer -> expect ~2.35 Gbit/s (vs 941 Mbit/s at 1G).
3. `ifconfig rge0 media 2500Base-T mediaopt full-duplex` -> `active`, not
   `no carrier`.
4. Cold reboot, re-check -> must come up 2.5G on cold boot (proves the fix holds
   from a firmware-initialized cold state, not just a warm re-init).

## Confound resolved: NOT a software problem (2026-07-29)

> This section previously argued "this is a software problem, full stop," on the
> premise that the same board trained 2.5G under Linux. That premise was a
> stepping confound and is now falsified. The corrected reasoning follows; the
> old argument is preserved inline as the mistake to learn from.

**The mistake.** The "software, full stop" claim compared FreeBSD-on-framework
(`0x64a`) against Linux-on-**`framework2`** (`0x649`). Two *different* chip
steppings. That is not holding hardware constant — it silently swapped the
silicon. The only thing proven was "a `0x649` board does 2.5G under Linux," which
says nothing about whether framework's `0x64a` can.

**The decisive test (finally run 2026-07-29).** Boot framework's *own* `0x64a`
chip under a Linux `r8169` that supports the stepping:

- Kernel **7.0.0-14-generic** — far past the ~6.11 that first added `VER_66`
  (the rev.b entry, upstream commit `69cb89981c7a`). No backport question; full
  rev.b support present.
- Auto-neg → **`1000Mb/s`**. Forced 2.5G → **`Speed: unknown`, `Link detected:
  no`.**

Identical to FreeBSD. A driver that knows framework's exact stepping cannot train
2.5G on this board either.

**Corrected conclusion.** The defect is **not** in software that differs between
the OSes. Hardware/magnetics/cable/link-partner was *not* actually held constant
in the original comparison; when it finally was (same chip, capable driver), 2.5G
failed. The remaining live causes are all below the driver:

1. ~~**Link partner (switch port).**~~ **RULED OUT (2026-07-29).** On Ubuntu the
   link-partner advertisement for framework's port reads:
   `10/100/1000baseT, 2500baseT/Full, 5000baseT/Full`. The switch port genuinely
   offers 2.5G (and 5G) to framework.
2. ~~**Cable run to this port.**~~ **RULED OUT (2026-07-29).** `framework2` was
   moved onto framework's exact former cable + switch port and negotiated
   **`Speed: 2500Mb/s, Link detected: yes`**. The cable and the port carry a real
   2.5G link — they are proven good.
3. **This specific `0x64a` silicon / board — CONFIRMED.** With the switch, the
   cable, the port, and three independent drivers all proven good on the same
   physical path, the only remaining variable is framework's onboard RTL8126A
   itself. It cannot train 2.5GBASE-T. Hardware fault.

Both ends advertise 2.5G, negotiation still settles at 1G, and forcing 2.5G gives
no link — a **PMA training failure local to framework's `0x64a` NIC**.

### How the physical path was exonerated (the decisive swap)

The switch advertising 2.5G does not by itself prove *this cable* can carry
2.5GBASE-T. The airtight test is to hand framework's exact cable + port to a NIC
known to do 2.5G:

- `framework2` (`0x649`, a proven-2.5G chip) was moved onto framework's former
  cable + switch port. It negotiated **2500Mb/s, link up.** => framework's cable
  and port are both 2.5G-capable.

That leaves framework's silicon as the sole failing element. No driver — FreeBSD
`rge`, FreeBSD vendor `if_re`, or Linux 7.0 `r8169` — trains 2.5G on it, and the
one thing that *does* work (framework2) does so on framework's own cable+port.
Case closed: **hardware, not software.**

## Bisection result: not `rge` glue — a FreeBSD-vs-Linux delta

The bisection used the **Realtek vendor `if_re` driver** on FreeBSD as an
apples-to-apples control: same OS, same PHY-config register tables and MCU blobs
(verified byte-identical), so any behavioral difference would isolate the delta
to `rge`-specific glue.

**Result: `if_re` also fails at 2.5G on FreeBSD (best = 1000baseT).** Both FreeBSD
Realtek drivers fail identically. At the time this was read as "the bug is shared
FreeBSD-vs-Linux" — but that inference leaned on the confounded belief that Linux
succeeded on *this* silicon. It didn't: see "Confound resolved" — framework's own
`0x64a` chip fails 2.5G under Linux 7.0 too. So the correct reading of this result
is narrower: **both FreeBSD drivers behave the same as each other and as Linux on
this chip.** The firmware byte-comparison below was still worth doing (it cleanly
eliminates the firmware image as the cause), but it was never going to find a fix.

Method note (safe rebind): framework's RTL8126 is its **only** NIC, so the test
uses a self-healing script that `kldload`s `if_re`, `devctl set driver -f rge0
re`, polls `re0` link across a 60s window, then reverts to `rge` via an EXIT
trap — surviving SSH loss. (Do **not** `devctl detach rge0` bare over SSH; that
frees the sole NIC with no re-attach and takes the host offline.) The script is
checked in at `FreeBSD/docs/rge/` alongside the decode tooling.

**Vendor-test result:** `if_re` (Realtek `rtl_bsd_drv` v1.102.01) was loaded on
framework and `rge0` rebound to `re0` via the self-healing script. Across the
full 60s poll window `re0` reached **no 2.5G link — best observed = 1000baseT**
(same as `rge`). Both FreeBSD Realtek drivers fail identically on this board. (The
contemporaneous "…while Linux succeeds on the same silicon" gloss was the
confound — Linux 7.0 on framework's own `0x64a` also fails, see "Confound
resolved.") This motivated the firmware byte-comparison below, which cleanly
eliminated the firmware image but — like every other driver-level lever — found
no fix.

## Firmware analysis: FreeBSD/vendor PHY RAM code vs Linux `.fw`

This is the concrete FreeBSD-vs-Linux difference on identical a-3 silicon.

### Chip stepping is correctly identified — no wrong-firmware-family bug

An early hypothesis was that FreeBSD applies the wrong firmware *family* (the
"a-3" image to a chip that is really the "a-2" stepping like framework2). That is
**disproven** by decoding the chip ID with Linux's own mask:

- Linux extracts the chip XID as `xid = (RTL_R32(TxConfig) >> 20) & 0xfcf`
  (`r8169_main.c`). Applied to framework's FreeBSD hwrev `0x64A00000`:
  `(0x64A00000 >> 20) & 0xfcf = 0x64a`.
- Linux's XID table: `0x64a -> RTL8126A, rtl8126a-3.fw`; `0x649 ->
  RTL8126A, rtl8126a-2.fw`.
- So framework is genuinely the **XID 0x64a = a-3 ("rev.c") stepping**, and
  FreeBSD's classification `MAC_R26_2` / vendor `MACFG_92` = "8126a_3" is
  **correct**. (framework2, which does 2.5G on Ubuntu, reports XID **0x649** = the
  *a-2* stepping — a different chip revision that loads `rtl8126a-2.fw`.)

The right comparison is therefore FreeBSD's embedded a-3 blob vs Linux
`rtl8126a-3.fw`, both targeting the same a-3 silicon.

### FreeBSD and the Realtek vendor driver ship the identical PHY firmware

Decoding `rge`'s `mac_r26_2_mcu[]` (`if_rge_microcode.h`, 2449 `{reg,val}` pairs)
and the vendor `if_re` `phy_mcu_ram_code_8126a_3_1[]` (`if_re.c`, flat u16
`reg,val,...`) into their PHY OCP write streams: they are **byte-for-byte
identical** (2449 pairs equal; the vendor array only adds a trailing
`0xffff,0xffff` sentinel that FreeBSD drops). Both stamp ram-code version
`0x0060` (`RGE_MAC_R26_2_RCODE_VER` == vendor `NIC_RAMCODE_VERSION_8126A_REV_C`).
This confirms FreeBSD transcribed its blob directly from a Realtek BSD drop, and
explains why both FreeBSD drivers behave the same.

### The FreeBSD/vendor blob DIFFERS from the Linux `.fw`

Linux ships `rtl8126a-3.fw`, version string **`rtl8126a-3_0.0.5 08/30/24`**
("rtl8126a rev.c mac"). Decoding its PHY microprogram (opcode format from
`r8169_firmware.c`: `0x13`=set OCP addr, `0x14`=data word, `0x8`=write,
`MDIO_CHG` toggles PHY vs MAC target) and comparing the RAM-code data words
against FreeBSD's:

| blob | RAM-code data words | vs Linux a-3.fw |
|---|---|---|
| FreeBSD `mac_r26_2_mcu[]` | 2372 | 96.6% similar |
| vendor `phy_mcu_ram_code_8126a_3_1` | 2372 (identical to FreeBSD) | 96.6% similar |
| Linux `rtl8126a-3_0.0.5 08/30/24` | 2357 | — |

- **Longest common prefix: 251 words**, then they diverge at word 251
  (`0x8223` in Linux vs `0x8233` in FreeBSD).
- `difflib` similarity 0.966; edit summary ~**88 words differ** (77 replaced, 10
  Linux-absent, 1 FreeBSD-absent). Several early diffs are constant `+0x10`/`+0x40`
  offsets on data words — consistent with shifted jump/branch targets because the
  code blocks are sized differently. This is a genuine microcode-content
  difference, not an encoding artifact.

### Version numbers are branches, not a linear "newer is better"

The counter-intuitive part: the **FreeBSD/vendor blob stamps version `0x0060`
(96)** while the **Linux a-3.fw internally stamps `0x0056` (86)**. FreeBSD's
number is *higher*, yet Linux's image is the one that trains 2.5G on this board.
The two are independently-numbered firmware **branches** for the same "rev.c"
stepping, not points on one increasing timeline. A higher on-chip ram-code
version is therefore no evidence that FreeBSD's image is the more correct one —
it is simply a *different* PHY microcode than the one Linux successfully applies.

### What this establishes (and what it does not)

Establishes: on identical a-3 silicon, the working (Linux) and non-working (both
FreeBSD) setups apply **different PHY RAM code** (~3.4% of words differ). This is
the first concrete, byte-level FreeBSD-vs-Linux delta found after every
register-table and glue comparison came back identical between the two FreeBSD
drivers.

Does not yet establish: that the firmware delta is *the* cause. Both FreeBSD
drivers embed Realtek's own a-3 blob, which Realtek presumably validated; the
delta could be a fix Realtek shipped only to Linux, or it could be a red herring
and the real cause an init/quirk step Linux performs around the firmware load.
The clean next test is to transplant the Linux `rtl8126a-3.fw` RAM-code words
into `mac_r26_2_mcu[]` (same `rge_write_phy_ocp` upload path, no other change) and
re-test 2.5G on framework. If that alone trains 2.5G, the firmware image is the
root cause; if not, the cause is in the surrounding init and the firmware delta
is incidental.

Decode/diff tooling for reproducing this analysis is checked in at
`FreeBSD/docs/rge/` (`decode_fw.py`, `fbsd_extract.py`,
`quantify.py`, `threeway.py`, and the interleave-aware `diff_canon.py`).

### Transplant test (executed)

`make_transplant.py rtl8126a-3.fw` translates the Linux `.fw` PHY-target RAM-code
body into 2433 `{reg,val}` pairs in the exact `rge_write_phy_ocp` convention
`mac_r26_2_mcu[]` uses. Only PHY-target `PHY_WRITE` (op `0x8`) opcodes are
emitted: `MDIO_CHG`-to-MAC regions are dropped (FreeBSD loads the MAC MCU
separately as `rtl8126_2_mac_bps`), and the patch-request preamble/teardown
handshake is done in C by `rge_patch_phy_mcu()`. Page/reg → OCP mapping is
`ocp = (page << 4) | (reg & 0xf)` (verified: the translated register sequence is
identical to the stock array for the first 1977 pairs, so only the data content
diverges). The only teardown-address difference is stock `{0xb82e,0x0000}` vs
transplant `{0xb827,0x0000}` — a genuine firmware content difference, not a
translation artifact.

Applied (regenerate with `splice.py`): replaced the `mac_r26_2_mcu[]` body in
`sys/dev/rge/if_rge_microcode.h` with the transplanted pairs, and lowered
`RGE_MAC_R26_2_RCODE_VER` `0x0060` → `0x0056` (`if_rgereg.h`) so the on-chip
`0x801e` stamp reflects the Linux image. `buildkernel`/`installkernel` GENERIC,
cold-boot framework.

Result: **negative — firmware is not the cause.** Cold-booted framework on the
transplant kernel (`#1 ...297394e995e5-dirty`, `if_rge_hw.o` rebuilt after the
header edit). `rge0` still autoselects only `1000baseT`; forcing
`2500Base-T` gives `status: no carrier`, exactly as with the stock blob. Both
partners advertise 2.5G (`adv(0xa5d4)=0x0081`, `lpa(0xa5d6)` carries the
`0x0400`/`0x0020` 2.5G bits) but `PHYSTAT` never reaches `0x0400` (2500M) — it
stays `0x0090`. Identical training failure.

(Note on the `rcodever=0x0060` still printed in `linkdiag`: `sc->rge_rcodever`
is sampled at `if_rge_hw.c:540`, at the *top* of `rge_phy_config`, **before**
`rge_phy_config_mcu` reloads and re-stamps. PHY RAM survives a warm reboot, so
this read reflects the *previous* boot's stamp, not the image loaded this boot.
It is not evidence the transplant failed to load — the negative link result is.)

**What this rules out:** the PHY RAM-code image itself. Loading Linux's exact
working `rtl8126a-3.fw` words through FreeBSD's `rge_write_phy_ocp` path changes
nothing. The 3.4% FreeBSD-vs-Linux firmware delta is therefore **incidental**,
not causal. Combined with the earlier disproven init-order and version-gate
hypotheses, and the vendor `if_re` also failing at 2.5G on this board, the cause
is neither the firmware image nor the `rge`-specific glue. It lives in the
init/quirk *sequence around* the PHY bring-up that Linux `r8169` performs and
both FreeBSD drivers do not — a step in the analog/PMA multi-gig bring-up (e.g.
a specific OCP quirk write, a SerDes/PCS setting, an EEE/downshift disable, or a
`phy-mode`/`led`/`aldps` quirk) applied outside the RAM-code blob. Next lever:
diff Linux `r8169`'s `rtl8126a_hw_phy_config` / `rtl_hw_init_8126a` *C-code*
register pokes (not the .fw) against `rge_phy_config_mac_r26_2`, focusing on
writes that touch the 2.5G/5G PMA and downshift paths.

## C-code PHY-config diff: FreeBSD/vendor vs Linux `r8169`

Comparing the *C-code* register pokes (the writes that surround the firmware
load) across the three drivers exposes a large structural split.

### Page/reg → OCP mapping

Linux expresses PHY writes as `phy_modify_paged(page, reg, mask, set)`; FreeBSD
and vendor use the flat OCP address. The correct conversion for the 0x0a4x
"standard PHY" pages (r8169_main.c:1252/1262, `ocp_base = page << 4`,
`addr = ocp_base + reg*2`, with the MDIO reg counted from its 0x10 base) is:

```
ocp = (page << 4) + (reg - 0x10) * 2
```

Ground truth: Linux `enable_gphy_10m` = page `0x0a44` reg `0x11` → OCP `0xa442`,
which is exactly vendor `re_set_eth_ocp_phy_bit(0xA442, BIT_11)` and FreeBSD
`RGE_PHY_SETBIT(0xa442, 0x0800)`. (The naive `(page<<4)|(reg&0xf)` used by the
firmware translator earlier is off-by-one for `reg ≥ 0x10`; it happened not to
matter for the RAM-code body because that stream addresses via `0xa436`/`0xa438`
directly, but it is wrong for these paged C writes.)

### The split

`rtl8126a_hw_phy_config` (Linux, MAC_VER_70 = a-3) is **six writes** after the
firmware:

| Linux helper | OCP | op |
|---|---|---|
| `enable_gphy_10m` | `0xa442` | SET `0x0800` (BIT11) |
| `legacy_force_mode` | `0xa5b4` | CLR `0x8000` (BIT15) |
| `disable_aldps` | `0xa430` | **CLR `0x0004` (BIT2)** |
| `config_eee_phy` | `0xa6d8` | CLR `0x0010` |
| `config_eee_phy` | `0xa428` | CLR `0x0080` |
| `config_eee_phy` | `0xa4a2` | CLR `0x0200` |

`rge_phy_config_mac_r26_2` (FreeBSD, `if_rge_hw.c:1145-1283`) is **~120 writes** —
`0xa442`/`0x8183`/`0xa654`/`0xb648`/`0xad2c`/`0xae06`/dozens of `0xb87c`+`0xb87e`
pairs/`0x8566` block/etc. This is a near-exact port of vendor
`re_hw_phy_config_8126a_3` (`if_re.c:44520-44775`; same registers, same order).
**Linux does none of this heavy tuning in C** — mainline `r8169` moved it into
the `.fw` and keeps only the six cleanups above.

### Two concrete divergences at shared registers

1. **ALDPS (`0xa430` BIT2).** Both Linux (`disable_aldps`) and vendor
   (`re_hw_phy_config_8126a_3:44769-74`, cleared when `phy_power_saving != 1`,
   the default) **clear** `0xa430` BIT2 with a 20 ms settle. FreeBSD `rge`
   **never touches** `0xa430` BIT2 (its only `0xa430` writes are SET `0x0003` at
   :1270 and CLR `0x8000` at :589 — different bits). So `rge` leaves ALDPS
   enabled. ALDPS left on is a known link-training destabiliser on Realtek
   multi-gig PHYs. Cheap to test (task #14), but note vendor clears it and still
   fails, so unlikely to be sufficient alone.

2. **The ~120-write tuning block vs firmware.** The (then) stronger hypothesis:
   Linux applies its firmware and then leaves the PHY largely alone; FreeBSD
   applies the MCU firmware and *then overwrites* ~120 PHY registers from the
   OpenBSD/Realtek C table, possibly clobbering firmware-set values.

### Strip-to-minimal test (executed) — NEGATIVE

Stripped `rge_phy_config_mac_r26_2` to just the firmware load plus Linux's two
writes not already in the common tail (`SET 0xa442 0x0800`, `CLR 0xa430 0x0004`
+20 ms); the common `rge_phy_config` tail already does `legacy_force` (`0xa5b4`)
and the three EEE clears (`0xa6d8`/`0xa428`/`0xa4a2`). Kept the **stock** firmware
to isolate the C-block variable cleanly (one change at a time; the Linux-`.fw`
transplant already tested negative with the full C block, so testing stock-fw +
stripped-C isolates exactly "are the ~120 writes harmful?"). Built GENERIC (`#2`,
`if_rge_hw.o` rebuilt 01:09), cold-booted framework.

Result: **no change.** `rge0` still autoselects `1000baseT`; forced `2500Base-T`
links but `PHYSTAT=0x00f3` shows the 1000M bit (`0x0010`), never `0x0400`
(2500M). Cold boot advertises 2.5G (`adv(0xa5d4)=0x0081`), partner advertises
2.5G (`lpa=0x0420`), training still never completes at 2.5G. Removing the C block
neither fixed nor (for 2.5G) worsened anything — though link *recovery* after a
media toggle became stickier (needs a longer settle / a second `down`/`up`),
i.e. the tuning block aids 1G link stability but is irrelevant to 2.5G training.

**Conclusion:** the ~120-write C block is **not** the cause. Test B (Linux `.fw`
+ stripped C) was skipped: with stock firmware already failing under stripped C,
and the Linux `.fw` already failing under the full C block, the fw×C-block
combination space is exhausted for the PHY-config path. The cause is **not** in
`rge_phy_config` / the PHY RAM code at all — every combination of {stock, Linux}
firmware × {full, stripped} C-config trains only 1G. Attention must move to the
**MAC-side / bus-side** setup that Linux does outside the PHY path:
`rtl_hw_init_8126` / `rtl_init_one` ERI/CSI/ASPM/EEE-plus writes, the MAC MCU
image (`rtl8126_2_mac_bps`, 339 words — never yet compared against Linux), or a
PCIe/`RGE_` MAC register FreeBSD never programs.

Vendor `if_re` failing at 2.5G is consistent with this: it does the *same* heavy
C block as FreeBSD, so it would clobber its firmware the same way. The driver
that works (Linux) is precisely the one that does **not** apply the C tuning
block.

## MAC-side diff: FreeBSD/vendor vs Linux `r8169` (the `0xe614` divergence)

With the PHY-config path exhausted, the next comparison was the MAC/bus init.
Linux brings the 8126 MAC up in `rtl_hw_start_8126a` (`r8169_main.c:3975`) →
`rtl_hw_start_8125_common` (`:3861`); FreeBSD does it inline in
`rge_init_locked` (`if_rge.c:~1170`); vendor in `re_hw_start_unlock_8125`
(`if_re.c:~9380`).

**Two structural findings, then one concrete register.**

1. **MAC-MCU image — all THREE drivers carry a *different* one (corrected).**
   An earlier draft here claimed Linux applies no MAC-MCU. That was wrong. The
   Linux a-3 firmware `rtl8126a-3.fw` (version string:
   `"rtl8126a rev.c mac and phy mcu firmware patch code"`) contains **both** a
   PHY-MCU section (2449 writes — byte-identical count to FreeBSD's
   `mac_r26_2_mcu[]`) **and** a MAC-MCU section, applied through the paged MDIO
   protocol (`PHY_MDIO_CHG data!=0` → `mac_mcu_write`, then `reg 0x1f`=page-select,
   even regs = code words). See "Firmware: MAC-MCU is a three-way mismatch" below.
   The three MAC-MCU code images do **not** match:

   | source | code head | words |
   |---|---|---|
   | Linux `rtl8126a-3.fw` page `0x0f80` | `e010 e02c e04e e052 e054 e056…` | 111 nonzero (+trailer) |
   | vendor `re_set_mac_mcu_8126a_3` (`if_re.c:2996`) | `e010 e02c e04e e052 e055 e058…` | 131 |
   | FreeBSD `rtl8126_2_mac_bps` (`if_rge_microcode.h`, loaded `if_rge_hw.c:347-369`) | `e00a e026 e048 e04c e04f e052…` | 339 |

   Linux and vendor share only a 4-word prefix (jump-table head) then diverge;
   **FreeBSD shares *zero* prefix with either.** This is unlike the PHY-MCU, where
   FreeBSD == vendor byte-for-byte. The MAC-MCU is Realtek control-plane offload
   (checksum/WoL/coalescing quirks), a priori *not* the analog-training path — but
   it is the **last untested firmware component** and the one place FreeBSD
   diverges from *both* Realtek references, so it is now queued for a transplant
   test (task #17).

   ### Firmware: MAC-MCU is a three-way mismatch — and how the geometry was pinned

   The MAC-MCU lives in a small code RAM inside the MAC, addressed through an OCP
   window. Before transplanting the Linux image you must be certain the three
   drivers *address* that RAM the same way, or a "correct" image lands at the
   wrong offsets and the armed breakpoints jump into garbage. The vendor loader
   `re_write_mac_mcu_ram_code` (`if_re.c:1789-1832`) pins it unambiguously:

   - **Window:** each code word `i` is written to OCP `0xF800 + i*2`.
   - **Paging:** `offset = i % page_size`; when `offset == 0`, select page
     `i / page_size` via OCP `0xE446` bits `[1:0]`
     (`re_switch_mac_mcu_ram_code_page`).
   - **Page size:** `MacMcuPageSize = RTL8125_MAC_MCU_PAGE_SIZE = 256`
     (`if_rereg.h:1357`) for MACFG_92 (8126a-3).

   FreeBSD's `rge_mac_config_ext_mcu` (`if_rge_hw.c:353-361`) is byte-for-byte the
   same scheme: `0xf800…` window, `rge_switch_mcu_ram_page` on `0xe446`, first 256
   words to page 0, remainder to page 1. So the addressing is identical; only the
   *content* differs.

   The Linux `.fw` uses a different *notation* for the same RAM — MDIO index
   `reg 0x1f` selects a page (`0x0f80`, `0x0f90`), then even regs are code words —
   but it maps cleanly onto the FreeBSD window:

   | Linux `.fw` page/offset | FreeBSD word | FreeBSD OCP |
   |---|---|---|
   | `0x0f80` + `k` (k=0..0xfe) | word `k` (0..127) | `0xf800 + k` |
   | `0x0f90` + `k` | word `128 + k/2` (128..255) | `0xf900 + k` |

   So the Linux a-3 MAC-MCU image is **256 words** (128 from `0x0f80`, 128 from
   `0x0f90`), landing entirely in FreeBSD page 0 — FreeBSD's page-1 loop runs zero
   iterations once `bps->count == 256`. The version trailer sits at words 252-255
   (`6847 0b18 0409 0a1c`), exactly where `rge_mcu_get_bin_version` reads it (last
   4 words).

   **Breakpoints differ too, and this is the subtle trap.** The `.fw` programs
   breakpoints through page `0x0fc2` (base OCP `0xFC20`; offset `0x06` → `0xFC26`).
   Decoded, the three drivers arm *different* sets — because each carries a
   different code image with entry points at different offsets:

   | OCP | Linux `.fw` | vendor `if_re` | FreeBSD `rge` |
   |---|---|---|---|
   | `0xFC26` | `0x8000` | `0x8000` | `0x8000` |
   | `0xFC2C` | `0x14A4` | `0x14A4` | `0x14A4` |
   | `0xFC2E` | — | `0x4176` | `0x4176` |
   | `0xFC30` | — | `0x41FC` | `0x41FC` |
   | `0xFC32` | — | `0x4298` | `0x4298` |
   | `0xFC3A` | — | — | `0x234A` |
   | `0xFC48` (enable mask) | `0x0004` | `0x003C` | `0x023C` |

   Linux arms **3**; vendor **6**; FreeBSD **7**. When transplanting Linux's image
   you must *also* replace FreeBSD's breakpoint block with Linux's 3-entry set —
   arming `0xFC2E/30/32/3A` against Linux's code would branch into wrong offsets.

   **Transplant (task #17, executed).** Replaced `rtl8126_2_mac_bps` with the
   256-word Linux a-3 image (`if_rge_microcode.h`; head `e010 e02c e04e e052
   e054…`, trailer `6847 0b18 0409 0a1c`) and replaced the R26_2 breakpoint block
   in `rge_mac_config_ext_mcu` with the Linux 3-entry set (`0xFC26=0x8000`,
   `0xFC2C=0x14A4`, `0xFC48=0x0004`; dropped `0xFC2E/30/32/3A`). Verified in the
   compiled `if_rge_hw.o`: `rtl8126_2_mac_bps_vals` is now `0x200` bytes (256
   words) and its `.rodata` head disassembles to `e010 e02c e04e e052 e054…`.
   Built GENERIC on bigone, installed via NFS-mounted `bigone:/usr/src` +
   `/mnt/bigobj`, cold-booted framework (kernel `#4`). **Result: NEGATIVE.** Still
   `1000baseT` on autoselect; forced `2500Base-T` → `no carrier`,
   `PHYSTAT=0x0090` (never `0x0400`), with framework advertising 2.5G
   (`adv=0x0081`) and the partner offering it (`lpa=0x0420`/`0x4420`). Identical
   signature to every prior test — PMA never trains 2.5G. Source reverted to
   stock (`rtl8126_2_mac_bps` back to 339 words, 7-entry breakpoint block).

   This eliminates the **last untested firmware component**. It confirms the a
   priori reasoning: the MAC-MCU is control-plane offload (checksum/WoL/coalescing
   quirks), *not* on the 2.5G analog-training path. The one place FreeBSD was the
   outlier from both Realtek references turned out not to matter — same outcome as
   the `0xe614` register (the one place FreeBSD matched vendor but differed from
   Linux). Both the "FreeBSD-is-outlier" and "Linux-is-outlier" MAC candidates are
   now dead.

2. **The decisive register: OCP `0xe614`, field `0x0700`.** This field is
   programmed per-chip-generation and is the *only* MAC register where Linux's
   8126 value differs from both BSD drivers:

   | chip | Linux `r8169` | FreeBSD `rge` | vendor `if_re` |
   |---|---|---|---|
   | 8126a (VER_70 / R26 / MACFG_92) | **`0x0400`** (`:3891`) | **`0x0300`** (`if_rge.c:1193`) | **`0x0300`** (else branch, `if_re.c:9398`) |
   | 8125b (VER_63 / R25B) | `0x0200` | `0x0200` | `0x0200` |
   | 8125a / others (R25) | `0x0300` | `0x0300` | `0x0300` |
   | 8127 (VER_80 / R27) | `0x0f00` (mask `0x0f00`) | `0x0f00` | `0x0f00` |

   Linux gives the 8126a its own value `0x0400`; `rge` lumps R26 in with R25 and
   writes `0x0300`. Vendor `if_re` writes `0x0300` too — its `else` branch — and
   it *also* fails at 2.5G on FreeBSD. This is the **exact signature of the real
   cause seen everywhere in this investigation: `rge == vendor`, both differ from
   Linux, both fail.** Tellingly, vendor's code contains a dead `4<<8`
   (=`0x0400`) branch gated on `MACFG_100||101` — a condition already caught
   above it — as if Realtek meant to give the 8126 a distinct value and the BSD
   drop's gate is stale. The masked field `0x0700` has the profile of a MAC
   datapath/clock-select that would leave legacy 1G intact while starving 2.5G.

3. Two registers Linux writes in the common block that **neither** BSD driver
   writes for the 8126 — `0xd3e2` (`→0x03a9`), `0xd3e4` (`→0x0000`), `0xe860`
   (`|=0x0080`) at `:3877-3879` — are written by Linux for *all* 8125/8126
   uniformly (vendor gates them on `MACFG_67`, an 8125-class part). Not
   8126-distinguishing, so they can't explain why the 8126 alone fails; kept as
   secondary companions only.

**`0xe614=0x0400` test (executed) — NEGATIVE.** Changed the R26 arm of the
`0xe614` write from `val|0x0300` to `val|0x0400` (verified in the compiled
`if_rge.o`: the `orl $0x400` lands on the R26 branch), built GENERIC on bigone,
installed + cold-booted framework (kernel `#3`). Result: still `1000baseT`
autoselect; forced `2500Base-T` gives `PHYSTAT=0x0090` (never `0x0400`), partner
still offers 2.5G (`lpa=0x0420`), training never completes. The MAC clock/lane
field `0xe614` is **not** the gate. Reverted to stock `0x0300`.

(Side observation on that boot: autoselect linkdiag showed `adv(0xa5d4)=0x0001`
— the 2.5G advertise bit *not* set in auto mode — while forced mode set it
(`adv=0x0081`). So even the advertise register content varies by mode; but since
forced mode advertises 2.5G and the partner offers it, the failure is squarely in
PMA training, not advertisement — consistent with every prior result.)

**Where that leaves the MAC-side theory.** The one register that fit the
"Linux-differs-from-both-BSD" signature turned out not to matter. Combined with
the fully-eliminated PHY path, the remaining candidates are (a) the MAC-MCU image
itself (`rtl8126_2_mac_bps`, still uncompared word-for-word to what Linux's `.fw`
would load — deprioritized earlier as control-plane, but now back in scope since
cheaper levers are exhausted); (b) a register Linux writes that neither BSD driver
does AND that we haven't yet cross-checked against the *8127/8125d* arms (the
common block has several `VER_70`-gated lines); (c) PCIe/EPHY (`rtl_ephy_init`)
config — note Linux runs **no** EPHY init for the 8126 (`rtl_hw_start_8126a`),
same as `rge`, so EPHY is unlikely. Realistically the next high-value move is a
full apples-to-apples MAC-MCU image comparison (decode Linux `rtl8126a-3.fw`
MAC-target stream vs `rtl8126_2_mac_bps`), or accept the in-base driver cannot yet
train 2.5G on this a-3 silicon and document the vendor-kmod as the interim path.

## Upstreaming

**There is no 2.5G fix to upstream.** The 2.5G failure is not a driver defect
(see "Confound resolved" — framework's `0x64a` fails 2.5G under a rev.b-aware
Linux 7.0 too). None of the driver changes explored here fix it, so none is worth
sending as a "fixes 2.5G" patch.

The init-order reorder (`rge_chipinit`) was **disproven** as the cause and should
be dropped entirely — it changes nothing observable and diverges from OpenBSD for
no benefit.

One change stands on its own merits, *independent of the 2.5G question*:

- **`rge_phy_config_mcu`: drop the version-stamp gate; always load the RAM code.**
  Matches Linux `r8169` (`r8169_apply_firmware`, no read of the on-chip ram-code
  version) and the Realtek vendor driver. It is a correctness/robustness fix (the
  stamp is unreliable), not a 2.5G fix — frame it that way if submitted.
  Maintainers: Adrian Chadd (FreeBSD `rge`), Kevin Lo (OpenBSD origin).

Before any submission, revert the diagnostic `printf` in `rge_link_state`
(`if_rge.c`, added for linkdiag).
