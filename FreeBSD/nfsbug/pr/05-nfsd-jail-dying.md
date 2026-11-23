<!-- ron-dev PR text for pr/nfsd-jail-dying (#9 + #10). First line = title, the rest = description. Open with: git switch pr/nfsd-jail-dying && git pr main -->
nfsd, rpcsec_gss: Free the state of a removed vnet jail

A removed vnet jail running nfsd stayed dying forever when the server
still had a client record, after an NFSv4.0 client or a client gone
without DESTROY_CLIENTID, or a Kerberos context: both keep a credential
of the jail, and were freed only at vnet destroy, which waits for the
jail to go away.

When the last nfsd of a dying jail exits, throw its client state away,
since the jail cannot run nfsd again.  When a vnet jail is removed with
no nfsd running, do the same from a jail removal hook, and refuse to
start an nfsd in a dying jail.  Free each record with nfsrv_zapclient(),
so that its credential, callback connection and counters are released
too.  Forget the RPCSEC_GSS server contexts of a vnet jail when it is
removed, and at vnet cleanup, which freed only their hash.

Measured: server jails left dying after the test suite, 7 -> 0. NFSv4.0
client, client jail removed first, server removed while mounted, nfsd
stopped before the removal: dying forever -> gone in 0 to 71s (the 70s
cases are likely TCP TIME_WAIT of the server's connections; not
measured). An nfsd restart in a live jail keeps its client state.
DDB `show prison` on the dying jails showed `ref = 1`, one per client
record or GSS context.

Both jail removal hooks do their work in a task that holds a jail
reference, because a hook runs with `allprison_lock` held exclusively:
freeing a GSS context still in setup calls gssd, and an nfsd thread that
mounts a ZFS snapshot during a compound needs `allprison_lock` while it
holds a reference on `nfsv4rootfs_lock`. Both found by reading the code,
not reproduced.

Tested in a bhyve VM with `tests/sys/fs/nfs` (server and clients in vnet
jails), kernel = main plus all pending NFS jail changes, GENERIC-NODEBUG and
GENERIC (INVARIANTS, WITNESS): all 13 cases pass, no jail left dying, no
panic or KASSERT. The branch also builds alone on main (kernel and the
nfscommon, nfscl, nfsd, krpc, kgssapi and nfslockd modules).

Reviewers: rmacklem
PR: <Bugzilla number, from nfsbug/BUGREPORT-nfsd-jail-dying.txt>
