# LLDB

## Doc

https://lldb.llvm.org/use/map.html

## Examples
```
~$ lldb clinfo
(lldb) target create "clinfo"
Current executable set to '/usr/local/bin/clinfo' (x86_64).
(lldb) image list
[  0] 4D45409A 0x0000000000200000 /usr/local/bin/clinfo
(lldb) image lookup -vn main
1 match found in /usr/local/bin/clinfo:
(etc.)
(lldb) b main
Breakpoint 1: where = clinfo`main + 45 at clinfo.c:4587:6, address = 0x000000000021d98d
(lldb) br l
Current breakpoints:
1: name = 'main', locations = 1, resolved = 1, hit count = 1
  1.1: where = clinfo`main + 45 at clinfo.c:4587:6, address = 0x000000000021d98d, resolved, hit count = 1
(lldb) r
Process 9348 launched: '/usr/local/bin/clinfo' (x86_64)
Process 9348 stopped
* thread #1, name = 'clinfo', stop reason = breakpoint 1.1
    frame #0: 0x000000000021d98d clinfo`main(argc=1, argv=0x000000082031cf48) at clinfo.c:4587:6

```

Start and stop immediately:
```
process launch --stop-at-entry
```
