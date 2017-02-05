# Discovering and testing Toeplitz hash algorithm

Compilation instruction:
```
make
````

Run:
```
% ./testrss
Verifying the RSS Hash Calculation
https://msdn.microsoft.com/en-us/windows/hardware/drivers/network/verifying-the-rss-hash-calculation
key:
6d5a56da255b0ec2
4167253d43a38fb0
d0ca2bcbae7b30b4
77cb2da38030f20c
6a42b73bbeac01fa

MS websibe dispaly table with destination IP first, but because all functions use source first, I've swapped them
Source IP:port          Dest IP:port            2tuple MS ref   2tuple fbsd     4tuple MS ref   4tuple fbsd
66.9.149.187:2794       161.142.100.80:1766     323e8fc2        323e8fc2        51ccc178        51ccc178
199.92.111.2:14230      65.69.140.83:4739       d718262a        d718262a        c626b0ea        c626b0ea
24.19.198.95:12898      12.22.207.184:38024     d2d0a5de        d2d0a5de        5c2b394a        5c2b394a
38.27.205.30:48228      209.142.163.6:2217      82989176        82989176        afc7327f        afc7327f
153.39.163.191:44251    202.188.127.2:1303      5d1809c5        5d1809c5        10e828a2        10e828a2

```

FreeBSD version:

```
% uname -a
FreeBSD lame4.bsdrp.net 12.0-CURRENT FreeBSD 12.0-CURRENT #21 r312988M: Mon Jan 30 15:34:27 CET 2017     olivier@lame4.bsdrp.net:/usr/obj/usr/src/sys/GENERIC-NODEBUG  amd64
```
