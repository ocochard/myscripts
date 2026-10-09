# FreeBSD: `ifconfig <epair> vnet <jid>` hangs forever in `epoch_drain_callbacks`, wedging every interface operation

Status: **open. Reproducible but INTERMITTENT** -- see "How often" below. Not the
fib_algo panic (that one is fixed by `e9c3a9fad530`); this is a separate,
non-fatal but fatal-in-practice hang.

## Summary

Moving an `epair(4)` endpoint into a VNET jail can block indefinitely inside
`epoch_drain_callbacks()`. The thread holds the ifnet `sx` lock while blocked, so
every subsequent interface operation on the machine queues behind it. The box
keeps running but no interface can be created, destroyed, addressed or moved
again, and `reboot` cannot complete — recovery needs a hard reset.

## Impact

- Any workload that creates and destroys VNET jails with epairs concurrently.
  Found with the FRR topotests, which do exactly that.
- Observed with 30 parallel pytest workers: wedged after ~5 minutes, with 30
  further `ifconfig` processes stacked up behind the first.
- Serially (one test at a time) it still happens, just rarely: once in a
  16-hour, 584-directory run.

### How often (measured, not estimated)

| run | configuration | outcome |
| --- | --- | --- |
| 1 | `-n 30`, 12 vCPUs / 42G | wedged at ~5 min, 61 tests in |
| 2 | same, `net.link.log_link_state_change=0` | **no wedge in 75+ min, 1500+ tests** |
| 3 | same as 1, 2026-10-04, fully instrumented | no wedge; **killed at 16m49s by a different panic** (`rn_match`, see `BUG-rtsock-rn_match-panic.md`) |
| 4 | same as 1, 2026-10-04, fully instrumented | **no wedge, no panic**: whole suite done in 35m35s (7166 results) |
| 5-40 | same as 1, looped 2026-10-04/05, guest rebooted between runs | **no wedge in 36 runs** (~18 h): runs 5-14 stock kernel (one `rn_match` panic, run 14), runs 16-40 with the `rn_match` fix; run 15 void |

So parallelism makes it far likelier than a serial run, but it is **not
deterministic even at `-n 30`**. Budget for several attempts. Do not read run 2
as evidence that the sysctl helps: the console-flood premise behind that knob
was measured and refuted (below), so the difference between the two runs is
most likely luck.

## Environment

```
FreeBSD 16.0-CURRENT  main-n289791-a2fbd988638e  __FreeBSD_version 1600026
GENERIC-NODEBUG (KDB and DDB present, INVARIANTS/WITNESS absent)
amd64, bhyve guest: 12 vCPUs, 42 GiB RAM
host: AMD Ryzen 7 7735HS, 16 cores, 59.7 GiB
```

Also seen on `main-n289139-372b94623ca4` (1600025), so it is not new in n289791.

## Symptoms

The holder, spinning but consuming no CPU (`0:00.00` after 5+ minutes):

```
pid 31195  state RJ  /sbin/ifconfig epair0b vnet 55
mi_switch <- sched_ule_bind <- epoch_drain_callbacks <- if_detach_internal
          <- if_vmove <- if_vmove_loan <- ifioctl <- kern_ioctl <- sys_ioctl
```

Everything else piles up on the ifnet lock:

```
29 x state DJ   /sbin/ifconfig <epair> vnet <jid>
mi_switch <- _sx_xlock_hard <- ifioctl <- kern_ioctl <- sys_ioctl
```

All `softirq_N` gtaskqueue threads are idle (`msleep_spin` in
`gtaskqueue_thread_loop`), i.e. no epoch callback work is pending or running,
yet the drain does not return.

## Status after the 2026-10-05 loop

The wedge has not recurred in ~37 full-suite runs since the one at ~5 minutes
(run 1). By the rule of three its per-run rate is now below ~1 in 12 at 95%
confidence, so repeating recipe A has poor odds. One unproven possibility: the
rtentry use-after-free in `BUG-rtsock-rn_match-panic.md` corrupts unrelated
kernel memory -- its reproducer showed freed memory reused while still queued
on the epoch callback list -- so the single wedge may have been a side effect
of that bug rather than a scheduler or epoch defect. The kernel the wedge was
seen on had that bug; nothing here proves the link.

