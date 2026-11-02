# kgssapi: one gssd in one vnet makes nfsd hang in every other vnet

Summary: kgssapi: once gssd answers in one vnet, upcalls from vnets without
gssd wait for minutes, so nfsd in such a jail does not serve.

Product: Base System. Component: kern. Version: 16.0-CURRENT (main
584f44221f45).

Patch: `kgss_vnet.patch`, against main 7868958f5c79.

## 1. Background

**gssd upcalls.** The kernel's GSS-API code (`sys/kgssapi`) does not do
Kerberos itself. It sends RPCs to the userland daemon gssd(8). The
transport is netlink, and a call reaches the gssd listening in the *current
vnet*: `clnt_nl_call()` asserts `curvnet` and builds the request with
`.cr_vnet = curvnet` (`sys/rpc/clnt_nl.c:271-278`). So each vnet jail has
its own gssd, or none. The handle `kgss_gssd_handle` is one global since
4602d45eb3b1 ("kgss: de-virtualize kgss_gssd_handle").

**Two timeouts.** `kgss_gssd_client()` (`sys/kgssapi/gss_impl.c:241`) works
in two phases:

1. Until gssd has answered once, every call is preceded by a Null RPC with a
   200 ms timeout. A failure returns NULL at once, and the next try is held
   off for 5 s. The caller sees "no gssd" quickly.
2. After the first successful Null RPC, the handle timeout becomes 300 s
   with 30 retries, and the Null RPC is no longer sent. The point is to
   ride out a gssd restart.

Both timeouts are set on the handle with `CLSET_TIMEOUT`, because a netlink
handle ignores the timeout of each call. `client_nl_create()` gives every
handle `nl_timo = 60 * hz` (`sys/rpc/clnt_nl.c:202`), and `clnt_nl_call()`
uses the per-call timeout only when `nl_timo` is 0
(`sys/rpc/clnt_nl.c:335-337`). So the timeout of the shared handle applies
to every vnet.

The switch is recorded in two function-local statics:

```c
static time_t nextrpc = 0;
static bool done_upcall = false;
```

**nfsd and gssd.** When nfsd starts, `nfsrvd_nfsd()` registers its Kerberos
name with `rpc_gss_set_svc_name_call()` three times, for NFSv2, 3 and 4
(`sys/fs/nfsserver/nfs_nfsdkrpc.c:667-678`). It does this whenever kgssapi
is loaded, before `svc_run()`. Each call goes through `kgss_gssd_client()`.
455c354dd4db made this fast when no gssd runs at all.

## 2. The problem

`done_upcall` is global, but gssd is per vnet. After gssd answers in any
vnet, every vnet is in phase 2. An upcall from a vnet jail without gssd then
waits for a reply that will never come: 300 s, with retries. A jailed nfsd
started after that blocks in `rpc_gss_set_svc_name_call()` and serves
nothing.

How to repeat it (bhyve VM, kernel with `options KGSSAPI`; `kgssapi.ko`
behaves the same):

1. Start a vnet jail with allow.nfsd and gssd, and use it once. Any
   Kerberos NFS mount does it; so does nfsd's own name registration.
2. Remove it, then start a second vnet jail with allow.nfsd and no gssd,
   running `mountd -R` and `nfsd -t`.
3. Mount it from the host:

   ```
   nfsd: can't register svc name nfs@srv.nfstest.test jid:3
   ```

   The mount never succeeded: the test retried every 2 s, and the test body
   timed out after 300 s. The same server setup on a kernel without
   kgssapi serves at once.

Found by the tests/sys/fs/nfs framework: running `krb5_test` first made
the plain `basic_test` fail with `NFSPROC_NULL: RPC: Timed out`.

## 3. The fix

`kgss_vnet.patch`, two files:

```diff
+VNET_DEFINE_STATIC(bool, kgss_gssd_seen);
+VNET_DEFINE_STATIC(time_t, kgss_nextrpc);
...
-	clnt_control(cl, CLSET_RETRIES, &(int){30});
-	clnt_control(cl, CLSET_TIMEOUT, &nulltimo);
+	clnt_control(cl, CLSET_TIMEOUT, &(struct timeval){0});
...
-		    rpctimo);	/* rpctimo is ignored by clnt_nl_call(). */
+		    nulltimo);
...
-		CLNT_CONTROL(cl, CLSET_TIMEOUT, &rpctimo);
```

```diff
 	case CLSET_TIMEOUT:
-		nl->nl_timo = tvtohz((struct timeval *)info);
+		/* A zero timeout makes each call use its own. */
+		if (timevalisset((struct timeval *)info))
+			nl->nl_timo = tvtohz((struct timeval *)info);
+		else
+			nl->nl_timo = 0;
```

