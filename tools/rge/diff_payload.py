#!/usr/bin/env python3
# Encoding-independent compare: extract ONLY the RAM-code data words
# (Linux 0x14 writes in PHY target / FreeBSD 0xa438 writes) in order, plus
# the sequence of addr-set values (Linux 0x13 / FreeBSD 0xa436), and diff each.
import sys, re, struct
RTL_VER_SIZE=32

def linux_streams(path):
    data=open(path,"rb").read()
    fs=struct.unpack_from("<I",data,4+RTL_VER_SIZE)[0]
    fl=struct.unpack_from("<I",data,4+RTL_VER_SIZE+4)[0]
    words=[struct.unpack_from("<I",data,fs+i*4)[0] for i in range(fl)]
    target="PHY"; addrs=[]; datas=[]; other=[]
    for a in words:
        op=a>>28; d=a&0xffff; reg=(a&0x0fff0000)>>16
        if op==0x4: target="MAC" if d else "PHY"; continue
        if op!=0x8 or target!="PHY": continue
        if reg==0x13: addrs.append(d)
        elif reg==0x14: datas.append(d)
        else: other.append((reg,d))
    return addrs,datas,other

def fbsd_streams(path,name):
    txt=open(path).read()
    m=re.search(r'static const struct rge_hw_regaddr_array '+re.escape(name)+r'\[\]\s*=\s*\{(.*?)\n\};',txt,re.S)
    pairs=re.findall(r'\{\s*(0x[0-9a-fA-F]+)\s*,\s*(0x[0-9a-fA-F]+)\s*\}',m.group(1))
    addrs=[]; datas=[]; other=[]
    for r,v in pairs:
        r=int(r,16); v=int(v,16)
        if r==0xa436: addrs.append(v)
        elif r==0xa438: datas.append(v)
        else: other.append((r,v))
    return addrs,datas,other

def diff(tag,a,b):
    n=min(len(a),len(b)); m=sum(1 for i in range(n) if a[i]!=b[i])
    print("%s: linux=%d fbsd=%d  common=%d mismatches=%d"%(tag,len(a),len(b),n,m))
    if m:
        for i in range(n):
            if a[i]!=b[i]:
                print("   first diff @%d: linux=0x%04x fbsd=0x%04x"%(i,a[i],b[i])); break
    return m,len(a)==len(b)

la,ld,lo=linux_streams(sys.argv[1] if len(sys.argv)>1 else "rtl8126a-3.fw")
fa,fd,fo=fbsd_streams("if_rge_microcode.h","mac_r26_2_mcu")
print("=== RAM-CODE DATA WORD STREAM (the actual PHY microcode) ===")
dm,dlen=diff("data",ld,fd)
print("=== ADDR-SET STREAM ===")
am,alen=diff("addr",la,fa)
print("=== OTHER (direct) WRITES ===")
print("linux:",lo)
print("fbsd :",fo)
if dm==0 and dlen:
    print("\n*** PHY RAM-CODE PAYLOAD IDENTICAL (%d data words) ***"%len(ld))
else:
    print("\n*** PHY RAM-CODE PAYLOAD DIFFERS ***")
