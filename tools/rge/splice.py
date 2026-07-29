#!/usr/bin/env python3
# Splice the Linux-derived mac_r26_2_mcu[] body into if_rge_microcode.h.
# Keeps the declaration line and closing '};', replaces the pair body.
import sys
HDR="/usr/src/sys/dev/rge/if_rge_microcode.h"
BODY="/home/olivier/fw_compare/mac_r26_2_mcu_linux.txt"

lines=open(HDR).read().split("\n")
# find declaration and its closing brace
decl=None
for i,l in enumerate(lines):
    if "mac_r26_2_mcu[] = {" in l:
        decl=i; break
assert decl is not None
close=None
for j in range(decl+1,len(lines)):
    if lines[j].strip()=="};":
        close=j; break
assert close is not None
print("decl line %d, close line %d, replacing %d body lines"%(decl+1,close+1,close-decl-1))

body=open(BODY).read().rstrip("\n").split("\n")
# add provenance comment right after declaration
comment=[
 "\t/*",
 "\t * TRANSPLANT: PHY RAM code translated from Linux linux-firmware",
 "\t * rtl_nic/rtl8126a-3.fw (version rtl8126a-3_0.0.5 08/30/24,",
 "\t * sha256 18ffaf3b...).  The stock Realtek blob (== vendor if_re",
 "\t * phy_mcu_ram_code_8126a_3_1) links this 8126a rev.c part only at",
 "\t * 1000baseT; Linux' r8169 trains 2.5G with this image on the same",
 "\t * silicon.  Preamble/teardown handshake and version stamp are done",
 "\t * in C by rge_phy_config_mcu()/rge_patch_phy_mcu(), so only the RAM-",
 "\t * code body is embedded here.  Regenerate with docs/rge/make_transplant.py.",
 "\t */",
]
new=lines[:decl+1]+comment+body+lines[close:]
open(HDR,"w").write("\n".join(new))
print("spliced OK; new body pairs written")
