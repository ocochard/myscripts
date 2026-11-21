Replaces the first review (of 57cbd2c34fc9, unfenced version).

0a28cd495fe3c7bdd3e0e84c1c6df9bed419b77d ("linuxkpi: Give each srcu_struct its own grace period")

No runtime bug found. The store-load race from the first review is closed.

## Ordering proof

Reader R: `critical_enter()` (plain store `td_critnest++`), `ss_phase`
load-acquire, `ss_readers[idx]` add-acquire, `atomic_thread_fence_rel()`,
`critical_exit()`. Writer W: seq_cst fence, flip, `cpus_fence_seq_cst()`,
`quiesce_all_critical()`, acquire fence, `ss_readers[idx]` load-acquire
loop. Same pattern as lock_prof_reset() / lock_profile_obtain_lock_success()
(sys/kern/subr_lock.c:343, :623), plus the acquire fence that lock_prof
lacks.

Chain W -> every CPU: the flip precedes `atomic_store_rel_int(&smp_rv_waiters[0], 0)`
(subr_smp.c smp_rendezvous_cpus); each target does
`atomic_add_acq_int(&smp_rv_waiters[0], 1)` (an RMW in that release
sequence), then the action runs `atomic_thread_fence_seq_cst()`. Chain
every CPU -> W: `atomic_add_rel_int(&smp_rv_waiters[3])` after the action,
W's `atomic_load_acq_int(&smp_rv_waiters[3])` before returning. Interrupts
are precise, so the IPI fence on R's CPU sits at one point of R's program
order. Three cases cover every interleaving:

1. Fence before R's `td_critnest` store: R's phase load comes after a
   fence that follows its acquire of the rendezvous setup, so it reads the
   flip (or later). R counts in the new phase; W does not wait for it.
   R's later data loads also see W's unpublish (ordered before the flip by
   W's seq_cst fence).
2. Fence between the `td_critnest` store and `critical_exit()` (this
   includes the IPI arriving between `critical_enter()` and the phase
   load, and a `td_critnest` store still sitting in the store buffer on
   amd64: the handler's locked add drains it; on arm64 `dmb ish` orders the
   `str`). The store is visible before the waiters[3] release, so W's
   quiesce reads `td_critnest != 0` on R's CPU (pc_curthread is R: a
   thread cannot switch out inside a critical section) and spins until R's
   `critical_exit()`. Reading that zero pairs fence-rel (R) with fence-acq
   (W): W's counter load sees the increment. If R's phase load came after
   the fence it saw the new phase anyway (case 1 logic).
3. Fence after `critical_exit()` (R ran its whole lock path before the IPI,
   e.g. with interrupts disabled): the increment is visible through the
   waiters[3] release/acquire, before quiesce even runs.

So after quiesce + acquire fence, every reader that sampled the old phase
has a visible increment, and no later reader can sample the old phase:
`ss_readers[idx]` only decreases, the wait cannot be starved.

- amd64 (TSO): rel/acq fences are compiler barriers, enough under TSO;
  the only reordering that mattered (store `td_critnest`, load `ss_phase`)
  is broken by the IPI's locked add. Note `atomic_add_acq_int` is a locked
  op but comes after the phase load, so it never helped; the IPI is what
  closes it.
- arm64: `ldar` may pass an earlier plain `str`, the IPI `dmb ish` closes
  it; `dmb ish` before `critical_exit()` and after quiesce give the
  message-passing pair; other-multi-copy-atomicity makes the rendezvous
  chain transitive. powerpc (non-MCA) also holds: `sync` in the handler is
  cumulative, lwsync pairs for the rel/acq fences.
- Second grace period (old report steps 1-4): step 2 can no longer happen.
  W1 either sees R's phase-0 sample through quiesce and waits on
  `ss_readers[0]` until R unlocks, or R sampled phase 1 and W2 waits on it.
- Readers on W's CPU: W is not in a critical section (MPASS in quiesce)
  and is running, so no other thread on that CPU is inside its lock path;
  a reader that finished there was ordered by the context switch
  (thread_lock). The local action runs from smp_rendezvous_cpus() itself.
- Readers in interrupt filters bump the interrupted thread's
  `td_critnest`, still seen by quiesce.

## Calling contexts

`cpus_fence_seq_cst()` -> `smp_rendezvous_cpus()` requires interrupts
enabled and no spinlock section (`MPASS(md_spinlock_count == 0)`), takes
the `smp_ipi_mtx` spin mutex, and runs locally before `smp_started`.
`pause()` in the same function already requires all of that (mi_switch in
a critical section panics), so the IPI adds no new restriction; holding
sleep locks or Giant is fine (rms_unblock_readers() does the same).
Callers checked:

