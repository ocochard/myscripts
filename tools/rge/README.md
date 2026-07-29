# rge / RTL8126 PHY firmware decode + compare tools

Tooling used to investigate why FreeBSD `rge(4)` links an onboard RTL8126A only
at 1000baseT while Linux `r8169` trains 2.5G on the same silicon. Full writeup:
`rge_rtl8126_stuck_1bg.md`.

These scripts decode the Realtek PHY MCU "RAM code" from three sources and diff
them:

- **Linux** `rtl8126a-3.fw` / `rtl8126a-2.fw` — the `r8169` external firmware
  files (microprogram format, opcodes per `r8169_firmware.c`).
- **FreeBSD** `mac_r26_2_mcu[]` — embedded blob in `sys/dev/rge/if_rge_microcode.h`
  (`{reg,val}` OCP-write pairs).
- **Vendor** `phy_mcu_ram_code_8126a_3_1[]` — embedded blob in the Realtek
  out-of-tree `if_re.c` (flat `reg,val,reg,val` u16 stream).

## Inputs expected in the working directory

- `rtl8126a-3.fw`, `rtl8126a-2.fw` — decompress from a Linux host:
  `zstd -d /lib/firmware/rtl_nic/rtl8126a-3.fw.zst -o rtl8126a-3.fw`
- `if_rge_microcode.h` — from `sys/dev/rge/`
- `if_re.c` — from the Realtek `rtl_bsd_drv` tree

## Scripts

| script | purpose |
|---|---|
| `decode_fw.py FILE [-v]` | disassemble a Linux `.fw`: version string, opcode histogram, PHY vs MAC-MCU write counts |
| `normalize.py FILE [N]` | collapse the Linux MDIO `0x13`/`0x14` stream into OCP `(addr,data)` writes |
| `fbsd_extract.py HDR ARRAY [N]` | extract a `rge_hw_regaddr_array` from the FreeBSD header as an OCP stream |
| `diff_canon.py [FW]` | interleave-aware event diff (addr-set / data / direct-write) FreeBSD vs Linux — locates the true first divergence |
| `diff_payload.py [FW]` | diff the raw RAM-code data-word streams (address-independent) |
| `quantify.py [FW]` | quantify divergence: longest common prefix, difflib similarity, edit summary |
| `threeway.py [FW]` | three-way: prove FreeBSD == vendor exactly, then both vs Linux |
| `make_transplant.py FW [-c]` | translate the Linux `.fw` PHY RAM-code body into the `{reg,val}` pairs for `mac_r26_2_mcu[]` (page/addr/data mapping `ocp=(page<<4)|(reg&0xf)`); `-c` emits the C array body. Skips MAC-target and patch-handshake opcodes (those are done in C by `rge_patch_phy_mcu`). |
| `splice.py` | splice the transplanted body into `sys/dev/rge/if_rge_microcode.h` in place, preserving the declaration/`};` and adding a provenance comment. Reads `mac_r26_2_mcu_linux.txt` (the `make_transplant.py -c` output). Run with `sudo` on root-owned `/usr/src`. |

## Key findings (see doc for detail)

- Chip is XID `0x64a` = a-3 ("rev.c") stepping; FreeBSD classifies it correctly.
- FreeBSD `mac_r26_2_mcu[]` == vendor `phy_mcu_ram_code_8126a_3_1` **byte-identical**.
- Both differ from Linux `rtl8126a-3_0.0.5 08/30/24` by ~88 words (3.4%),
  common prefix 251 words. FreeBSD/vendor stamp version `0x0060`, Linux `0x0056`
  — independent branches, not a linear sequence.

## `re_swap_test.sh`

Self-healing hardware test: rebinds framework's sole NIC from `rge` to the vendor
`re`, polls `re0` for up to 60s, then **always** reverts to `rge` via an EXIT
trap. Run detached (`daemon`/`nohup`) so it survives SSH loss. Never
`devctl detach rge0` bare over SSH — that frees the only NIC and takes the host
offline.
