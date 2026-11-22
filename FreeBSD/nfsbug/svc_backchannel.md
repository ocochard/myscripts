# #8: recalls lost after an nfscbd restart

Patch: [`svc_backchannel.patch`](svc_backchannel.patch), against main
6dc19a71f70c, on top of #7. Not committed, not filed. Touches the generic
krpc (`sys/rpc/svc.c`): needs review by rmacklem.

Read [`nfscbd_jail.md`](nfscbd_jail.md) first: it explains delegations,
callbacks, the backchannel and `nfscbd`.

## 1. Background

**Pools and transports.** The kernel RPC server code groups service threads
in a *pool*. Each connection the pool serves is a *transport* (`SVCXPRT`),
registered in the pool with `xprt_register()`. When a request arrives on a
transport, `xprt_active()` hands the transport to an idle thread.

**The callback pool.** The client's callbacks are served by `nfscbd_pool`,
whose threads are those of `nfscbd(8)`. For NFSv4.1 each mount has one
transport there, without a socket of its own: the *backchannel* of its TCP
connection to the server. It is registered once, when the mount connects
(`CLSET_BACKCHANNEL` in `sys/rpc/clnt_rc.c`), and unregistered at unmount
(`clnt_reconnect_destroy()`).

**Stopping a pool.** When `nfscbd` exits, its threads leave `svc_run()` and
`svcpool_close()` empties the pool, so that the next `nfscbd` starts clean:
it unregisters every transport and every program.

## 2. The problem

After `nfscbd` is stopped (SIGUSR1) and started again, a recall on a mount
made before the restart is never answered. The conflicting open waits
255 s. Measured in a bhyve VM, client and `nfscbd` on the host (no jail
needed), server in a vnet jail, stock kernel:

| | conflicting write |
|---|---|
| before the restart | 0 s |
| after the restart, same mount | 255 s |
| after the restart and a remount | 0 s |

A capture shows the server sending CB_COMPOUND on the backchannel 11 times in
20 s, with no reply; the client's `cbproc=` debug print never appears. After
2 x lease + 15 s = 255 s (`nfs_nfsdstate.c`) the server revokes the
delegation and lets the write through.

The cause: `svcpool_close()` also unregisters the mounts' backchannel
transports, and nothing registers them again. A recall still reaches the
client's connection, which queues it and calls `xprt_active()`; that sees an
unregistered transport and drops it ("Race with xprt_unregister - we lose").
A remount connects again and registers a new transport, which is why it
helps.

## 3. The fix

- `svcpool_close()` keeps transports without a socket registered. Only the
  backchannel makes such transports (`svc_vc_create_backchannel()`); it
  belongs to the mount, not to the service, so the mount stays its owner
  and still unregisters it at unmount. `svcpool_destroy()` keeps removing
  everything.
- A service thread that exits with a transport assigned to it now clears
  `xp_thread` and puts the transport back on the active list if it has a
  request. Before, the pointer was left on the freed thread. That was
  harmless while every transport was unregistered right after; a kept
  backchannel would have stayed stuck.

With the fix, a recall that arrives while `nfscbd` is down waits in the
transport until `nfscbd` starts again, instead of being dropped.

Alternatives:

- **Register the transport again when a call arrives** (`clnt_vc.c`). Stays
  in the client code, but registers from a socket upcall and races with
  `svcpool_close()` and the reference counts.
- **Document it** in `nfscbd(8)`: a restart needs a remount. No kernel
  change, but the stalls stay.

Tradeoff: the change is in the generic krpc. The nfsd pool uses
`svcpool_close()` too, but all its transports have sockets, so nothing
changes there.

## 4. Tested

bhyve VM, main 6dc19a71f70c with #3, #4, #5, #7 and #8, client and `nfscbd` on
the host, a second client in a vnet jail, server in a vnet jail, NFSv4.1:

| | stock (with #3 to #5) | #8, GENERIC-NODEBUG | #8, GENERIC (INVARIANTS, WITNESS) |
|---|---|---|---|
| recall on a mount older than the restart | 255 s | 0 s | 0 s |
| recall while `nfscbd` is down, started 10 s later | not tested | write done at +10 s | write done at +10 s |
| unmount while `nfscbd` is down, restart, new mount, recall | not tested | 0 s | 0 s |
| full `tests/sys/fs/nfs` suite with `recall` | | passed | passed |
| panic, KASSERT | | none | none |

Lock order reversals on the WITNESS kernel: `ifnet_sx` -> `in_control`
(`netinet/in.c`) and `ufs` -> `tmpfs` (mounting the jail roots); neither
involves an RPC or NFS lock. Not checked whether a stock WITNESS kernel shows
them too.

Untested: RPC-over-TLS mounts, pNFS data server sessions, unloading the
nfscl module after a close.
