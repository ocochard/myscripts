# Let a vnet jail mount NFS

Patch: `nfscl_jail.patch`, against main 584f44221f45.

Two changes:

1. The NFS client file system gets `VFCF_JAIL`. A jail created with
   `allow.mount allow.mount.nfs` can then mount NFS.
2. `nfssvc(NFSSVC_DUMPMNTOPTS)` no longer needs `PRIV_NFS_DAEMON`. Without
   this change, umount(8) in such a jail exits 1.

## 1. Background

**Jails and mounts.** A jail can mount a file system only if three things
hold:

- the jail has `allow.mount` set;
- the jail has `allow.mount.<fstype>` set;
- `enforce_statfs` is below 2.

The kernel creates the `allow.mount.<fstype>` parameter only for file
systems registered with the `VFCF_JAIL` flag: `vfs_register()` calls
`prison_add_vfs()` (`sys/kern/vfs_init.c:530`). tmpfs, nullfs, devfs and
others have the flag. The NFS client did not:

```
sys/fs/nfsclient/nfs_clvfsops.c:160
VFS_SET(nfs_vfsops, nfs, VFCF_NETWORK | VFCF_SBDRY);
```

So `allow.mount.nfs` did not exist, and no jail could mount NFS.

**vnet.** A vnet jail has its own network stack. Any kernel code that
creates a socket on behalf of a jail must run with that jail's vnet as
`curvnet`. If it doesn't, the socket lands in the host's network stack.

**The NFS client is already vnet-aware.** That work was done for other
reasons, but it covers what a jailed mount needs:

- `mountnfs()` sets `curvnet` from the mounting credential (b837f100e1c8,
  "nfs: set vnet(9) context in mountnfs()").
- Every RPC, including those from the nfsiod and renew threads, switches
  to the vnet of the mount's credential
  (`sys/fs/nfs/nfs_commonkrpc.c:608`).
- The NFSv4 client ID owner string comes from the jail's own `hostuuid`
  (`getcredhostuuid()`, `sys/fs/nfsclient/nfs_clstate.c:913`). Two jails
  therefore get two client IDs from the same server.
- The kernel's gssd and rpctls upcalls are per vnet: the netlink RPC
  transport sends to `curvnet` (`sys/rpc/clnt_nl.c:271-278`). So is
  nfsuserd (`sys/fs/nfs/nfs_commonsubs.c:101`).

**umount(8) and NFSv4.** After unmount(2), umount(8) sends an NFSv3 Mount
protocol UNMOUNT RPC, unless the mount is NFSv4. It learns the version
from `nfssvc(NFSSVC_DUMPMNTOPTS)` (`sbin/umount/umount.c:393-400`). That
call reads the option string of a mount the caller names by path, the
same string `nfsstat -m` prints. `sys_nfssvc()` lets anyone read the NFS
statistics (d2ce00e9a617), but it required `PRIV_NFS_DAEMON` for this
call (`sys/nfs/nfs_nfssvc.c:86`). A jail gets that privilege only with
`allow.nfsd`, which a client jail has no reason to have.

## 2. The problem

Before the patch:

```
# jail -c name=cli ... vnet allow.mount allow.mount.nfs enforce_statfs=1
jail: unknown parameter: allow.mount.nfs
```

With only `VFCF_JAIL` added, in a bhyve VM, a client jail mounts from an
nfsd running in a second vnet jail:

```
+ jexec cli mount -t nfs -o nfsv4,minorversion=1 192.0.2.2:/ /mnt
mount rc=0
+ jexec cli sh -c 'echo from-jailed-client > /mnt/f && cat /mnt/f'
from-jailed-client
+ cat srv/export/f                    (on the host, the server's export)
from-jailed-client
+ jexec cli umount /mnt
umount: 192.0.2.2: MOUNTPROG: RPC: Port mapper failure - RPC: Timed out
umount rc=1
```

The unmount itself succeeded. umount(8) failed afterwards: the version
query returned EPERM, so umount assumed NFSv3 and called rpcbind on the
server.

## 3. The fix

```diff
-VFS_SET(nfs_vfsops, nfs, VFCF_NETWORK | VFCF_SBDRY);
+VFS_SET(nfs_vfsops, nfs, VFCF_NETWORK | VFCF_SBDRY | VFCF_JAIL);
```

