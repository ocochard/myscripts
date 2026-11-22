# #9: an NFS server jail stays dying forever

Patch: [`nfsd_jail_state.patch`](nfsd_jail_state.patch), against main
6edecf52def6, one commit with #10, f5ab46ed04b0, on branch `nfsd-jail-dying` in
`~/freebsd-src-nfsddying`. Not committed upstream, not filed. Needs review
by rmacklem. The Kerberos variant of the same problem is #10,
[`gss_jail_remove.md`](gss_jail_remove.md).

## 1. Background

**Dying jails.** `jail -r` kills a jail's processes and marks it *dying*. The
jail is freed, with its network stack (its *vnet*), only when the last
reference on it goes. Every credential (`struct ucred`) of a process in the
jail holds such a reference, so a credential kept anywhere in the kernel
keeps the jail around.

**The NFSv4 server's client records.** For each client, nfsd keeps a record
(`struct nfsclient`) with its opens, locks and delegations. The record keeps a
credential for callbacks to the client (`lc_req.nr_cred`, taken from the
request at SETCLIENTID or EXCHANGE_ID). The server builds request credentials
in its own jail (`svc_getcred()`: `prison_hold()`), so each record holds a
reference on the server's jail.

**When records go away.** An NFSv4.1 client sends DESTROY_CLIENTID at unmount,
which frees its record. NFSv4.0 has no such operation; its record stays until
the lease has been expired for 5 leases (720 s) *and* an nfsd handles a
request. Stopping nfsd keeps the records, on purpose: a restarted nfsd keeps
serving its clients. The records of a vnet are finally freed by
`nfsrv_cleanup()`, which runs from `vnet_destroy()`.

## 2. The problem

`vnet_destroy()` runs only once the jail's last reference is gone, and a
record holds one. So a server jail that still has a client record when it is
removed stays dying forever, with its vnet. Each run of the NFS tests left up
to 7 such jails.

Measured in a bhyve VM (server and clients in vnet jails), time for the
server jail to go away after `jail -r`:

| scenario | client records | server jail | `show prison` (DDB) |
|---|---|---|---|
| NFSv4.1 client, clean unmount | 0 | gone at once | |
| NFSv4.0 client, clean unmount | 1 | still dying after 971 s | `ref = 1`, `uref = 0` |
| NFSv4.0, nfsd kept running 900 s first | 1 after 900 s | still dying | `ref = 1` |
| client jail removed before its unmount | 1 | still dying | `ref = 1` |
| server removed while the client is mounted | 1 | still dying | `ref = 1` |

Every dying server jail had exactly one reference and one client record.

A second bug sits on the same path: `nfsrv_throwawayallstate()`, used by
`nfsrv_cleanup()`, freed each record with `free()` alone. It never released
the credential, the callback connection or the address, never removed the
record from its hash list, and never updated the client counters, unlike
`nfsrv_zapclient()`.

## 3. The fix

- `nfsrv_throwawayallstate()` removes each record from the hash and frees it
  with `nfsrv_zapclient()`, as the client expiry code does.
- `nfssvc_nfsd()`, when the last nfsd of a vnet exits and the timer callout
  is drained, throws the client state away if its jail is dying: a dying
  jail can never run nfsd again, so the state can never be used. A host
  nfsd, or one in a live jail, keeps its state across a restart as before.
- If nfsd was stopped before the jail is removed, no nfsd exits during the
  removal. A jail removal hook (`PR_METHOD_REMOVE`, registered at module
  load) then throws the state away when no nfsd runs in the vnet and it
  has clients. The hook runs while the jail's processes are still alive,
  so `nfsrvd_nfsd()` refuses to start an nfsd in a dying jail; both check
  under `NFSD_LOCK`, so either the hook sees the nfsd and leaves the state
  to its exit, or the nfsd sees the jail dying.
- Both paths free the state with `nfsrv_throwawaydyingstate()`, under the
  exclusive `nfsv4rootfs_lock`, as the admin revoke code does, since
  `nfsdumpstate` may still run in the jail. It frees only the clients and
  lock files of the vnet, not the pNFS layouts and device IDs, which are
  global; `nfsrv_throwawayallstate()` still frees those at vnet destroy.

Alternatives:

- **The hook alone.** An nfsd may still run when it is called, so it would
  have to wait for the nfsd to exit.
- **No credential in the record.** The callback code needs it to find the
  vnet of the client connection.

The hook does not free the state itself: it holds a reference on the jail
and queues the work on `taskqueue_thread`. The hook runs with
`allprison_lock` held, and an nfsd thread can hold a shared reference on
`nfsv4rootfs_lock` (for a whole compound, `nfsrvd_compound()`) while it
needs `allprison_lock`: a LOOKUP into a ZFS `.zfs/snapshot/` mounts the
snapshot, and `vfs_exjail_clone()` takes `allprison_lock` shared. Waiting
for the exclusive lock in the hook could deadlock with it, so the task does
that wait without `allprison_lock`, then releases the jail. Module unload
waits for pending tasks (`taskqueue_quiesce()`). Found by reading the code,
not reproduced (the VM uses UFS).

## 4. Tested

bhyve VM, main 6dc19a71f70c with #3, #4, #5, #7, #8, #9 and #10, NFSv4.0 and
NFSv4.1, server and clients in vnet jails:

| | stock | #9 | #9 + #10, NODEBUG | #9 + #10, GENERIC (WITNESS) |
|---|---|---|---|---|
| NFSv4.0 clean unmount: server jail | dying forever | gone at 0 s | gone at 0 s | gone at 0 s |
| client jail removed first / server removed while mounted | dying forever | gone at 70 s | gone at 70 s | gone at 70 s |
| nfsd restart in a live jail: record kept, I/O after | | yes | yes | yes |
| NFSv4.0, nfsd stopped before `jail -r` (with the hook) | dying forever | | gone at 0 s | gone at 0 s |
| NFSv4.1 still mounted, nfsd stopped, `jail -r` | | | gone after 598 s | |
| server jails dying after the full suite + 70 s | 7 | 3 (Kerberos, #10) | 0 | 0 |
| full `tests/sys/fs/nfs` suite | | passed | passed | passed |
| panic, KASSERT | | none | none | none |

The 70 s is likely TCP TIME_WAIT (2 x MSL) of the server's connections; not
measured. The 598 s case is TCP too: stopping nfsd closed its end, the live
client kept its own open, and the server's socket stayed in `FIN_WAIT_2`
(seen with `netstat`) holding the jail until TCP gave up on it; no NFS
state was left. WITNESS showed only `ifnet_sx` -> `in_control` and `ufs` -> `tmpfs`,
seen before this patch too.

Untested: NFSv3 and NLM, pNFS, delegations held at removal, the start guard
(it needs a process left in a jail that is already dying).