- **Whether gssd answered becomes per vnet.** It is now
  `V_kgss_gssd_seen`, and `V_kgss_nextrpc` replaces `nextrpc`. Each vnet
  probes its own gssd with the 200 ms Null RPC until it answers once.
- **The shared handle no longer carries a timeout.** Setting a timeout on
  it for one vnet would change it for all of them. clnt_nl gets a way to
  say "use the timeout of each call": `CLSET_TIMEOUT` with a zero timeval.
  The probe passes 200 ms. The other upcalls pass the 25 s that the
  rpcgen stubs use (`static struct timeval TIMEOUT = { 25, 0 }` in the
  generated `gssd_clnt.c`).
- **No retry.** The handle keeps the clnt_nl default of one try. With 30
  retries and no handle timeout, each try would get 25/30 s, and a slow
  `init_sec_context` (it may contact the KDC) would be sent again before
  gssd answered.
- **Callers already have to set `curvnet`.** `clnt_nl_call()` reaches
  `V_nl_ctl` through `nl_send_group()`, so the new `V_` accesses add no
  requirement.

The first version made only the two statics per vnet. It did not fix
anything: the probe still waited 60 s in a vnet without gssd, because the
handle's default `nl_timo` overrode its 200 ms. A procstat of the stuck
nfsd showed it:

```
_sleep clnt_nl_call clnt_call_private kgss_gssd_client gss_import_name
rpc_gss_acquire_svc_cred rpc_gss_set_svc_name nfsrvd_nfsd
```

Tradeoff: in a vnet whose gssd answered once and then died, an upcall now
waits 25 s, not 300 s with retries. The 5-minute window was meant for a
gssd that starts late at boot; the 5 s re-probe from 455c354dd4db covers
that now, and with this patch it works per vnet.

Alternatives:

- **Report "no listener" from netlink.** `nl_send_group()` would return
  false when no socket of the vnet is in the group, and `clnt_nl_call()`
  would fail at once. That is the cleanest signal, but it changes a return
  value that every netlink group sender sees (`netlink_domain.c:242-250`).
- **Per-vnet handles.** This undoes 4602d45eb3b1. `client_nl_create()` also
  refuses a second group with the same name.
- **Keep 300 s for the normal upcalls.** That would need a per-call
  timeout in `struct rpc_callextra` (a KBI change), or a different
  timeout in the rpcgen stubs.

What the patch does NOT change: rpctls and rpcbind never pass a zero
timeout to `CLSET_TIMEOUT`, so their netlink handles behave as before.

## 4. Tested

bhyve VM, GENERIC (INVARIANTS, WITNESS) plus `options KGSSAPI`,
`device epair`, `device if_bridge` and `options NULLFS`, on main
7868958f5c79 with `kgss_vnet.patch`. The kernel also had
`nfscl_jail.patch`, which the Kerberos tests need for jailed clients.
These are the tests/sys/fs/nfs cases, with the framework's gssd
workaround removed, run in this order in one boot:

| Case | Unpatched | First version (statics only) | Patched |
|---|---|---|---|
| krb5_test:krb5 (a gssd answers in a jail) | failed for the TMPDIR reason, but its gssd answered | passed | passed |
| basic_test:basic (server jail without gssd) | failed: `NFSPROC_NULL: RPC: Timed out` | failed: same | passed |
| basic_test:two_clients | failed: same | failed: same | passed |
| recovery_test:server_reset | not run | failed: same | passed |
| krb5_test:krb5i, krb5p | not run in this order | passed | passed, twice each |

The patched krb5i/krb5p result comes from a second boot. In the first boot
krb5i failed because the test wrote before tcpdump was capturing, a test
bug fixed since.

"Unpatched" is 584f44221f45 + nfscl_jail.patch + KGSSAPI. The TMPDIR
problem was in the test, not the kernel, and is fixed in the framework.
The unpatched kernel was GENERIC-NODEBUG; the other two, GENERIC.

The `kgssapi` module builds with the patch (`MODULES_OVERRIDE=kgssapi`,
`-Werror`). WITNESS reported two lock order reversals, neither in this code:
tmpfs/ufs on nullfs unmount, and `in_control`/`ifnet_sx` in
`vnet_destroy()`.

Untested:

- `kgss_vnet.patch` without `nfscl_jail.patch`. Only the Kerberos tests
  need jailed clients.
- The module loaded on a real system.
- A gssd killed and restarted while upcalls are pending.
- A KDC that answers slowly enough to approach 25 s.
