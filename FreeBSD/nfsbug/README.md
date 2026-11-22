# FreeBSD NFS regression tests with client and server in jails, and the fixes they need

**The goal.** Make NFS regression tests easy to write by running both the
NFS server and the NFS clients in vnet jails on one machine. Each jail has
its own network stack, so a test builds a real network of server and
clients in seconds, never touches the test machine itself, and can have
several clients: two clients sharing a file, a lock conflict, a Kerberos
client next to a plain one.

**Where FreeBSD stands.** The server already runs in a vnet jail
(`allow.nfsd`, since 15.0). The client could not: a jail was not allowed to
mount NFS (#3). Kerberos in jails also hit a kernel bug (#4). Until #3
lands, the tests (#5) fall back to a client on the test machine.

**How it started.** A FreeBSD NFSv4.1 client mounting Amazon EFS hung for
good after a few hours. Chasing that hang turned up three client bugs (#1,
#2, #6). Everything here was reproduced without EFS, in a bhyve VM, using a
small proxy that makes a normal FreeBSD nfsd behave like EFS.

## Patches

In commit order. #1 and #2 are in main; #3 to #10 are proposed in this order.

| # | patch | component | defect | symptom without it | depends on | write-up | upstream |
|---|---|---|---|---|---|---|---|
| 1 | [`badsession.patch`](badsession.patch) | NFS client (`nfs_commonkrpc.c`) | recovery restarts only if the session is not already marked defunct | two server resets within ~45 s: every process touching the mount hangs in `nfsbadse` until reboot | - | [`badsession.md`](badsession.md) (Bugzilla: [`BUGREPORT.txt`](BUGREPORT.txt); investigation: [`nfsbug.md`](nfsbug.md)) | yes, 5ab48fb9f7ac (PR 297252, by rmacklem) |
| 2 | [`staleclientid.patch`](staleclientid.patch) | NFS client (`nfs_clrpcops.c`) | `STALE_CLIENTID` in the renew window returns EIO instead of doing EXCHANGE_ID | 45 to 60 s with no I/O, and a CREATE_SESSION storm | - | [`staleclientid.md`](staleclientid.md) (Bugzilla: [`BUGREPORT-staleclientid.txt`](BUGREPORT-staleclientid.txt)) | yes, 7a0021a0988f (PR 299221) |
| 3 | [`nfscl_jail.patch`](nfscl_jail.patch) | NFS client, `nfssvc(2)` | the client lacks `VFCF_JAIL`; reading mount options needs `PRIV_NFS_DAEMON` | a jail cannot mount NFS, so a test client must run on the host; `umount` in a jail exits 1 | nothing; needs the NFS maintainer's agreement (jail policy) | [`nfscl_jail.md`](nfscl_jail.md) | no |
| 4 | [`kgss_vnet.patch`](kgss_vnet.patch) | kgssapi, `clnt_nl` | "gssd answered" and the upcall timeout are global, but gssd runs per jail | after one jail used Kerberos, an nfsd started in a jail without gssd does not serve | nothing (tested with #3 applied) | [`bugreport_kgss_vnet_upcall.md`](bugreport_kgss_vnet_upcall.md) | no, not filed |
| 5 | [`nfs_vnet_tests.patch`](nfs_vnet_tests.patch) | `tests/sys/fs/nfs` | the tree had no NFS test at all | regressions like #1 and #2 reach users | #4 when kgssapi is loaded; with #3, also two-client and Kerberos cases | [`nfs_vnet_tests.md`](nfs_vnet_tests.md) | no |
| 6 | [`session-leak.patch`](session-leak.patch) | NFS client | old sessions are never freed until unmount | `NFSCL session` memory grows with every recovery (37 to 256 in 27 h on EFS) | nothing; can go any time | [`session-leak.md`](session-leak.md) (Bugzilla: [`BUGREPORT-session-leak.txt`](BUGREPORT-session-leak.txt)) | no, not filed |
| 7 | [`nfscbd_jail.patch`](nfscbd_jail.patch) | NFS client callbacks (`nfs_clkrpc.c`), `nfscbd(8)` | the callback program is registered only with the UDP socket, which a jail cannot add | a client jail running nfscbd never gets a delegation | nothing (tested with #3 to #5) | [`nfscbd_jail.md`](nfscbd_jail.md) | no, not filed |
| 8 | [`svc_backchannel.patch`](svc_backchannel.patch) | krpc (`sys/rpc/svc.c`) | `svcpool_close()` at nfscbd exit unregisters the mounts' backchannel transports for good | after an nfscbd restart, recalls on older mounts are dropped: the conflicting open waits 255 s | #7 (tested on top of it) | [`svc_backchannel.md`](svc_backchannel.md) | no, not filed |
| 9 | [`nfsd_jail_state.patch`](nfsd_jail_state.patch) | NFS server (`nfs_nfsdport.c`, `nfs_nfsdstate.c`, `nfs_nfsdkrpc.c`) | a client record's credential holds the server jail, and records are freed only after the jail is | a removed server jail with any client record (NFSv4.0, or a client gone without DESTROY_CLIENTID) stays dying forever | nothing | [`nfsd_jail_state.md`](nfsd_jail_state.md) | no, not filed |
| 10 | in [`nfsd_jail_state.patch`](nfsd_jail_state.patch), one commit with #9 | krpc RPCSEC_GSS (`svc_rpcsec_gss.c`) | same cycle with the Kerberos server contexts | a removed Kerberos server jail stays dying forever | nothing (tested with #9) | [`gss_jail_remove.md`](gss_jail_remove.md) | no, not filed |

Why this order: the goal is client and server in jails, and #3 is what
allows the client in a jail, so it goes first. It changes jail policy and
needs the NFS maintainer's agreement. #4 fixes the bug that hangs a jailed
nfsd once Kerberos is used in another jail. The tests (#5) then land at full
strength: two clients and Kerberos, relying on #4 instead of a workaround.
#6 is independent; ideally a leak check is added to the tests before it.
Tradeoff: the tests wait for the slowest review, #3, although they could run
today with the client on the test machine.

Upstream status checked against `freebsd/main` at `cf58c8667cfd`
(2026-11-15): #1 and #2 are committed, and #3 to #6 still apply cleanly. They
are on local branches: #3 is `nfscl-jail` in `~/freebsd-src-nfscljail`, #4 is
`kgss-vnet` in `~/freebsd-src-kgssvnet`, #5 is `nfs-vnet-tests` in
`~/freebsd-src-nfstest`.

## What went wrong, explained

**Sessions and client IDs.** An NFSv4.1 client first introduces itself to the
server with EXCHANGE_ID, and gets a *client ID*. It then opens a *session*
with CREATE_SESSION, and every later request starts with a SEQUENCE operation
that names the session. If the server forgets the session, it answers
`NFS4ERR_BADSESSION`. If it also forgot the client ID, CREATE_SESSION with the
old client ID gets `NFS4ERR_STALE_CLIENTID`. The client must then start over:
EXCHANGE_ID, CREATE_SESSION, and reclaim its open files and locks. RFC 8881
Section 8.4.2 describes this as recovery after a server restart.

**What EFS does.** EFS does this on every TCP connection reset, many times a
day, without any server failure. A Linux client recovers in 8 ms. That is
legal per the RFC, but it sends FreeBSD down its server-restart path in
normal operation, where nobody had tested it much.

**The renew window.** The FreeBSD client allows only one full recovery per
`nfsc_renew` seconds, half the server lease: 45 s on EFS, 60 s with a FreeBSD
server. The first two bugs only appear when the server forgets the client
twice within that window.

**Bug #1, the hang.** During recovery the client marks the old session
*defunct* and installs a new one. When the second loss came inside the
window, the client was left with only a defunct session. Every request on a
defunct session answers `BADSESSION`, and the code that restarts recovery on
`BADSESSION` did so only when the session was *not* defunct. Nothing could
ever clear the flag, so the client retried once a second, forever, and every
program touching the mount blocked. The fix restarts recovery even when the
session is already defunct.

**Bug #2, the 45-second stall.** After #1 was fixed, the second recovery in
the window still failed: CREATE_SESSION got `STALE_CLIENTID`, and the client
returned an error instead of doing EXCHANGE_ID, as the RFC requires. The
mount then did no I/O until the window ended. The fix treats
`STALE_CLIENTID` as "start over now".

**Bug #6, the leak.** Each recovery leaves the old session in a list, because
a request in flight may still use it, and nothing ever frees it. The patch
counts the requests that hold a session and frees old sessions once nobody
holds them.

**Why the tests needed kernel changes (#3, #4).** A good NFS test puts the
server and the clients in jails, each with its own network stack (a vnet
jail). The test machine is then never touched, and a test can have two
clients. FreeBSD lets nfsd run in a vnet jail, but the client could not
mount NFS from a jail: the file system was never flagged as allowed in jails
(#3). With Kerberos, each jail runs its own gssd, but the kernel remembered
"gssd answered" for the whole machine, so a jail without gssd waited for a
reply that never came (#4).

**How the tests reproduce EFS.** `nfs_reset_proxy.py` sits between client
and server. On a signal, it resets the client connection and then answers
for the server: `BADSESSION` for the old session, `STALE_CLIENTID` for the
old client ID. A probe writes a file every second; a gap of more than 10 s
fails the test. On a kernel before #2 the double-reset test fails with
"NFS I/O stalled for 47s"; before #1, with no I/O at all.

## Files

- `nfsbug.md`: the full troubleshooting of #1 (root cause, packet and kernel
  trace evidence, the separate efs-utils watchdog `df` fix, open items).
- `<patch>.md` next to each patch, and `bugreport_kgss_vnet_upcall.md`: the
  write-up of that patch, for a reader new to NFS.
- `BUGREPORT*.txt`: the plain-text bug reports for Bugzilla, written for NFS
  developers.
- `vm-results/`: raw logs of the stock vs patched runs for #2 and #6.
- `scripts/`:
  - `badsession-proxy.py`: the first fault-injecting proxy; reproduced #1
    against a plain local nfsd. See `REPRODUCE.md`.
  - `REPRODUCE.md`: step-by-step reproduction of #1 without EFS.
  - `efs-reset-proxy.py`: mimics an EFS connection reset; drives #2 and #6.
    The test proxy in #5 is derived from it.
  - `repro.sh`: runs the proxy, `nfsrecov.d` and a 1 s probe in the bhyve VM.
  - `nfsrecov.d`: DTrace of every SetClient, CreateSession and ExchangeID,
    and TCP resets.
  - `capture-setup.sh`: arm the trace and pcap capture and mount EFS (on the
    EC2 instance, as root).
  - `watch-wedge.sh`: poll for the hang; tells a transient stall from a
    permanent one.
  - `decode-trace.sh`: summarize an `nfsdbg.log` into the timeline.
  - `nfs41-pcap-ops.py`: list the NFSv4.1 operations of each RPC in a
    plaintext pcap.

The root cause of the frequent resets is on the EFS side; see the efs-utils
port notes for the efs-proxy connection-leak fix (aws/efs-utils#380).

## Bug #1 in detail

EFS returns `NFS4ERR_BADSESSION` (10052) on SEQUENCE every so often, and the
client ID is stale too (`NFS4ERR_STALE_CLIENTID`, 10022), so recovery must do
a full EXCHANGE_ID and CREATE_SESSION. It does, and that succeeds. But when
two recoveries land within one `nfsc_renew` (observed at 12:30:43 and
12:31:28), the live session is left with `nfsess_defunct = 1` and no
replacement. From there:

- `nfs_commonkrpc.c:1281-1283` restarts recovery only when
  `nfsess_defunct == 0`, so the renew thread's `BADSESSION` every 45 s is
  ignored (2 h 17 min with no `Initiate recovery`);
- `nfsv4_sequencelookup()` (`nfs_commonsubs.c:5400-5406`) returns
  `NFS4ERR_BADSESSION` for any operation on a defunct session, so foreground
  operations spin in the 1 s `Badsession looping` loop forever.

Nothing clears `nfsess_defunct` except a recovery that is never attempted
again. Line numbers are from the code before 5ab48fb9f7ac.

Source locations (`sys/fs/`):

- `nfs/nfs_commonkrpc.c:1255-1338`: the BADSESSION handler; the restart
  guarded by `defunct == 0` (`:1281-1283`); the `Badsession looping` retry
  loop (`:1313-1338`).
- `nfs/nfs_commonkrpc.c:1136-1147`: decodes the failing SEQUENCE; source of
  the `fop=`, `fst=` and `failed seq=` debug lines.
- `nfs/nfs_commonsubs.c:5400-5406`: `nfsv4_sequencelookup()` returns
  BADSESSION on a defunct session.
- `nfs/nfs_commonsubs.c:135-184`: `nfsv4_opflag[]`; Getattr has
  `loopbadsess = 1` (line ~145).
- `nfsclient/nfs_clstate.c:2164-2224`: `nfscl_recover()`; `:2806-2811` the
  once-per-`nfsc_renew` gate in `nfscl_renewthread()`.
- `nfsclient/nfs_clrpcops.c:1040-1182`: `nfsrpc_setclient()`, CREATE_SESSION
  with the existing client ID, then the EXCHANGE_ID fallback (`:1107-1124`).
- Error and operation numbers: `nfs/nfsproto.h` (`NFSERR_BADSESSION` 10052);
  op 53 is SEQUENCE, op 43 is CREATE_SESSION.

## Environment of the original capture

EC2 instance, FreeBSD 16.0-CURRENT amd64, `__FreeBSD_version` 1600019. EFS in
us-east-1 with IAM, mounted `-o tls,iam` with efs-utils 3.2.0. `/etc/hostid`
unique (the duplicate-hostid theory was ruled out). Captured 2026-08-03.

To reproduce on an instance: `sudo sh scripts/capture-setup.sh <fs-id> /efs`,
then `sh scripts/watch-wedge.sh`. It hangs within minutes to hours; analyze
with `sh scripts/decode-trace.sh /tmp/nfsdbg.log`. Only a reboot recovers.
Without EFS, use the tests in #5 or `scripts/REPRODUCE.md`.