## Analysis

From the dump (`kgdb`, frame 3 of the holder):

```
#2  sched_ule_bind (td=0xfffff80008128780, cpu=6)
#3  epoch_drain_callbacks (epoch=0xffffffff81e01f80 <epoch_array+384>)
        at /usr/src/sys/kern/subr_epoch.c:1004
    cpu = 6,  old_cpu = 9,  was_bound = 0,  er = 0xfffffe00e6162a00
#4  if_detach_internal
#5  if_vmove (ifp=0xfffff8094f7a5800)
#6  if_vmove_loan (ifname="epair0b")
```

`epoch_drain_callbacks()` walks the CPUs and `sched_bind()`s itself to each one
in turn. It is stuck on the bind to **CPU 6**. The holder's own scheduler state
is the key fact:

```
td_state = TDS_RUNQ        (runnable and queued -- NOT sleeping)
td_wchan = 0x0   td_wmesg = 0x0
td_oncpu = -1    td_pinned = 1    td_priority = 141
```

Meanwhile other CPUs are idle:

```
cpuid_to_pcpu[0]->pc_curthread->td_name = "idle: cpu0"
cpuid_to_pcpu[9]->pc_curthread->td_name = "idle: cpu9"   (old_cpu was 9)
cpuid_to_pcpu[6]->pc_curthread->td_name = "swi0: uart uart++"
```

So the thread is **runnable, pinned to CPU 6, and never scheduled there for
5+ minutes while other CPUs sit idle.** Nothing is blocking on a lock or a
wchan; it simply does not run. That points at the ULE bind/migration path --
a lost migration or a thread queued somewhere its bound CPU will not pick it
up -- rather than at epoch or at the network stack. `epoch_drain_callbacks()`
is merely the caller that happens to use `sched_bind()` while holding the
ifnet `sx` lock, which is what turns one stuck thread into a machine-wide
interface stall.

### A hypothesis that was tested and REFUTED

The first theory was console flooding: link-state messages from 30 workers
creating and destroying epairs saturating the emulated 16550 and keeping
`swi0: uart` on the CPU the drain wanted. **Measured and false.** The entire
wedged run produced **12,937 bytes** of console output, with exactly two
"link state changed" lines, both from boot. There was no flood.

`swi0: uart` being current on CPU 6 is an artifact of the measurement: the
dump was triggered with `sysctl debug.kdb.panic=1`, which prints the panic
message out the serial console, so uart interrupt work is precisely what is
expected to be running when the other CPUs are stopped. **Do not read
"what each CPU was doing" from a dump taken by a console-printing panic.**

### Better next measurement

The guest kernel has DDB compiled in (`GENERIC-NODEBUG` keeps KDB/DDB). While
wedged, break into DDB on the console instead of panicking, and read the live
state that a panic would distort:

```
db> show allpcpu          # what each CPU is really running
db> show lockchain <tid>  # confirm nothing is actually blocking it
db> bt <tid>
```

`runvm.sh` keeps the console on `/dev/nmdm-frrtopo-B`; `debug.debugger_on_panic`
is 0 for unattended runs, so entering DDB has to be deliberate (console escape,
or `sysctl debug.kdb.enter=1`, which does NOT print a panic message).

## Reproduce

Two recipes. The first is fast and is the one to use.

### A. Parallel FRR topotests in a VM (minutes to an hour; see "How often")

Needs the VM from `~/myscripts/FreeBSD/frr-topotest-vm/` (see `README.md`; it
exists because this host cannot capture a kernel dump at all). Then:

```sh
# host
sudo ./mkvm.sh                       # once, ~4 min; clones the running host
sudo ./runvm.sh &                    # 12 vCPUs / 42G, restarts guest across panics
sudo ./sync-frr.sh                   # ship ~/frr in and build it in the guest

# guest (ssh -i ~/.ssh/id_ed25519_frrvm root@<guest>)
sh /mnt/host/guest-prep.sh           # pkg deps + pytest stack, once per image
cd /root/frr/tests/topotests
python3 -m pytest -s -vv -n 30 --dist=loadfile > /root/xdist.log 2>&1
```

