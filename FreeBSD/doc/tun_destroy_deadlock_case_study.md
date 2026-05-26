# Case study: `tun_destroy()` parks a global sx-lock on FreeBSD 16-CURRENT

*Author: Claude (Anthropic Claude Opus 4)*

> **Status: DRAFT — NOT PEER-REVIEWED.** This document was written by
> the agent as a side product of debugging the `tun_destroy` deadlock,
> and reviewed only by Olivier Cochard (whose C/kernel experience is
> limited). The reproducer, the kgdb evidence, the patch, and the
> validation runs are all real and machine-verifiable. The
> *explanatory* prose — the background sections, the framing as a
> teaching case study, and the exercise prompts — is *plausible* but
> not *validated by FreeBSD kernel maintainers*. Factual errors found
> in companion material from the same workflow suggest analogous
> errors may remain here. Treat it as a starting point for your own
> reading, not a finished tutorial.

A real-world kernel-locking bug, walked through from "I can reproduce
this in three lines of shell" to "here is the upstream patch and why
that exact shape is correct."

This document is written for someone learning OS programming. It assumes
you have heard of mutexes and condition variables but have not
necessarily seen them tangled up with a global reader/writer lock
before. Concepts are introduced as they appear.

- **Platform:** FreeBSD 16.0-CURRENT (mid-2026).
- **Subsystem:** `tun(4)` virtual point-to-point interface + the
  `if_clone(9)` framework that creates and destroys cloneable network
  interfaces.
- **Bug class:** a kernel thread that holds a global exclusive sx lock
  goes to sleep on a condition variable that only userspace can signal.
  If userspace does not cooperate, the lock is held forever and every
  other consumer wedges behind it.
- **Fix:** five lines (plus a comment), patch at
  [`tun_destroy_ebusy.patch`](tun_destroy_ebusy.patch).

---

## Table of contents

