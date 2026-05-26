# vnet / jail / ifnet-clone deadlock on 16-CURRENT

## Summary

On `bigone` (FreeBSD 16.0-CURRENT, build `main-n285947-ca67cfa5237f`, kernel
`GENERIC-NODEBUG`), userland calls that touch the global ifnet/clone or
jail allprison locks regularly wedge in uninterruptible sleep (state `D`)
and never wake. The processes cannot be killed with `SIGKILL`; only a
reboot clears them.

The hang is reproducible enough to be a normal-workflow blocker:

- starts spontaneously after running `mlvpn` (tun cloners) or `bird_test.sh`
  (vnet jails with `epair`/`lo` cloners)
- once one cloner-destroy hangs holding the lock, every subsequent
  `jls`, `jail -R`, `ifconfig <if> destroy`, and indirectly `poudriere`
  (which calls `jls` during jail setup) piles up behind it
- only a reboot recovers — the system stays usable for unrelated work
  but anything that touches the cloners/jail subsystem hangs forever

## Snapshot of stuck processes (2026-05-26 14:21, uptime 8d 02h)

```
PID    STATE  STARTED    COMMAND
41135  D      Sat15      ifconfig tun0 destroy
48890  D      Sat15      ifconfig tun0 destroy
51303  D      Sat16      ifconfig tun0 destroy
59961  D      Sat16      ifconfig tun1 destroy
31137  D      12:09      /sbin/ifconfig lo110 vnet 487      (bird_test.sh)
31922  D      12:20      jail -R bird1                       (bird_test.sh)
32013  D      12:23      jls
31924  D+     12:20      jls
33780  D      12:28      jls -j builder-official              (poudriere)
34838  D      13:09      jls -j 142-amd64-official            (poudriere)
```

Three days of stale `ifconfig tun0/tun1 destroy` from `mlvpn` restarts on
Saturday are still wedged on Tuesday afternoon. Today's run of
`bird_test.sh start` added the rest.

## Kernel stacks (`procstat -kk`)

All ifnet-destroy callers blocked on the **exclusive** ifnet-clone sx
lock:

```
ifconfig tun0 destroy           (41135, 48890, 51303, 59961)
  mi_switch -> _sx_xlock_hard -> if_clone_destroy -> ifioctl
                                                  -> kern_ioctl
                                                  -> sys_ioctl
ifconfig lo110 vnet 487         (31137)
  mi_switch -> _sx_xlock_hard -> ifioctl
                              -> kern_ioctl
                              -> sys_ioctl
jail -R bird1                   (31922)
  mi_switch -> _sx_xlock_hard -> if_clone_detach
                              -> tuntap_prison_remove
                              -> osd_call
                              -> prison_deref
                              -> sys_jail_remove
```

All `jls` callers blocked on the **shared** allprison sx lock:

```
jls / jls -j ...                (32013, 31924, 33780, 34838)
  mi_switch -> _sx_slock_hard -> kern_jail_get -> sys_jail_get
```

`_sx_xlock_hard` + `_sx_slock_hard` on different but related locks is
the classic shape of a reader-vs-writer starvation or an outright
deadlock between the ifnet-clone lock and `allprison`. The
`tuntap_prison_remove -> osd_call -> if_clone_detach` path is the one
that closes the cycle: `prison_deref` holds allprison, then drops into
`if_clone_detach` which wants the ifnet-clone xlock; meanwhile the
`ifconfig ... destroy` writers from the host side hold (or are blocked
behind something holding) the ifnet-clone lock and block readers like
`jls` that came in via `kern_jail_get`.

The very first wedged process — one of the Saturday `ifconfig tun0
destroy` callers — is the original holder. Everything after it just
piles on.

## What this blocks in normal use

- `bird_test.sh start` (net/bird regression lab) — hangs at the first
  `jail -c persist vnet ...` after creating any `epair*` cloners
