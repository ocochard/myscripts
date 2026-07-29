#!/usr/bin/env python3
# Normalize Linux PHY write stream into OCP {addr,val} writes, matching how
# FreeBSD rge_write_phy_ocp stores mac_r26_2_mcu[] entries.
#
# In the r8169 MDIO stream for 8125/8126 PHYs, OCP register access is:
#   write 0x1f, page            (page select; 0x0a43 etc.)
#   write 0x13, ocp_addr        (set OCP address)
#   write 0x14, ocp_data        (write OCP data)
# FreeBSD rge_write_phy_ocp(reg,val) writes 0xa436=reg then 0xa438=val, i.e.
# exactly the 0x13/0x14 pair. mac_r26_2_mcu[] holds those (ocp_addr, ocp_data).
#
# But the RAM-code upload uses a *streaming* form: after one 0x13,<start>,
# successive 0x14,<data> writes auto-increment. FreeBSD stores each as an
# explicit {0xADDR, data} because rge_write_phy_ocp re-addresses each time...
# Actually no: mac_r26_2_mcu[] entries feed rge_write_phy_ocp(reg,val) which
# ALWAYS re-addresses. So each FreeBSD entry == one (addr,data) OCP write.
# The Linux streaming 0x14-run must therefore expand: the RAM-code region
# writes 0x13,0xa014 once then many 0x14,<data>; FreeBSD would need 0xa438
# repeated. Compare the *data payload* sequences instead of addresses.

import sys, struct
RTL_VER_SIZE=32
def load(path):
    data=open(path,"rb").read()
    magic=struct.unpack_from("<I",data,0)[0]
    version=data[4:4+RTL_VER_SIZE].split(b'\0')[0].decode('latin1')
    fs=struct.unpack_from("<I",data,4+RTL_VER_SIZE)[0]
    fl=struct.unpack_from("<I",data,4+RTL_VER_SIZE+4)[0]
    code=data[fs:fs+fl*4]
    return version,[struct.unpack_from("<I",code,i*4)[0] for i in range(fl)]

def phy_ocp_writes(words):
    """Return list of (ocp_addr, data) for the PHY target, tracking 0x13/0x14
    with auto-increment on repeated 0x14."""
    out=[]; target="PHY"; cur_addr=None
    for a in words:
        op=a>>28; data=a&0xffff; reg=(a&0x0fff0000)>>16
        if op==0x4: target="MAC" if data else "PHY"; continue
        if op!=0x8: continue
        if target!="PHY": continue
        if reg==0x13:
            cur_addr=data
        elif reg==0x14:
            if cur_addr is not None:
                out.append((cur_addr,data)); cur_addr+=2
        else:
            out.append((0x10000|reg,data))  # non-OCP direct MDIO write
    return out

if __name__=="__main__":
    v,w=load(sys.argv[1])
    ocp=phy_ocp_writes(w)
    print("version=%r  PHY-OCP writes(after 0x13/0x14 collapse, autoinc)=%d"%(v,len(ocp)))
    direct=[x for x in ocp if x[0]&0x10000]
    print("  of which direct(non-OCP) MDIO writes=%d"%len(direct))
    print("  pure OCP RAM/reg writes=%d"%(len(ocp)-len(direct)))
    if len(sys.argv)>2:
        for a,d in ocp[:int(sys.argv[2])]:
            tag="MDIO" if a&0x10000 else "OCP "
            print("  %s 0x%04x 0x%04x"%(tag,a&0xffff,d))
