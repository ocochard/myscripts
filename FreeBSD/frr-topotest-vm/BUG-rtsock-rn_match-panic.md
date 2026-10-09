# FreeBSD: page fault in `rn_match()` from a routing-socket `RTM_ADD` during the FRR topotests

Status: **root cause identified from a dump, reproduced, patched and verified
(2026-10-05): rtentry use-after-free in the multipath append path of
`add_route_flags()`, a regression from `c24a8f19c5d5` (2022).** Patch:
`route_ctl-mpath-uaf.patch` (against main `a52c50b4b7c2`, still affected). Separate from the epoch wedge in
`BUG-epair-vnet-epoch-hang.md`; found while running its recipe A.

## What happened

2026-10-04 17:33, `frrtopo` guest (12 vCPUs, 42 GiB), kernel
`main-n289791-a2fbd988638e` GENERIC-NODEBUG, FRR topotests with
`pytest -n 30 --dist=loadfile`, 16m49s after boot:

```
Fatal trap 12: page fault while in kernel mode
cpuid = 9; apic id = 09
fault virtual address	= 0x10
instruction pointer	= 0x20:0xffffffff80d9c577
current thread		= 79018/155403 (zebra/zebra)
rcx: 0000000000000000 rdx: fffff808663a9880 r14: fffff808663a9800
rn_match() at rn_match+0x47
rn_lookup() at rn_lookup+0x6c
add_route_flags() at add_route_flags+0x5e
rib_add_route() at rib_add_route+0x2de
rts_send() at rts_send+0xab8
sosend_generic_locked() ... sys_write()
```

Full console excerpt: `/zroot/vm/share/crash/panic-rn_match-20261004-1733.txt`.
30 tests were in flight; which one owned zebra pid 79018 is unknown, because
the guest then cleared `/tmp/topotests` at boot.

## Second occurrence, with a dump (2026-10-05)

Loop run 14 (recipe A, `-n 30`), 15m35s after boot, identical trap
(`rn_match+0x47`, zebra `RTM_ADD`). Dump saved to the host share by the new
`rc.local` path: `/zroot/vm/share/crash/frrtopo/vmcore.0.zst` (597 MB zstd,
`vmcore.0` beside it decompressed). kgdb in the guest:

```
kgdb -q /mnt/host/kernel.debug /mnt/host/crash/frrtopo/vmcore.0 < cmds
```

(this kgdb has no `-batch`/`-x`; feed commands on stdin; there is no
`curthread` symbol, use `cpuid_to_pcpu[7]->pc_curthread`).

What the dump says:

- Thread: zebra pid 56580 in jail `ft1625x14_munet.ft1625x16_r2` (jid 1076),
  `PRISON_STATE_ALIVE`, `pr_uref = 12`, vnet `vnet_shutdown = false`. The
  `rib_head` (`0xfffff801f93e6c00`, AF_INET fib 0) belongs to that vnet,
  `rib_dying = false`. **The vnet-teardown theory is dead**: the table was
  live. (The pid matched an earlier test's r0 zebra in `/tmp/topotests` --
  pid reuse.)
- Route being added: `rt = 0xfffff8020b1bb000`, dst `110.0.19.1/32`.
- Replaying the descent for that key:

```
depth 0 node rnh_nodes[1]        bit 32 -> L 0xfffff808ee3db228
depth 1 node 0xfffff808ee3db228 bit 33 -> R 0xfffff8020b1bb030
depth 2 node 0xfffff8020b1bb030 bit 0, parent NULL, L NULL, R NULL   <- all zero
```

  `0xfffff8020b1bb030` is `rt_nodes[1]` of **the rtentry being added right
  now**. The tree holds a link into an rtentry that was freed while still
  linked; UMA handed the same item, zeroed, to this `rt_alloc()`, and the
  lookup walked into it.

## Root cause

`add_route_flags()` (`sys/net/route/route_ctl.c`), when the prefix exists and
multipath append applies, drops the RIB lock and calls

```c
error = add_route_flags_mpath(rnh, rt_orig, rnd_add, &rnd_orig, op_flags, rc);
```

with `rt_orig`, the existing entry, protected only by the epoch. If a
concurrent delete removes that prefix (`rt_free()` -> freed at the end of the
epoch), `change_route_conditional()` finds no prefix and returns `EAGAIN` with
`rnd_orig->rnd_nhop = NULL`; on the retry it takes

```c
if (rnd_orig->rnd_nhop == NULL)
	error = add_route(rnh, rt, rnd_new, rc);     /* rt == rt_orig */
```

and **re-inserts the deleted `rt_orig`**. `rc_cmd == RTM_ADD`, so the freshly
allocated `rt` is neither inserted nor freed (leaked). When the epoch ends,
`destroy_rtentry_epoch()` frees `rt_orig` while it is linked; the next
`rt_alloc()` that gets that item turns the stale link into the zeroed node
seen above.

Introduced by `c24a8f19c5d5` ("routing: fix rib_add_route_px()",
2022-08-29), which changed the argument from `rt` to `rt_orig` because
`rib_add_route_px()` without `RTM_F_CREATE` now passes `rt = NULL`. Related:
the `EAGAIN` refresh in `add_route_flags_mpath()` tests
`rnd_orig == NULL`, a pointer that is never NULL (meant
`rnd_orig->rnd_nhop == NULL`), so the no-create case can also reach the
fallback add with `rt_orig`.

Fix direction: pass the fresh `rt` when there is one (`rt != NULL ? rt :
rt_orig`, only its key is needed for the lookups), and refuse the fallback add
without `RTM_F_CREATE` (`ENOENT`). Trigger in the topotests: zebra appending a
multipath next hop to a prefix while the same prefix is deleted.