- `poudriere testport` / `poudriere bulk` — hangs in the jail-startup
  phase because the very first thing poudriere does is `jls -j
  <jailname>` to check whether the jail is already running. The script
  shows as idle (`I`) state in `ps` but its child `jls` is in `D`
- routine `mlvpn` reload (which is what seeded the original wedge on
  Saturday)

## Kernel build

```
FreeBSD 16.0-CURRENT #0 main-n285947-ca67cfa5237f
Built: Mon May 18 09:56:17 CEST 2026
Conf:  GENERIC-NODEBUG    (no WITNESS, no INVARIANTS, no DEBUG_LOCKS,
                          no DDB, no DEADLKRES)
```

`GENERIC-NODEBUG` is the production-style config. None of the lock
diagnostics that would name the holder are compiled in, which is why we
only see "stuck on `_sx_xlock_hard`" without a `lockmgr` chain or a
WITNESS lock-order trace.

## To debug — first session after reboot

1. **Rebuild with WITNESS + INVARIANTS + DEADLKRES + DDB** (the four
   that matter here). `GENERIC` already has them; the simplest path is
   to boot the matching `GENERIC` kernel rather than rebuild
   `GENERIC-NODEBUG`:

       cd /usr/src
       make KERNCONF=GENERIC buildkernel installkernel
       # then reboot into kernel.GENERIC

   `DEADLKRES` is the key one — it watchdogs threads stuck in
   uninterruptible sleep for too long and dumps every thread's stack on
   the console, which would tell us *who holds the lock* in addition to
   *who is waiting*.

2. **Enable verbose lock tracking on the suspect locks:**

       sysctl debug.lock_prof.enable=1
       sysctl debug.lock_prof.skipspin=1

   Then reproduce (a single `bird_test.sh start` followed by
   `bird_test.sh stop` should be enough), and:

       sysctl debug.lock_prof.stats > /tmp/lockprof.txt

   Look for the ifnet-clone sx and `allprison` rows — the "longest
   wait" and "longest hold" columns identify whichever critical section
   is sitting on the lock with another lock already held.

3. **Capture a kernel core via `sysctl debug.kdb.panic=1` from a healthy
   parallel ssh session** while the wedge is active. With DDB compiled
   in, the panic produces a dump under `/var/crash/` and `kgdb` against
   that gives every thread's stack at the moment of the hang (not just
   the `D`-state threads). This is the single highest-value artifact
   for the bug report.

4. **Search PR tracker** for prior reports — the bird_test.sh script
   itself already cites
   <https://bugs.freebsd.org/bugzilla/show_bug.cgi?id=264981> ("Previous
   jail stuck in dying state"). Also check:

   - <https://bugs.freebsd.org/bugzilla/buglist.cgi?quicksearch=if_clone_destroy>
   - <https://bugs.freebsd.org/bugzilla/buglist.cgi?quicksearch=tuntap_prison_remove>
   - `cgit.freebsd.org/src/log/sys/net/if_clone.c` and
     `cgit.freebsd.org/src/log/sys/net/if_tun.c` around the
     `tuntap_prison_remove` path — there were commits in this area in
     2025/early-2026 worth reading.

5. **Minimal repro recipe** to take into the debugging session:

       # one-shot, kernel-only — no bird needed
       ifconfig epair create
       jail -c name=t1 host.hostname=t1 persist vnet \
           vnet.interface=epair0a
       jail -R t1               # this is the call that wedges in
                                # if_clone_detach->tuntap... if tun was
                                # also touched in the same boot

   If `epair`-only doesn't reproduce, add a `tun` cloner step
   beforehand (`ifconfig tun create; ifconfig tun0 destroy`) since the
   Saturday seed wedge was on a `tun` cloner specifically.

## Pre-reboot snapshots (captured 2026-05-26 14:26, uptime 8d 02h)

The following artifacts are saved alongside this document so they
survive the reboot:

