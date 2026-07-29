#!/usr/bin/env python3
# Quantify FreeBSD mac_r26_2_mcu vs Linux rtl8126a-3.fw PHY RAM-code divergence.
# Use difflib on the data-word streams (address-independent RAM code payload).
import sys, re, struct, difflib
RTL_VER_SIZE=32

def linux_data(path):
    d=open(path,"rb").read()
    fs=struct.unpack_from("<I",d,4+RTL_VER_SIZE)[0]
    fl=struct.unpack_from("<I",d,4+RTL_VER_SIZE+4)[0]
    words=[struct.unpack_from("<I",d,fs+i*4)[0] for i in range(fl)]
    out=[]; target="PHY"
    for a in words:
        op=a>>28; da=a&0xffff; reg=(a&0x0fff0000)>>16
        if op==0x4: target="MAC" if da else "PHY"; continue
        if op==0x8 and target=="PHY" and reg==0x14: out.append(da)
    return out

def fbsd_data(path,name):
    txt=open(path).read()
    m=re.search(r'static const struct rge_hw_regaddr_array '+re.escape(name)+r'\[\]\s*=\s*\{(.*?)\n\};',txt,re.S)
    pairs=re.findall(r'\{\s*(0x[0-9a-fA-F]+)\s*,\s*(0x[0-9a-fA-F]+)\s*\}',m.group(1))
    return [int(v,16) for r,v in pairs if int(r,16)==0xa438]

L=linux_data(sys.argv[1] if len(sys.argv)>1 else "rtl8126a-3.fw")
F=fbsd_data("if_rge_microcode.h","mac_r26_2_mcu")
print("Linux RAM-code data words = %d"%len(L))
print("FreeBSD RAM-code data words = %d"%len(F))
# longest common prefix
p=0
while p<min(len(L),len(F)) and L[p]==F[p]: p+=1
print("longest common prefix = %d words (%.1f%% of linux)"%(p,100*p/len(L)))
sm=difflib.SequenceMatcher(a=L,b=F,autojunk=False)
r=sm.ratio()
print("difflib similarity ratio = %.4f"%r)
matched=sum(b.size for b in sm.get_matching_blocks())
print("total matching words (longest common subseq blocks) = %d (%.1f%% of linux)"%(matched,100*matched/len(L)))
# summarize opcodes of divergence
ops=sm.get_opcodes()
ins=sum(j2-j1 for t,i1,i2,j1,j2 in ops if t=='insert')
dele=sum(i2-i1 for t,i1,i2,j1,j2 in ops if t=='delete')
rep=sum(max(i2-i1,j2-j1) for t,i1,i2,j1,j2 in ops if t=='replace')
print("edit summary: replace=%d insert(fbsd-only)=%d delete(linux-only)=%d"%(rep,ins,dele))
