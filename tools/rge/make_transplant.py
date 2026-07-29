#!/usr/bin/env python3
# Translate the PHY-target RAM-code body of a Linux r8169 .fw into the exact
# {reg,val} pair stream FreeBSD's mac_r26_2_mcu[] uses (fed to rge_write_phy_ocp).
#
# Mapping rules (derived from matching the vendor/FreeBSD array against a-3.fw):
#   - Only the PHY-target region is emitted (MDIO_CHG to MAC space is skipped:
#     FreeBSD loads MAC MCU separately as rtl8126_2_mac_bps).
#   - The patch-request preamble/teardown handshake (READ/OR/AND/WRITE_PREV/
#     CLR_RC/DELAY_MS/COMP*/RC_EQ_SKIP/BJMPN around the body) is done in C by
#     rge_patch_phy_mcu(); it is NOT part of the array. We detect the body as the
#     contiguous run of PHY-target WRITE (op 0x8) opcodes and translate those.
#   - Within that run:
#       0x1f (page select)  -> dropped (rge_write_phy_ocp addresses via OCP)
#       0x13 (set ocp addr) -> {0xa436, val}
#       0x14 (ocp data)     -> {0xa438, val}
#       0x10 on page 0x0b82 -> {0xb820, val}   (page-base translation)
#       other direct reg    -> {OCPBASE(page)+reg*2, val}
#
# OCP base for a page: FreeBSD OCP addr = 0xa400 + ... no; the observed mapping
# is page 0x0b82 reg 0x10 -> 0xb820. i.e. ocp = (page<<0? ) Actually:
#   page 0x0b82, reg 0x10 -> 0xb820.  0x0b82*? ... 0xb820 = (0x0b82<<4)|... no.
# Empirically: ocp_addr = (page_low_byte based). Derive generically below by
# tracking the current page and computing base = page*? We instead hard-map the
# only two direct-write pages that appear (0x0b82->0xb820 region, 0x0b80->0xb800)
# using the relation ocp = 0xb800 + (page-0x0b80)*0x?  -- but simplest correct
# form matching rge_write_phy_ocp: FreeBSD stores the *full OCP address*, and the
# r8169 page/reg pair maps as ocp = (page << 4) | (reg & 0xf)?? Check: 0x0b82<<4
# = 0xB820, |0x10low nibble 0 -> 0xB820. YES: ocp = (page<<4)|(reg&0xf).
# Validate: page 0x0a43 reg 0x13 is the addr-set path (handled specially), and
# page 0x0b80 reg? not used for direct data here.
import sys, struct
RTL_VER_SIZE=32

def load(path):
    d=open(path,"rb").read()
    fs=struct.unpack_from("<I",d,4+RTL_VER_SIZE)[0]
    fl=struct.unpack_from("<I",d,4+RTL_VER_SIZE+4)[0]
    return [struct.unpack_from("<I",d,fs+i*4)[0] for i in range(fl)]

def ocp_from_page_reg(page,reg):
    # matches rge convention: full OCP addr = (page<<4)|(reg&0xf)
    return ((page<<4)|(reg&0xf)) & 0xffff

def translate(words):
    pairs=[]
    target="PHY"; page=None
    for a in words:
        op=a>>28; d=a&0xffff; reg=(a&0x0fff0000)>>16
        if op==0x4:
            target="MAC" if d else "PHY"; continue
        if target!="PHY": continue
        if op!=0x8:
            # flow-control / handshake opcode -> done in C by rge_patch_phy_mcu
            continue
        if reg==0x1f:
            page=d; continue
        if reg==0x13:
            pairs.append((0xa436,d))
        elif reg==0x14:
            pairs.append((0xa438,d))
        else:
            pairs.append((ocp_from_page_reg(page,reg),d))
    return pairs

if __name__=="__main__":
    w=load(sys.argv[1])
    pairs=translate(w)
    print("translated %d {reg,val} pairs"%len(pairs))
    if len(sys.argv)>2 and sys.argv[2]=="-c":
        # emit C array body
        out=[]
        line=[]
        for r,v in pairs:
            line.append("{ 0x%04x, 0x%04x }"%(r,v))
            if len(line)==3:
                out.append("\t"+", ".join(line)+",")
                line=[]
        if line: out.append("\t"+", ".join(line)+",")
        print("\n".join(out))
    else:
        for r,v in pairs[:24]:
            print("  { 0x%04x, 0x%04x }"%(r,v))
