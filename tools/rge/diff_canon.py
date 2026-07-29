#!/usr/bin/env python3
# Canonical compare that preserves interleave. Build an event list for each side:
#   ('A', addr)  address set
#   ('D', data)  data word (RAM code)
#   ('W', reg, val) direct MDIO write (page selects etc.)
# Drop Linux page-select/direct writes that FreeBSD does in C (reg 31=0x1f page,
# reg 16, reg 23) so only the RAM-code upload remains, then diff event-by-event.
import sys, re, struct
RTL_VER_SIZE=32
SKIP_LINUX_DIRECT={0x1f}  # only page-selects done in C; keep bit-op writes

def linux_events(path):
    data=open(path,"rb").read()
    fs=struct.unpack_from("<I",data,4+RTL_VER_SIZE)[0]
    fl=struct.unpack_from("<I",data,4+RTL_VER_SIZE+4)[0]
    words=[struct.unpack_from("<I",data,fs+i*4)[0] for i in range(fl)]
    ev=[]; target="PHY"
    for a in words:
        op=a>>28; d=a&0xffff; reg=(a&0x0fff0000)>>16
        if op==0x4: target="MAC" if d else "PHY"; continue
        if op!=0x8 or target!="PHY": continue
        if reg==0x13: ev.append(('A',d))
        elif reg==0x14: ev.append(('D',d))
        elif reg in SKIP_LINUX_DIRECT: pass
        else: ev.append(('W',reg,d))
    return ev

def fbsd_events(path,name):
    txt=open(path).read()
    m=re.search(r'static const struct rge_hw_regaddr_array '+re.escape(name)+r'\[\]\s*=\s*\{(.*?)\n\};',txt,re.S)
    pairs=re.findall(r'\{\s*(0x[0-9a-fA-F]+)\s*,\s*(0x[0-9a-fA-F]+)\s*\}',m.group(1))
    ev=[]
    for r,v in pairs:
        r=int(r,16); v=int(v,16)
        if r==0xa436: ev.append(('A',v))
        elif r==0xa438: ev.append(('D',v))
        else: ev.append(('W',r,v))
    return ev

L=linux_events(sys.argv[1] if len(sys.argv)>1 else "rtl8126a-3.fw")
F=fbsd_events("if_rge_microcode.h","mac_r26_2_mcu")
print("linux events=%d  fbsd events=%d"%(len(L),len(F)))
n=min(len(L),len(F)); diffs=0; shown=0
for i in range(n):
    if L[i]!=F[i]:
        diffs+=1
        if shown<15:
            print("  @%4d linux=%s fbsd=%s"%(i,L[i],F[i])); shown+=1
print("mismatches in first %d = %d"%(n,diffs))
if diffs==0 and len(L)==len(F):
    print("*** IDENTICAL RAM-CODE UPLOAD ***")
elif diffs==0:
    print("*** prefix identical; length differs linux=%d fbsd=%d ***"%(len(L),len(F)))
    longer=L if len(L)>len(F) else F; who="linux" if len(L)>len(F) else "fbsd"
    print("extra %s tail:"%who, longer[n:n+8])
