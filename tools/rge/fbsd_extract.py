#!/usr/bin/env python3
# Extract a named rge_hw_regaddr_array {reg,val} table from if_rge_microcode.h
# and re-express it as the same (ocp_addr, data) stream the Linux .fw decodes to,
# so the two can be diffed directly.
#
# Encoding in FreeBSD (identical semantics to r8169 MDIO):
#   {0xa436, X}  -> set OCP address to X          (== Linux 0x13,X)
#   {0xa438, D}  -> write data D at current addr, addr += 2 (== Linux 0x14,D)
#   {other,  D}  -> direct MDIO/OCP write to `other` (page selects, bit ops)
import sys, re

def extract(path, name):
    txt=open(path).read()
    m=re.search(r'static const struct rge_hw_regaddr_array '+re.escape(name)+r'\[\]\s*=\s*\{(.*?)\n\};', txt, re.S)
    if not m: raise SystemExit("array %s not found"%name)
    body=m.group(1)
    pairs=re.findall(r'\{\s*(0x[0-9a-fA-F]+)\s*,\s*(0x[0-9a-fA-F]+)\s*\}', body)
    return [(int(r,16),int(v,16)) for r,v in pairs]

def to_ocp(pairs):
    out=[]; cur=None
    for reg,val in pairs:
        if reg==0xa436:
            cur=val
        elif reg==0xa438:
            if cur is not None:
                out.append((cur,val)); cur+=2
            else:
                out.append((0x20000|reg,val))
        else:
            out.append((0x10000|reg,val))  # direct write
    return out

if __name__=="__main__":
    path,name=sys.argv[1],sys.argv[2]
    pairs=extract(path,name)
    ocp=to_ocp(pairs)
    print("array=%s raw{}=%d  ocp-stream=%d"%(name,len(pairs),len(ocp)))
    direct=[x for x in ocp if x[0]&0x10000]
    print("  direct(non-OCP)=%d  OCP=%d"%(len(direct),len(ocp)-len(direct)))
    if len(sys.argv)>3:
        for a,d in ocp[:int(sys.argv[3])]:
            tag="MDIO" if a&0x10000 else ("OCP " if not a&0x20000 else "A438")
            print("  %s 0x%04x 0x%04x"%(tag,a&0xffff,d))
