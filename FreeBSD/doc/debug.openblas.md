# How to debug a port build crash: a worked example

*Author: Claude (Anthropic), Opus 4 — written while working through
the `math/openblas` 0.3.33 SIGBUS regression.*

This document walks through the *process* of diagnosing a real-world
crash — `math/openblas` 0.3.33 failing the `sblat3` test suite with a
SIGBUS — using only standard Unix tooling (`lldb`, `objdump`, `nm`,
`readelf`, `git`). The point isn't the bug itself; it's the *method*.

The recipe in short:

1. Read the build log. Find the actual failing command and the actual
   error message (not the cascade of `make` errors that follow).
2. Reproduce by hand, outside poudriere. Isolate the failing binary.
3. Get a debugger attached. Resolve the crash to a register, an
   instruction, and a function — in that order.
4. Form a hypothesis (e.g. "this kernel is being entered with a
   misaligned buffer"). Verify it by *narrowing*, not guessing.
5. If the bug appeared between two versions of upstream, bisect the
   source — disassemble, diff, and follow the data.

Everything below maps to one of those steps.

---

## 1. Read the build log carefully

Poudriere produces a per-port log under
`/usr/local/poudriere/data/logs/bulk/<jail>/<timestamp>/logs/<pkg>.log`.

```
$ less /usr/local/poudriere/data/logs/bulk/builder-default/2026-05-13_12h10m37s/logs/openblas-0.3.33,2.log
```

Skim from the bottom up. You'll see a wall of:

```
gmake[1]: *** [Makefile:274: level3] Bus error
gmake: *** [Makefile:176: tests] Error 2
*** Error code 2
```

That cascade is noise. The *signal* is the first line that mentions
a real signal, a real address, or a real binary. In this log:

```
OMP_NUM_THREADS=1 ./sblat3 < ./sblat3.dat
gmake[2]: *** [Makefile:274: level3] Bus error (core dumped)
```

So the failing command is `./sblat3 < ./sblat3.dat`, and it died with
SIGBUS. Note: `Bus error` is **not** the same as `Segmentation
fault`. On x86_64, SIGBUS almost always means *misaligned access by
an SSE/AVX instruction that requires alignment* (`movaps`, `movapd`,
`vmovaps`, ...). SIGSEGV would mean a bad page. The distinction is a
huge clue.

## 2. Reproduce by hand

Don't keep retrying through poudriere — each build is minutes of
overhead. Instead, build the port once with the work tree preserved
and then run the failing test as your normal user from the
work-tree's test directory.

```sh
# Build once, in batch mode, keeping work/
cd /usr/ports/math/openblas
sudo make BATCH=yes clean extract patch configure build
```

`BATCH=yes` skips the interactive options dialog (which otherwise
deadlocks any non-tty invocation).

You don't need `sudo` to *run* the resulting binary — `sudo` is only
needed for operations against the root-owned `work/` tree. For
debugging, copy what you need into a writable scratch directory:

```sh
cp -a work/OpenBLAS-0.3.33/test /tmp/openblas-debug
cd /tmp/openblas-debug
LD_LIBRARY_PATH=$PWD/../OpenBLAS-0.3.33 OMP_NUM_THREADS=1 ./sblat3 < ./sblat3.dat
```

This matters because `sblat3` writes `SBLAT3.SUMM` in the current
directory; if `cwd` isn't writable you'll get a *different* error
("Cannot open file SBLAT3.SUMM") that masks the real one.

## 3. Get the debugger in

On FreeBSD, `lldb` is the standard debugger. For a short, scripted
session it's much cleaner to use a command file than to type at the
`(lldb)` prompt:

```sh
$ cat > lldb-cmds <<'EOF'
target create "./sblat3"
process launch -i ./sblat3.dat --
EOF

$ lldb -s lldb-cmds
```

`lldb -s file` reads commands one per line. For multi-step
investigation, build the file up:

```
target create "./sblat3"
settings set target.run-args
process launch --stdin ./sblat3.dat
register read
bt
disassemble --frame --count 20
```

When the process dies, `lldb` stops at the faulting instruction. The
two most useful commands at that point are:

- `register read` — shows you what every register holds, including
  the operands of the instruction that just trapped.
- `disassemble --frame --count 20 --line` — shows you the
  instructions around the crash, in context.

In our case, lldb stopped here:

```
(lldb) register read
     rax = 0x...   rbx = 0x...
     r8  = 0x0000000000662414
     ...
(lldb) disassemble --frame --count 4
->  0x1188fd0: movaps (%r8), %xmm3
    0x1188fd4: ...
```

`movaps` requires the memory operand to be 16-byte aligned. The
operand here is `(%r8) = 0x662414`, which is `0x662414 mod 16 = 4`.
**Off by 4 bytes** — that's the immediate cause of the SIGBUS.

This is also the moment to look up what function `0x1188fd0` lives
in. `lldb` will print the symbol name in the backtrace
(`bt`); cross-check it with `nm`.

`nm(1)` lists the symbols defined in (or referenced from) an object
file or library, one per line, as `ADDRESS TYPE NAME`. The
single-letter type tells you what kind of symbol it is — the ones we
care about here:

| type | meaning |
|---|---|
| `T` / `t` | text (executable code), global / local |
| `D` / `d` | initialised data, global / local |
| `R` / `r` | read-only data, global / local |
| `B` / `b` | uninitialised data (BSS), global / local |
| `U` | undefined — imported from another object |

To find which function contains a given crash address, list the `T`
symbols sorted by address and keep the ones whose address is `≤` the
crash PC. The last line is the function that contains the address:

```sh
$ nm libopenblasp-r0.3.33.so | awk '$1 <= "0000000001188fd0"' | tail -5
0000000001188af0 T strsm_kernel_RT_BARCELONA
0000000001188fd0 ... (inside strsm_kernel_RT_BARCELONA, +0x4e0)
```

The crash PC `0x1188fd0` minus the function start `0x1188af0` gives
the offset within the function (`0x4e0` = 1248 bytes in). That
offset is what we'll feed to `objdump` next.

So now we know: the BARCELONA single-precision triangular-solve
right-transpose kernel is being entered with a non-16-byte-aligned
input buffer.

## 4. Inspect the binary directly with objdump

`lldb` shows you only a handful of instructions around `pc`. To
understand the *function* — what prologue set up `%r8`, what loop
the trapping `movaps` is inside, what comes after — you need a
wider view. `objdump(1)` disassembles a chosen range from any
object file or shared library, without running it.

The key question for choosing a window: *how big is the function
that crashed, and where in the file does it sit?*

`nm` told us the function starts at `0x1188af0`. We want to dump from
that start to at least the crash PC plus some tail. Two ways to size
the window:

1. **Look up the next symbol.** Run `nm | sort` and find what comes
   immediately after `strsm_kernel_RT_BARCELONA` — say
   `strsm_kernel_RT_OPTERON` at `0x11891a0`. Subtract:
   `0x11891a0 − 0x1188af0 = 0x6b0`. That's the exact length of the
   function. Round to `0x6a0` or just dump to the next symbol.
2. **Crash-relative.** The crash is at `+0x4e0` into the function.
   For most diagnostic purposes you want at least the prologue (to
   see where `%r8` came from) plus a few hundred bytes past the
   trap. `start + 0x6a0` covers prologue + crash site + a margin.

In short: `0x6a0` isn't a magic number — it's "a bit more than the
crash offset, less than the function's full size." For a tighter
view you'd subtract two adjacent `nm` addresses to get the exact
function size.

```sh
# Disassemble the whole function (start … just past the crash site)
objdump -d --start-address=0x1188af0 --stop-address=0x11891a0 \
        ../OpenBLAS-0.3.33/libopenblasp-r0.3.33.so | less
```

Useful objdump flags:

| flag | what it does |
|---|---|
| `-d` | disassemble executable sections |
| `-dC` | also demangle C++ symbols |
| `-s -j .data` | hex-dump the `.data` section |
| `--start-address=N --stop-address=M` | restrict to an address range |
| `-h` | show section headers (find vaddr/offset of `.text`, `.data`...) |

### Finding a global data symbol's bytes on disk

`objdump -d` is for code. To look at a *global data structure* (in
our case, the OpenBLAS runtime dispatch table `gotoblas_BARCELONA`),
we need to read the bytes the linker placed in `.data`. There's a
small address-arithmetic problem to solve first.

The address you get from `nm` (for a `D` symbol) is the *virtual
address* — where the loader will map the symbol when the library is
loaded into a process. But on disk, the same bytes live at a *file
offset* into the `.so` file. The two differ because the loader
relocates `.data` to a high virtual address while it sits near the
beginning of the file.

`readelf(1)` is the tool that prints the structure of an ELF file:
its header, program headers, section headers, dynamic symbols, etc.
The flag we need is `-S` ("section headers") with `-W` ("don't wrap
lines"). That gives a table where each row shows, among other
columns, a section's *virtual address* and its *file offset*. The
difference between the two is exactly the shift we need.

```sh
$ nm libopenblasp-r0.3.33.so | grep ' gotoblas_BARCELONA$'
0000000001c0c678 D gotoblas_BARCELONA          # virtual address of the symbol

$ readelf -WS libopenblasp-r0.3.33.so | grep ' .data '
  [25] .data  PROGBITS  0000000001c00000  01bfd000  ...
#                       ^^^^^^^^^^^^^^^^  ^^^^^^^^
#                       vaddr of .data    file offset of .data

# Convert vaddr -> file offset:
#   file_offset_of(symbol) = file_offset_of(.data)
#                          + (vaddr_of(symbol) - vaddr_of(.data))
#                          = 0x1bfd000 + (0x1c0c678 - 0x1c00000)
#                          = 0x1c09678
```

Now we have a byte offset into the file. To pull a fixed-size window
of raw bytes out of a file, the standard Unix pair is `dd` (read N
bytes at offset M) piped into `xxd` (format binary as side-by-side
hex + ASCII). Together they're a "read this struct from the file"
recipe:

```sh
# Read 64 bytes starting at file offset 0x1c09678; print as hex.
dd if=libopenblasp-r0.3.33.so bs=1 skip=$((0x1c09678)) count=64 \
   2>/dev/null | xxd
```

What we're *searching for* with this: we want to see the actual
field values stored in `gotoblas_BARCELONA` — `dtb_entries`,
`switch_ratio`, `divide_rate`, `offsetA`, `offsetB`, `align`, ... —
so we can confirm that the runtime values match what `param.h`
declares for BARCELONA, and detect any struct-layout drift between
versions (which is exactly what bit us).

The general pattern — `nm` for the symbol address, `readelf -WS` for
the section's vaddr/file-offset shift, then `dd | xxd` (or a tiny
Python script) for the bytes — works for any `D` / `R` / `B` symbol
in any ELF file.

## 5. Form a hypothesis and *narrow*, don't guess

After step 3 we know:
- SIGBUS in `strsm_kernel_RT_BARCELONA`.
- `%r8` (the input buffer pointer) is offset 4 mod 16.

The natural first hypothesis is "an OpenMP worker thread is given a
small stack and the buffer is on that stack". Easy to test:

```sh
OMP_STACKSIZE=64M OMP_NUM_THREADS=1 ./sblat3 < ./sblat3.dat
```

Same crash, same address. Hypothesis falsified. **Don't move on from
a failed hypothesis until you've checked it actually failed for the
reason you think.** If a workaround "doesn't help", that's
diagnostic information about where the bug *isn't*.

The next hypothesis is "the BARCELONA kernel's assembly changed
between versions". To check, fetch a known-good version
(`v0.3.30`) and diff:

```sh
$ cd /tmp && fetch https://.../OpenBLAS-0.3.30.tar.gz && tar xf ...
$ diff -r OpenBLAS-0.3.30/kernel/x86_64/ \
         /usr/ports/math/openblas/work/OpenBLAS-0.3.33/kernel/x86_64/ \
   | grep '^diff\|^Only'
```

In this case, the BARCELONA kernel assembly is byte-identical
between the two versions. So the bug isn't in the kernel itself —
it's in *whoever calls the kernel* and supplies the buffer pointer.

## 6. The mixing experiment

A powerful technique when you have two versions and one fails: build
both, then mix the binaries. In this case:

```sh
# Build 0.3.30 the same way (same compiler, same flags)
cd /tmp/OpenBLAS-0.3.30 && gmake \
    USE_OPENMP=1 DYNAMIC_ARCH=1 DYNAMIC_OLDER=1 \
    NO_AVX=1 NO_AVX2=1 NO_AVX512=1 BINARY=64

# Three test combos:
mkdir test-30-30 test-33-33 test-mix
cp 0.3.30/sblat3 0.3.30/sblat3.dat 0.3.30/libopenblasp-r0.3.30.so test-30-30/
cp 0.3.33/sblat3 0.3.33/sblat3.dat 0.3.33/libopenblasp-r0.3.33.so test-33-33/
cp 0.3.33/sblat3 0.3.33/sblat3.dat 0.3.30/libopenblasp-r0.3.30.so test-mix/

for d in test-30-30 test-33-33 test-mix; do
    (cd $d && LD_LIBRARY_PATH=. patchelf --replace-needed \
       libopenblasp-r0.3.33.so libopenblasp-r0.3.30.so sblat3 2>/dev/null
     LD_LIBRARY_PATH=. ./sblat3 < sblat3.dat &>$d.out; echo "$d: $?")
done
```

Result:
- `test-30-30` passes.
- `test-33-33` crashes (SIGBUS).
- `test-mix` (0.3.33 binary + 0.3.30 lib) passes.

This narrows the bug to the *library binary*, not the test driver.
Anything in `sblat3.f` / `sblat3.dat` is exonerated.

## 7. Source bisect with git

Now you know the bug is in the library and is between two upstream
tags. Clone upstream and let `git` do the elimination:

```sh
$ git clone https://github.com/OpenMathLib/OpenBLAS.git
$ cd OpenBLAS
$ git log --oneline v0.3.30..v0.3.33 -- \
    kernel/x86_64/ driver/level3/ driver/others/ common_param.h param.h
```

That lists every commit between the two tags that touched the
relevant subtrees. Read commit messages from oldest to newest,
looking for changes that could affect: buffer layout, struct
layouts, dispatch logic, alignment guarantees.

When a suspicious commit shows up, `git show <hash>` displays the
diff. In this case, a series of commits added three new fields
(`divide_rate`, `divide_limit`, `preferred_size`) to a runtime
dispatch struct (`gotoblas_t`), shifting every later field by 12
bytes.

To *verify* the impact in the actual built binary, disassemble the
caller (`strsm_RTUU`) in both versions, normalize away
address-dependent bytes, and diff:

```sh
$ objdump -dC libopenblasp-r0.3.30.so \
    | awk '/^[0-9a-f]+ <strsm_RTUU/{p=1} p{print} /^$/&&p{p=0}' \
    | sed -E 's/^ *[0-9a-f]+: *//; s/0x[0-9a-f]+ <[^>]+>/<sym>/' \
    > /tmp/strsm_RTUU.30.norm
$ # same for 0.3.33
$ diff strsm_RTUU.30.norm strsm_RTUU.33.norm
```

The diff shows every field-offset load (`movl 0x18(%r9),%ecx`,
`movslq 0x14(%r9),%rsi`, ...) shifted by exactly 12 bytes. That
matches the size of the three added struct fields and confirms the
library-level change.

## 8. Caller bug or kernel-internal bug? (lldb breakpoints)

Sections 1-7 located **where** the crash happens
(`movaps (%r8),%xmm3` at `+6096` inside `strsm_kernel_RT_BARCELONA`)
and **why** (`%r8` is not 16-byte aligned). They did not answer the
load-bearing question:

> Does the kernel receive a misaligned `%r8` from its caller, or does
> it walk `%r8` off alignment by itself?

The answer changes the fix surface:
- **Caller bug** → buffer allocation / packing routine elsewhere.
- **Kernel-internal bug** → the `.S` file or whatever macros drive
  its preprocessing.

### 8.1 The plan

Set a breakpoint on `strsm_kernel_RT_BARCELONA` **entry**. Snapshot
the arg registers each time. If `%r8` is ever misaligned on entry,
it's a caller bug. If every entry is aligned but the SIGBUS still
fires, the kernel walks itself off.

Calling convention (System V AMD64) for
`strsm_kernel_RT(bm, bn, bk, alpha, a, b, c, ldc, offset)`:

| reg   | arg        |
|-------|------------|
| rdi   | bm         |
| rsi   | bn         |
| rdx   | bk         |
| xmm0  | alpha      |
| rcx   | a          |
| **r8**| **b** ← the buffer that crashes |
| r9    | c          |
| 8(rsp)| ldc        |
| 16(rsp)| offset    |

### 8.2 Gotcha: FreeBSD lldb has no Python

The natural first attempt was a Python breakpoint callback. It fails:

```
$ lldb --print-script-interpreter-info
{"language":"lua", ...}
$ lldb -o "command script import /tmp/lldb-stepC.py"
error: lua failed to import '/tmp/lldb-stepC.py': invalid extension
```

FreeBSD's lldb ships with **lua** as the only script interpreter,
not Python — even `lldb -l python` is ignored. Workaround: drop
scripting entirely and use lldb's own command list, attached to the
breakpoint with `breakpoint command add`. Each line of the command
list is a regular lldb command; the list ends with `DONE` on its own
line.

### 8.3 Conditional breakpoint — does the caller ever misalign?

`/tmp/openblas-debug/lldb-stepC-cmds`:

```
target create /tmp/openblas-debug/sblat3
breakpoint set --name strsm_kernel_RT_BARCELONA --condition "($r8 & 0xf) != 0"
breakpoint command add 1
register read rdi rsi rdx rcx r8 r9
expression -- (unsigned long)$r8 & 0xf
bt 4
DONE
process launch -i /tmp/openblas-debug/sblat3.dat
quit
```

The `--condition` is gold here: lldb evaluates `($r8 & 0xf) != 0` at
every hit and only stops when the low 4 bits of `%r8` are non-zero.
The breakpoint becomes a filter — across the millions of kernel
entries the test driver makes, only a misaligned one (if any) would
stop the program.

Run it:

```
$ lldb -s /tmp/openblas-debug/lldb-stepC-cmds
... (test runs to completion or to SIGBUS, never to our breakpoint) ...
Process stopped: signal SIGBUS  pc=0x...11835d0
```

**Result: the conditional breakpoint never fires.** The program
reaches the SIGBUS without lldb ever stopping at a misaligned
entry. The kernel is **always entered with `%r8` 16-byte aligned**.
The caller is innocent.

### 8.4 Unconditional dump — what's the entry state vs the crash state?

To compare entry and crash side by side, drop the condition and let
the breakpoint fire on every hit. `lldb-stepC2-cmds`:

```
target create /tmp/openblas-debug/sblat3
breakpoint set --name strsm_kernel_RT_BARCELONA
breakpoint command add 1
register read rdi rsi rdx rcx r8 r9
expression -- (unsigned long)$r8 & 0xf
continue
DONE
process launch -i /tmp/openblas-debug/sblat3.dat
quit
```

The `continue` inside the command list makes the breakpoint
**non-stopping**: it prints registers, then resumes execution. The
output is a log of every kernel entry. The last entry before SIGBUS
is the one we care about.

Extracted from the trace:

```
Last entry to strsm_kernel_RT_BARCELONA:
  rdi=0x0   rsi=0x7   rdx=0x7
  rcx=0x...25600040   r8=0x...25662380   r9=0x821df3da0
  $r8 & 0xf = 0     ← aligned

SIGBUS at +6096 (0x11835d0):
  rdi=0x0   rsi=0x7   rdx=0x7
  rcx=0x...25600040   r8=0x...25662414   r9=0x821df3da0
  $r8 & 0xf = 4     ← misaligned

Advance inside the kernel: 0x25662414 - 0x25662380 = 0x94 = 148 bytes
148 mod 16 = 4
```

So `%r8` advanced by 148 bytes from its aligned entry value, and 148
is not a multiple of 16. The kernel walks `%r8` off alignment by
itself. **Kernel-internal bug confirmed.**

### 8.5 Stack args — what's `offset`?

To see the stack args (`ldc`, `offset`) at entry, dump 16 bytes past
`%rsp`. `lldb-stepC3-cmds`:

```
target create /tmp/openblas-debug/sblat3
breakpoint set --name strsm_kernel_RT_BARCELONA
breakpoint command add 1
register read rdi rsi rdx rcx r8 r9
memory read --size 8 --count 2 --format x $rsp
continue
DONE
process launch -i /tmp/openblas-debug/sblat3.dat
```

`$rsp` at function entry points at the return address; in SysV AMD64
the **caller's** stack args sit just above. `memory read --size 8
--count 2 $rsp` gets two 8-byte words — the return address and the
first stack-passed arg (`ldc`). To get `offset`, read further.

### 8.6 Bridging to the prologue

We now know the misalignment is introduced inside the kernel. The
prologue disassembly (from Section 4) shows where:

```
1181e4e: leaq (,%rsi,4), %rax       # rax = bn * 4
1181e56: imulq %rdx, %rax           # rax = bn * bk * 4
1181e5a: addq  %rax, %r8            # r8 += bn * bk * 4   ← here
...
1181e74: testq $0x1, %rsi           # if bn is odd:
1181e7b: je    ...+0x970
1181e89: movq  %rdx, %rax
1181e8c: shlq  $0x2, %rax           # rax = bk * 4
1181e90: subq  %rax, %r8            # r8 -= bk * 4
```

With the captured values `bn=7, bk=7`:

```
bn * bk * 4 = 7 * 7 * 4 = 196 bytes        ; 196 mod 16 = 4
bk * 4      = 7 * 4     = 28  bytes        ; 28  mod 16 = 12
net advance = 196 - 28  = 168 bytes        ; 168 mod 16 = 8
```

`%r8` started aligned, and the prologue's pointer arithmetic
guarantees it is no longer aligned for any odd `bn` (the
`testq $0x1, %rsi` branch is taken precisely when `bn` is odd, and
the `-bk*4` correction is itself not a multiple of 16). From there
the main loop does `addq $0x40, %r8` (64 = aligned, doesn't help),
and the `(bk-offset)%4` tail eventually executes `movaps (%r8)` —
SIGBUS.

### 8.7 What we know now

- `strsm_kernel_RT_BARCELONA` is **entered correctly aligned** every
  time. No caller / packing-routine bug.
- The kernel walks `%r8` off alignment inside its own prologue when
  `bn*bk` is not a multiple of 4 (e.g., bn=7, bk=7).
- The crash is a **`.S`-file (or `.S`-macro) bug** in the BARCELONA
  STRSM kernel. The fix surface is now small:
  `kernel/x86_64/strsm_kernel_RT_*.S` and whatever common macros it
  pulls in.

### 8.8 Technique recap (reusable on other kernels)

1. Identify entry symbol and SysV AMD64 arg mapping.
2. **First pass — conditional breakpoint** filtering on the
   suspected bad property: `breakpoint set --name FN --condition
   "(reg & MASK) != 0"`. If it fires → caller bug; if it doesn't →
   kernel-internal bug.
3. **Second pass — unconditional logging breakpoint** with `register
   read` + `continue` inside `breakpoint command add` to dump every
   entry. Compare last entry to crash registers.
4. Compute `crash_addr - entry_addr` for the pointer in question.
   Non-multiple-of-required-alignment proves the kernel moved it.
5. Map the delta back to instructions in the prologue/loop.
6. On FreeBSD: **lldb only speaks lua**, not Python. Use command
   lists, not script callbacks.

## 9. Automated source bisection with `git bisect run`

Section 7 used `git log` to *read* commit messages and form a
hypothesis. That works when there are a few dozen relevant commits
and they have distinctive messages. The full v0.3.30→v0.3.33 range
in this case is **910 commits**, most of them ARM / RISC-V / WASM
work that visually looks unrelated to x86_64 STRSM. Eyeballing 910
commit messages is not bisection — it's guessing.

`git bisect run` does the elimination for you. You give it:

1. a known-good ref and a known-bad ref,
2. a test script that returns 0 (good) / 1 (bad) / 125 (skip),

and it does a binary search across the range, calling the script at
each midpoint. For 910 commits that's ~`log2(910) ≈ 10` builds.
Walk away; come back to the answer.

### 9.1 The test script

The script reproduces exactly the failure we want to bisect — not a
"smoke test", not a similar failure, the **same** SIGBUS in STRSM
inside `sblat3`. Anything else risks bisecting toward the wrong
commit.

`/tmp/openblas-debug/bisect-test.sh`:

```sh
#!/bin/sh
# Bisect test for OpenBLAS BARCELONA strsm SIGBUS regression.
# Exit 0 = good (sblat3 passes), 1 = bad (SIGBUS/numerical), 125 = skip (build broken).

set -u
SRC=/tmp/OpenBLAS-bisect
SHA=$(cd "$SRC" && git rev-parse --short HEAD)
LOGDIR=/tmp/openblas-debug

cd "$SRC" || exit 125

# Match the FreeBSD port's build flags exactly. Pass on every gmake
# invocation — Makefile.system re-evaluates them.
COMMON_FLAGS="CC=gcc14 FC=gfortran14 NO_AVX=1 NO_AVX2=1 NO_AVX512=1 \
              DYNAMIC_ARCH=1 DYNAMIC_OLDER=1 USE_OPENMP=1 NUM_THREADS=64"

# Clean previous iteration. `gmake clean` doesn't always remove the
# library archives — wipe them manually so we never accidentally test
# stale code.
gmake -s clean >/dev/null 2>&1
rm -f libopenblas*.a libopenblas*.so* test/*blat*.o test/?blat? 2>/dev/null

echo "=== building $SHA ==="
gmake -j32 $COMMON_FLAGS libs netlib >"$LOGDIR/build.log" 2>&1
if [ $? -ne 0 ]; then
    echo "BUILD FAILED"
    tail -30 "$LOGDIR/build.log"
    exit 125          # 125 tells `git bisect run` to skip this commit
fi

echo "=== building sblat3 ==="
gmake -C test -j8 $COMMON_FLAGS sblat3 >"$LOGDIR/test-build.log" 2>&1
if [ ! -x "$SRC/test/sblat3" ]; then
    echo "TEST BUILD FAILED"
    exit 125
fi

echo "=== running sblat3 ==="
cd "$SRC/test" || exit 125
rm -f SBLAT3.SUMM
OMP_NUM_THREADS=1 ./sblat3 < sblat3.dat >"$LOGDIR/test.out" 2>&1
RC=$?

# Archive the per-commit summary so we can inspect any iteration later.
cp -f SBLAT3.SUMM "$LOGDIR/SBLAT3.SUMM.$SHA" 2>/dev/null

# Non-zero exit code → SIGBUS / SIGSEGV / abort.
if [ $RC -ne 0 ]; then
    echo "TEST FAILED (rc=$RC)"
    exit 1
fi

# sblat3 returns 0 even when computational checks fail.
# Its actual results land in SBLAT3.SUMM (path/unit configured in sblat3.dat).
[ -s SBLAT3.SUMM ] || { echo "TEST FAILED (no SBLAT3.SUMM)"; exit 1; }
grep -q "END OF TESTS" SBLAT3.SUMM || { echo "TEST INCOMPLETE"; exit 1; }
grep -E "(FAILED|FATAL)" SBLAT3.SUMM && { echo "TEST FAILED (numerical)"; exit 1; }

echo "TEST PASSED $SHA"
exit 0
```

Three gotchas baked into this script (each one was a real bug
during initial development):

| Gotcha | Symptom | Fix |
|---|---|---|
| `gmake clean` doesn't drop the `.a` archive | Bisect tested stale code, every commit looked identical | Explicit `rm -f libopenblas*.a` |
| Build flags must repeat on every invocation | `gmake -C test` saw a different `Makefile.system` evaluation; some symbols missing | Pass `$COMMON_FLAGS` to **both** `gmake libs netlib` and `gmake -C test` |
| `sblat3` writes to `SBLAT3.SUMM` not stdout | "test.out" was always empty; first attempt at result-grepping always said PASSED | Read `SBLAT3.SUMM`; only use `rc` for crashes |

### 9.2 Setting up the worktree

Use a dedicated worktree so bisect doesn't disturb a working checkout:

```sh
$ git clone https://github.com/OpenMathLib/OpenBLAS.git /tmp/OpenBLAS-git
$ cd /tmp/OpenBLAS-git
$ git worktree add /tmp/OpenBLAS-bisect v0.3.33
```

### 9.3 Confirm the endpoints (the most important step)

Never start a bisect without verifying both endpoints with the
**actual script you're about to run**. If the "good" commit fails
your test for a different reason, the bisect lands on a meaningless
commit.

```sh
$ cd /tmp/OpenBLAS-bisect
$ git checkout v0.3.30 && /tmp/openblas-debug/bisect-test.sh
=== building 993fad6ae ===
=== building sblat3 ===
=== running sblat3 ===
TEST PASSED 993fad6ae          ← v0.3.30 confirmed GOOD

$ git checkout v0.3.33 && /tmp/openblas-debug/bisect-test.sh
TEST FAILED (rc=138)            ← rc=138 = SIGBUS (128+10). v0.3.33 confirmed BAD.
```

`rc=138` decodes as `signal 138 - 128 = 10 = SIGBUS` on FreeBSD.
(See `kill -l` for the signal-to-number mapping on your platform.)

### 9.4 Run the bisect

```sh
$ cd /tmp/OpenBLAS-bisect
$ git bisect start
$ git bisect bad  v0.3.33
$ git bisect good v0.3.30
Bisecting: 459 revisions left to test after this (roughly 9 steps)
$ git bisect run /tmp/openblas-debug/bisect-test.sh
```

Then wait. With DYNAMIC_ARCH building every per-CPU kernel variant
(~12 min/iteration on 32 cores) and 9-10 steps, expect 2 hours.

### 9.5 Reading the result

`git bisect run` ends with:

```
<sha> is the first bad commit
commit <sha>
Author: …
Date: …

    <commit subject>

 <files…> | <stats>
```

That commit is the regression. From here:

1. `git show <sha>` to see the diff.
2. Map the diff back to the symptoms found in section 8 (kernel walks
   `%r8` off alignment for odd `bn*bk`). The bisect identifies the
   commit; section 8 explains *why* that commit broke STRSM
   specifically — that pairing is what makes the fix tractable.
3. `git bisect reset` to return to `develop`.

### 9.6 When `git bisect run` is the wrong tool

- The bug is **flaky** (race conditions, ASLR-dependent crashes).
  The script will mis-classify commits; bisection lies. Re-run each
  step manually, or wrap the test in a stress loop and only call
  it "good" after N consecutive passes.
- Many commits in the range **don't build** for unrelated reasons.
  Use `exit 125` to skip them (the script above does this for build
  failures). If `skip` ranges are dense, bisect resolution drops.
- The bug spans **multiple commits** (introduced in commit A,
  surfaced by commit B). `git bisect` will pin one of them — usually
  B. Confirm by reverting just that commit; if the bug persists, A
  is still in the tree and a wider bisect is needed.

### 9.7 Actual bisect outcome for this case

After 13 iterations (~3 hours of build/test on 32 cores), bisect
narrowed to:

```
$ git bisect log | tail -5
# good: [9a46ffba3] Merge pull request #5766 from martin-frbg/lapack1251
# only skipped commits left to test
# possible first bad commit: [fd862d43b] Remove redundant quick return
# possible first bad commit: [74486799b] Move quick return out of the scope of the DYNAMIC_ARCH conditional for SME
```

Two candidates remained — both **adjacent commits** (1 hour apart,
same author) that bisect couldn't separate because three commits in
that vicinity hit a `gmake -C test` link failure (`undefined
reference to gotoblas / exec_blas`). The build failure is unrelated
to the SIGBUS — it's a transient `Makefile` skew in `interface/`.

To break the tie, the static **library** itself builds fine in the
skipped commits; only the test driver's link line fails to pull
some `.a` archive members. Two workarounds:

```sh
# (a) Use --start-group so the linker re-scans the archive:
gfortran14 -o sblat3 sblat3.o \
    -Wl,--start-group ../libopenblasp-r0.3.32.dev.a -Wl,--end-group \
    -lpthread -lgfortran

# (b) Use the OpenBLAS in-tree `tests` target, which uses cmake/ctest
#     and gets the archive members right:
gmake -j32 CC=gcc14 FC=gfortran14 ... tests
```

Building each skipped commit with workaround (a) and re-running
sblat3 produced:

```
74486799b  → END OF TESTS, STRSM 2592 CALLS PASSED   ← GOOD
fd862d43b  → SIGBUS (rc=138)                          ← BAD
```

Resuming bisect with `git bisect good 74486799b` produced:

```
fd862d43b is the first bad commit
commit fd862d43b6330a90baa296d1a02aa6b6df9277e5
Author: Martin Kroeker <martin@ruby.chemie.uni-freiburg.de>
Date:   2026-04-22 15:36:57 +0200

    Remove redundant quick return

 interface/trsm.c | 2 --
 1 file changed, 2 deletions(-)
```

The "redundant" quick return was the unconditional
`if ((args.m == 0) || (args.n == 0)) return;` near the bottom of
the function. Upstream concluded it was redundant because the
previous commit (`74486799b`) added an earlier
`if (args.m == 0 || args.n == 0) return;`. Apparently the earlier
one is **not** sufficient on x86_64 DYNAMIC_ARCH — likely because
the SMP thread-fanout path between the two returns can produce
per-block `bm` values that are 0 even when the original `args.m`
isn't, and only the late return guarded the kernel against that.
(Section 8 showed `bm=0, bn=7, bk=7` at the crashing entry.)

### 9.8 Verifying the fix

Always verify a bisect result by **reverting the suspected commit
on top of the bad ref**. If the bug disappears, the bisect was
correct; if it persists, the bisect lied (or the bug is multi-commit).

```sh
$ git worktree add /tmp/OpenBLAS-fix v0.3.33
$ cd /tmp/OpenBLAS-fix
$ git revert --no-edit fd862d43b
$ gmake -j32 CC=gcc14 FC=gfortran14 NO_AVX=1 NO_AVX2=1 NO_AVX512=1 \
        DYNAMIC_ARCH=1 DYNAMIC_OLDER=1 USE_OPENMP=1 NUM_THREADS=64 tests
$ cd test && OMP_NUM_THREADS=1 ./sblat3 < sblat3.dat
$ grep "STRSM\|END OF TESTS" SBLAT3.SUMM
 STRSM  PASSED THE TESTS OF ERROR-EXITS
 STRSM  PASSED THE COMPUTATIONAL TESTS (  2592 CALLS)
 END OF TESTS
```

**The fix is confirmed.** This single-commit revert is the minimal
patch for the port — much smaller than carrying a behavioral patch
to the `.S` kernel or to `level3_thread.c`.

## 10. Package the fix as a port patch and verify in poudriere

Once the upstream revert is identified and verified in a worktree,
the FreeBSD-port side of the work is mechanical: turn the two-line
revert into a named patch under `files/`, bump `PORTREVISION`, and
run `poudriere testport` on the same jail that originally reproduced
the bug. The point of this last step is to verify the *port* applies
the patch cleanly and that the *packaged* library passes the
in-tree tests inside a clean jail — not just on the dev host.

### 10.1 Writing the patch

FreeBSD ports use a filename-encoding convention where `__` in the
patch filename stands for a path separator. The patch we need lives
at `interface/trsm.c`, so the file is named:

```
math/openblas/files/patch-interface__trsm.c
```

The patch is additive (re-adding the two lines that `fd862d43b`
removed). The patch body is a normal unified diff with FreeBSD
header conventions (`--- file.orig\tUTC_timestamp`):

```diff
--- interface/trsm.c.orig	2026-04-23 13:50:46 UTC
+++ interface/trsm.c
@@ -383,6 +383,8 @@ if (strcmp(gotoblas_corename(), "armv9sme") == 0

 #endif

+  if ((args.m == 0) || (args.n == 0)) return;
+
   IDEBUG_START;

   FUNCTION_PROFILE_START();
```

Above the diff, document **why** the patch exists — what was reverted
and what symptom it fixes. A reviewer should be able to read the patch
header and know whether the patch is still needed at the next port
update without re-running the bisection. A good header includes:
- The upstream commit hash being reverted.
- One sentence on the architectural why
  (e.g. *"SMP block-fanout produces per-block `bm=0` even when the caller
  passed a non-zero `args.m`; the late return was the only thing
  protecting the BARCELONA STRSM prologue from being entered with
  degenerate dimensions"*).
- The user-visible symptom (e.g. *"`sblat3` STRSM block killed by SIGBUS
  on AMD64 with `DYNAMIC_ARCH`"*).
- A pointer to the upstream issue/PR once filed.

Gotcha — `make makepatch` for a *new* patch needs an `.orig` snapshot.
If you're patching a file that has never been patched before, `cp
file file.orig` inside the WRKSRC before editing it; otherwise
`makepatch` silently skips the file with no warning. (In this case
the patch is small enough to author by hand from the upstream diff,
which avoids the issue.)

### 10.2 Bumping `PORTREVISION`

Any port content change — patch added/removed, build option flipped,
plist tweak — that doesn't change the upstream distfile requires
`PORTREVISION` to be bumped. The bump goes immediately under
`DISTVERSION` (and above `PORTEPOCH` if present):

```diff
 DISTVERSION=	0.3.33
+PORTREVISION=	1
 PORTEPOCH=	2
```

If `PORTREVISION` was previously absent, this is `=1`. If it was
already non-zero, increment it. Without this bump, `pkg upgrade`
will not notice the new package on user systems even though the
binary changed.

### 10.3 Verifying with `poudriere testport`

`testport` is the right command (not `bulk`) when you want the
in-tree test/QA phases to run, which is exactly what catches a
regression like this one. Run it on the same jail that originally
reproduced the SIGBUS:

```sh
$ sudo poudriere testport -j builder -p official -o math/openblas \
      > /tmp/openblas-debug/poudriere-testport.log 2>&1
```

What to look for in the log, in order:

| Phase                | What it confirms                                          |
|----------------------|-----------------------------------------------------------|
| `patch`              | Our `files/patch-interface__trsm.c` applies at line 383   |
| `build`              | Library compiles (no FORTIFY/strict warnings tripped)     |
| `utest`              | Internal C unit tests pass (`125/125 ok`)                 |
| `utest_ext`          | Extended unit tests pass (`1522/1522 ok`)                 |
| BLAS Fortran tests   | sblat3 runs and reaches `END OF TESTS` without SIGBUS     |
| `stage-qa`           | Library is shipped correctly (rpaths, perms, etc.)        |
| `check-plist`        | No extra/missing files vs `pkg-plist`                     |
| `package` / `install` / `deinstall` | Package is well-formed and reinstalls clean |

For this fix, the final log line was:

```
Queued: 1 Inspected: 0 Ignored: 0 Built: 1 Failed: 0 ...
build time: 00:02:53
```

— on the `builder` (16.0-CURRENT) jail where v0.3.33 unpatched
SIGBUS'd inside `sblat3` STRSM. That same test pass is the
end-to-end confirmation that the port is ready to commit.

### 10.4 What this tells you about the upstream report

The poudriere run is also evidence for the upstream bug report:
the same patch fixes the *packaged* library, not just an out-of-tree
build, and it does so without touching any other component
(`level3_thread.c`, the `.S` kernel, or the BLAS dispatch table).
That bounds the regression cleanly to the single removed line and
makes it easy for upstream to reproduce: revert `fd862d43b` on
`v0.3.33`, rebuild with `DYNAMIC_ARCH=1 NO_AVX*=1` so the dispatch
lands on BARCELONA, run `sblat3` single-threaded.

## 11. What this teaches

- **Signals carry information.** SIGBUS ≠ SIGSEGV. Read the signal
  before reading the code.
- **Don't trust workarounds as diagnoses.** If a workaround doesn't
  help, the hypothesis behind it is wrong; that's data.
- **Disassembly is cheap.** `objdump -d`, `nm`, `readelf` are fast
  and give you ground truth. The source tree is what you think
  *should* be running; the binary is what's running.
- **Mixing experiments isolate the bad component.** If a library
  has multiple consumers (test driver + library), swap one at a
  time. Like a `git bisect` but for the file boundary.
- **`git log path/to/area`** narrows a noisy upstream history to
  the commits that could matter. Combined with disassembly diff,
  it converts "a regression somewhere in 6 months" into "this
  specific commit shifted these specific offsets."

## Appendix: minimum lldb cheat sheet

```
target create "./binary"             # load the program
process launch --stdin ./input.txt   # run it; --stdin replaces redirection
                                      # (lldb won't honor shell <)
register read                        # all GPRs + flags at the stop
register read rdi rsi rdx            # specific regs
disassemble --frame --count N        # N instructions around PC
disassemble --start-address=0xAAA \
            --end-address=0xBBB      # explicit range
bt                                   # backtrace
frame select N                       # move up the stack to frame N
frame variable                       # locals/args in the selected frame
memory read --size 4 --format x --count 16 0xADDR   # peek memory
expression -- (int)foo               # evaluate a C expression
```

## Appendix: minimum objdump cheat sheet

```
objdump -d FILE                                   # disassemble all code
objdump -dC FILE                                  # ...and demangle
objdump -d --start-address=A --stop-address=B FILE
objdump -h FILE                                   # section headers
objdump -s -j .data FILE                          # hex-dump .data
objdump -t FILE | grep funcname                   # symbol table for funcname
objdump -R FILE                                   # dynamic relocations
```

And `nm FILE | grep ' T '` for text (code) symbols, `' D '` for
initialised data, `' R '` for read-only data, `' U '` for undefined
(things this binary imports from elsewhere).
