<!-- ron-dev PR text for pr/nfscl-slot-session. First line = title, the rest = description. Open with: git switch pr/nfscl-slot-session && git pr main -->
nfscl: Free a slot on the session it was taken from

When a recovery replaced the MDS session while an RPC was in progress,
newnfs_request() (after RPC_CANTSEND, RPC_CANTRECV, RPC_SYSTEMERROR,
RPC_INTR or RPC_AUTHERROR) and nfsv4_freeunsentslot() freed the RPC's
slot on the new MDS session, which never gave that slot to it.  Another
RPC could lose its slot there, or "freeing free slot!!" was printed.

Record in the request the MDS session its slot comes from, and free the
slot there.  The BADSESSION retry, which moves the RPC to the new
session, updates it.  A session is freed only at unmount, so the pointer
stays valid for the whole RPC.  A flag marks it set, since
nfsrv_getuser() builds its request without nfscl_reqstart().

Found by code reading, while reviewing a patch that freed the replaced
sessions (dropped as too complex); not reproduced: it needs an RPC that
fails across a recovery, which a test cannot time.

Tested in a bhyve VM with `tests/sys/fs/nfs` (server and clients in vnet
jails), kernel = main plus the pending NFS jail changes, GENERIC-NODEBUG
and GENERIC (INVARIANTS, WITNESS): all 12 cases pass, `server_reset` and
`server_reset_twice` 3 runs each, no "freeing free slot!!", no panic or
KASSERT. The branch also builds alone on main (kernel and the NFS and RPC
modules).

**Order:** none; can open now.

Reviewers: rmacklem
PR: none
