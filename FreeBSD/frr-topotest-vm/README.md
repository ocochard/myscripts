# frr-topotest-vm

A bhyve guest for running the FreeBSD FRR topotests (FRR PR 23475), built so a
kernel panic is captured instead of losing the workstation.

## Why

The topotests drive VNET jails and `epair(4)` in tight create/destroy loops,
which is the path that panics -CURRENT. This workstation cannot capture such a
panic, and cannot be made to:

- No swap and no dump device (`dumpon -l` reports `/dev/null`).
- No room for one. `gpart show` leaves 7.5K free on nda0; the disk is EFI +
  Windows 268G + ZFS 195G + recovery 1.7G.
- Netdump cannot arm: `rge(4)`/RTL8125 has no `DEBUGNET` support. Verified —
  `dumpon -v -s ... -c ... rge0` answers *"Unable to configure netdump because
  the interface driver does not yet support netdump"* (exit 71). Only 8 drivers
  in the tree define `DEBUGNET_DEFINE`, and `rge` is not one of them.
- A ZFS zvol cannot be a dump device: `zvol_cdevsw` has no `.d_dump` and
  OpenZFS answers no `GEOM::kerneldump` attribute. Swap files are out for the
  same reason.

Inside a guest the virtual disk is a plain `vtbd`, so an ordinary
`freebsd-swap` slice *is* a dump device, and a panic costs a guest reboot.

## Use

```sh
sudo ./mkvm.sh                 # build /zroot/vm/frr-topotest.img (~4 min)
sudo ./runvm.sh                # run it; restarts the guest across panics
ssh -i ~/.ssh/id_ed25519_frrvm root@<guest>
```

The guest takes a DHCP lease with a fixed MAC, so `arp -an | grep
58:9c:fc:10:00:01` finds it after any reboot; the console log
(`/zroot/vm/frrtopo-console.log`) records the lease too. Console root password
is `topotest`; sshd is key-only.

Files exchange through a virtio-9p share: `/zroot/vm/share` on the host is
`/mnt/host` in the guest, mounted from `/etc/fstab` at boot.

## Verifying the dump path

`GENERIC-NODEBUG` keeps KDB and DDB (`std.nodebug` only drops INVARIANTS and
WITNESS), so the whole path can be tested on demand:

```sh
ssh root@<guest> 'sync; sysctl debug.kdb.panic=1'
```

Measured: `Dumping 589 out of 16342 MB`, guest back on the network 28 seconds
later, `savecore` writing `/var/crash/vmcore.0`.

Debug host-side — the guest runs a copy of THIS host's kernel, so the host's
own symbols match the guest's core with nothing to line up:

```sh
cp /var/crash/vmcore.0 /mnt/host/crash/        # in the guest
echo bt | sudo kgdb -q /usr/lib/debug/boot/kernel/kernel.debug \
    /zroot/vm/share/crash/vmcore.0             # on the host
```

Module symbols resolve too (`if_epair.ko`, `if_bridge.ko`), which is what the
VNET panics need.

## Things that cost real time — do not undo them

- **The nmdm B side must be raw with echo off.** It is a tty, and a plain `cat`
  reader (unlike `cu`) leaves echo on, so every byte the guest prints comes
  back to it as console input. That feedback loop parks the loader at the `OK`
  prompt echoing itself (55 MB of "unknown command") and makes `getty` answer
  its own banner with "Login incorrect". `runvm.sh` runs `stty raw -echo`
  before every boot and drains the queue.
- **`beastie_disable`/`autoboot_delay=0`** — with `0`, loader.conf(5) boots
  immediately *"unless a key has already been pressed"*, and nmdm keeps stale
  keystrokes queued across VM restarts.
- **No `/boot/kernel.old` in the image.** `defaults/loader.conf` lists
  `kernels="kernel kernel.old"`, and the host's `kernel.old` is from March. A
  guest that falls back to it runs a March kernel under a September userland:
  casper fails with `Invalid pdflags at fork 0x4` (PD_NOWAITPID postdates it),
  `dhclient` dies on SIGSEGV, no network.
- **`newfs -j`, not `-U`, plus `background_fsck="NO"`.** This guest exists to
  panic; a soft-updates root that crashes gets mounted rw while a background
  fsck is still repairing it.
- **The guest is a copy of the running host, not `make installworld`.**
  `/usr/src` and `/usr/obj` are read-only NFS from bigone and the obj tree is
  older than the source, so install rules try to rebuild and die on the
  read-only mount (`bsdxml.h`, then `cc: not found`).
- **`runvm.sh` waits for `/dev/vmm/$VM` to disappear** before starting the next
  bhyve after a guest reset.

## Scripts

| script | runs on | does |
| --- | --- | --- |
| `mkvm.sh` | host | builds `/zroot/vm/frr-topotest.img` from the running host |
| `runvm.sh` | host | boots it, restarts it across panics, logs the console |
| `sync-frr.sh` | host | ships `~/frr` in over 9p and builds it in the guest |
| `guest-build-frr.sh` | guest | bootstrap + configure + gmake install |
| `guest-pimsweep.sh` | guest | runs every PIM test one at a time, crash-resumable |
| `hammer-run.sh` | guest | drives either wedge probe under load, stops on a stall |
| `hammer-epoch-drain.c` | guest | clone+destroy an interface: `if_detach_internal` -> epoch drain |
| `hammer-sched-bind.c` | guest | `sched_bind(9)` only, through `cpuctl(4)`, no network stack |
| `hammer-vnet-move.c` | guest | VNET jail + epair + `SIOCSIFVNET`: `if_vmove_loan()`, the reported frame |
| `hammer-epoch-churn.c` | guest | net-epoch callback producers (ifa, mcast, route, bpf, bridge), `hammer-run.sh -c` |
| `BUG-rtsock-rn_match-panic.md` | - | a second panic hit during recipe A: rtentry use-after-free, root-caused and patched |
| `hammer-rt-mpath-race.c` | guest | multipath append vs delete race: panics a stock kernel in ~5 s |
| `route_ctl-mpath-uaf.patch` | - | the fix, against FreeBSD main |
| `ddb-on-wedge.sh` | host | waits for the wedge, then collects DDB state over the console |

