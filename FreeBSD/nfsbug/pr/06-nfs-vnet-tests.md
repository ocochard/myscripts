<!-- ron-dev PR text for pr/nfs-vnet-tests (tests). First line = title, the rest = description. Open with: git switch pr/nfs-vnet-tests && git pr main -->
tests: Add NFS tests with client and server in vnet jails

The NFS client recovery paths had no test.  Run nfsd in a vnet jail, and
the clients too when the kernel allows NFS mounts in jails.  A proxy makes
the server lose the session and client ID, as AWS EFS does on every
connection reset; losing them twice within one renewal period stalls the
client for 46s before 7a0021a0988f.

The cases also cover NFSv4.0, NFSv3 without NLM, which cannot run in a
jail, Kerberos, two clients sharing locks, the recall of a delegation,
which needs nfscbd(8) to serve callbacks from a jail, that a removed
server jail goes away, with NFSv4.0 and with Kerberos.

12 cases, all `is_exclusive`: basic, v3_basic, v40_basic,
v40_server_freed, two_clients, server_reset, server_reset_twice, krb5,
krb5i, krb5p, server_freed, recall. `make install` plus `kyua test -k
/usr/tests/sys/fs/nfs/Kyuafile` (what `make check` runs) works. The cases
skip when the kernel lacks NFS in jails or Kerberos. The reset proxy runs
under daemon(8), so the cleanup can still unmount through it.

Tested in a bhyve VM with `tests/sys/fs/nfs` (server and clients in vnet
jails), kernel = main plus all pending NFS jail changes, GENERIC-NODEBUG and
GENERIC (INVARIANTS, WITNESS): all 12 cases pass, no jail left dying, no
panic or KASSERT. The branch also builds alone on main (kernel and the
nfscommon, nfscl, nfsd, krpc, kgssapi and nfslockd modules). A per-commit
review found issues that are fixed in this version; the list and its
status are in the author's notes (review-2026-11-24.md).

**Order:** Open after 01, 02, 03 and 05 have landed: without them the jailed-client,
Kerberos, delegation and jail-freed cases fail.

Reviewers: rmacklem, and the tests/ maintainers
PR: none (not a bug)