FRR tree: PR https://github.com/FRRouting/frr/pull/23475 (FreeBSD topotest
support) cherry-picked onto a current master. Branch `pim-freebsd` here.

It may wedge within minutes, or not at all in an hour -- see "How often".
Confirm a wedge by AGE, not by state:

```sh
# the signature: an ifconfig vnet older than ~120s (one RJ, the rest DJ behind it)
ps -ax -o etimes,pid,state,command | awk '/[i]fconfig .* vnet /{if ($1+0>=120) print}'
procstat -kk <that pid>          # expect epoch_drain_callbacks / if_detach_internal
```

**State `RJ` alone is NOT the signature** -- it just means "running, jailed",
which every healthy jailed process shows briefly. That false positive cost a
detection cycle here.

`ddb-on-wedge.sh` in this directory automates all of it: it polls for the
age-based signature, captures pids/TID and `procstat` output *before* stopping
anything, enters DDB, runs the command list below over the console, and writes
everything to `/zroot/vm/share/ddb-wedge-<timestamp>.txt` on the host side so it
survives resetting the guest. Run it as root alongside the test run.

### B. Minimal probe — DOES NOT reproduce, documented so nobody repeats it

`epair-vnet-hang.sh` loops jail-create + epair-create + `ifconfig … vnet` with a
60 s watchdog. **Survived 300 iterations.** The bare operation is not enough; it
needs the churn of real topologies (many jails, several interfaces each, bridges,
routing daemons running, and — per the hypothesis above — heavy console output).

### C. Hammers: the same two syscalls, thousands of times faster

Written 2026-10-03. All three hammers have since been run against the
wedging kernel and **none of them wedges** (results below). The
point of both is rate: recipe A reaches `epoch_drain_callbacks()` a few times a
second and `sched_bind()` a few dozen times a second, which is why a wedge
takes minutes to hours. Each hammer isolates one of the two and runs it flat
out, with a heartbeat written *before* the syscall under test so a stall is
detected by the age of the last attempt, never by process state.

| probe | kernel path | measured rate (16-core host) | a wedge costs |
| --- | --- | --- | --- |
| `hammer-epoch-drain.c` | `SIOCIFDESTROY` -> `if_detach_internal` -> `NET_EPOCH_DRAIN_CALLBACKS` | ~500 cycles/s, one worker | the machine: `ifnet_detach_sxlock` is held, as in the real wedge |
| `hammer-sched-bind.c` | `CPUCTL_CPUID` -> `cpuctl_do_cpuid` -> `set_cpu` -> `sched_bind` | ~70k binds/s with heartbeat, ~500k/s without | one process; no kernel lock is held, machine stays usable |

Both are driven by `hammer-run.sh`, which also starts CPU hogs (the report's
oversubscription), polls the heartbeats and, on a stall, prints `procstat -kk`
and `procstat -t` for the stuck pid and leaves it alone for `ddb-on-wedge.sh`:

```sh
# in the guest, as root
sudo ./hammer-run.sh -m drain            # workers = hogs = hw.ncpu, stall = 60s
sudo ./hammer-run.sh -m bind -l 0 -t 30  # no hogs: maximum bind rate
sudo ./hammer-run.sh -m drain -i epair   # epair clones two ifnets, so two drains
```

Why these two paths and not the epair/vnet pair of recipe B:

- Every interface **destroy** goes through `if_detach_internal()`, which is
  where the drain lives. `if_vmove()` is not special; jails, epairs and
  bridges only make the path more expensive, not more reachable. So the
  cheapest clone (`lo`) reaches the identical drain.
- The dump says the thread was stuck in `sched_bind()` with no epoch work
  pending anywhere. `cpuctl(4)` binds the calling thread for the duration of
  one ioctl and does nothing else, so the bind hammer tests that hypothesis
  with the network stack entirely out of the picture.

What each outcome means:

- **bind hammer wedges** -> the bug is ULE's bind/migration path. Nothing in
  epoch or in the network stack needs to be involved, and the fix belongs in
  the scheduler.