1. [The three-line reproducer](#1-the-three-line-reproducer)
2. [Background: what is `tun(4)` and what is `if_clone`?](#2-background-what-is-tun4-and-what-is-if_clone)
3. [What deadlocks, and what does "deadlock" even mean here?](#3-what-deadlocks-and-what-does-deadlock-even-mean-here)
4. [The lock chain in the kernel](#4-the-lock-chain-in-the-kernel)
5. [Reading the dump in kgdb](#5-reading-the-dump-in-kgdb)
6. [The culprit code](#6-the-culprit-code)
7. [The patch and why this shape is correct](#7-the-patch-and-why-this-shape-is-correct)
8. [Validating the fix](#8-validating-the-fix)
9. [Exercises](#9-exercises)

---

## 1. The three-line reproducer

```sh
ifconfig tun create                # → e.g. tun1
sleep 99999 < /dev/tun1 &          # holds /dev/tun1 open as fd 0
ifconfig tun1 destroy              # ← hangs forever on a buggy kernel
```

That's it. After those three lines:

- the third `ifconfig` never returns,
- every subsequent `ifconfig <anything> destroy` on the host hangs the
  same way,
- `jail -R` (jail remove) on any vnet jail that owns a cloned
  interface also hangs,
- `kill -9` on the wedged `ifconfig` does not free it,
- **only a reboot recovers.**

The script in [`FreeBSD/repro_tun_destroy_deadlock.sh`](../repro_tun_destroy_deadlock.sh)
wraps this with a timeout and a wedged-state report so you can run it
safely on a throwaway VM.

### What the reproducer actually does

```mermaid
sequenceDiagram
    autonumber
    participant U as User shell
    participant K as Kernel (tun + if_clone)
    participant H as Holder process<br/>(`sleep 99999 < /dev/tun1`)

    U->>K: ifconfig tun create
    K-->>U: tun1 created (tun_busy = 0)

    U->>H: spawn `sleep 99999 < /dev/tun1`
    H->>K: open("/dev/tun1", O_RDWR)
    K-->>H: fd 0 (tun_busy = 1)

    Note over H: parks in select/read forever<br/>fd stays open

    U->>K: ifconfig tun1 destroy
    Note over K: takes ifnet_detach_sxlock<br/>(exclusive)
    Note over K: enters tun_destroy()<br/>sees tun_busy != 0
    Note over K: cv_wait_sig() on tun_cv<br/>WAITING FOR holder.close()

    Note over K,H: Holder will never close.<br/>The lock is held forever.
```

The arrangement is mundane: one process opens the tun device and
parks. Another process asks the kernel to destroy that device. On
Linux or on older FreeBSD this would either succeed (kicking the
holder off) or fail cleanly with `EBUSY`. On this kernel it just
hangs, and worse, it takes a global lock down with it.

---

## 2. Background: what is `tun(4)` and what is `if_clone`?

### `tun(4)`: a network interface backed by a file descriptor

A normal network interface (e.g. `re0`) is backed by hardware: bytes
go in, bytes come out, the driver talks to a card. A `tun(4)`
interface is backed by a file descriptor. A userspace process opens
`/dev/tunN`, and from that moment:

- packets sent to the tun interface by the kernel can be `read(2)` from
  the fd,
- bytes `write(2)`-ten to the fd are injected into the kernel as if
  they arrived from a wire.

This is how userspace VPN daemons like `openvpn`, `mlvpn`, and
`wireguard-go` work: the kernel routes IP packets at them, they
encrypt/decapsulate, and send the result over a real socket.

Inside the kernel each `tun(4)` device is represented by a
`struct tuntap_softc` ("softc" = software context). Two fields matter
here:

- `tun_busy` — a refcount of open file descriptors against
  `/dev/tunN`. Bumped by `tun_open()`, decremented by `tunclose()`.
- `tun_cv` — a condition variable used by destroy to wait for
  `tun_busy` to reach zero.

### `if_clone(9)`: the framework for creatable interfaces

Some interfaces always exist (`lo0`, your physical NICs). Others can
be created and destroyed at runtime: `tun`, `tap`, `epair`, `lo`,
`vlan`, `bridge`, and others. The shared machinery for this lives in
`sys/net/if_clone.c` and exposes:

- `ifconfig X create` → calls `if_clone_create()` → calls the type's
  cloner-create callback (e.g. `tun_clone_create`).
- `ifconfig X destroy` → calls `if_clone_destroy()` →
  `if_clone_destroyif()` → the type's cloner-destroy callback
  (e.g. `tun_clone_destroy`).

To keep the interface list consistent across concurrent
create/destroy, `if_clone.c` uses a **global exclusive lock**
called `ifnet_detach_sxlock`. Every cloner destroy on the host —
across every cloner type — takes this same lock.

> **Sx locks in one paragraph.** FreeBSD's `sx(9)` is a
> reader/writer sleeping lock. Multiple threads can hold it shared
> (`sx_slock`), or one thread can hold it exclusive (`sx_xlock`). Writers
> block readers and vice versa. Because it can block, you may sleep
> while holding it — but if you do, every other thread that wants
> that lock waits for you to wake up. That is exactly the trap this
> bug is built on.

---

## 3. What deadlocks, and what does "deadlock" even mean here?

The textbook definition of deadlock is *a cycle of threads, each
waiting for a resource that the next thread in the cycle holds.*
What you have here is a slightly different shape: a **one-thread
indefinite wait**, plus a **pile-up** of unrelated threads behind it.
The community usually calls both "deadlock"; some authors prefer
"livelock" for the second case and "starvation" for the first. The
behaviour from the user's point of view is identical: the kernel is
wedged and a reboot is the only way out.

The thread chain:

```mermaid
flowchart TD
    A["Holder process<br/>open /dev/tun1, tun_busy = 1<br/>then parks in select()"]
    B["ifconfig tun1 destroy<br/>holds ifnet_detach_sxlock X<br/>parks in cv_wait_sig on tun_cv<br/>waiting for tun_busy = 0"]
    C["ifconfig tun2 destroy<br/>or jail -R, or any cloner op<br/>blocked in sx_xlock_hard<br/>waiting for ifnet_detach_sxlock"]
    D["jls<br/>blocked in sx_slock_hard<br/>waiting for allprison<br/>held by the wedged jail -R"]

    A -.->|never closes fd| B
    B -->|holds the sx lock| C
    C -->|if it was jail -R, also held allprison| D

    classDef wedged fill:#f99,stroke:#900
    class B,C,D wedged
```

Two important facts to take away:

1. **The original wedged thread is in state `S`, not `D`.** It is
   sleeping on a condition variable in `cv_wait_sig`, which is
   nominally an interruptible sleep. In production we observed that
   `SIGKILL` to that thread did not break the wait. The bug fix should
   not depend on signal delivery — *holding a global sx lock while
   sleeping for a userspace action is the real defect*.
2. **The pile-up is what makes this a system-wide outage.** If only
   the one `ifconfig` hung, you would notice and move on. Because
   every cloner destroy across every type takes the same lock, the
   first wedge takes the whole subsystem down with it.

---

## 4. The lock chain in the kernel

Let's look at the kernel side step by step.

```mermaid
sequenceDiagram
    autonumber
    participant U as Userland: ifconfig tun1 destroy
    participant CL as if_clone_destroy<br/>(sys/net/if_clone.c)
    participant TD as tun_destroy<br/>(sys/net/if_tuntap.c)
    participant CV as tun_cv<br/>(condition variable)
    participant SX as ifnet_detach_sxlock<br/>(global sx lock)

    U->>CL: ioctl SIOCIFDESTROY
    CL->>SX: sx_xlock(&ifnet_detach_sxlock)<br/>(line 480)
    Note over SX: held EXCLUSIVE by this thread
    CL->>TD: tun_clone_destroy → tun_destroy(may_intr=true)
    TD->>TD: TUN_LOCK(tp)<br/>tp->tun_flags |= TUN_DYING
    loop while tp->tun_busy != 0
        TD->>CV: cv_wait_sig(&tun_cv, &tun_mtx)
        Note over CV,TD: tun_mtx released atomically;<br/>thread sleeps
    end
    Note over SX: lock is STILL HELD — we are sleeping with it
```

Until step 8 the thread is on the CPU and the sx lock can be
released by the unlocker (us). After step 8 the thread is parked, and
only the cv signal — which only fires from `tunclose()` — can wake
it. `tunclose()` only runs when userspace `close(2)`s its fd. If it
doesn't, no progress.

### What the other waiters look like

Any other thread that calls into a cloner-destroy hits
`sx_xlock(&ifnet_detach_sxlock)` and goes to sleep waiting. This is
visible in `procstat -kk`:

```
ifconfig tun2 destroy
  mi_switch → _sx_xlock_hard → if_clone_destroyif at sys/net/if_clone.c:480
```

And a `jail -R` that owns a tun interface ends up here:

```
jail -R bird1
  mi_switch → _sx_xlock_hard → if_clone_detach → tuntap_prison_remove
                                              → osd_call → prison_deref
```

That last chain matters because `prison_deref` is itself holding
`allprison`, so once you have a wedged `jail -R`, every plain `jls`
also queues up — visible as a separate pile of threads blocked on
`_sx_slock_hard`. This is the classic cascade.

---

## 5. Reading the dump in kgdb

The previous section walked through the lock chain as if we already
knew what was happening. We didn't — we **confirmed** it by loading
the kernel dump in `kgdb` and following pointers. This section shows
the exact commands, in the order I ran them, so you can do the same
on a panic dump of your own.

### Preliminaries: getting a usable dump

A `GENERIC-NODEBUG` kernel won't help you here — the lock-debug
machinery and `DEADLKRES` watchdog you need are compiled out. Boot
the matching `GENERIC` kernel (it's installed alongside
`GENERIC-NODEBUG` at `/boot/kernel/kernel` vs `/boot/kernel.GENERIC/`)
or rebuild with these enabled in your config:

    options WITNESS
    options INVARIANTS
    options DEADLKRES
    options DDB

Then lower the deadlock-watchdog thresholds so it fires in seconds
instead of minutes:

    sudo sysctl debug.deadlkres.slptime_threshold=120
    sudo sysctl debug.deadlkres.blktime_threshold=60

Reproduce the wedge (the three-line recipe from §1), wait ~2 minutes,
and the kernel will panic itself with a message like:

    panic: deadlres_td_sleep_q: possible deadlock detected for
           0xfffff8011f4ea000 (ifconfig), blocked for 120339 ticks

That hex pointer is the wedged thread's `struct thread *` — write it
down, you'll need it. The dump gets written to `/var/crash/` as
`vmcore.0` (or `.zst`-compressed if `dumpon -z` is in effect).

### Loading the dump

After the host reboots, decompress if needed and open with `kgdb`:

    cd /var/crash
    sudo zstd -d vmcore.0.zst                    # if compressed
    sudo kgdb /boot/kernel/kernel ./vmcore.0

`kgdb` will print the panic string, the dumping CPU's stack, and
drop you at the `(kgdb)` prompt. From this point everything is just
reading memory and following pointers.

### Step 1 — confirm the panic message and identify the victim

    (kgdb) p (char *) panicstr
    $1 = 0xffffffff81de3b10 <vpanic[buf]>
         "deadlres_td_sleep_q: possible deadlock detected for
          0xfffff8011f4ea000 (ifconfig), blocked for 120339 ticks"

So `DEADLKRES` named one specific thread (`0xfffff8011f4ea000`) as
*its* victim. That's a **waiter**, not necessarily the holder — the
watchdog notices a thread that has been asleep too long, not a thread
that's holding a lock.

### Step 2 — list every thread, find ifconfig processes

    (kgdb) info threads

This produces hundreds of lines. The useful filter:

    (kgdb) info threads
    ... (long output) ...

In a stuck system you usually know what command got wedged
(`ifconfig tun1 destroy` here). The process names are in the
`info threads` output; pick the one matching your reproducer.
Alternatively, before the panic you can capture `procstat -kk` of
the wedged ifconfig and write down its `TID` — that's the most
reliable way to land on the right thread in the dump.

In this case there were two `ifconfig` threads:

| Description | TID | `struct thread *` |
| --- | --- | --- |
| `ifconfig tun1 destroy` (holder candidate) | 105425 | `0xfffff8011f502000` |
| `ifconfig tun2 destroy` (DEADLKRES victim) | 105919 | `0xfffff8011f4ea000` |

### Step 3 — switch to a thread and print its backtrace

The crucial gotcha: in `kgdb`, `bt <address>` does **not** switch
thread context — it just backtraces from a frame pointer, which is
not what you want. To inspect another thread's stack you have to
switch to it first:

    (kgdb) tid 105425             # switch context to the holder
    (kgdb) bt                     # now bt walks THAT thread's stack

Output (trimmed to the interesting frames):

    #5 _cv_wait_sig (cvp=0xfffff830608b86b8, lock=0xfffff830608b8698)
                    at kern_condvar.c:275
    #6 tun_destroy  (tp=0xfffff830608b8600, may_intr=true)
                    at sys/net/if_tuntap.c:662
    #7 if_clone_destroyif_flags (ifc=..., ifp=..., flags=0)
                    at sys/net/if_clone.c:465
    #8 if_clone_destroyif (...)
                    at sys/net/if_clone.c:481
    #9 if_clone_destroy (name="tun1")
                    at sys/net/if_clone.c:431

Frame #6 hands you two gifts: the `tuntap_softc *` for the wedged
tun (`tp=0xfffff830608b8600`), and the call site line number
(`if_tuntap.c:662`). Frames #7–#8 confirm the caller had taken
`ifnet_detach_sxlock` (at `if_clone.c:480`, one line up from #8's
`:481`).

### Step 4 — inspect the softc to read the bug's preconditions

The `tuntap_softc` is the per-device kernel struct. Print it:

    (kgdb) p *(struct tuntap_softc *) 0xfffff830608b8600

Long output; the fields that matter:

    tun_pid           = 15757    /* the holder process: our `sleep` */
    tun_busy          = 1        /* exactly one open fd */
    tun_flags         = 0x203    /* TUN_OPEN | TUN_INITED | TUN_DYING */
    tun_cv.cv_waiters = 1        /* exactly our ifconfig is waiting */
    tun_mtx.mtx_lock  = 0        /* released by cv_wait, as expected */

This proves four things at once:

- The tun **is** in use (`tun_busy == 1`).
- `tun_destroy` already entered the wait path (`TUN_DYING` set).
- The CV has exactly one waiter, matching our wedged ifconfig.
- The `tun_mtx` was correctly released by `cv_wait` (otherwise we'd
  have a much worse problem).

So the kernel state is internally consistent — this isn't a
corrupted-softc bug, it's a logic bug in *who waits for whom*.

### Step 5 — backtrace the waiter, identify the contested lock

    (kgdb) tid 105919             # the DEADLKRES victim
    (kgdb) bt

    #2 sleepq_switch  (wchan=0xffffffff822e6ea8 <ifnet_detach_sxlock>)
    #4 _sx_xlock_hard (sx=0xffffffff822e6ea8 <ifnet_detach_sxlock>,
                       file="sys/net/if_clone.c", line=480)
    #6 if_clone_destroyif (...)         at sys/net/if_clone.c:480
    #7 if_clone_destroy (name="tun2")   at sys/net/if_clone.c:431

The `wchan` and `sx=` are the **lock identity**: a global symbol
named `ifnet_detach_sxlock` at address `0xffffffff822e6ea8`. The
`file=/line=` are the call site that's blocked, i.e. **this thread
is queued on a lock that some other thread holds**.

### Step 6 — decode the lock's owner field

The whole point of this exercise is to prove that the holder thread
(step 3) is the one parking this lock. Print the lock:

    (kgdb) p ifnet_detach_sxlock
    $3 = {
      lock_object = { lo_name = "ifnet_detach_sx", ... },
      sx_lock = 18446735282436841476
    }

`sx_lock` is an integer that encodes both the holder thread pointer
and a few flag bits in its lowest 3 bits. Convert it to hex:

    (kgdb) p /x ifnet_detach_sxlock.sx_lock
    $4 = 0xfffff8011f502004

Mask the bottom 3 bits to get the holder `struct thread *`:

    (kgdb) p /x ifnet_detach_sxlock.sx_lock & ~7
    $5 = 0xfffff8011f502000

And the flag bits:

    (kgdb) p /x ifnet_detach_sxlock.sx_lock & 7
    $6 = 0x4

Two pieces of information drop out:

- **Holder td = `0xfffff8011f502000`**, which is *exactly* tid
  105425 — the `ifconfig tun1 destroy` thread we backtraced in
  step 3. The thread that is asleep in `cv_wait_sig` is the same
  thread that holds `ifnet_detach_sxlock` exclusively. QED.
- **Flag `0x4` is `SX_LOCK_EXCLUSIVE_WAITERS`**, defined in
  `sys/sys/sx.h`. It means at least one other thread is queued
  waiting for the xlock — which matches tid 105919 in step 5.

> **Where do the sx_lock bit definitions live?** `sys/sys/sx.h`,
> around `SX_LOCK_SHARED`, `SX_LOCK_SHARED_WAITERS`,
> `SX_LOCK_EXCLUSIVE_WAITERS`, `SX_LOCK_RECURSED`. Worth reading
> once; the encoding shows up in any kgdb session on a sleeping
> lock. The `mtx(9)` and `rwlock(9)` encodings are similar.

### Step 7 — make the picture explicit

After steps 1–6 you have:

```
        sx_lock      = 0xfffff8011f502004
                       └──────────────┴─── flags  = 0x4 (SX_LOCK_EXCLUSIVE_WAITERS)
                       └──────────┬────── holder td = 0xfffff8011f502000
                                  │
                                  ▼
                        tid 105425 "ifconfig tun1 destroy"
                        sleeping in cv_wait_sig (frame #5)
                        called from tun_destroy (frame #6, line 662)
                        called from if_clone_destroyif_flags
                        called from if_clone_destroyif (frame #8, line 481)
                        ^^^^^^^^^^^ which took the xlock at line 480 ^^^^^^^^^^^

        tid 105919 "ifconfig tun2 destroy"
        queued on _sx_xlock_hard for the same lock
        (this is the thread DEADLKRES named)
```

No ambiguity left: the bug is "`tun_destroy` parks on a CV while
holding `ifnet_detach_sxlock`."

### A minimal kgdb cheat-sheet for this kind of bug

| Goal | Command |
| --- | --- |
| Open the dump | `sudo kgdb /boot/kernel/kernel /var/crash/vmcore.0` |
| Print the panic message | `p (char *) panicstr` |
| List all threads | `info threads` |
| Switch to a specific thread by tid | `tid <tid>` |
| Backtrace the current thread | `bt` |
| Backtrace every thread (long!) | `thread apply all bt` |
| Print a struct at an address | `p *(struct foo *) 0xADDR` |
| Print a global by name | `p <symbol>` |
| Print a value in hex | `p /x <expr>` |
| Decode an sx-lock holder | `p /x lockvar.sx_lock & ~7` |
| Find a source line | `list sys/net/if_tuntap.c:662` |

What `kgdb` is *not* good at: it cannot resume the kernel or execute
anything — you are reading a frozen snapshot of memory. Everything is
"follow this pointer, print that struct." Treat it as a debugger over
a corpse, not a running program.

### What if it weren't a dump but a live wedged system?

If you don't have DEADLKRES enabled but the system is still wedged,
you can still get useful information without panicking the host:

    sudo procstat -kk <pid>          # kernel stack of one process
    sudo procstat -akk               # every thread on the system
    sudo lockstat -P                 # if LOCK_PROFILING compiled in

The `procstat -akk` output is essentially what kgdb shows in
`thread apply all bt`, but without the ability to dereference
structs. It's enough to identify the *shape* of a wedge (which lock,
which call sites) but not to confirm the *holder* — for that you
need the dump.

A trick that works well in the lab: from a parallel ssh session,
trigger a controlled panic to get the dump *while* the wedge is
active:

    sudo sysctl debug.kdb.panic=1

This is destructive (the host reboots), but on a debug kernel it
gives you the same `vmcore` that DEADLKRES would have, without
waiting for the watchdog.

---

## 6. The culprit code

The kernel side, in `sys/net/if_tuntap.c`, looked like this (line
numbers from the pre-patch tree at `n286096-490c53e9353f`):

```c
static int                                              /* line 647 */
tun_destroy(struct tuntap_softc *tp, bool may_intr)
{
    int error;

    TUN_LOCK(tp);
    MPASS((tp->tun_flags & (TUN_DYING | TUN_TRANSIENT)) != TUN_DYING);
    tp->tun_flags |= TUN_DYING;
    error = 0;
    while (tp->tun_busy != 0) {                         /* line 659 */
        if (may_intr)
            error = cv_wait_sig(&tp->tun_cv, &tp->tun_mtx);   /* 662 */
        else
            cv_wait(&tp->tun_cv, &tp->tun_mtx);
        if (error != 0 && tp->tun_busy != 0) {
            tp->tun_flags &= ~TUN_DYING;
            TUN_UNLOCK(tp);
            return (error);
        }
    }
    /* ... carry on with the actual destroy ... */
```

Read it once and the bug looks fine — `cv_wait_sig` is interruptible,
right? In practice no, for two reasons:

1. The `ifconfig` process is wedged inside a syscall. Signals don't
   reach a process parked in `cv_wait_sig` deep in a kernel path that
   isn't checking for them frequently. Even `SIGKILL` (which usually
   wins) was observed not to dislodge it.
2. **Even if signals worked**, holding a global exclusive sx lock
   across an unbounded sleep is the wrong design. A user with no
   privileges and an unkillable VPN daemon can wedge every cloner on
   the host.

### The caller

In `sys/net/if_clone.c`:

```c
int
if_clone_destroyif(struct if_clone *ifc, struct ifnet *ifp)         /* 476 */
{
    int err;
    sx_xlock(&ifnet_detach_sxlock);                                 /* 480 */
    err = if_clone_destroyif_flags(ifc, ifp, 0);                    /* 481 */
    sx_xunlock(&ifnet_detach_sxlock);                               /* 482 */
    return (err);
}
```

So by the time `tun_destroy` enters its `while` loop on line 659, the
caller has already taken the global sx lock at line 480. That lock
will not be released until line 482 runs, which will not run until
the loop exits, which will not happen until userspace closes the fd.

### Confirming this from a real kernel dump

Reading the source is one thing; confirming the kernel actually
behaves that way at runtime is another. The full kgdb walkthrough is
in §5 above — `DEADLKRES` panics the host, we load the resulting
`vmcore` in `kgdb`, switch into the holder thread, print its softc,
and decode the sx-lock owner field. The output matches the source
exactly: holder td `0xfffff8011f502000` is the thread parked in
`cv_wait_sig`, and the sx-lock's `EXCLUSIVE_WAITERS` flag confirms
others are queued behind it.

---

## 7. The patch and why this shape is correct

There are two callers of `tun_destroy`:

```mermaid
flowchart LR
    A[tun_clone_destroy<br/>at if_tuntap.c:729<br/>called from if_clone_destroyif] -->|may_intr = true| TD[tun_destroy]
    B[tun_uninit<br/>at if_tuntap.c:773<br/>called from MOD_UNLOAD] -->|may_intr = false| TD

    style A fill:#fdd,stroke:#900
    style B fill:#dfd,stroke:#090
```

- The red one (`may_intr=true`) is the path that holds
  `ifnet_detach_sxlock` exclusively. This is the one that causes the
  outage.
- The green one (`may_intr=false`) is module unload. It does **not**
  hold the global sx lock, and it has nothing useful to do until
  every device is gone, so it is fine to wait.

So the fix has two requirements:

1. The red path must not park inside `cv_wait_sig` while holding the
   global lock. Refusing with `EBUSY` is the natural answer and matches
   how the rest of the network stack signals "this is in use, try
   again later" (`vlan` on a busy parent, etc.).
2. The green path must keep its existing behaviour.

The boolean `may_intr` already discriminates between the two callers,
so we can branch on it:

```c
/*
 * If our caller is willing to be interrupted (i.e. we are reached from
 * if_clone_destroy(), holding ifnet_detach_sxlock exclusively) and
 * the device currently has an open consumer, refuse the destroy with
 * EBUSY rather than parking on tun_cv with the global sx lock held.
 * Waiting here is unbounded: tun_busy only drops to 0 when the
 * consumer close(2)s the device, and a process holding the fd open
 * in select(2) (e.g. openvpn) will not do so on demand. The result
 * is that every subsequent ifnet-clone destroy on the host wedges in
 * _sx_xlock_hard, with only a reboot to recover.
 *
 * Module unload (may_intr == false, from tun_uninit() outside the
 * ifnet-clone path) still waits, because the unload itself cannot
 * proceed past in-use devices and is not holding any global sx lock.
 */
if (may_intr && tp->tun_busy != 0) {
    TUN_UNLOCK(tp);
    return (EBUSY);
}
```

The full patch lives at [`tun_destroy_ebusy.patch`](tun_destroy_ebusy.patch).
After applying, the loop simplifies to the non-interruptible case
only — the `if (may_intr) cv_wait_sig else cv_wait` branch collapses,
and an `MPASS(!may_intr)` documents that assumption inside the loop.

### Things this patch deliberately does NOT do

- **It does not drop the sx lock around `cv_wait`.** That sounds
  appealing — sleep without the lock, retake it on wake — but in
  practice the cloner state can change underneath you (another
  destroy can race in, the softc can disappear), and getting the
  re-validation right is much harder than just refusing the request.
- **It does not add a timeout.** A timeout of `T` seconds just means
  "the system is wedged for T seconds instead of forever." That's not
  a fix, just a less-bad bug. A real configuration with an active
  openvpn on a tun should not be torn down on a timer.
- **It does not change `tunclose` or `tun_busy` accounting.** The
  open-consumer counting is already correct. The bug was on the
  destroy side, and that's where the fix lives.

### The shape of the call stack, before and after

```mermaid
flowchart TD
    subgraph before [Before patch]
        B1[if_clone_destroy] --> B2[sx_xlock]
        B2 --> B3[tun_destroy]
        B3 --> B4["while tun_busy != 0:<br/>cv_wait_sig (FOREVER)"]
        B4 -.->|userspace never closes| B4
        B2 -.->|lock held the entire time| BL[Global lock<br/>held forever]
    end

    subgraph after [After patch]
        A1[if_clone_destroy] --> A2[sx_xlock]
        A2 --> A3[tun_destroy]
        A3 -->|tun_busy != 0| A4[return EBUSY]
        A4 --> A5[sx_xunlock]
        A5 --> A6[ifconfig prints<br/>'SIOCIFDESTROY: Device busy']
    end

    classDef bad fill:#fdd,stroke:#900
    classDef good fill:#dfd,stroke:#090
    class B4,BL bad
    class A4,A5,A6 good
```

---

## 8. Validating the fix

We rebuilt the kernel with the patch and ran three tests on a
non-production host.

### Test 1 — does the EBUSY path actually fire?

```sh
$ sh FreeBSD/test_tun_destroy_patch.sh
[+] created tun0
[+] /dev/tun0 held open by PID 1234
[+] running 'ifconfig tun0 destroy' (timeout 5s)...
  exit code: 1
  stderr:    ifconfig: SIOCIFDESTROY: Device busy

PASS: kernel correctly returned EBUSY. Patch is live.
```

The validator script at [`FreeBSD/test_tun_destroy_patch.sh`](../test_tun_destroy_patch.sh)
returns PASS/FAIL automatically with a 5-second timeout, so it
distinguishes "fixed" from "still wedged" without ambiguity.

### Test 2 — does it still refuse, kill the holder, then destroy cleanly?

```sh
$ ifconfig tun0 destroy            # while held
ifconfig: SIOCIFDESTROY: Device busy
$ kill $HOLDER_PID                 # let the fd close
$ ifconfig tun0 destroy            # now should succeed
$ ifconfig -l | grep tun0          # gone
```

Result: rc=0, tun0 gone, no leftover state.

### Test 3 — 10 parallel destroys against the same in-use tun

```sh
TUN=$(ifconfig tun create)
sleep 99999 < /dev/$TUN &
for i in 1 2 3 4 5 6 7 8 9 10; do
    ifconfig $TUN destroy &
done
wait
```

Result: all 10 returned `Device busy`, no panic, no lock contention,
final cleanup after killing the holder succeeded normally.

```mermaid
flowchart LR
    H[1 holder<br/>fd open]
    P1[destroy #1] -->|EBUSY| R[Refused]
    P2[destroy #2] -->|EBUSY| R
    P3[destroy ...] -->|EBUSY| R
    P10[destroy #10] -->|EBUSY| R
    R --> K[holder killed]
    K --> D[destroy #11] -->|rc=0| OK[tun gone]
```

If the fix had been subtly wrong (for example, if the EBUSY path had
leaked `TUN_DYING`), the second-and-later destroys would have seen
a confused softc state. They didn't.

---

## 9. Exercises

For the student. None of these require modifying the kernel further;
they are all readable from the existing sources.

1. Read `tun_open()` in `sys/net/if_tuntap.c` around line 1100 and
   trace exactly which counter `tun_busy` is, what locks protect it,
   and where it is decremented. (Hint: `tun_unbusy_locked` /
   `tunclose`.)
2. The sx lock has a field `sx_lock` that we decoded above. Look at
   `sys/sys/sx.h` and find where the bottom-bit flags are defined.
   Which flag value is `0x4`? What does it tell you about the lock
   state when set?
3. Find `if_clone_destroyif_flags` in `sys/net/if_clone.c`. It
   asserts the sx lock is held exclusively. What would happen if a
   future refactor changed `tun_destroy` to drop and retake the lock
   itself? Sketch a race that would break it.
4. The `epair(4)` cloner does *not* have this bug, even though it
   uses the same `if_clone` framework. Read `if_epair.c`'s destroy
   path. Why doesn't `epair_clone_destroy` need a `cv_wait`?
5. The pre-patch comment said `cv_wait_sig` makes the loop
   interruptible. We observed that SIGKILL didn't dislodge a wedged
   ifconfig. Read `sleepq_catch_signals` in `sys/kern/subr_sleepqueue.c`
   and propose a hypothesis why. (Hint: which lock is the syscall
   path also holding when the signal would be delivered?)

---

## References

- [`tun_destroy_ebusy.patch`](tun_destroy_ebusy.patch) — the patch.
- [`FreeBSD/repro_tun_destroy_deadlock.sh`](../repro_tun_destroy_deadlock.sh) — three-line wedge, scripted.
- [`FreeBSD/test_tun_destroy_patch.sh`](../test_tun_destroy_patch.sh) — automated PASS/FAIL validator.
- Source: `sys/net/if_tuntap.c`, `sys/net/if_clone.c`, `sys/sys/sx.h`.
- FreeBSD manpages: `tun(4)`, `if_clone(9)`, `sx(9)`, `condvar(9)`, `kgdb(1)`, `procstat(1)`, `dumpon(8)`.
