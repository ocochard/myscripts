#!/usr/bin/env python3
# Three-way compare of the RTL8126A rev.c (a-3) PHY RAM code across:
#   FreeBSD  mac_r26_2_mcu[]          (if_rge_microcode.h, {reg,val} pairs)
#   vendor   phy_mcu_ram_code_8126a_3_1[]  (if_re.c, flat u16 reg,val,reg,val)
#   Linux    rtl8126a-3.fw            (r8169 firmware microprogram)
import re, struct, difflib
RTL_VER_SIZE=32

def fbsd_pairs():
    txt=open("if_rge_microcode.h").read()
    m=re.search(r'mac_r26_2_mcu\[\]\s*=\s*\{(.*?)\n\};',txt,re.S)
    p=re.findall(r'\{\s*(0x[0-9a-fA-F]+)\s*,\s*(0x[0-9a-fA-F]+)\s*\}',m.group(1))
    return [(int(r,16),int(v,16)) for r,v in p]

def vendor_pairs():
    txt=open("if_re.c").read()
    m=re.search(r'phy_mcu_ram_code_8126a_3_1\[\]\s*=\s*\{(.*?)\n\};',txt,re.S)
    nums=[int(x,16) for x in re.findall(r'0x[0-9a-fA-F]+',m.group(1))]
    return list(zip(nums[0::2],nums[1::2]))

def data_words_from_pairs(pairs):
    return [v for r,v in pairs if r==0xa438]

def linux_data():
    d=open("rtl8126a-3.fw","rb").read()
    fs=struct.unpack_from("<I",d,4+RTL_VER_SIZE)[0]
    fl=struct.unpack_from("<I",d,4+RTL_VER_SIZE+4)[0]
    words=[struct.unpack_from("<I",d,fs+i*4)[0] for i in range(fl)]
    out=[]; target="PHY"
    for a in words:
        op=a>>28; da=a&0xffff; reg=(a&0x0fff0000)>>16
        if op==0x4: target="MAC" if da else "PHY"; continue
        if op==0x8 and target=="PHY" and reg==0x14: out.append(da)
    return out

fb=fbsd_pairs(); ve=vendor_pairs()
print("FreeBSD pairs=%d  vendor pairs=%d"%(len(fb),len(ve)))
print("FreeBSD==vendor (exact pair list)? %s"%(fb==ve))
if fb!=ve:
    n=min(len(fb),len(ve))
    for i in range(n):
        if fb[i]!=ve[i]:
            print("  first pair diff @%d fbsd=%s vendor=%s"%(i,fb[i],ve[i])); break
fbd=data_words_from_pairs(fb); ld=linux_data()
sm=difflib.SequenceMatcher(a=ld,b=fbd,autojunk=False)
print("\nFreeBSD/vendor data words=%d  Linux a-3.fw data words=%d"%(len(fbd),len(ld)))
print("similarity (FreeBSD-vendor vs Linux a-3) = %.4f"%sm.ratio())
p=0
while p<min(len(ld),len(fbd)) and ld[p]==fbd[p]: p+=1
print("common prefix = %d words"%p)
