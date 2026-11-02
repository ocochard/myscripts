# #4: let a jail mount NFS

Patch: [`nfscl_jail.patch`](nfscl_jail.patch), against main 584f44221f45.
Branch `nfscl-jail` in `~/freebsd-src-nfscljail`. Not committed upstream; it
changes jail policy, so it needs the NFS maintainer's agreement.

## 1. Background

**Why it matters.** The NFS tests ([`nfs_vnet_tests.md`](nfs_vnet_tests.md))
want the client in a jail. Then a client bug hangs a jail, not the test
machine, and a test can have two clients, for example to check that a lock
taken by one blocks the other.

**Mounting from a jail.** A jail may mount a file system only if three
things hold:

1. the jail was created with `allow.mount`;
2. it has `allow.mount.<type>`, for example `allow.mount.tmpfs`;
3. its `enforce_statfs` setting is below 2.

The kernel creates the `allow.mount.<type>` parameter only for file systems
registered with the `VFCF_JAIL` flag, a promise that the file system is
safe to mount from a jail (`prison_add_vfs()` in `vfs_register()`,
`sys/kern/vfs_init.c:530`). tmpfs, nullfs and devfs have it. The NFS client
did not:

```
sys/fs/nfsclient/nfs_clvfsops.c:160
VFS_SET(nfs_vfsops, nfs, VFCF_NETWORK | VFCF_SBDRY);
```

**What a jailed NFS client needs from the kernel.** A *vnet* jail has its
own network stack. Kernel code that opens a socket for the jail must open
it in the jail's network stack, or the traffic leaves from the host. The
NFS client already does this, for other reasons:

| need | where it is handled |
|---|---|
| mount sockets in the jail's network | `mountnfs()` sets it from the mounting process (b837f100e1c8, 2025) |
| every RPC, including background threads | switches to the mount's network (`sys/fs/nfs/nfs_commonkrpc.c:608`) |
| a distinct client identity per jail | client ID built from the jail's own `hostuuid` (`sys/fs/nfsclient/nfs_clstate.c:913`) |
| Kerberos and TLS helper daemons | kernel calls reach the daemon in the caller's network (`sys/rpc/clnt_nl.c:271-278`) |

So the missing piece was the flag.

**How umount(8) treats NFS.** After unmounting, umount(8) sends an NFSv3
"unmount" message to the server, unless the mount is NFSv4. To find out, it
asks the kernel for the mount's options with `nfssvc(NFSSVC_DUMPMNTOPTS)`,
the same call `nfsstat -m` uses (`sbin/umount/umount.c:393-400`). The
kernel allowed that call only with `PRIV_NFS_DAEMON`, a privilege a jail
gets only with `allow.nfsd`, meant for NFS servers (`sys/nfs/nfs_nfssvc.c`).

## 2. The problem

Before the patch:

```
# jail -c name=cli ... vnet allow.mount allow.mount.nfs enforce_statfs=1
jail: unknown parameter: allow.mount.nfs
```

With only the flag added, in a bhyve VM, a client jail mounted from an
nfsd in a second jail, wrote a file, and the server saw it. But umount in
the jail failed after unmounting:

```
+ jexec cli umount /mnt
umount: 192.0.2.2: MOUNTPROG: RPC: Port mapper failure - RPC: Timed out
umount rc=1
```

The options query failed with EPERM, so umount assumed NFSv3 and tried to
reach an NFSv3 helper that an NFSv4-only server does not run.

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

The second change follows d2ce00e9a617, which let anyone read the NFS
statistics. Reading mount options is just as harmless:

- the kernel looks the path up with the caller's own permissions and root,
  so a jail reaches only its own mounts;
- it only reads; it changes nothing;
- the options are things like `nfsv4`, `tcp`, `hard` and `timeout`, not
  secrets.

Alternatives:

- **Give client jails `allow.nfsd`.** That hands a jail every NFS server
  privilege just to read mount options.
- **Make umount(8) ignore the failed NFSv3 message.** That would hide real
  NFSv3 failures on normal machines, and `nfsstat -m` would still fail in
  jails.

What this does NOT fix or check:

- NFSv3 file locking (NLM) from a jail fails with "No locks available", even
  with `rpcbind`, `rpc.statd` and `rpc.lockd` in the jail. Mounting with
  `nolockd` works.
- NFSv4.0 delegations were not exercised. NFSv4.0's callback daemon and port
  are shared by the whole machine; NFSv4.1 and later do not use them.
- `umount -N` (forced dismount) inside a jail still needs the privilege; the
  host can still force it.
- The `vfs.nfs.*` settings and the list of client IDs are shared by all
  jails; the isolation of that list was not reviewed.
- Security: a jail with `allow.mount.nfs` can create network mounts. It is
  opt-in per jail, as for every other jail-safe file system.

## 4. Tested

bhyve VM, main 584f44221f45 with the patch. One server jail
(`allow.nfsd`) and two client jails (`allow.mount allow.mount.nfs
enforce_statfs=1`) on one virtual bridge.

| Case | Result |
|---|---|
| NFSv4.1 mount, write, read, file seen on the server | works |
| `nfsstat -m` in the client jail | works (EPERM before) |
| `umount` in the client jail | exit 0 (exit 1 before) |
| NFSv4.0 mount, write, read | works |
| NFSv3 over TCP with `nolockd` | works |
| NFSv3 with locking (NLM) | fails: "No locks available" |
| two client jails share a file | works |
| lock through c1, then `lockf -w -t 0` through c2 | c2 gets "already locked" |
| client jails after `jail -r` | gone after 45 to 60 s (normal TCP TIME_WAIT) |
| `tests/sys/fs/nfs` with jailed clients | all cases passed |

Untested: NFSv4.2-specific operations, NFS over TLS from a jail, pNFS, a
jail without vnet, and the NFS client loaded as a module.
