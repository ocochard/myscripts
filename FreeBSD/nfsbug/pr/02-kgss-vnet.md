<!-- ron-dev PR text for pr/kgss-vnet (#4). First line = title, the rest = description. Open with: git switch pr/kgss-vnet && git pr main -->
kgssapi: Track gssd(8) per vnet

gssd runs per vnet, but the "gssd answered" flag was a global, and the
first answer raised the timeout of the one netlink handle shared by
all vnets to 300s.  Once a gssd answered in one vnet jail, an nfsd
starting in a vnet jail without gssd waited out that timeout on each
svc name registration, instead of 200ms, and did not serve.

Keep the flag and the retry time per vnet, and give the shared handle
its 5 minute timeout with 30 retries from the start.  Let clnt_nl give
a call that asks for less than one attempt of its handle a single
attempt of that length, so that the probe waits 200ms in every vnet,
while the other gssd upcalls, whose stubs ask for 25s, keep the 10s
attempts and the 5 minutes that some gssd calls need.  The other
netlink RPC clients ask for more than one attempt and do not change.

Measured with the NFS tests: after a Kerberos case ran (gssd answering in
a jail), the next server jail without gssd never served: its nfsd logged
"can't register svc name", and mounts failed with `NFSPROC_NULL: RPC:
Timed out` until the 300s test timeout. With the patch, the `basic`,
`two_clients` and `server_reset` cases pass after the Kerberos cases.

The other netlink RPC clients keep their behavior: rpcbind (60s handle,
6 tries, 60s calls) and rpc.tlsclntd/rpc.tlsservd (15s handle, 1 try, 25s
and 30s calls) never ask for less than one try. Not testable in the VM:
the ~27s gssd upcalls that e3c26ce5cb41 raised the limit for; the patch
keeps them at 10s tries for 5 minutes, as upstream.

Tested in a bhyve VM with `tests/sys/fs/nfs` (server and clients in vnet
jails), kernel = main plus all pending NFS jail changes, GENERIC-NODEBUG and
GENERIC (INVARIANTS, WITNESS): all 13 cases pass, no jail left dying, no
panic or KASSERT. The branch also builds alone on main (kernel and the
nfscommon, nfscl, nfsd, krpc, kgssapi and nfslockd modules). A per-commit
review found issues that are fixed in this version; the list and its
status are in the author's notes (review-2026-11-24.md).

Reviewers: rmacklem, glebius (clnt_nl)
PR: <Bugzilla number, from nfsbug/bugreport_kgss_vnet_upcall.md>
