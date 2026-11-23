<!-- ron-dev PR text for pr/nfscbd-jail (#7). First line = title, the rest = description. Open with: git switch pr/nfscbd-jail && git pr main -->
nfscl: Serve NFSv4.1 callbacks from an nfscbd in a jail

The callback program was registered only along with the sockets that
nfscbd(8) adds, and in a jail svc_dg_create() refuses its UDP socket.
The client then offered a backchannel, answered the server's CB_NULL
with PROG_UNAVAIL, and never got a delegation.

Register the program on the pool when nfscbd starts, fail
NFSSVC_CBADDSOCK when the socket cannot be served, and let nfscbd skip
UDP in a jail.

Measured (pcap): the server's CB_NULL on the backchannel got
PROG_UNAVAIL from a jailed nfscbd, so the server never set CB and never
issued a delegation. With the patch: delegation issued, and a
conflicting open by a second client recalls it in 0s.

Tradeoff: an old nfscbd(8) binary in a jail on a patched kernel exits at
start ("can't Add UDP socket"), where before it ran and served nothing.

Tested in a bhyve VM with `tests/sys/fs/nfs` (server and clients in vnet
jails), kernel = main plus all pending NFS jail changes, GENERIC-NODEBUG and
GENERIC (INVARIANTS, WITNESS): all 13 cases pass, no jail left dying, no
panic or KASSERT. The branch also builds alone on main (kernel and the
nfscommon, nfscl, nfsd, krpc, kgssapi and nfslockd modules).

Reviewers: rmacklem
PR: <Bugzilla number, from nfsbug/BUGREPORT-nfscbd-jail.txt>