| File | Size | What it is | Key findings |
| --- | --- | --- | --- |
| `vnet_jail_deadlock_procstat-akk.txt` | 328K, 2090 lines | `procstat -akk` — kernel stacks of every thread on the system at the time of the wedge | **Primary artifact.** Line 1824 names the holder (PID 28397, `tun_destroy → _cv_wait_sig`, state `S`). Lines 1833, 1835, 1878, 1889, 1891, 2023 show the five xlock waiters (`_sx_xlock_hard`) on the ifnet-clone lock. Lines 1836, 1839, 1843, 1850 show the four `jls` slock waiters on `allprison` |
| `vnet_jail_deadlock_procstat-aL.txt` | 9.2K, 230 lines | `procstat -aL` — every line is `procstat: sysctl method is not supported`. Requires `WITNESS` in the kernel, not compiled into `GENERIC-NODEBUG`. Kept as a tombstone so we don't try this again pre-rebuild | Nothing useful — rebuild target |
| `vnet_jail_deadlock_vmstat-i.txt` | 7.1K, 140 lines | `vmstat -i` — interrupt counters per CPU and per device | Only normal `cpuN:timer` ticks (20–70/s) and the usual NIC/NVMe/AHCI rates. **No interrupt storm** → rules out a livelock driven by runaway interrupts |
| `vnet_jail_deadlock_netstat-m.txt` | 1.2K, 22 lines | `netstat -m` — mbuf and cluster usage | 14428 mbufs in use, 0 denied, 0 delayed across all sizes. **No mbuf pressure** → rules out the "kernel can't free the tun because mbufs are exhausted" hypothesis |
| `vnet_jail_deadlock_dmesg.txt` | 55K, 1509 lines | `dmesg` (full ring) | Lines 1474–1502: nine `tun/tap protocol violation, non-controlling process closed last` messages from repeated `mlvpn` restarts on `tun1`/`tun2`, confirming the disorderly-close pattern that seeded the wedge on Saturday. Lines 1506–1509: `epair112a/b` "Ethernet address" + link UP, confirming `bird_test.sh start` got as far as creating the epair pair before its `jail -c` wedged. No `panic`, no `lock order reversal`, no `witness` lines (expected — debug not compiled) |

### Likely lock holder identified from the akk dump

PID 28397, `ifconfig tun0 destroy`, started **Sat 12:00** (two and a
half days before the wedge becomes obvious), state `S` (not `D` like
the others), stack:

```
28397 ifconfig tun0 destroy
  mi_switch
    sleepq_catch_signals
      sleepq_wait_sig
        _cv_wait_sig            <-- interruptible CV wait
          tun_destroy
            if_clone_destroyif_flags
              if_clone_destroy
                ifioctl ...
```

This is **the original wedge.** It entered `if_clone_destroy` (which
takes the ifnet-clone sx xlock), then descended into
`tun_destroy` which parks itself in `_cv_wait_sig` waiting for the tun
device's last reference to drop. The reference never drops, so the CV
is never signalled, the xlock is never released.

### Live diagnostic — the holder of /dev/tun0 (2026-05-26, pre-reboot)

```
$ sudo fstat | grep -E 'tun[0-9]'
root  openvpn  77719  5  /dev  170  crw-------  tun0  rw

$ ps -o pid,ppid,state,lstart,wchan,command -p 77719 28397
  PID  PPID STAT STARTED                  WCHAN    COMMAND
28397 28396 I    Sat May 23 12:32:07 2026 tun_cond ifconfig tun0 destroy
77719     1 Ss   Mon May 18 12:14:54 2026 select   /usr/local/sbin/openvpn ...
                                                   openvpn_nflx ...
```

The fd holder is **not `mlvpn`** as originally hypothesised — it is
**`openvpn_nflx`** (PID 77719), a long-running, healthy daemon started
on Mon May 18 (a week before the wedge). Its state is `Ss` parked in
`select(2)`. It will never voluntarily close `/dev/tun0`.

