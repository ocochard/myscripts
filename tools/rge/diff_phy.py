#!/usr/bin/env python3
# Diff FreeBSD mac_r26_2_mcu[] PHY MCU vs Linux rtl8126a-3.fw PHY write stream.
import sys
from normalize import load, phy_ocp_writes
from fbsd_extract import extract, to_ocp

lin_ver, lin_words = load(sys.argv[1] if len(sys.argv)>1 else "rtl8126a-3.fw")
lin = phy_ocp_writes(lin_words)
fb = to_ocp(extract("if_rge_microcode.h", "mac_r26_2_mcu"))

# strip tag bits for pure data-stream compare (keep only the A438 data run +
# addr sets). Compare as flat (addr,data) sequences.
def norm(seq):
    r=[]
    for a,d in seq:
        r.append((a & 0xffff, d))
    return r
L=norm(lin); F=norm(fb)
print("Linux PHY OCP writes = %d   FreeBSD = %d"%(len(L),len(F)))
n=min(len(L),len(F)); diffs=0; first=[]
for i in range(n):
    if L[i]!=F[i]:
        diffs+=1
        if len(first)<20: first.append((i,L[i],F[i]))
print("first %d compared, mismatches=%d"%(n,diffs))
for i,l,f in first:
    print("  [%4d] linux (0x%04x,0x%04x)  fbsd (0x%04x,0x%04x)"%(i,l[0],l[1],f[0],f[1]))
if len(L)!=len(F):
    print("LENGTH DIFF: linux=%d fbsd=%d (tail differs)"%(len(L),len(F)))
    longer = L if len(L)>len(F) else F
    who = "linux" if len(L)>len(F) else "fbsd"
    print("extra tail (%s):"%who)
    for a,d in longer[n:n+10]:
        print("  (0x%04x,0x%04x)"%(a,d))
if diffs==0 and len(L)==len(F):
    print("*** PHY MCU IMAGES ARE IDENTICAL ***")
