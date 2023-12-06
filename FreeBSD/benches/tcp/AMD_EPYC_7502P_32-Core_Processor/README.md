# Impact of TCP stacks and Congestion Control Algo mix
## Concept
Dummy iperf2/iperf3 benches using localhost interface (client -> server), no latency neither drop emulated,
server bind to one cpu and client to another. So should expect equivalent result.
-  TCP stacks available: freebsd,rack,bbr
-  CC Algos available: cubic htcp cdg chd dctcp vegas newreno,
## System info
### FreeBSD kernel
```
FreeBSD 15.0-CURRENT #8 main-n266813-4b92c7721dee: Mon Dec  4 20:34:36 CET 2023
    root@bigone:/usr/obj/usr/src/amd64.amd64/sys/GENERIC-NODEBUG

```
### CPU
model: AMD EPYC 7502P 32-Core Processor
32 cores, 2 threads per core, 64 total CPUs
### Verbose
[sysinfo](sysinfo.md)
## Comparing impact of Congestion Control Algorithms (same TCP stack)
### TCP stack: freebsd
#### iperf3
```
x iperf3.freebsd.cdg
+ iperf3.freebsd.chd
* iperf3.freebsd.cubic
% iperf3.freebsd.dctcp
# iperf3.freebsd.htcp
@ iperf3.freebsd.newreno
O iperf3.freebsd.vegas
+--------------------------------------------------------------------------+
|     O        O       +        O       O        O       #                @|
|               |_________A_____M___|                                      |
|                        |_________A____M___|                              |
|              |________________A________________|                         |
|                                |____________A__M_________|               |
|                                   |___M_____A_________|                  |
|         |_____________________M_______A______________________________|   |
||_____________M_______A______________________|                            |
+--------------------------------------------------------------------------+
    N           Min           Max        Median           Avg        Stddev
x   3          37.7          37.9          37.9     37.833333    0.11547005
+   3          37.8            38            38     37.933333    0.11547005
No difference proven at 95.0% confidence
*   3          37.7          38.1          37.9          37.9           0.2
No difference proven at 95.0% confidence
%   3          37.9          38.2          38.1     38.066667    0.15275252
No difference proven at 95.0% confidence
#   3            38          38.2            38     38.066667    0.11547005
No difference proven at 95.0% confidence
@   3          37.7          38.4          37.9            38    0.36055513
No difference proven at 95.0% confidence
O   3          37.6          38.1          37.7          37.8    0.26457513
No difference proven at 95.0% confidence
```
#### iperf
```
x iperf.freebsd.cdg
+ iperf.freebsd.chd
* iperf.freebsd.cubic
% iperf.freebsd.dctcp
# iperf.freebsd.htcp
@ iperf.freebsd.newreno
O iperf.freebsd.vegas
+--------------------------------------------------------------------------+
|          x x                                           **    O#+O  O *O #|
||___________M_____________A_________________________|                     |
|                                                         |___AM__|        |
|                                                     |___M___A_______|    |
|                                                              |MA__|      |
|                                                            |__M__A_____| |
|                                                              |__MA___|   |
|                                                                 |__A__|  |
+--------------------------------------------------------------------------+
    N           Min           Max        Median           Avg        Stddev
x   3          33.9            40          34.1            36     3.4655447
+   3            40            41          40.7     40.566667    0.51316014
No difference proven at 95.0% confidence
*   3          39.9          41.8          40.1          40.6     1.0440307
No difference proven at 95.0% confidence
%   3          40.8          41.5          40.9     41.066667    0.37859389
No difference proven at 95.0% confidence
#   3          40.8          42.2          40.9          41.3    0.78102497
No difference proven at 95.0% confidence
@   3          40.8          41.9          41.1     41.266667    0.56862407
No difference proven at 95.0% confidence
O   3          41.1          41.9          41.6     41.533333    0.40414519
No difference proven at 95.0% confidence
```
#### iperf2 vs iperf3
```
##### CCA: cubic
```
x iperf.freebsd.cubic
+ iperf3.freebsd.cubic
+--------------------------------------------------------------------------+
|+   +  +                               x   x                             x|
|                                 |_________M________A_________________|   |
||___A__|                                                                  |
+--------------------------------------------------------------------------+
    N           Min           Max        Median           Avg        Stddev
