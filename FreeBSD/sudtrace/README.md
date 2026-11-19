# sudtrace: syscall interposition that also sees Go programs

A non-Wine use case for `procctl(PROC_SYSCALL_DISPATCH_CTL)`
(see [../docs/procctl_syscall_dispatch.md](../docs/procctl_syscall_dispatch.md)).

Tools such as torsocks, proxychains, fakeroot or libfaketime work by
replacing libc functions with `LD_PRELOAD`.  A program that makes its
system calls without libc never calls those functions, so the tool silently
does nothing.  Go programs are the common case: even when linked against
libc (cgo), the Go runtime issues its own `syscall` instructions.

- `hooktrace.so`: the classic approach.  It replaces `connect()`, `open()`,
  `openat()` and `execve()` and logs each call.
- `sudtrace.so`: the same idea built on syscall dispatch.  Every system call
  made outside a small assembly stub of the library raises SIGSYS; the handler logs
  it, runs it, and returns the result.  It also counts where each call came
  from.

## Build and run

Needs a kernel with `procctl_syscall_dispatch.patch`, amd64.

```sh
make
LD_PRELOAD=$PWD/hooktrace.so gh api /zen
LD_PRELOAD=$PWD/sudtrace.so SUDTRACE_OUT=/tmp/gh.log gh api /zen
```

`SUDTRACE_ALL=1` logs every system call by name, not only
open/connect/execve.

## Result with gh 2.x (Go, cgo, linked to libthr/libc/libsys)

`hooktrace.so` prints nothing: 0 lines.

`sudtrace.so` (excerpt):

```
sudtrace[15416] program: open(/home/olivier/.config/gh/hosts.yml) = 4
sudtrace[15416] program: open(/etc/resolv.conf) = 5
sudtrace[15416] program: connect(192.168.100.254:53) = 0
sudtrace[15416] program: connect(140.82.121.6:443) = -1 errno 36
sudtrace[15416] program: open(/usr/local/etc/ssl/cert.pem) = 6
...
sudtrace[15416] summary: 429 via libsys (a libc hook can see these), 2282 bypassing it (2282 from the program itself)
sudtrace  program's own: _umtx_op=917 read=279 fstat=259 nanosleep=155 open=137 close=136 thr_kill=121 ...
```

So 84% of gh's system calls, including every file open and every network
connection, are invisible to an `LD_PRELOAD` tool.  The DNS query and the
HTTPS connection to GitHub would bypass torsocks.  The 12 threads gh
creates are traced too (the library wraps `thr_new` so each new thread turns
dispatch on for itself).

Cost: `gh api /zen` takes 0.30 s with or without `sudtrace.so` (network
bound, about 2700 trapped calls), and 0.36 s under `truss -f -o /dev/null`.

## What the handler has to take care of

- A trapped call while SIGSYS is blocked kills the process, so the handler
  emulates `sigprocmask` on the saved context and never lets it block
  SIGSYS.  A program's `sigaction(SIGSYS)` is recorded but not installed.
- `sigaltstack` fails with EPERM when the handler runs on the alternate
  stack; that call is run back in the program's context through a
  `syscall; ret $128` stub inside the allowed range.
- `setcontext` is loaded through `sigreturn`, so the kernel restores the
  selector; `vfork` becomes `fork`, because the child would otherwise return
  through the parent's handler frame.
- The handler never enters the run-time linker (`-z now`, no allocation).

Not handled: system calls made by signal handlers (the kernel lets them
through, as Wine needs), `rfork(RFMEM)`, and a program's own SIGSYS use.

## Kernel finding: sigfastblock

The first version of the kernel patch killed even a plain C program with
`Bad system call` as soon as the library turned dispatch on.  rtld and
libthr defer signals with `sigfastblock(2)` while they hold their locks,
and still make system calls there (here rtld's `mprotect` for RELRO).
`trapsignal()` treated the fast-block word like a blocked mask and killed
the process.  Setting `kern.elf64.sigfastblock=0` made the demo work and
confirmed the cause.

Wine never hit this: it allows the whole of libsys and only blocks while
Windows code runs.  The patch now delivers the dispatch SIGSYS even when
the thread has fast-blocked signals (`sig == SIGSYS` and `ksi_code ==
SYS_USER_DISPATCH` in `trapsignal()`).  A real `sigprocmask` block still
kills the process, as on Linux; the handler is the dispatcher's own code
and must be safe to run inside rtld's and libthr's critical sections, which
this one is.  With that kernel the demo runs with the default sysctl, and
the Kyua tests pass (14/14, including a `fastblock` case and two
`stub_*` cases that trap the whole process the way this library does).