## Reproducer and verification

`hammer-rt-mpath-race.c`: a VNET jail of its own, an epair with 10.77.0.1/24,
8 threads appending one of 2 gateways to 110.0.19.1/32 (`RTM_ADD` with a
gateway = `RTM_F_APPEND`) and 4 threads deleting one of them (`RTM_DELETE`
with a gateway). A multipath prefix is only deleted with its last path, so 2
gateways keep the prefix flipping between one path and two -- the window.
(A first version deleted without a gateway; that never succeeds on a
multipath prefix, `rt_delete_conditional()` returns `ESRCH`, and nothing
raced.)

```
./hammer-rt-mpath-race -a 8 -r 4 -g 2 -d 300
```

| kernel (guest, same build otherwise) | result |
| --- | --- |
| stock `a2fbd988638e` GENERIC-NODEBUG | **panic after ~5 s, 2 of 2 runs** (dumps `crash/frrtopo/vmcore.1.zst`, `vmcore.2.zst`) |
| `a2fbd988638e` + the patch | **survived 300 s**, 63.2 M successful adds and 63.2 M successful deletes |

The repro's panic is the other face of the same freed memory, not the
`rn_match` trap: `epoch_call_task()` calls `entry->function(entry)` with a NULL
function (`rip = 0`, thread `softirq_N`); by dump time that `ck_epoch_entry`
holds a different, live callback (`destroy_fd_instance_epoch`, a fib_algo
instance), i.e. it was freed and reused while queued. Which structure a freed
and reused rtentry corrupts first decides which panic appears. The patch
removes both; that the topotest `rn_match` crash is the same bug rests on its
dump and the code path above, not on the repro alone.

Build notes: the test kernel was built from a shared clone of the source at
the guest's commit (`~/src-rtfix`, branch `rtfix-mpath-uaf`) with the old-style
`config -d ~/obj-rtfix/GENERIC-NODEBUG GENERIC-NODEBUG && make -j16
NO_MODULES=yes` (84 s; the host toolchain is the same commit) and installed in
the guest as `/boot/kernel.rtfix/kernel` beside the stock modules. The same
patch on current main (`/usr/src`, local `zroot/usr/src` after unmounting the
read-only NFS `bigone:/usr/src`) builds clean the same way (`~/obj-main`).

## Field result on the patched kernel

Recipe A looped back to back (full FRR topotest suite, `pytest -n 30
--dist=loadfile`, guest rebooted between runs), 2026-10-04/05:

| guest kernel | full-suite runs | `rn_match` panics |
| --- | --- | --- |
| stock `a2fbd988638e` | 12 (runs 3-14) | 2 (16m49s into run 3, 15m35s into run 14) |
| `a2fbd988638e` + patch | 25 (runs 16-40) | **0** |

At the stock rate (~1 in 6 runs), 25 clean runs in a row has a ~1%
probability ((5/6)^25). Stopped there on 2026-10-05 14:06.

## Analysis of the first occurrence (from the console only)

Disassembly of `rn_match` from the same kernel binary: `+0x47` is
`cmpw $0x0, 0x10(%rcx)`, the `t->rn_bit` test in the descent loop
(`radix.c:285`), with `rcx` (= `t`) NULL. So the walk followed a NULL
`rn_left`/`rn_right` out of an internal node. `rdx`, the tree top, is
`r14 + 0x80`, i.e. `rnh_nodes[1]` embedded in the `rib_head` at `r14`: head
and lock were intact (`RIB_WLOCK` was taken), the tree contents were not.

What it is probably not:

- **Teardown of the socket's vnet.** `rib_head` is freed only by
  `rt_table_destroy()` (from `in_detachhead()`, vnet teardown), and
  `sousrsend()` runs `rts_send()` under `CURVNET_SET(so->so_vnet)`; the
  socket's credential pins that prison, and `vnet_destroy()` runs only for a
  prison with no references left.

What it probably is: a radix node reached through a live link that points
into freed memory -- an `rtentry` (whose `rt_nodes[]` are the tree's
internal nodes) freed while still linked. Unconfirmed: needs a dump.

Context, not evidence: zebra logs `rtm_write() unexpectedly returned -2 for
command RTM_ADD` constantly in this suite (996 lines since 2026-10-02), and a
few just before the panic.

## Why there is no dump

The panic dumped fine (`Dump complete`) and savecore wrote
`/var/crash/vmcore.1.zst` on the next boot. 29 s later the root file system,
damaged by the first crash, panicked (`handle_written_inodeblock: Invalid link
count 65535`); `kern.sync_on_panic=0` and soft updates meant the saved vmcore
never reached disk, and the second panic's dump overwrote the dump device.

Fixed for next time: the guest now has `savecore_enable=NO` and
`/etc/rc.local` saves a pending dump to `/mnt/host/crash/frrtopo/` (the host
share, on ZFS) once the late 9p mount is up; `clear_tmp_enable=NO` keeps the
per-test logs. The root got `fsck_ffs -fy` from the host (unreferenced inodes
reconnected, one link count fixed), clean on a second pass.

## Next

Rerun recipe A until it recurs, then from the dump: the `rtentry` holding the
node with the NULL child (UMA state of that item), the fib and vnet of the
socket, and which test's jail zebra pid belonged to. An INVARIANTS kernel would
trash freed items (0xdeadc0de instead of NULL) and could catch the culprit
earlier, at the cost of not being the kernel the epoch wedge was seen on.