`ifconfig tun0 destroy` (PID 28397, started Sat May 23 12:32) is in
WCHAN `tun_cond` — the very CV `tun_destroy` is waiting on. It was run
against a tun cloner that was still in active use by openvpn, and the
kernel's `tun_destroy` path has no timeout, no force-close path, and
no way to break the wait while the fd is open by another process.

So the trigger was *not* an mlvpn restart race; the dmesg `tun/tap
protocol violation` lines from `mlvpn` on `tun1`/`tun2` are a separate
phenomenon. The actual seed of the wedge is: **someone ran `ifconfig
tun0 destroy` while openvpn still had it open.** This is the real bug
class — `tun_destroy` should either refuse (EBUSY) or forcibly tear
down references when the tun is in use, not park the global ifnet-clone
xlock indefinitely.

Killing openvpn would release the CV — but openvpn must stay up for
this workload, so the only path is reboot.

Everything afterwards that wants the ifnet-clone xlock (the four other
`ifconfig tun*/tun1 destroy` callers from Sat 15:00 and Sat 16:00, the
`ifconfig lo110 vnet 487` from today's `bird_test.sh`, and the `jail -R
bird1` via `tuntap_prison_remove → if_clone_detach`) piles up on
`_sx_xlock_hard` behind it.

The `jls` callers parked on `_sx_slock_hard` in `kern_jail_get` are a
separate but related backup — `jail -R bird1` (PID 31922) is holding
the allprison xlock via `prison_deref` while blocked on the ifnet-clone
sx, so every reader that wants allprison piles up too.

### Reproducer — confirmed sequence

Updated after the live diagnostic above and tracing the caller. The
Saturday-noon sequence was:

1. `openvpn_nflx` (PID 77719) running since Mon May 18, holding
   `/dev/tun0` open in `select(2)`
2. On Sat May 23 12:32, the **first version** of
   `~/myscripts/FreeBSD/ports-tests/mlvpn_test.sh` ran `ifconfig tun0
   destroy` unconditionally during its `stop` phase, blindly targeting
   `tun0` instead of the tun(s) that the mlvpn instances actually
   created. That `tun0` was openvpn's.
3. `tun_destroy` parked in `_cv_wait_sig` on `tun_cond` waiting for
   openvpn to close its fd; openvpn never does, the ifnet-clone xlock
   is held forever.

**Operational fix (already applied):** `mlvpn_test.sh` now records which
tun interfaces carry the test IPs (`10.0.16.1/30`, `10.0.16.2/30`)
before stopping the daemons, and only destroys those — see
`mlvpn_test.sh:141-156`. This avoids nuking unrelated tun(4) consumers
on the host.

**Kernel bug still stands:** even with a buggy caller, `tun_destroy`
should not be able to wedge the global ifnet-clone xlock forever. It
should either refuse with `EBUSY` when the tun has open consumers, or
break the wait on a signal / timeout. That is the upstream PR to file.

If we can reproduce that race with WITNESS + DEADLKRES compiled in,
DEADLKRES should print the holder + waiter stacks within ~10 minutes of
the wedge starting (default
`debug.deadlkres.totalticks=5400` = 90 s, with
`debug.deadlkres.slptime_threshold` ~ 5 minutes for sleep state).

### Useful commands to re-run on the next wedge

    sudo procstat -akk             | tee /tmp/procstat-akk.txt
    sudo procstat -aL              | tee /tmp/procstat-aL.txt   # needs WITNESS
    sudo sysctl debug.lock_prof.stats | tee /tmp/lockprof.txt   # needs LOCK_PROFILING
    sudo dmesg                     | tee /tmp/dmesg.txt

## Workaround until fixed

- Reboot recovers; the wedge is not data-loss-inducing
- After reboot, **don't run `mlvpn` restarts and `bird_test.sh` in the
  same uptime as `poudriere`** if avoidable — once tun/epair cloners
  have been destroyed-while-jailed, the lock is at risk
- For port regression smoke tests that don't need the multi-jail
  topology (e.g. net/bird config-parse), use a single-process
  `bird -p -c <conf>` test instead of bringing up the vnet lab
