# Discovering Toeplitz hash algorithm

Compilation instruction:
```
make
````

Run:
```
olivier@lame4:~/myscripts/FreeBSD/testrss % ./testrss
Verifying the RSS Hash Calculation
https://msdn.microsoft.com/en-us/windows/hardware/drivers/network/verifying-the-rss-hash-calculation
Dest IP:port            Source IP:port          2tuple MS ref   2tuple fbsd     4tuple MS ref   4tuple fbsd
161.142.100.80:1766     66.9.149.187:2794       0x323e8fc2      0x51ccc178      0x323e8fc2      0xeb7a28c4
65.69.140.83:4739       199.92.111.2:14230      0xd718262a      0xc626b0ea      0xd718262a      0xbc99014d
12.22.207.184:38024     24.19.198.95:12898      0xd2d0a5de      0x5c2b394a      0xd2d0a5de      0x697acc65
209.142.163.6:2217      38.27.205.30:48228      0x82989176      0xafc7327f      0x82989176      0xd5c52866
202.188.127.2:1303      153.39.163.191:44251    0x5d1809c5      0x10e828a2      0x5d1809c5      0x52f29f29
olivier@lame4:~/myscripts/FreeBSD/testrss % uname -a
FreeBSD lame4.bsdrp.net 12.0-CURRENT FreeBSD 12.0-CURRENT #21 r312988M: Mon Jan 30 15:34:27 CET 2017     olivier@lame4.bsdrp.net:/usr/obj/usr/src/sys/GENERIC-NODEBUG  amd64
```
