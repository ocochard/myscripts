# #10: a Kerberos NFS server jail stays dying forever

Patch: part of [`nfsd_jail_state.patch`](nfsd_jail_state.patch), against
main 6edecf52def6: #9 and #10 are one commit, 9b8e54c993f0, on branch
`nfsd-jail-dying` in `~/freebsd-src-nfsddying` (squashed 2026-11-22). Not
committed upstream, not filed. Touches the krpc RPCSEC_GSS code: needs review by
rmacklem.

Read [`nfsd_jail_state.md`](nfsd_jail_state.md) (#9) first: same cycle, other
holder.

## 1. Background

**RPCSEC_GSS server contexts.** For each Kerberos client, the kernel's
RPCSEC_GSS server code keeps a context (`struct svc_rpc_gss_client`) in a
per-vnet list. The context keeps the client's mapped credential (`cl_cred`),
built in the service's jail (`rpc_gss_svc_getcred()`: `prison_hold()`), so it
holds a reference on that jail.

**When contexts go away.** `svc_rpc_gss_timeout_clients()` frees expired
contexts, but it runs only when a new request arrives. The per-vnet cleanup
at `vnet_destroy()` frees the list's array.

## 2. The problem

With #9, the three Kerberos cases of the NFS tests still left their server
jail dying, each with `ref = 1`. A dying jail gets no request, so its
contexts never expire, and `vnet_destroy()` needs the jail freed first: the
same cycle as #9.

Also, `svc_rpc_gss_vnet_cleanup()` freed only the array of lists, never the
contexts in it, so their credentials leaked.

## 3. The fix

- A jail removal hook (`PR_METHOD_REMOVE`, registered with
  `osd_jail_register()` at load) has every context of a removed vnet jail
  forgotten, from a task on `taskqueue_thread` that holds a reference on
  the jail. Jails without their own vnet are skipped: they use their
  parent's; so are jails without contexts.
- `svc_rpc_gss_vnet_cleanup()` forgets the contexts too, before freeing the
  array.

Contexts are reference counted: a service thread that still uses one keeps
it until it lets go, as with the timeout code. So the cleanup is safe while
the jail's nfsd still runs.

Why a task: the hook runs with `allprison_lock` held exclusively. Freeing a
context still being set up (`ctx->handle` set; `kgss_transfer_context()`
clears it only once setup completes) calls up to gssd
(`gss_delete_sec_context()`), and waiting for that RPC under
`allprison_lock` would stall every jail operation on the host. A first
version did the work in the hook itself; a local review against the
callees found it. Module unload waits for pending tasks.

Alternative: call a GSS cleanup from nfsd's exit path (#9). nfsd reaches
kgssapi only through function pointers, and it would cover nfsd only.

## 4. Tested

See the table in [`nfsd_jail_state.md`](nfsd_jail_state.md): with #9 alone 3
Kerberos server jails stayed dying after the suite; with #9 and #10, none,
on GENERIC-NODEBUG and on GENERIC with WITNESS, with the `krb5`, `krb5i` and
`krb5p` cases passing.

Untested: a Kerberos service in a jail without its own vnet, other
RPCSEC_GSS services than nfsd, unloading kgssapi.


## Review 2026-11-24

A per-commit review (see [`review-2026-11-24.md`](review-2026-11-24.md))
found the issues below in this patch; the text above describes the fixed
version. Retested afterwards: all 13 cases of `tests/sys/fs/nfs` on
GENERIC-NODEBUG and GENERIC with WITNESS, no jail left dying, no panic.

- D2: the hook took `svc_rpc_gss_lock` shared under `allprison_lock`, and
  that lock is held exclusively across gssd upcalls. Fixed: the hook takes
  no lock and queues the task for every vnet jail.
- D3: a context created after the hook ran (nfsd still serving) was never
  freed. Fixed: `svc_rpc_gss_create_client()` refuses new contexts in a
  dying jail (AUTH_REJECTEDCRED). Not testable in the VM.
