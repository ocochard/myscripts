# hashcat usage

## cheets
```
- [ Built-in Charsets ] -

  ? | Charset
 ===+=========
  l | abcdefghijklmnopqrstuvwxyz [a-z]
  u | ABCDEFGHIJKLMNOPQRSTUVWXYZ [A-Z]
  d | 0123456789                 [0-9]
  h | 0123456789abcdef           [0-9a-f]
  H | 0123456789ABCDEF           [0-9A-F]
  s |  !"#$%&'()*+,-./:;<=>?@[\]^_`{|}~
  a | ?l?u?d?s
  b | 0x00 - 0xff
```

## Examples

Simple usage, cracking a SHA1 hash, password length is 8 characters long and has only lower characters:
```
hashcat -m 100 -a 3 $(echo -n password | sha1sum | awk '{print $1}') ?l?l?l?l?l?l?l?l
```

Pushing hardware (-O for optimized kernel, -w 3 for workload profile "high"), password 8 characters long with letters, decimals and special:
```
hashcat -m 100 -a 3 -O -w 3 $(echo -n m0tdP!ss | sha1sum | awk '{print $1}') ?a?a?a?a?a?a?a?a
```

We know the hash is sha1 and password is 8 characters long with letters and decimal only, so create a custom set:
```
hashcat -m 100 -a 3 -O -w 3 -1 ?l?u?d $(echo -n m0tdP3s4 | sha1sum | awk '{print $1}') ?1?1?1?1?1?1?1?1
```

Output example:
```
(etc.)
5e931ff5251842984887ad84c6ec401636f3d459:m0tdP3s4

Session..........: hashcat
Status...........: Cracked
Hash.Mode........: 100 (SHA1)
Hash.Target......: 5e931ff5251842984887ad84c6ec401636f3d459
Time.Started.....: Sat Apr 15 18:34:24 2023 (40 mins, 51 secs)
Time.Estimated...: Sat Apr 15 19:15:15 2023 (0 secs)
Kernel.Feature...: Optimized Kernel
Guess.Mask.......: ?1?1?1?1?1?1?1?1 [8]
Guess.Charset....: -1 ?l?u?d, -2 Undefined, -3 Undefined, -4 Undefined
Guess.Queue......: 1/1 (100.00%)
Speed.#1.........:  6899.1 MH/s (96.51ms) @ Accel:32 Loops:1024 Thr:512 Vec:1
Speed.#2.........:  6779.8 MH/s (98.20ms) @ Accel:32 Loops:1024 Thr:512 Vec:1
Speed.#3.........:  6708.2 MH/s (99.30ms) @ Accel:32 Loops:1024 Thr:512 Vec:1
Speed.#*.........: 20387.2 MH/s
Recovered........: 1/1 (100.00%) Digests
Progress.........: 49940911882240/218340105584896 (22.87%)
Rejected.........: 0/49940911882240 (0.00%)
Restore.Point....: 207749120/916132832 (22.68%)
Restore.Sub.#1...: Salt:0 Amplifier:26624-27648 Iteration:0-1024
Restore.Sub.#2...: Salt:0 Amplifier:83968-84992 Iteration:0-1024
Restore.Sub.#3...: Salt:0 Amplifier:65536-66560 Iteration:0-1024
Candidate.Engine.: Device Generator
Candidates.#1....: 5OMxWbh3 -> YvsVF0jd
Candidates.#2....: eQCZY39j -> FLac5U1b
Candidates.#3....: 10t2yZ8b -> zbgjQtc2
Hardware.Mon.#1..: Temp: 69c Util: 83% Core:1545MHz Mem:5000MHz Bus:16
Hardware.Mon.#2..: Temp: 69c Util: 83% Core:1545MHz Mem:5000MHz Bus:16
Hardware.Mon.#3..: Temp: 69c Util: 83% Core:1560MHz Mem:5000MHz Bus:16

Started: Sat Apr 15 18:34:17 2023
Stopped: Sat Apr 15 19:15:17 2023
```

Hash is MD5, Password lenght somewhere between 1 and 8 caracters long, all characters:
```
hashcat -m 0 -a 3 -O -w 3 --increment $(echo -n 'm0tdP!' | md5sum | awk '{print $1}') ?a?a?a?a?a?a?a?a
```