- **drain hammer wedges but the bind hammer does not** -> the bind alone is
  not sufficient; the trigger needs the drain's context (holding
  `e_drain_mtx`, a `thread_lock()` round per CPU, epoch callbacks landing on
  the gtaskqueues).
- **neither wedges** -> something else in the topotest workload is required,
  and the next lever is concurrency against the `ifnet` lock rather than rate.

#### Result: the bind hammer does not wedge

2026-10-04, in the `frrtopo` guest (12 vCPUs, kernel
`main-n289791-a2fbd988638e`, the same build that wedges):

```
./hammer-run.sh -m bind -l 0 -t 30 -d 1800
==> mode=bind workers=12 hogs=0 ncpu=12 stall=30s
==> survived 1800s, 2115260725 iterations, no stall
```

**2.1 billion sched_bind() calls across all 12 CPUs in 30 minutes** (~1.2M/s,
~2 context switches each, confirmed by `vmstat -s`), no worker ever more than
one second behind its heartbeat. Pre-state verified clean: `jls -N` empty,
`ifconfig -l` just `vtnet0 lo0`, no aged `ifconfig`.

So `sched_bind()` on its own does not reproduce the hang, at a rate five
orders of magnitude above what the topotest run generates. Either the trigger
needs the drain's context around the bind -- `e_drain_mtx` held, a
`thread_lock()`/`thread_unlock()` round per CPU, epoch callbacks landing on
the gtaskqueues, `ifnet_detach_sxlock` held across all of it -- or it needs
the *concurrency* the hammer lacks: here one thread binds at a time per
worker, while the wedge happened with 30 processes contending for the ifnet
lock behind a single drainer.

This does not clear the scheduler: `cpuctl(4)` binds from a thread that is not
holding a mutex, so the one structural difference between the two paths
(`epoch_drain_callbacks()` calls `sched_bind()` with `e_drain_mtx` held and
the thread lock taken) is untested. A next variant would be a bind hammer that
takes a mutex first, which needs a small kernel module.

#### Result: the drain hammer reaches the reported state but does not wedge

2026-10-04, fresh-booted guest (0 jails, `vtnet0 lo0` only), 12 workers on
`lo` plus 12 spin hogs on 12 vCPUs. Within 90 seconds one worker had not
completed a cycle for 67 s, and DDB on the live machine showed exactly the
topology the bug report describes:

```
db> show lockchain 100190
thread 100190 (pid 4317, hammer-epoch-drain) is blocked on lock
    0xffffffff81e35568 (sx) "ifnet_detach_sx" XLOCK
thread 100273 (pid 4314, hammer-epoch-drain) is sleeping on
    0xffffffff81e01f80 "EDRAIN"
```

`0xffffffff81e01f80` is the same epoch the original dump names
(`epoch_array+384`, `net_epoch_preempt`), and the stack of the holder is the
reported one down to `if_detach_internal+0x57` -- reached from
`lo_clone_destroy()` instead of `if_vmove()`, which is the point of the probe.

**But this was a false positive, not the bug.** `show thread` on both parties
gave `last voluntary switch: 0.000 s ago`: the drain was being entered and
left continuously, and the machine recovered the moment the load stopped.
What stalled was one *worker*, starving on a non-FIFO `sx` lock behind eleven
others. Two lessons, both now fixed in the probe:

- **Measure progress across all workers, not per worker.** The wedge stops
  every interface operation at once; one worker waiting a minute under 12-way
  contention is normal. `hammer-run.sh` now trips only when the *total*
  iteration count stops advancing for `-t` seconds (default 60; use 180 under
  load).
- **`set $lines 0` before anything else in DDB.** The pager stops long output
  with `--More--` and swallows every following command as pager input; the
  first capture lost `ps`, `bt`, `show lockchain` and `show alllocks` that
  way. `ddb-on-wedge.sh` now sends it first.

Also measured: while the drain hammer runs with 12 spin hogs, new `ssh`
sessions to the guest can take minutes to produce output, though the watcher's
short polls still get through. The serial console is the reliable channel for
anything interactive; `runvm.sh` keeps it on `/dev/nmdm-frrtopo-B`.

With that detection in place, the full run:

