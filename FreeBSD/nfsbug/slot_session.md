# A slot is freed on the wrong NFSv4.1 session after a recovery

Patch: [`slot_session.patch`](slot_session.patch), commit bdd6a92a5712 on
branch `nfscl-slot-session` in `~/freebsd-src-slotsess`, against main
f0ce2ae67f9f. ron-dev PR branch `pr/nfscl-slot-session`. Not committed
upstream, not filed.

This replaces the session-leak patch (#6, [`session-leak.md`](session-leak.md)),
dropped on 2026-11-26 after rmacklem's reply: the leak is slow, and
reference counting sessions is too messy for what it saves. A code review
of #6 found this smaller, separate bug in the code around it.

## 1. Background

**Sessions and slots.** An NFSv4.1 client talks to its server through a
*session* (`struct nfsclsession`, `sys/fs/nfs/nfsclstate.h`). A session has
a fixed number of *slots*: each RPC takes a free slot, puts the slot number
and its sequence number in the SEQUENCE operation at the start of the
compound, and gives the slot back when the reply arrives. The server uses
the slot and sequence number to detect a retransmission. The client keeps
the busy slots in a bit mask of the session (`nfsess_slots`), and
`nfsv4_freeslot()` (`sys/fs/nfs/nfs_commonsubs.c`) clears a slot's bit.

**Where the slot comes from.** `nfscl_reqstart()` (`nfs_commonsubs.c`)
builds the compound. For a normal RPC it takes the mount's current MDS
session (`nfsmnt_mdssession()`) and a slot of it.

**Recovery.** When the server forgets the client (a server reboot, or a
connection reset with AWS EFS), the client does EXCHANGE_ID and
CREATE_SESSION again, puts the new session at the head of the mount's
session list, and marks the old one defunct (`nfsrpc_setclient()`,
`sys/fs/nfsclient/nfs_clrpcops.c`). The old session stays in memory until
unmount.

## 2. The problem

Found by reading the code, during the review of #6; not reproduced. An
RPC that takes its slot from session A, and fails while a recovery
replaces A with session B, frees its slot in these places:

- `newnfs_request()` (`sys/fs/nfs/nfs_commonkrpc.c`), after `RPC_CANTSEND`,
  `RPC_CANTRECV`, `RPC_SYSTEMERROR` or `RPC_INTR` (an `intr` or `soft`
  mount), and after `RPC_AUTHERROR`;
- `nfsv4_freeunsentslot()` (`sys/fs/nfsclient/nfs_clcomsubs.c`), for a
  compound built but not sent.

Each looks the session up again with `nfsmnt_mdssession()`, which now
returns B. So the slot number of A is freed in B, where the RPC never had
it:

- if that slot is free in B, `nfsv4_freeslot()` prints
  "freeing free slot!!";
- if another RPC holds that slot in B, its bit is cleared, so a third RPC
  can take the same slot while the second is still in flight.

Slot A stays busy in the defunct session, which no longer matters.

## 3. The fix

```diff
+	struct nfsclsession	*nd_sep;	/* MDS session of nd_slotid */
+#define	ND_MDSSESS		0x400000000000	/* nd_sep is set (client) */
```

- `nfscl_reqstart()` records the MDS session it took the slot from in
  `nd_sep` and sets `ND_MDSSESS`.
- The BADSESSION retry in `newnfs_request()`, which moves the RPC to the
  new session and takes a slot there, updates `nd_sep`.
- `newnfs_request()` (three places, through `nfs_reqsession()`) and
  `nfsv4_freeunsentslot()` free the slot on `nd_sep` when `ND_MDSSESS` is
  set, and fall back to the current MDS session otherwise.

Why a flag and not just the pointer: `nfsrv_getuser()` builds its request
on the stack without `nfscl_reqstart()`, so `nd_sep` would be garbage
there. Only `nfscl_reqstart()` sets the flag, and it assigns `nd_flag`
afresh first.

Why the pointer is safe without a reference count: sessions are freed only
at unmount, after every RPC of the mount is done. That is what #6 would
have changed, and why #6 needed the counting.

Alternatives:

- **Count references on sessions (#6).** Frees the old sessions too, but
  is much larger and was found messy (pNFS device entries, RPCs that
  return before their reply); dropped.
- **Find the session from the session ID in the request.** The ID is in
  the built mbuf chain; looking it up again costs a list walk and parsing
  for every failing RPC.

What the patch does NOT change: data server (pNFS) RPCs, which pass their
session explicitly; the defunct sessions themselves, still kept until
unmount.

Unrelated, already in main: d2bc774c2724 ("nfscommon: Fix a couple of
slot handling cases") fixes a server shrinking the slot table and a
`1 << n` overflow above slot 31. This patch is on top of it.

## 4. Tested

bhyve VM, kernel = main f0ce2ae67f9f + the pending NFS jail patches (#3,
#4, #7, #8, #9 + #10) + the 12-case tests + this patch:

| check | GENERIC-NODEBUG | GENERIC (INVARIANTS, WITNESS) |
|---|---|---|
| all 12 cases of `tests/sys/fs/nfs` | passed | passed |
| `server_reset`, `server_reset_twice`, 3 runs each (6 server resets per pair) | all passed | all passed |
| "freeing free slot!!", panic, KASSERT | none | none |

The patch also builds alone on main (kernel and the NFS and RPC modules),
no compiler warning.

Untested: the bug itself. It needs an RPC that fails with RPC_INTR, a
transport error or an auth error across a recovery, which the tests cannot
time on demand; the runs above show only that the patch breaks nothing.
