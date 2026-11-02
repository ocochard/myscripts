# Bug #2: a 45-second outage after the server forgets the client twice

Patch: [`staleclientid.patch`](staleclientid.patch). Committed upstream as
7a0021a0988f ("nfscl: Do not delay recovery for a stale ClientID"),
PR 299221. Bugzilla text:
[`BUGREPORT-staleclientid.txt`](BUGREPORT-staleclientid.txt).

Read [`badsession.md`](badsession.md) first: it explains client IDs,
sessions and recovery.

## 1. Background

**Two kinds of recovery.** When the server answers `NFS4ERR_BADSESSION`, the
client does not know yet how much the server forgot:

- If only the session is gone, a new CREATE_SESSION with the existing client
  ID is enough. This is the cheap recovery.
- If the client ID is gone too, that CREATE_SESSION fails with
  `NFS4ERR_STALE_CLIENTID`. The client must introduce itself again with
  EXCHANGE_ID, open a session, and reclaim its open files and locks. This is
  the full recovery. RFC 8881 Section 8.4.2 says the client *must* do this.

Both are in `nfsrpc_setclient()` (`sys/fs/nfsclient/nfs_clrpcops.c`): try the
cheap way first, fall back to the full way.

**The rate limit.** The renew thread allows only one full recovery per
`nfsc_renew` seconds, half the server lease: 45 s on EFS, 60 s with a FreeBSD
server (`nfscl_renewthread()`, `sys/fs/nfsclient/nfs_clstate.c`). Inside that
window it passes `retok = true`, which means "cheap recovery only". The idea
is to avoid recovery storms against a struggling server.

## 2. The problem

EFS forgets the session and the client ID together, and sometimes does so
twice within 45 s. The first time, the full recovery runs and works. The
second time, inside the window, only the cheap recovery is allowed, and it
cannot work: the server answers `STALE_CLIENTID`. `nfsrpc_setclient()` then
gave up with EIO, and nothing happened until the window ended.

DTrace of `nfsrpc_setclient()` on a mount on EFS (`retok=1` means
cheap-only):

```
18:30:41 setclient start /mnt/efs-soak retok=0
18:30:41 createsession ret=10022
18:30:41 exchangeid ret=0
18:30:41 createsession ret=0                <- recovered
18:30:59 setclient start /mnt/efs-soak retok=1   <- 2nd reset, 18s later
18:30:59 createsession ret=10022
18:30:59 setclient ret=5 retok_out=1        <- EIO, no EXCHANGE_ID
18:31:41 setclient start /mnt/efs-soak retok=0   <- 42s later
18:31:41 createsession ret=10022
18:31:41 exchangeid ret=0
18:31:41 createsession ret=0
```

```mermaid
sequenceDiagram
  participant C as client
  participant S as server
  S-->>C: BADSESSION (1st loss)
  C->>S: CREATE_SESSION old ID
  S-->>C: STALE_CLIENTID
  C->>S: EXCHANGE_ID, CREATE_SESSION
  Note over C: recovered; window of 45 s starts
  S-->>C: BADSESSION (2nd loss, 18 s later)
  C->>S: CREATE_SESSION old ID
  S-->>C: STALE_CLIENTID
  Note over C: cheap only: give up (EIO)
  Note over C: no I/O until the window ends
  C->>S: EXCHANGE_ID, CREATE_SESSION
```

On EFS, 4 of 17 recoveries in 2.5 hours took this path, with outages of 42,
46, 46 and 45 s. Under load it got worse: every BADSESSION started another
doomed cheap recovery, 78 CREATE_SESSION calls in one minute.

Before bug #1 was fixed, this same failure left the client with only a
defunct session, and the mount hung for good.

## 3. The fix

`STALE_CLIENTID` is a definite answer: the server has forgotten the client,
and waiting cannot change that. So on that error, drop the cheap-only
restriction and do the full recovery now:

```diff
-				if (*retokp)
+				if (error == NFSERR_STALECLIENTID)
+					*retokp = false;
+				else if (*retokp)
 					return (NFSERR_IO);
```

Clearing `*retokp` matters twice:

- `nfsrpc_setclient()` goes on to EXCHANGE_ID.
- On return, `nfscl_recover()` sees `retok == false` and reclaims open files
  and locks, which a new client ID requires.

Other errors keep the old behavior.

Tradeoff: a server that forgets the client ID constantly now gets a full
recovery each time, not one per window. The `RECOVER` and `RECVRINPROG`
flags still allow only one recovery at a time, and this is what the RFC asks
for.

Alternatives:

- **Shorten the window.** That only makes the outage shorter, and allows more
  needless full recoveries for errors that a wait would fix.
- **Always do the full recovery.** It reclaims every open file and lock even
  when only the session was lost, which costs more and is not what the RFC
  describes.

## 4. Tested

bhyve VM, local nfsd behind `efs-reset-proxy.py`: two resets 15 s apart,
every 120 s, with a probe reading a file every second for 200 s.

| Measured over 200 s, 4 resets | stock | patched |
|---|---|---|
| probe stalls | 45 s, 47 s | none |
| CREATE_SESSION answered STALE_CLIENTID | 96 | 4 |
| CREATE_SESSION / EXCHANGE_ID sent | 101 / 5 | 9 / 5 |

The test framework (`tests/sys/fs/nfs`, `recovery_test:server_reset_twice`)
gives the same result:

| Kernel | Result |
|---|---|
| main 7a0021a0988f | passed |
| 64857418bb23 (just before 7a0021a0988f), client on the host | failed: NFS I/O stalled for 47 s |
| 64857418bb23 + `nfscl_jail.patch`, client in a jail | failed: NFS I/O stalled for 46 s |

Untested: pNFS mounts, and stable/15 (not merged there yet).