```
./hammer-run.sh -m drain -w 12 -l 8 -t 180 -d 3600
==> mode=drain workers=12 hogs=8 ncpu=12 stall=180s
==> survived 3600s, 177770 iterations, no stall
```

**177,770 interface create/destroy cycles in one hour** -- ~49 drains per
second, every one of them through `if_detach_internal()` ->
`NET_EPOCH_DRAIN_CALLBACKS()` under `ifnet_detach_sx`, on 12 vCPUs
oversubscribed by 8 spin hogs. No global stall of even 180 s. For comparison,
the run that wedged did perhaps a few hundred drains in five minutes.

So the drain by itself does not wedge either, at roughly two orders of
magnitude more drains than the topotest workload. Neither half of the stuck
frame reproduces alone. What the two hammers between them do NOT cover, and
what the next probe has to add:

1. **`if_vmove()`, not `if_detach()`.** The reported drain runs with
   `vmove == 1`: the ifnet is moved between vnets with `CURVNET_SET()` around
   it, and the epoch callbacks it waits for belong to the *source* vnet. The
   `lo` hammer never leaves vnet0.
2. **VNET jail teardown.** `jail_remove()` destroys a whole network stack,
   which is where the topotests spend their churn.
3. **Other epoch users running.** A real topology has routing daemons,
   bridges and multicast state queueing epoch callbacks; the hammer's drains
   almost always find the callback lists empty.

`hammer-vnet-move.c` does 1 and 2 (result in the next subsection):
`jail_setv(vnet=new)` + epair clone + `SIOCSIFVNET` -- which is
`if_vmove_loan()`, the exact frame in the report -- + `jail_remove()` +
destroy, as N parallel workers. It needs `-ljail` and a `vnet` mode in
`hammer-run.sh`.

#### Result: the vnet-move hammer does not wedge either

2026-10-04, fresh-booted guest (0 jails, `vtnet0 lo0` only), same kernel, 12
workers plus 8 spin hogs on 12 vCPUs, `ddb-on-wedge.sh` armed on the host:

```
./hammer-run.sh -m vnet -w 12 -l 8 -t 180 -d 3600
==> mode=vnet workers=12 hogs=8 ncpu=12 stall=180s
==> survived 3600s, 21785 iterations, no stall
```

**21,785 iterations in one hour** (~6/s, flat from the first minute to the
last). Each one is the reported operation itself: VNET jail create, epair
clone, `SIOCSIFVNET` -> `if_vmove_loan()` -> `if_vmove()` ->
`if_detach_internal()` -> `NET_EPOCH_DRAIN_CALLBACKS()` with `vmove == 1`, then
`jail_remove()` tearing the vnet down (a second `if_vmove()` back to vnet0),
then the epair destroy (two more drains). That is roughly 87,000 drains in the
vmove and vnet-teardown contexts, against a few hundred in the run that
wedged. Polled every 10 minutes: interfaces and jails stayed in a fixed band
(10-21 ifnets, a dozen jails), so vnet teardown kept up and nothing leaked.
After the run, the jails and epairs left by workers killed mid-iteration were
removed by hand and the guest returned to `vtnet0 lo0` with no jails, dying or
otherwise.

The probe needed two fixes before its first run, both in the committed file:
`<sys/jail.h>` does not compile without `<sys/param.h>`, and it destroyed the
`a` side of the epair after `jail_remove()`, which may not be back in vnet0
yet if vnet teardown is deferred; with `ENXIO` ignored that would have leaked
a pair per iteration. It now destroys the `b` side, which never leaves vnet0.

