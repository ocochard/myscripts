# GDB

```
fetch sources https.:git//
unzip archive
cd src
gdb /usr/local/bin/clinfo
set print thread-events
break main


(gdb) info threads
  Id   Target Id                                   Frame
* 1    LWP 100674 of process 9459                  main (argc=1, argv=0x7fffffffe9b8) at src/clinfo.c:4672
  2    LWP 100876 of process 9459 "clinfo:cs0"     _umtx_op_err () at /usr/src/lib/libthr/arch/amd64/amd64/_umtx_op_err.S:38
  3    LWP 100877 of process 9459 "clinfo:sh0"     _umtx_op_err () at /usr/src/lib/libthr/arch/amd64/amd64/_umtx_op_err.S:38
  4    LWP 100878 of process 9459 "clinfo:shlo0"   _umtx_op_err () at /usr/src/lib/libthr/arch/amd64/amd64/_umtx_op_err.S:38
  5    LWP 100879 of process 9459 "clinfo:traceq0" _umtx_op_err () at /usr/src/lib/libthr/arch/amd64/amd64/_umtx_op_err.S:38
  6    LWP 100880 of process 9459 "clinfo:traceq0" _umtx_op_err () at /usr/src/lib/libthr/arch/amd64/amd64/_umtx_op_err.S:38

bt full