- in tree: ib_uverbs_uapi.c:699 (uverbs_disassociate_api_pre, no spin
  lock), mlx5_ib_mr.c:58 and :1320 (under CONFIG_INFINIBAND_ON_DEMAND_PAGING,
  not defined in sys/modules or sys/conf, so not built).
- ~/drm-kmod (olivier-amdxdna HEAD): drm_drv.c:491 drm_dev_unplug (no lock
  in the function), i915 intel_reset.c:1530 via synchronize_srcu_expedited
  (bit locks and wait_event only), amdxdna_ctx.c:87 from the destroy ioctl
  with `client_lock` and `dev_lock` held (LinuxKPI mutex = sx, sleepable)
  inside drm_dev_enter(), and from amdxdna_hwctx_remove_all() on close.
  All sleepable, none in a spinlock section.
- Suspend: device suspend/resume methods run while all CPUs are up
  (suspend_cpus() is after DEVICE_SUSPEND), so the rendezvous cannot hang
  on a parked AP from a drm suspend path.

## __FreeBSD_version

freebsd/main (now 6a83ecfe812e, one commit past the 6dc19a71f70c base,
param.h untouched) is 1600031; 1600032 is the next value and no other
pr/* branch bumps it. Re-check at push time.

## Comments

- Commit message: "modules that embed or declare one (drm-kmod,
  ib_uverbs)" omits mlx5ib, which does embed one
  (sys/dev/mlx5/mlx5_ib/mlx5_ib.h:805 `mr_srcu`). The first review was
  wrong on that point. Harmless (base module, rebuilt with the kernel);
  add it or write "e.g.".
- Still open from the first review, all minor: `srcu_barrier()` still
  calls `linux_rcu_barrier(RCU_TYPE_SLEEPABLE)`, unrelated to SRCU readers
  now (no `call_srcu()` in LinuxKPI); `RCU_SKIP()` checked separately in
  lock and unlock leaks a count across a panic/kdb entry; `ss_writer` is a
  pause loop with no fairness between concurrent writers.
- Cost: one IPI round to all CPUs per `synchronize_srcu()`. Callers above
  are slow paths.
- Untested with INVARIANTS/WITNESS: the new `MPASS` in
  cleanup_srcu_struct() and the `WITNESS_WARN` would be the first to flag a
  drm caller holding a LinuxKPI spinlock. Worth one run.

## Checks

- style(9): clang-format21 with freebsd/main .clang-format on lines
  427-505 of linux_rcu.c: no diff. srcu.h: only the tab-aligned struct
  members differ (FreeBSD convention clang-format cannot express). OK.
- Non-ASCII in added lines: none (`LC_ALL=C grep '[^[:print:][:space:]]'`
  on the diff).
- GPL: per-struct two-phase counter with IPI fence + critical-section
  quiesce is the FreeBSD lock_prof pattern, not Linux SRCU (per-CPU
  lock/unlock counts, srcu_flip with smp_mb pairs, srcu_gp state machine).
  No copied code.
- Drivers datasheet: n/a.
- Commit message: subject 52 chars (limit 50 "if possible"; prefix
  `linuxkpi:` is used in tree), body <= 72 columns, no tags, no PR. OK.
- Tutorial ~/myscripts/FreeBSD/docs/linuxkpi_srcu_per_struct.md: present;
  linuxkpi_srcu_per_struct.patch is byte-identical to the commit diff.
  "Memory ordering" section correct, with these fixes:
  - header: "branch olivier-lkpi-srcu ... one commit on main 46ce9acd6d15"
    is stale. Local and origin (GitHub) olivier-lkpi-srcu are 5a7cd54c9e27,
    the first, unfenced version. Update the branch or point the link at
    the fenced commit on 6dc19a71f70c.
  - "as lock_prof_reset() does": lock_prof uses the IPI fence and the
    reader release fence, not the writer acquire fence after quiesce. Say
    two of the three.
  - "interrupts every CPU": the calling CPU runs the fence itself, no IPI.
  - "a reader that read the phase before it has its td_critnest store
    visible, so quiesce waits for it": also true if the reader already
    left its critical section, but then quiesce does not wait; the
    increment is visible through the rendezvous completion instead. One
    clause.
  - Test table: consistent with lkpi_srcu_test.c (`MIN(NREADERS,
    mp_ncpus - 1)` = 7 on 8 vCPUs, 500 ms hold = `hz / 2`, poison check).
    Results themselves not re-run.

VERDICT: ready