Typical cycle:

```sh
sudo ./mkvm.sh && sudo ./runvm.sh &     # once
./sync-frr.sh                            # after every change to ~/frr
ssh -i ~/.ssh/id_ed25519_frrvm root@<guest> 'nohup sh /mnt/host/guest-pimsweep.sh &'
```

`guest-pimsweep.sh` writes the test it is about to run to `/root/pim-current`
and `sync`s first, so after a panic that file names the culprit; finished tests
land in `/root/pim-results` and are skipped when the script is re-run, so a
sweep resumes where the crash stopped it.

## PIM on FreeBSD needs ip_mroute

`GENERIC` does not set `MROUTING`; it lives in `ip_mroute.ko` and nothing loads
it. Without it `MRT_INIT` returns `EOPNOTSUPP`, pimd's mroute socket stays at
`-1`, and since pimd reads IGMP from that socket (`pim_mroute.c`,
`process_igmp_packet`), every PIM test fails having learned no groups — with
nothing in the output saying why. The guest's `kld_list` carries it.

## Open: `ifconfig <epair> vnet <jid>` can hang

Seen once (2026-10-02, kernel `main-n289791-a2fbd988638e`) during topotest
*setup*, while munet was adding links:

```
/sbin/ifconfig epair0a vnet 5    state RJ, 0:00.00 CPU, 14+ minutes
mi_switch <- sched_ule_bind <- epoch_drain_callbacks <- if_detach_internal
          <- ifioctl <- kern_ioctl <- sys_ioctl
```

Every `softirq_N` gtaskqueue thread was idle, so no epoch callback work was
pending, yet the drain never returned. The stuck thread holds the ifnet sx
lock, so every subsequent interface operation blocks behind it
(`_sx_xlock_hard <- ifioctl`) and `reboot` cannot complete either.

**Recovery:** `sudo bhyvectl --force-reset --vm=frrtopo`. The guest root is
`newfs -j` with foreground fsck, so a hard reset is safe.

**Probes:** `hammer-epoch-drain.c` hammers the drain itself
(`if_detach_internal()` runs on every interface destroy, so no jail or epair is
needed) and `hammer-sched-bind.c` hammers `sched_bind(9)` alone through
`cpuctl(4)`; `hammer-run.sh` runs either under load and stops on a stall.
Both have now been run against the wedging kernel and **neither reproduces**:
2.1 billion binds in 30 minutes, and 177,770 interface create/destroy cycles
(~49 drains/s) in an hour on an oversubscribed guest. So neither half of the
stuck frame is sufficient on its own. `hammer-vnet-move.c` adds what they
lack (`if_vmove_loan()` and VNET jail teardown, i.e. the reported operation
itself) and **does not reproduce either**: 21,785 jail + epair + `SIOCSIFVNET`
+ `jail_remove` cycles in an hour, 12 workers and 8 spin hogs on 12 vCPUs. Adding
independent callback producers (`hammer-epoch-churn.c`: addresses, routes,
multicast, bpf, bridge members, in vnet0 and in VNET jails) at ~550,000
net-epoch callbacks/s, ~470x what the vnet hammer queues by itself, made the
drains ~25x slower but **still no wedge** in an hour (644 iterations). Nor
do binds that must wake a halted vCPU (the dump's condition: bound to a CPU
while others sat idle): 64 million of them in 30 minutes, each a real IPI to a
vCPU in `hlt` per bhyve's counters, none lost. Every isolated ingredient has
now been hammered; the next step is recipe A again, fully instrumented. See recipe C in
`BUG-epair-vnet-epoch-hang.md`.

The older `epair-vnet-hang.sh` loops jail-create + epair-create +
`ifconfig ... vnet` with a 60s watchdog, recording the iteration before each
attempt so a hang names it. It survived 300 iterations, and the test that
exposed the hang has since run twice cleanly — the bare operation is not
enough, it needs the churn of a real topology. Unreproduced on demand; not
worth reporting upstream until it is.

Unrelated to the fib_algo panic, which is fixed (see below).

## Fixed: the fib_algo VNET panic

`panic: page fault` / `_rm_wlock <- softclock_call_cc` with
`c_func = handle_fd_callout` and `c_lock = fd_rh->rib_lock` was
`rt_table_destroy()` skipping `fib_destroy_rib()` because removing
`opt_route.h` from `sys/net/route.c` left it without `FIB_ALGO`. Fixed by
`e9c3a9fad530` (2026-09-30), `Fixes: 254b23eb1f5`.

Verify the fix is compiled in rather than merely present in the source:

```sh
nm /usr/obj/usr/src/amd64.amd64/sys/GENERIC-NODEBUG/route.o | grep fib_destroy_rib
# must print:  U fib_destroy_rib
```

Pre-fix dumps are kept in `/zroot/vm/share/crash/` (`vmcore.1`, `vmcore.2`).