So points 1 and 2 above are ruled out as sufficient triggers, at well over an
order of magnitude more operations than the topotest workload. What is left
is point 3: **other epoch users queueing callbacks while the drain runs**.
The hammers' own operations do queue callbacks (`if_free_deferred`,
`ifa_destroy`, rtentry and nhop frees on vnet teardown), but in lockstep with
their own drains and nothing else in the system queues any; the callback rate
was not measured (`kern.epoch.stats.epoch_calls`). In the topotests, routing
daemons (FRR's zebra installing and withdrawing routes), bridges, multicast
state and bpf are queueing `NET_EPOCH_CALL()` work into the same epoch,
independently of the drains. More rate on the same operations is not the
next lever.

#### Result: other epoch users queueing callbacks do not wedge it either

2026-10-04. First the baseline that the previous paragraph lacked, sampled
from `kern.epoch.stats.epoch_calls` on a fresh boot:

| load | net-epoch callbacks queued |
| --- | --- |
| idle guest | ~1 per minute |
| `hammer-run.sh -m vnet -w 12 -l 8` alone | **~1,170/s** (~200 per iteration) |

So the vnet hammer was never draining empty queues: each vnet teardown frees
hundreds of ifaddrs, routes, nexthops and lltable entries through
`NET_EPOCH_CALL()`, and with 12 workers, one worker's teardown is queueing
callbacks while another worker drains. The concurrency this axis was meant to
add was already partly present.

`hammer-epoch-churn.c` adds producers that run independently of any drain,
one per worker, flat out: `ifa` (alias add/delete on lo0: `ifa_destroy` plus
the host route), `mcast` (join/leave: `if_destroymulti`), `route` (PF_ROUTE
add/delete: rtentry + nhop), `bpf` (open, `BIOCSETIF`, close: `bpfd_free`),
`bridge` (addm/deletem: `bridge_delete_member_cb`); `@j` runs a producer in a
VNET jail of its own. Each alone, 4 workers, in callbacks/s: ifa 162k, mcast
13k, route 493k (2.5M inside a jail), bpf 7k, bridge 125k.
`hammer-run.sh -c` starts them next to the drain-side workers, does not count
them towards a stall, and reports the callback rate every minute.

```
./hammer-run.sh -m vnet -w 12 -l 0 -t 180 -d 3600 \
    -c ifa:2,mcast:2,route:1,bpf:1,bridge:2,ifa@j:1,route@j:1
==> 61s: 13 iterations, 12 workers alive, epoch_calls 617366/s, ...
==> survived 3600s, 644 iterations, no stall
```

**~550,000 callbacks/s for an hour** (490k-630k at every minute mark, ~470x
the vnet hammer's own rate), 527 million churn operations, 644 vnet-move
iterations (~2,600 drains), no stall. The 10 churn workers replaced the 8 spin
hogs as the oversubscription (22 runnable threads on 12 vCPUs).

One side effect is itself a measurement: under the churn, the vnet hammer fell
from ~300 to ~11 iterations per minute. Each drain waits for every CPU's
softirq grouptask to work through its callback queue, so drain latency scales
with the backlog -- yet with half a million callbacks a second queued, every
drain still completed. A deep queue makes drains slow, not stuck. That rate,
~40 drains a minute, also happens to be close to the topotest run that
wedged, so this was not a run with too few drains to hit a rare event.

With this, every ingredient of the stuck frame has been run in isolation and
combined, against the wedging kernel, without a wedge. What the hammers still
never did is in the dump itself: the stuck thread was runnable and bound to
CPU 6 **while other CPUs were idle**. Every bind and drain hammer run kept all
12 vCPUs busy (workers plus hogs), so a bind never had to wake a halted vCPU.
That is the next probe.

#### Result: binds that wake a halted vCPU do not wedge either

2026-10-04, fresh-booted guest. The guest idles with `machdep.idle=acpi`, but
no ACPI C-state hook is installed (`idle_available` is `spin, hlt`), so
`cpu_idle_acpi()` falls back to `sti; hlt` in `STATE_SLEEPING`, for which
`cpu_idle_wakeup()` returns 0: every wakeup of an idle CPU is a real IPI that
bhyve must deliver to a halted vCPU. One bind worker and no hogs leaves 11
vCPUs idle, so round-robin binds land on idle CPUs.

A first minute at default settings was discarded: ULE's idle thread spins up
to `kern.sched.ule.idlespins` (10000) iterations before halting once a CPU's
switch count is high (`sched_ule.c:3168`), so at this bind rate the targets
were mostly spinning, not halted. The real run used
`sysctl kern.sched.ule.idlespins=0`, which makes an idle CPU halt at once, as
the topotest's lightly loaded CPUs do:

```
./hammer-run.sh -m bind -w 1 -l 0 -t 60 -d 1800     # idlespins=0
==> survived 1800s, 64165149 iterations, no stall
```

bhyve's per-vCPU counters on the host confirm what was exercised: each vCPU
took ~5.5M HLT exits and received ~5.3M IPIs during the run (`bhyvectl
--get-stats`), i.e. **~64 million IPI wakeups of a halted vCPU, each followed by
a bound thread running there, none lost.** A lost IPI to an idle vCPU in this
bhyve, or a ULE race on the idle-CPU notification, would have to be rarer than
1 in 6.4e7 to hide from this run.

Every isolated ingredient of the stuck frame has now been hammered without a
wedge: the bind, the bind to an idle halted vCPU, the drain, the vmove, vnet
teardown, and a deep callback queue. The next step is recipe A again, with
everything instrumented, so the next wedge is captured completely. Note for
that capture: **this kernel's DDB has no `show runq`** (ULE registers no DDB
commands), so the deciding state -- CPU 6's `tdq_load`, `tdq_lowpri`,
`tdq_owepreempt`, `tdq_cpu_idle`, and its `pc_monitorbuf.idle_state` -- has
to come from kgdb on a dump taken after the live DDB capture.

Caveat on rates: those numbers are single-process and unloaded. With CPU hogs
running, ULE drops the hammer to timeshare priority (the stuck thread in the
dump was at `td_priority = 141`, the same place), and the measured aggregate
fell to a few hundred binds/s. If a high bind rate matters more than
oversubscription, run with `-l 0`.

## Artifacts

- `vmcore.0` (8.9 GB) + `info.0`, taken **while wedged** via
  `sysctl debug.kdb.panic=1` from a second ssh session; the dump device needed
  `dumpon -Z` to fit a 42 GiB guest into the 10 GB slice. Moved 2026-10-04 to
  the host share, `/zroot/vm/share/crash/epoch-wedge-20261003/` (sha256
  `f0209e8f...49c8b`, verified on both sides), so the guest's `/var/crash` is
  empty and has room for the next dump (17 GB free on its root).
- Analyse from inside the guest, which avoids copying it back:
  `kgdb -q /mnt/host/kernel.debug /mnt/host/crash/epoch-wedge-20261003/vmcore.0`
  -- the guest runs the host's exact kernel, so the host's `/usr/lib/debug`
  symbols match. Note this `kgdb` has no `ps` command; use `info threads`,
  then `thread <n>`, `frame`, `info locals`.
- Earlier dumps from the (now fixed) fib_algo panic: `/zroot/vm/share/crash/`.

## Next steps

1. **Catch it in DDB, then dump** (see "Better next measurement" above):
   `show all pcpu`, `show thread`, `show lockchain` live, then a dump for
   kgdb to read the bound CPU's `struct tdq` (no `show runq` in this DDB).
   This is the one measurement that distinguishes "queued on the wrong CPU"
   from "queued on the right CPU and not picked up".
2. **Check whether the bound CPU varies** across wedges. Always CPU 6 would
   suggest something specific to that vCPU; varying would point at the generic
   bind path.
3. **Try fewer vCPUs or fewer workers.** If 30 workers on 12 vCPUs is required,
   scheduler oversubscription is part of the trigger; if it reproduces at
   `-n 4`, it is not.
4. **Rule bhyve in or out.** The same test on real hardware, or with a
   different vCPU count, separates a guest-scheduler bug from a vCPU/IPI
   delivery problem in bhyve.
5. **Check `er->er_drain_state`** and the per-CPU epoch records to confirm the
   drain was waiting rather than mis-accounting.
5. If confirmed, the kernel question is whether `epoch_drain_callbacks()` should
   bind at all, or should tolerate a CPU it cannot reach.

## Not this bug

The PIM topotests also used to panic the kernel outright:
`panic: page fault`, `_rm_wlock <- softclock_call_cc`, `c_func = handle_fd_callout`.
That was `rt_table_destroy()` skipping `fib_destroy_rib()` because removing
`opt_route.h` from `sys/net/route.c` left it without `FIB_ALGO`. Fixed by
`e9c3a9fad530` (2026-09-30), verified here: 8 consecutive runs of
`multicast_pim_dr_nondr_test`, previously fatal on iteration 2, now clean.
