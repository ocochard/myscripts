# #7: NFSv4.1 callbacks from an nfscbd in a jail

Patch: [`nfscbd_jail.patch`](nfscbd_jail.patch), against main 6edecf52def6.
Branch `nfscbd-jail` in `~/freebsd-src-nfscbdjail`, commit b2016b20d2a9.
Not committed upstream, not filed.
Needs review by rmacklem.

## 1. Background

**Delegations.** An NFSv4 server can hand a client a *delegation* on a file:
a promise that nobody else will change it. The client can then cache the
file and its attributes without asking the server. When another client opens
the file in a conflicting way, the server *recalls* the delegation: it sends
the holder a CB_RECALL request and waits for it to give the delegation back.

**Callbacks.** So, for delegations, the server must be able to call the
client. In NFSv4.1 the server sends these callbacks on the client's own TCP
connection, in the opposite direction (the *backchannel*). The server first
checks the path with a CB_NULL call, and issues delegations only once it
succeeds (`LCL_CALLBACKSON`, shown as `CB` by `nfsdumpstate(8)`). NFSv4.0 used
a separate connection from server to client; the FreeBSD client no longer
offers it (71ac1ec5c9d9), so NFSv4.0 gets no delegations at all.

**nfscbd.** On a FreeBSD client, `nfscbd(8)` serves callbacks. It starts the
kernel's callback pool of threads (`nfscbd_pool`) and adds sockets to it with
`nfssvc(NFSSVC_CBADDSOCK)`. A pool runs an RPC *program* only once it has
been registered on it with `svc_reg()`; for callbacks that is program
0x40000000 (`NFS_CALLBCKPROG`).

## 2. The problem

With `nfscbd` running in the client's vnet jail, the server never issues a
delegation. Measured in a bhyve VM, server and client in vnet jails:

```
Flags         OpenOwner      Open LockOwner      Lock     Deleg ...
                      3         0         0         0         0 ...   <- no CB
```

A capture on the bridge shows why: the server sends CB_NULL on the
backchannel, and the client answers PROG_UNAVAIL (accepted, status 1).
The server logs `aft newnfs_request=13` (EACCES) and leaves callbacks off.

The cause is where the program gets registered. `svc_reg()` was called only
in `nfscbd_addsock()`, for each socket that `nfscbd` adds:

1. `nfscbd` first adds a UDP socket. In a jail, `svc_dg_create()` refuses
   it (`if (jailed(...)) return (NULL)`, from 6a76d35cac8e, which lets nfsd
   run in a jail over TCP only). So `svc_reg()` is never reached.
2. `nfscbd_addsock()` still returns 0, so the caller sets
   `nfscl_enablecallb`, and the client offers a backchannel at
   CREATE_SESSION.
3. The TCP listener adds a socket only when a server connects to it, which
   NFSv4.1 never does.

So the pool serves no program, and every callback is refused. On the host,
step 1 succeeds and registers the program as a side effect; and since the
pool is one global, a host `nfscbd` also made callbacks work for jailed
clients, which hid the bug.

## 3. The fix

- `nfscbd_nfsd()`, which runs the pool, registers the program on the pool
  itself before `svc_run()`, and enables callbacks there. `svc_reg()` needs
  a transport only to find the pool, so a temporary backchannel transport
  is used and released at once. This runs at each `nfscbd` start, because
  `svcpool_close()` removes the registrations when `nfscbd` exits.
  Callbacks are enabled only if that registration succeeds.
- `nfscbd(8)` skips the UDP socket in a jail, which the kernel cannot serve
  there anyway.
- `rc.d/nfscbd` is `nojailvnet` instead of `nojail`, as `rc.d/nfsd`, so
  `nfscbd_enable` works in a vnet jail.

Alternatives:

- **An error from `nfscbd_addsock()` for the refused UDP socket.** A first
  version did this; the 2026-11-24 review found that it made an older
  `nfscbd` binary exit in a jail, although the pool registration already
  serves it. Removed.
- **A pool-level `svc_reg()` variant in the krpc.** Cleaner than the
  temporary transport, but it changes the krpc interface for one caller.
- **Run `nfscbd` on the host.** Works today, but serves every jail from the
  host and hides the bug.

Design limit, not changed: the callback pool is one for the whole host, so
a jailed `nfscbd` also serves the host's NFSv4.1 mounts, and they lose
their callbacks when that jail stops.

The callback pool stays one global: one `nfscbd`, on the host or in any jail,
serves the callbacks of every vnet.

## 4. Tested

bhyve VM, GENERIC-NODEBUG, main 6dc19a71f70c with #3, #4 and #5, server and
clients in vnet jails, NFSv4.1:

| | stock | with #7 |
|---|---|---|
| `nfscbd` in client jail c1: server `CB` flag, delegation on read | no, 0 | yes, 1 |
| c2 opens the file for writing: recall | not reached | write done in 0 s, c1 returned it |
| `nfscbd` on the host, host client (regression) | delegation, recall in 0 s | same |
| `delegation_test:recall` (draft test) | failed: no delegation | passed |
| full `tests/sys/fs/nfs` suite | passed | passed (`session_leak`: expected failure, #6) |

Found on the way, not caused by #7: after `nfscbd` is restarted, recalls on
older mounts are dropped and the conflicting open waits 255 s, on the stock
kernel too. Measured and fixed in #8, see
[`svc_backchannel.md`](svc_backchannel.md).

Untested: Kerberos callbacks (`nfscbd -P`), pNFS layout recalls, a WITNESS
kernel.


## Review 2026-11-24

A per-commit review (see [`review-2026-11-24.md`](review-2026-11-24.md))
found the issues below in this patch; the text above describes the fixed
version. Retested afterwards: all 13 cases of `tests/sys/fs/nfs` on
GENERIC-NODEBUG and GENERIC with WITNESS, no jail left dying, no panic.

- C2: the EPERM for the refused UDP socket, removed.
- C3: `rc.d/nfscbd` was `nojail`. Fixed.
- C4: `svc_reg()`'s result was ignored. Fixed.