```diff
-	/* Allow anyone to get the stats. */
-	if ((uap->flag & ~(NFSSVC_GETSTATS | NFSSVC_NEWSTRUCT)) != 0) {
+	/*
+	 * Allow anyone to get the stats and the options of an NFS mount
+	 * they can look up.
+	 */
+	if ((uap->flag & ~(NFSSVC_GETSTATS | NFSSVC_NEWSTRUCT |
+	    NFSSVC_DUMPMNTOPTS)) != 0) {
```

Why the second change is safe: the `NFSSVC_DUMPMNTOPTS` handler
(`sys/fs/nfsclient/nfs_clport.c`) only does three things:

1. It looks the path up with the caller's credential and root directory,
   so a jail can only reach its own mounts.
2. It checks that the file system is NFS.
3. It copies out the option string.

It changes no state. The string holds options such as `nfsv4`, `tcp`,
`hard`, `rsize` and `timeout`, not secrets.

Alternatives:

- **Give client jails `allow.nfsd`.** That grants the nfsd, mountd and gssd
  privileges to a jail that only wants to mount, which is far more than
  reading mount options.
- **Make umount(8) ignore the UNMOUNT RPC error.** That hides real NFSv3
  failures on the host, and `nfsstat -m` would still fail in jails.
- **Have umount(8) find the version some other way.** statfs(2) has no NFS
  version field.

What this patch does NOT fix or check:

- **NFSv3 locking (NLM) from a jail fails** with "No locks available", even
  with rpcbind, rpc.statd and rpc.lockd in the client jail. Mounting with
  `nolockd` works. NLM is not vnet-aware.
- **NFSv4.0 delegations** were not exercised. The NFSv4.0 callback daemon
  and its port are global (`nfsv4_cbport`, `sys/fs/nfsclient/nfs_clport.c`).
  NFSv4.1 and later send callbacks on the client's own connection, so they
  do not use it.
- **`umount -N` (forced dismount) from inside a jail** still needs
  `PRIV_NFS_DAEMON`. The host can still force it.
- **Every client ID is on one global list** (`nfsclhead`), shared by all
  jails. Entries are keyed per jail by `hostuuid`, but this was not
  reviewed for isolation.
- **The `vfs.nfs.*` sysctls are global.**
- **Security:** the patch lets a jail with `allow.mount.nfs` create network
  mounts. This is opt-in per jail, as for every other `VFCF_JAIL` file
  system.

## 4. Tested

bhyve VM, kernel main 584f44221f45 with the patch, GENERIC-NODEBUG plus
`device epair`, `device if_bridge` and `options NULLFS`. One server jail
(`allow.nfsd`) and two client jails (`allow.mount allow.mount.nfs
enforce_statfs=1`) share a bridge.

| Case | Result |
|---|---|
| NFSv4.1 mount, write, read, server sees the file | works |
| `nfsstat -m` in the client jail | works (EPERM before the patch) |
| `umount` in the client jail | rc 0 (rc 1 before the patch) |
| NFSv4.0 mount, write, read | works |
| NFSv3 over TCP, `nolockd`, write, read, lockf | works |
| NFSv3 with NLM locking | fails: "No locks available" |
| Two client jails share a file | works |
| Lock through c1, `lockf -w -t 0` through c2 | c2 gets "already locked" (75) |
| Client jails after `jail -r` | gone after 45 to 60 s (TCP TIME_WAIT) |
| tests/sys/fs/nfs with jailed clients | 4 of 4 passed |

Untested:

- NFSv4.2-specific operations.
- Kerberos (`sec=krb5*`) and NFS over TLS from a jail.
- pNFS from a jailed client.
- A non-vnet jail.
- Running with nfscl as a module, not compiled in.

Side finding, unrelated to this patch: after a server jail served clients
that used NFSv3 with NLM, or clients driven through the fault-injecting
proxy, it stays dying for more than 150 s after `jail -r`. A server jail
whose only client unmounted cleanly over NFSv4.1 is gone in 1 s. This
looks like nfsd state keeping the vnet alive, and needs its own
investigation.
