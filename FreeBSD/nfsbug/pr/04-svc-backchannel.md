<!-- ron-dev PR text for pr/svc-backchannel (#8). First line = title, the rest = description. Open with: git switch pr/svc-backchannel && git pr main -->
krpc: Keep backchannel transports registered across svcpool_close()

An NFSv4.1 mount registers its backchannel transport in the callback
pool once, at connect.  svcpool_close() at nfscbd(8) exit unregistered
it for good, so after an nfscbd restart every recall on an older mount
was dropped, and the conflicting open waited for the server to revoke
the delegation, 255s with nfsd.

Mark the backchannel transports and keep them registered on close;
their mount still unregisters them.  A service thread that exits now
gives back the transport assigned to it, instead of leaving it pointing
at the freed thread.

Measured with a host client and nfscbd (no jail needed): recall on a mount
older than an nfscbd restart 255s -> 0s; recall while nfscbd is down
completes when nfscbd starts again; unmount while nfscbd is down, restart,
new mount: 0s.

Tradeoff: the new `xp_backchannel` field changes the `SVCXPRT` layout, so
an out-of-tree RDMA module must be rebuilt, and an MFC needs care for the
KBI. An RDMA backchannel from that module is not marked and behaves as
before.

Tested in a bhyve VM with `tests/sys/fs/nfs` (server and clients in vnet
jails), kernel = main plus all pending NFS jail changes, GENERIC-NODEBUG and
GENERIC (INVARIANTS, WITNESS): all 13 cases pass, no jail left dying, no
panic or KASSERT. The branch also builds alone on main (kernel and the
nfscommon, nfscl, nfsd, krpc, kgssapi and nfslockd modules). A per-commit
review found issues that are fixed in this version; the list and its
status are in the author's notes (review-2026-11-24.md).

Reviewers: rmacklem
PR: <Bugzilla number, from nfsbug/BUGREPORT-svc-backchannel.txt>
