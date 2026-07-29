#!/usr/bin/env python3
# Decode an r8169 .fw microprogram into its PHY / MAC-MCU write streams.
# Format per drivers/net/ethernet/realtek/r8169_firmware.c
import sys, struct

RTL_VER_SIZE = 32

OPS = {0x0:"READ",0x1:"OR",0x2:"AND",0x3:"BJMPN",0x4:"MDIO_CHG",
       0x7:"CLR_RC",0x8:"WRITE",0x9:"RC_EQ_SKIP",0xa:"COMP_EQ_SKIPN",
       0xb:"COMP_NEQ_SKIPN",0xc:"WRITE_PREV",0xd:"SKIPN",0xe:"DELAY_MS"}

def load(path):
    data = open(path,"rb").read()
    magic = struct.unpack_from("<I", data, 0)[0]
    if magic != 0:
        # raw form: whole file is code
        version = path
        code = data
        start = 0
    else:
        # fw_info: magic(4) version(32) fw_start(4) fw_len(4) chksum(1)
        version = data[4:4+RTL_VER_SIZE].split(b'\0')[0].decode('latin1')
        fw_start = struct.unpack_from("<I", data, 4+RTL_VER_SIZE)[0]
        fw_len   = struct.unpack_from("<I", data, 4+RTL_VER_SIZE+4)[0]
        start = fw_start
        code = data[fw_start:fw_start+fw_len*4]
    n = len(code)//4
    words = [struct.unpack_from("<I", code, i*4)[0] for i in range(n)]
    return version, words

def decode(words):
    """Static disassembly: list opcodes; and separately extract flat WRITE
    streams per target space (PHY vs MAC-MCU) as MDIO_CHG toggles them."""
    listing=[]
    phy_writes=[]   # (regno,data)
    mac_writes=[]
    target="PHY"
    for i,a in enumerate(words):
        op=a>>28; data=a&0xffff; regno=(a&0x0fff0000)>>16
        name=OPS.get(op,"?0x%x"%op)
        listing.append((i,name,regno,data))
        if op==0x4:  # MDIO_CHG
            target = "MAC" if data else "PHY"
        elif op==0x8:  # WRITE
            (mac_writes if target=="MAC" else phy_writes).append((regno,data))
    return listing, phy_writes, mac_writes

if __name__=="__main__":
    path=sys.argv[1]
    version,words=load(path)
    listing,pw,mw=decode(words)
    print("file=%s"%path)
    print("version=%r  opcodes=%d"%(version,len(words)))
    from collections import Counter
    c=Counter(name for _,name,_,_ in listing)
    print("opcode histogram:", dict(c))
    print("PHY WRITE count=%d   MAC-MCU WRITE count=%d"%(len(pw),len(mw)))
    if len(sys.argv)>2 and sys.argv[2]=="-v":
        print("--- MAC-MCU writes (regno,data) ---")
        for r,d in mw: print("  0x%04x 0x%04x"%(r,d))
        print("--- first 40 PHY writes ---")
        for r,d in pw[:40]: print("  0x%04x 0x%04x"%(r,d))
