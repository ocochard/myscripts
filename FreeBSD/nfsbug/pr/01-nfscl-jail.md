<!-- ron-dev PR text for pr/nfscl-jail (#3). First line = title, the rest = description. Open with: git switch pr/nfscl-jail && git pr main -->
nfscl: Allow NFS mounts from a jail

The NFS client already runs its RPCs in the vnet of the mounting
credential and takes its client ID owner from the jail's hostuuid, so
a vnet jail with allow.mount.nfs can mount and use NFS.  Let
NFSSVC_DUMPMNTOPTS run without PRIV_NFS_DAEMON, as for the stats:
umount(8) uses it to find out that a mount is NFSv4, and in a jail it
otherwise sent an NFSv3 Unmount RPC and failed.

Without this, a jail cannot mount NFS (`allow.mount.nfs` does not exist,
since the client lacks `VFCF_JAIL`), and the NFS tests must run the client
on the test machine itself. Measured: a vnet jail with `allow.mount`,
`allow.mount.nfs` and `enforce_statfs=1` mounts NFSv3, NFSv4.0 and NFSv4.1
from an nfsd in another vnet jail; `umount` in the jail now exits 0.

Tested in a bhyve VM with `tests/sys/fs/nfs` (server and clients in vnet
jails), kernel = main plus all pending NFS jail changes, GENERIC-NODEBUG and
GENERIC (INVARIANTS, WITNESS): all 13 cases pass, no jail left dying, no
panic or KASSERT. The branch also builds alone on main (kernel and the
nfscommon, nfscl, nfsd, krpc, kgssapi and nfslockd modules).

Reviewers: rmacklem (jail policy for the NFS client)
PR: none (not a bug)
