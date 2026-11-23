<!-- ron-dev PR text for pr/nfscl-session-leak (#6). First line = title, the rest = description. Open with: git switch pr/nfscl-session-leak && git pr main -->
nfscl: Free the sessions that recovery replaced

When recovery replaces a session, nfsrpc_setclient() marks the old one
defunct but cannot free it, since RPCs in progress may still use it.
Nothing freed it later, so a mount kept one session per recovery until
unmount.

Count the requests that use a session, record when recovery replaced
it, and let the renew thread free a replaced session that nobody uses
2 * nfsc_renew later.

Measured: three server resets on one mount left 4 sessions (`vmstat -m`,
`NFSCL session`); with the patch, at most one after the 2 x nfsc_renew
grace. On AWS EFS (three mounts, 2.5 days) the count had grown from 37 to
256.

Tested in a bhyve VM with `tests/sys/fs/nfs` (server and clients in vnet
jails), kernel = main plus all pending NFS jail changes, GENERIC-NODEBUG and
GENERIC (INVARIANTS, WITNESS): all 13 cases pass, no jail left dying, no
panic or KASSERT. The branch also builds alone on main (kernel and the
nfscommon, nfscl, nfsd, krpc, kgssapi and nfslockd modules).

**Order:** Open after 06 has landed (the branch holds 06's commit below this one
until then; rebase onto main once 06 is in, so the PR has one commit).
This commit removes the `atf_expect_fail` of `recovery_test:session_leak`.

Reviewers: rmacklem
PR: <Bugzilla number, from nfsbug/BUGREPORT-session-leak.txt>