x   3          39.9          41.8          40.1          40.6     1.0440307
+   3          37.7          38.1          37.9          37.9           0.2
Difference at 95.0% confidence
	-2.7 +/- 1.70372
	-6.65025% +/- 3.9275%
	(Student's t, pooled s = 0.751665)
```
##### CCA: htcp
```
x iperf.freebsd.htcp
+ iperf3.freebsd.htcp
+--------------------------------------------------------------------------+
| +                                                                        |
| +  +                                            x x                     x|
|                                            |______M______A____________|  |
||MA_|                                                                     |
+--------------------------------------------------------------------------+
    N           Min           Max        Median           Avg        Stddev
x   3          40.8          42.2          40.9          41.3    0.78102497
+   3            38          38.2            38     38.066667    0.11547005
Difference at 95.0% confidence
	-3.23333 +/- 1.26537
	-7.82889% +/- 2.82934%
	(Student's t, pooled s = 0.558271)
```
##### CCA: cdg
```
x iperf.freebsd.cdg
+ iperf3.freebsd.cdg
+--------------------------------------------------------------------------+
|                                                    +                     |
|             x x                                   ++                    x|
||______________M__________________A_________________________________|     |
|                                                   |A|                    |
+--------------------------------------------------------------------------+
    N           Min           Max        Median           Avg        Stddev
x   3          33.9            40          34.1            36     3.4655447
+   3          37.7          37.9          37.9     37.833333    0.11547005
No difference proven at 95.0% confidence
```
##### CCA: chd
```
x iperf.freebsd.chd
+ iperf3.freebsd.chd
+--------------------------------------------------------------------------+
|    +                                                                     |
|+   +                                            x               x     x  |
|                                                  |___________A__M_______||
||__AM_|                                                                   |
+--------------------------------------------------------------------------+
    N           Min           Max        Median           Avg        Stddev
x   3            40            41          40.7     40.566667    0.51316014
+   3          37.8            38            38     37.933333    0.11547005
Difference at 95.0% confidence
	-2.63333 +/- 0.843019
	-6.49137% +/- 1.94992%
	(Student's t, pooled s = 0.371932)
```
##### CCA: dctcp
```
x iperf.freebsd.dctcp
+ iperf3.freebsd.dctcp
+--------------------------------------------------------------------------+
|+   + +                                                    x x           x|
|                                                         |___M__A_______| |
||__AM_|                                                                   |
+--------------------------------------------------------------------------+
    N           Min           Max        Median           Avg        Stddev
x   3          40.8          41.5          40.9     41.066667    0.37859389
+   3          37.9          38.2          38.1     38.066667    0.15275252
Difference at 95.0% confidence
	-3 +/- 0.654309
	-7.30519% +/- 1.49373%
	(Student's t, pooled s = 0.288675)
```
##### CCA: vegas
```
x iperf.freebsd.vegas
+ iperf3.freebsd.vegas
+--------------------------------------------------------------------------+
| + +     +                                                 x       x    x |
|                                                            |_____AM_____||
||__MA____|                                                                |
+--------------------------------------------------------------------------+
    N           Min           Max        Median           Avg        Stddev
x   3          41.1          41.9          41.6     41.533333    0.40414519
+   3          37.6          38.1          37.7          37.8    0.26457513
Difference at 95.0% confidence
	-3.73333 +/- 0.774189
	-8.98876% +/- 1.74842%
	(Student's t, pooled s = 0.341565)
```
##### CCA: newreno
```
x iperf.freebsd.newreno
+ iperf3.freebsd.newreno
+--------------------------------------------------------------------------+
| +  +        +                                        x    x             x|
|                                                    |______M__A_________| |
||___M_A_____|                                                             |
+--------------------------------------------------------------------------+
    N           Min           Max        Median           Avg        Stddev
x   3          40.8          41.9          41.1     41.266667    0.56862407
+   3          37.7          38.4          37.9            38    0.36055513
Difference at 95.0% confidence
	-3.26667 +/- 1.07911
	-7.91599% +/- 2.46911%
	(Student's t, pooled s = 0.476095)
```
### TCP stack: rack
#### iperf3
```
x iperf3.rack.cdg
+ iperf3.rack.chd
* iperf3.rack.cubic
% iperf3.rack.dctcp
# iperf3.rack.htcp
@ iperf3.rack.newreno
O iperf3.rack.vegas
+--------------------------------------------------------------------------+
|        x  O      O   O# # O *       O      %      %                O @  x|
||_____________________M___________A_________________________________|     |
|                  |___A____|                                              |
|            |________________M________A_________________________|         |
|                            |____________A__M________|                    |
|              |__________M_____________A________________________|         |
|        |_____________M______________A___________________________|        |
|            |____________A_M__________|                                   |
+--------------------------------------------------------------------------+
    N           Min           Max        Median           Avg        Stddev
x   3          22.8          26.6          23.6     24.333333     2.0033306
+   3          23.4          23.9          23.6     23.633333    0.25166115
No difference proven at 95.0% confidence
*   3          23.4          26.3            24     24.566667      1.530795
No difference proven at 95.0% confidence
%   3          23.9          25.3          24.9          24.7    0.72111026
No difference proven at 95.0% confidence
#   3          23.7          26.3          23.8          24.6      1.473092
No difference proven at 95.0% confidence
@   3          23.4          26.4          23.6     24.466667     1.6772994
No difference proven at 95.0% confidence
O   3            23          24.5          23.9          23.8    0.75498344
No difference proven at 95.0% confidence
```
#### iperf
```
x iperf.rack.cdg
+ iperf.rack.chd
* iperf.rack.cubic
% iperf.rack.dctcp
# iperf.rack.htcp
@ iperf.rack.newreno
O iperf.rack.vegas
+--------------------------------------------------------------------------+
|        # O*@% @O#OO                                                     *|
|         |_M_A___|                                                        |
|          A                                                               |
||_________________M_______________A_________________________________|     |
|          |__MA__|                                                        |
|       |__M_A____|                                                        |
|           |MA_|                                                          |
|                |_A|                                                      |
+--------------------------------------------------------------------------+
    N           Min           Max        Median           Avg        Stddev
x   3            21          23.6          21.1          21.9      1.473092
+   3          20.9            21          20.9     20.933333   0.057735027
No difference proven at 95.0% confidence
*   3          21.3          42.7          23.6          29.2     11.747766
No difference proven at 95.0% confidence
%   3            21          23.6          21.8     22.133333     1.3316656
No difference proven at 95.0% confidence
#   3          20.1          23.5          20.9          21.5     1.7776389
No difference proven at 95.0% confidence
@   3          21.6          22.6          21.7     21.966667    0.55075705
No difference proven at 95.0% confidence
O   3            23          24.1          23.6     23.566667    0.55075705
No difference proven at 95.0% confidence
```
#### iperf2 vs iperf3
```
##### CCA: cubic
```
x iperf.rack.cubic
+ iperf3.rack.cubic
+--------------------------------------------------------------------------+
|           x     +x+      +                                              x|
||_________________M_______________A_________________________________|     |
|                |__M_A___|                                                |
+--------------------------------------------------------------------------+
    N           Min           Max        Median           Avg        Stddev
x   3          21.3          42.7          23.6          29.2     11.747766
+   3          23.4          26.3            24     24.566667      1.530795
No difference proven at 95.0% confidence
```
##### CCA: htcp
```
x iperf.rack.htcp
+ iperf3.rack.htcp
+--------------------------------------------------------------------------+
|    x        x                            x ++                           +|
||____________M______A__________________|                                  |
|                                      |______M________A_______________|   |
+--------------------------------------------------------------------------+
    N           Min           Max        Median           Avg        Stddev
x   3          20.1          23.5          20.9          21.5     1.7776389
+   3          23.7          26.3          23.8          24.6      1.473092
No difference proven at 95.0% confidence
```
##### CCA: cdg
```
x iperf.rack.cdg
+ iperf3.rack.cdg
+--------------------------------------------------------------------------+
|       xx                   +         *                                  +|
||_______M________A_________________|                                      |
|                       |______________M_______A_______________________|   |
+--------------------------------------------------------------------------+
    N           Min           Max        Median           Avg        Stddev
x   3            21          23.6          21.1          21.9      1.473092
+   3          22.8          26.6          23.6     24.333333     2.0033306
No difference proven at 95.0% confidence
```
##### CCA: chd
```
x iperf.rack.chd
+ iperf3.rack.chd
+--------------------------------------------------------------------------+
| x x                                                         +    +      +|
||A_|                                                                      |
|                                                            |_____MA_____||
+--------------------------------------------------------------------------+
    N           Min           Max        Median           Avg        Stddev
x   3          20.9            21          20.9     20.933333   0.057735027
+   3          23.4          23.9          23.6     23.633333    0.25166115
Difference at 95.0% confidence
	2.7 +/- 0.413822
	12.8981% +/- 1.99038%
	(Student's t, pooled s = 0.182574)
```
##### CCA: dctcp
```
x iperf.rack.dctcp
+ iperf3.rack.dctcp
+--------------------------------------------------------------------------+
|   x            x                           x    +               +     +  |
||_______________M____A____________________|                               |
|                                                  |___________A__M_______||
+--------------------------------------------------------------------------+
    N           Min           Max        Median           Avg        Stddev
x   3            21          23.6          21.8     22.133333     1.3316656
+   3          23.9          25.3          24.9          24.7    0.72111026
Difference at 95.0% confidence
	2.56667 +/- 2.42713
	11.5964% +/- 11.9611%
	(Student's t, pooled s = 1.07083)
```
##### CCA: vegas
```
x iperf.rack.vegas
+ iperf3.rack.vegas
+--------------------------------------------------------------------------+
|*                           x             +         x                 +   |
| |_________________________AM_______________________|                     |
|  |___________________________________A___M______________________________||
+--------------------------------------------------------------------------+
    N           Min           Max        Median           Avg        Stddev
x   3            23          24.1          23.6     23.566667    0.55075705
+   3            23          24.5          23.9          23.8    0.75498344
No difference proven at 95.0% confidence
```
##### CCA: newreno
```
x iperf.rack.newreno
+ iperf3.rack.newreno
+--------------------------------------------------------------------------+
|   xx            x           +  +                                        +|
||___M___A_______|                                                         |
|                    |___________M____________A_______________________|    |
+--------------------------------------------------------------------------+
    N           Min           Max        Median           Avg        Stddev
x   3          21.6          22.6          21.7     21.966667    0.55075705
+   3          23.4          26.4          23.6     24.466667     1.6772994
No difference proven at 95.0% confidence
```
### TCP stack: bbr
#### iperf3
```
x iperf3.bbr.cdg
+ iperf3.bbr.chd
* iperf3.bbr.cubic
% iperf3.bbr.dctcp
# iperf3.bbr.htcp
@ iperf3.bbr.newreno
O iperf3.bbr.vegas
+--------------------------------------------------------------------------+
|     #     %  @  #          @     O O  *  O  +  + x  #             *     O|
| |_______________M______A_______________________|                         |
|                                          |__A__|                         |
|                             |_________M_______A_________________|        |
|             |____________A_______M____|                                  |
||________________M_______A________________________|                       |
|               |_________A__M______|                                      |
|                               |__________M_______A___________________|   |
+--------------------------------------------------------------------------+
    N           Min           Max        Median           Avg        Stddev
x   3          1.94           2.1          1.98     2.0066667    0.08326664
+   3          2.07          2.09          2.08          2.08          0.01
No difference proven at 95.0% confidence
*   3          2.04          2.16          2.06     2.0866667   0.064291005
No difference proven at 95.0% confidence
%   3          1.96          2.04          2.04     2.0133333   0.046188022
No difference proven at 95.0% confidence
#   3          1.94          2.11          1.98          2.01   0.088881944
No difference proven at 95.0% confidence
@   3          1.97          2.04          2.02          2.01   0.036055513
No difference proven at 95.0% confidence
O   3          2.05          2.18          2.07           2.1          0.07
No difference proven at 95.0% confidence
```
#### iperf
```
x iperf.bbr.cdg
+ iperf.bbr.chd
* iperf.bbr.cubic
% iperf.bbr.dctcp
# iperf.bbr.htcp
@ iperf.bbr.newreno
O iperf.bbr.vegas
+--------------------------------------------------------------------------+
|+                    %@         O O O    O @   * O *  x +       #        %|
|                                   |__________A__M______|                 |
|   |____________________________A________M____________________|           |
|                                         |____AM___|                      |
|                   |_____________________M___A_________________________|  |
|                                   |_________________A__________M______|  |
|                       |_________AM________|                              |
|                              |_____M__A________|                         |
+--------------------------------------------------------------------------+
    N           Min           Max        Median           Avg        Stddev
x   3          2.05          2.16          2.13     2.1133333   0.056862407
+   3          1.87          2.17          2.09     2.0433333    0.15534907
No difference proven at 95.0% confidence
*   3          2.09          2.14          2.12     2.1166667   0.025166115
No difference proven at 95.0% confidence
%   3          1.98          2.26          2.09          2.11    0.14106736
No difference proven at 95.0% confidence
#   3          2.04          2.21          2.21     2.1533333   0.098149546
No difference proven at 95.0% confidence
@   3          1.99           2.1          2.05     2.0466667   0.055075705
No difference proven at 95.0% confidence
O   3          2.04          2.13          2.06     2.0766667   0.047258156
No difference proven at 95.0% confidence
```
#### iperf2 vs iperf3
```
##### CCA: cubic
```
x iperf.bbr.cubic
+ iperf3.bbr.cubic
+--------------------------------------------------------------------------+
|         +          +               x               x         x          +|
|                                     |____________A_M__________|          |
||___________________M_____________A_________________________________|     |
+--------------------------------------------------------------------------+
    N           Min           Max        Median           Avg        Stddev
x   3          2.09          2.14          2.12     2.1166667   0.025166115
+   3          2.04          2.16          2.06     2.0866667   0.064291005
No difference proven at 95.0% confidence
```
##### CCA: htcp
```
x iperf.bbr.htcp
+ iperf3.bbr.htcp
+--------------------------------------------------------------------------+
|    +        +            x               +                     x         |
|                              |____________________A____________M________||
||____________M______A__________________|                                  |
+--------------------------------------------------------------------------+
    N           Min           Max        Median           Avg        Stddev
x   3          2.04          2.21          2.21     2.1533333   0.098149546
+   3          1.94          2.11          1.98          2.01   0.088881944
No difference proven at 95.0% confidence
```
##### CCA: cdg
```
x iperf.bbr.cdg
+ iperf3.bbr.cdg
+--------------------------------------------------------------------------+
|     +           +                   x              +        x        x   |
|                                       |________________A____M___________||
||________________M_______A_______________________|                        |
+--------------------------------------------------------------------------+
    N           Min           Max        Median           Avg        Stddev
x   3          2.05          2.16          2.13     2.1133333   0.056862407
+   3          1.94           2.1          1.98     2.0066667    0.08326664
No difference proven at 95.0% confidence
```
##### CCA: chd
```
x iperf.bbr.chd
+ iperf3.bbr.chd
+--------------------------------------------------------------------------+
|x                                           +  + *                 x      |
|    |_________________________________A__________M_______________________||
|                                            |__A_|                        |
+--------------------------------------------------------------------------+
    N           Min           Max        Median           Avg        Stddev
x   3          1.87          2.17          2.09     2.0433333    0.15534907
+   3          2.07          2.09          2.08          2.08          0.01
No difference proven at 95.0% confidence
```
##### CCA: dctcp
```
x iperf.bbr.dctcp
+ iperf3.bbr.dctcp
+--------------------------------------------------------------------------+
|                   +                                                      |
|+    x             +            x                                        x|
|  |_____________________________M____A_________________________________|  |
|  |__________A_____M____|                                                 |
+--------------------------------------------------------------------------+
    N           Min           Max        Median           Avg        Stddev
x   3          1.98          2.26          2.09          2.11    0.14106736
+   3          1.96          2.04          2.04     2.0133333   0.046188022
No difference proven at 95.0% confidence
```
##### CCA: vegas
```
x iperf.bbr.vegas
+ iperf3.bbr.vegas
+--------------------------------------------------------------------------+
|     x    +    x    +                            x                       +|
||______________M_______A______________________|                           |
||___________________M_____________A_________________________________|     |
+--------------------------------------------------------------------------+
    N           Min           Max        Median           Avg        Stddev
x   3          2.04          2.13          2.06     2.0766667   0.047258156
+   3          2.05          2.18          2.07           2.1          0.07
No difference proven at 95.0% confidence
```
##### CCA: newreno
```
x iperf.bbr.newreno
+ iperf3.bbr.newreno
+--------------------------------------------------------------------------+
|+          x                +          +    x                           x |
|            |_____________________________A_M____________________________||
|  |___________________A_____M_____________|                               |
+--------------------------------------------------------------------------+
    N           Min           Max        Median           Avg        Stddev
x   3          1.99           2.1          2.05     2.0466667   0.055075705
+   3          1.97          2.04          2.02          2.01   0.036055513
No difference proven at 95.0% confidence
```
## Comparing impact of TCP stacks (same Congestion Control Algorithms)
### CCA stack: cubic
#### iperf3
```
x iperf3.bbr.cubic
+ iperf3.freebsd.cubic
* iperf3.rack.cubic
+--------------------------------------------------------------------------+
|x                                          **    *                      ++|
|A                                                                         |
|                                                                        |A|
|                                           |M_A__|                        |
+--------------------------------------------------------------------------+
    N           Min           Max        Median           Avg        Stddev
x   3          2.04          2.16          2.06     2.0866667   0.064291005
+   3          37.7          38.1          37.9          37.9           0.2
Difference at 95.0% confidence
	35.8133 +/- 0.336699
	1716.29% +/- 90.9956%
	(Student's t, pooled s = 0.148549)
*   3          23.4          26.3            24     24.566667      1.530795
Difference at 95.0% confidence
	22.48 +/- 2.45561
	1077.32% +/- 131.165%
	(Student's t, pooled s = 1.08339)
```
#### iperf
```
x iperf.bbr.cubic
+ iperf.freebsd.cubic
* iperf.rack.cubic
+--------------------------------------------------------------------------+
|x                                  *   *                            +  + *|
|A                                                                         |
|                                                                   |MA_|  |
|                            |__________M_________A____________________|   |
+--------------------------------------------------------------------------+
    N           Min           Max        Median           Avg        Stddev
x   3          2.09          2.14          2.12     2.1166667   0.025166115
+   3          39.9          41.8          40.1          40.6     1.0440307
Difference at 95.0% confidence
	38.4833 +/- 1.67378
	1818.11% +/- 87.094%
	(Student's t, pooled s = 0.738456)
*   3          21.3          42.7          23.6          29.2     11.747766
Difference at 95.0% confidence
	27.0833 +/- 18.8285
	1279.53% +/- 889.92%
	(Student's t, pooled s = 8.30694)
```
### CCA stack: htcp
#### iperf3
```
x iperf3.bbr.htcp
+ iperf3.freebsd.htcp
* iperf3.rack.htcp
+--------------------------------------------------------------------------+
|x                                           *                            +|
|x                                           *    *                       +|
|A                                                                         |
|                                                                        |A|
|                                           |M_A__|                        |
+--------------------------------------------------------------------------+
    N           Min           Max        Median           Avg        Stddev
x   3          1.94          2.11          1.98          2.01   0.088881944
+   3            38          38.2            38     38.066667    0.11547005
Difference at 95.0% confidence
	36.0567 +/- 0.233544
	1793.86% +/- 134.538%
	(Student's t, pooled s = 0.103037)
*   3          23.7          26.3          23.8          24.6      1.473092
Difference at 95.0% confidence
	22.59 +/- 2.36525
	1123.88% +/- 146.016%
	(Student's t, pooled s = 1.04353)
```
#### iperf
```
x iperf.bbr.htcp
+ iperf.freebsd.htcp
* iperf.rack.htcp
+--------------------------------------------------------------------------+
|x                                **    *                              ++ +|
|A                                                                         |
|                                                                      |A_||
|                                |_MA___|                                  |
+--------------------------------------------------------------------------+
    N           Min           Max        Median           Avg        Stddev
x   3          2.04          2.21          2.21     2.1533333   0.098149546
+   3          40.8          42.2          40.9          41.3    0.78102497
Difference at 95.0% confidence
	39.1467 +/- 1.26161
	1817.96% +/- 151.692%
	(Student's t, pooled s = 0.556612)
*   3          20.1          23.5          20.9          21.5     1.7776389
Difference at 95.0% confidence
	19.3467 +/- 2.8534
	898.452% +/- 151.083%
	(Student's t, pooled s = 1.2589)
```
### CCA stack: cdg
#### iperf3
```
x iperf3.bbr.cdg
+ iperf3.freebsd.cdg
* iperf3.rack.cdg
+--------------------------------------------------------------------------+
|x                                         * *     *                     ++|
|A                                                                         |
|                                                                         A|
|                                         |__MA___|                        |
+--------------------------------------------------------------------------+
    N           Min           Max        Median           Avg        Stddev
x   3          1.94           2.1          1.98     2.0066667    0.08326664
+   3          37.7          37.9          37.9     37.833333    0.11547005
Difference at 95.0% confidence
	35.8267 +/- 0.228166
	1785.38% +/- 125.726%
	(Student's t, pooled s = 0.100664)
*   3          22.8          26.6          23.6     24.333333     2.0033306
Difference at 95.0% confidence
	22.3267 +/- 3.21356
	1112.62% +/- 179.18%
	(Student's t, pooled s = 1.41779)
```
#### iperf
```
x iperf.bbr.cdg
+ iperf.freebsd.cdg
* iperf.rack.cdg
+--------------------------------------------------------------------------+
|x                                   **   *                   ++          +|
|A                                                                         |
|                                                           |__M__A______| |
|                                   |_MA__|                                |
+--------------------------------------------------------------------------+
    N           Min           Max        Median           Avg        Stddev
x   3          2.05          2.16          2.13     2.1133333   0.056862407
+   3          33.9            40          34.1            36     3.4655447
Difference at 95.0% confidence
	33.8867 +/- 5.55506
	1603.47% +/- 272.896%
	(Student's t, pooled s = 2.45084)
*   3            21          23.6          21.1          21.9      1.473092
Difference at 95.0% confidence
	19.7867 +/- 2.36272
	936.278% +/- 120.324%
	(Student's t, pooled s = 1.04241)
```
### CCA stack: chd
#### iperf3
```
x iperf3.bbr.chd
+ iperf3.freebsd.chd
* iperf3.rack.chd
+--------------------------------------------------------------------------+
|x                                           *                            +|
|x                                          **                           ++|
|A                                                                         |
|                                                                         A|
|                                           |A                             |
+--------------------------------------------------------------------------+
    N           Min           Max        Median           Avg        Stddev
x   3          2.07          2.09          2.08          2.08          0.01
+   3          37.8            38            38     37.933333    0.11547005
Difference at 95.0% confidence
	35.8533 +/- 0.185759
	1723.72% +/- 16.6324%
	(Student's t, pooled s = 0.0819553)
*   3          23.4          23.9          23.6     23.633333    0.25166115
Difference at 95.0% confidence
	21.5533 +/- 0.403662
	1036.22% +/- 21.2763%
	(Student's t, pooled s = 0.178092)
```
#### iperf
```
x iperf.bbr.chd
+ iperf.freebsd.chd
* iperf.rack.chd
+--------------------------------------------------------------------------+
|                                   *                                      |
|xx                                 **                                  +++|
|A|                                                                        |
|                                                                       |A||
|                                   A|                                     |
+--------------------------------------------------------------------------+
    N           Min           Max        Median           Avg        Stddev
x   3          1.87          2.17          2.09     2.0433333    0.15534907
+   3            40            41          40.7     40.566667    0.51316014
Difference at 95.0% confidence
	38.5233 +/- 0.859315
	1885.32% +/- 245.238%
	(Student's t, pooled s = 0.379122)
*   3          20.9            21          20.9     20.933333   0.057735027
Difference at 95.0% confidence
	18.89 +/- 0.265621
	924.47% +/- 124.915%
	(Student's t, pooled s = 0.117189)
```
### CCA stack: dctcp
#### iperf3
```
x iperf3.bbr.dctcp
+ iperf3.freebsd.dctcp
* iperf3.rack.dctcp
+--------------------------------------------------------------------------+
|x                                           * **                        ++|
|A                                                                         |
|                                                                        |A|
|                                            |_A|                          |
+--------------------------------------------------------------------------+
    N           Min           Max        Median           Avg        Stddev
x   3          1.96          2.04          2.04     2.0133333   0.046188022
+   3          37.9          38.2          38.1     38.066667    0.15275252
Difference at 95.0% confidence
	36.0533 +/- 0.255767
	1790.73% +/- 70.5742%
	(Student's t, pooled s = 0.112842)
*   3          23.9          25.3          24.9          24.7    0.72111026
Difference at 95.0% confidence
	22.6867 +/- 1.15811
	1126.82% +/- 73.0068%
	(Student's t, pooled s = 0.510947)
```
#### iperf
```
x iperf.bbr.dctcp
+ iperf.freebsd.dctcp
* iperf.rack.dctcp
+--------------------------------------------------------------------------+
|xx                                 * *  *                               ++|
|A|                                                                        |
|                                                                        A||
|                                   |_A__|                                 |
+--------------------------------------------------------------------------+
    N           Min           Max        Median           Avg        Stddev
x   3          1.98          2.26          2.09          2.11    0.14106736
+   3          40.8          41.5          40.9     41.066667    0.37859389
Difference at 95.0% confidence
	38.9567 +/- 0.647535
	1846.29% +/- 210.523%
	(Student's t, pooled s = 0.285686)
*   3            21          23.6          21.8     22.133333     1.3316656
Difference at 95.0% confidence
	20.0233 +/- 2.14623
	948.973% +/- 151.213%
	(Student's t, pooled s = 0.946898)
```
### CCA stack: vegas
#### iperf3
```
x iperf3.bbr.vegas
+ iperf3.freebsd.vegas
* iperf3.rack.vegas
+--------------------------------------------------------------------------+
|x                                         * **                          ++|
|A                                                                         |
|                                                                        A||
|                                           |A_|                           |
+--------------------------------------------------------------------------+
    N           Min           Max        Median           Avg        Stddev
x   3          2.05          2.18          2.07           2.1          0.07
+   3          37.6          38.1          37.7          37.8    0.26457513
Difference at 95.0% confidence
	35.7 +/- 0.438631
	1700% +/- 98.2606%
	(Student's t, pooled s = 0.19352)
*   3            23          24.5          23.9          23.8    0.75498344
Difference at 95.0% confidence
	21.7 +/- 1.21522
	1033.33% +/- 83.5829%
	(Student's t, pooled s = 0.536144)
```
#### iperf
```
x iperf.bbr.vegas
+ iperf.freebsd.vegas
* iperf.rack.vegas
+--------------------------------------------------------------------------+
|x                                     ***                              +++|
|A                                                                         |
|                                                                        A||
|                                      |A|                                 |
+--------------------------------------------------------------------------+
    N           Min           Max        Median           Avg        Stddev
x   3          2.04          2.13          2.06     2.0766667   0.047258156
+   3          41.1          41.9          41.6     41.533333    0.40414519
Difference at 95.0% confidence
	39.4567 +/- 0.652147
	1900% +/- 79.3343%
	(Student's t, pooled s = 0.287721)
*   3            23          24.1          23.6     23.566667    0.55075705
Difference at 95.0% confidence
	21.49 +/- 0.885955
	1034.83% +/- 59.3291%
	(Student's t, pooled s = 0.390875)
```
### CCA stack: newreno
#### iperf3
```
x iperf3.bbr.newreno
+ iperf3.freebsd.newreno
* iperf3.rack.newreno
+--------------------------------------------------------------------------+
|x                                          *                            + |
|x                                          *     *                      ++|
|A                                                                         |
|                                                                       |A||
|                                          |M_A__|                         |
+--------------------------------------------------------------------------+
    N           Min           Max        Median           Avg        Stddev
x   3          1.97          2.04          2.02          2.01   0.036055513
+   3          37.7          38.4          37.9            38    0.36055513
Difference at 95.0% confidence
	35.99 +/- 0.580753
	1790.55% +/- 61.488%
	(Student's t, pooled s = 0.256223)
*   3          23.4          26.4          23.6     24.466667     1.6772994
Difference at 95.0% confidence
	22.4567 +/- 2.68887
	1117.25% +/- 138.246%
	(Student's t, pooled s = 1.1863)
```
#### iperf
```
x iperf.bbr.newreno
+ iperf.freebsd.newreno
* iperf.rack.newreno
+--------------------------------------------------------------------------+
|                                    *                                     |
|x                                   * *                                +++|
|A                                                                         |
|                                                                       |A||
|                                    MA|                                   |
+--------------------------------------------------------------------------+
    N           Min           Max        Median           Avg        Stddev
x   3          1.99           2.1          2.05     2.0466667   0.055075705
+   3          40.8          41.9          41.1     41.266667    0.56862407
Difference at 95.0% confidence
	39.22 +/- 0.915613
	1916.29% +/- 97.6984%
	(Student's t, pooled s = 0.40396)
*   3          21.6          22.6          21.7     21.966667    0.55075705
Difference at 95.0% confidence
	19.92 +/- 0.887114
	973.29% +/- 63.2686%
	(Student's t, pooled s = 0.391386)
```
