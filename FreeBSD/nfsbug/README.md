# FreeBSD NFSv4.1 client fixes found with Amazon EFS, and their regression tests

A FreeBSD NFSv4.1 client mounting Amazon EFS hung for good after a few hours.
Chasing that hang turned up three client bugs. Writing regression tests for
them then needed two more kernel changes, and turned up a sixth bug on the
way. Everything below was reproduced without EFS, in a bhyve VM, using a
small proxy that makes a normal FreeBSD nfsd behave like EFS.

## Patches

| # | patch | component | defect | symptom without it | write-up | upstream |
|---|---|---|---|---|---|---|
| 1 | [`badsession.patch`](badsession.patch) | NFS client (`nfs_commonkrpc.c`) | recovery restarts only if the session is not already marked defunct | two server resets within ~45 s: every process touching the mount hangs in `nfsbadse` until reboot | [`nfsbug.md`](nfsbug.md), [`BUGREPORT.txt`](BUGREPORT.txt) | yes, 5ab48fb9f7ac (PR 297252, by rmacklem) |
| 2 | [`staleclientid.patch`](staleclientid.patch) | NFS client (`nfs_clrpcops.c`) | `STALE_CLIENTID` in the renew window returns EIO instead of doing EXCHANGE_ID | 45 to 60 s with no I/O, and a CREATE_SESSION storm | [`BUGREPORT-staleclientid.txt`](BUGREPORT-staleclientid.txt) | yes, 7a0021a0988f (PR 299221) |
| 3 | [`session-leak.patch`](session-leak.patch) | NFS client | old sessions are never freed until unmount | `NFSCL session` memory grows with every recovery (37 to 256 in 27 h on EFS) | [`BUGREPORT-session-leak.txt`](BUGREPORT-session-leak.txt) | no, not filed |
| 4 | [`nfscl_jail.patch`](nfscl_jail.patch) | NFS client, `nfssvc(2)` | the client lacks `VFCF_JAIL`; reading mount options needs `PRIV_NFS_DAEMON` | a jail cannot mount NFS, so a test client must run on the host; `umount` in a jail exits 1 | [`nfscl_jail.md`](nfscl_jail.md) | no |
| 5 | [`kgss_vnet.patch`](kgss_vnet.patch) | kgssapi, `clnt_nl` | "gssd answered" and the upcall timeout are global, but gssd runs per jail | after one jail used Kerberos, an nfsd started in a jail without gssd does not serve | [`bugreport_kgss_vnet_upcall.md`](bugreport_kgss_vnet_upcall.md) | no, not filed |
| 6 | [`nfs_vnet_tests.patch`](nfs_vnet_tests.patch) | `tests/sys/fs/nfs` | the tree had no NFS test at all | regressions like #1 and #2 reach users | [`nfs_vnet_tests.md`](nfs_vnet_tests.md) | no |

Upstream status checked against `freebsd/main` at `e4a2b19aa961`. #1 and #2
are committed. #3 to #6 are only here, and on local branches: #4 is
`nfscl-jail` in `~/freebsd-src-nfscljail`, #5 is `kgss-vnet` in
`~/freebsd-src-kgssvnet`, and #6 is `nfs-vnet-tests` in
`~/freebsd-src-nfstest`. The tests (#6) run without #4 and #5, with the
client on the host and a workaround for #5. With #4 they also cover two
clients and Kerberos.

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

**Bug #3, the leak.** Each recovery leaves the old session in a list, because
a request in flight may still use it, and nothing ever frees it. The patch
counts the requests that hold a session and frees old sessions once nobody
holds them.

**Why the tests needed kernel changes (#4, #5).** A good NFS test puts the
server and the clients in jails, each with its own network stack (a vnet
jail). The test machine is then never touched, and a test can have two
clients. FreeBSD lets nfsd run in a vnet jail, but the client could not
mount NFS from a jail: the file system was never flagged as allowed in jails
(#4). With Kerberos, each jail runs its own gssd, but the kernel remembered
"gssd answered" for the whole machine, so a jail without gssd waited for a
reply that never came (#5).

**How the tests reproduce EFS.** `nfs_reset_proxy.py` sits between client
and server. On a signal, it resets the client connection and then answers
for the server: `BADSESSION` for the old session, `STALE_CLIENTID` for the
old client ID. A probe writes a file every second; a gap of more than 10 s
fails the test. On a kernel before #2 the double-reset test fails with
"NFS I/O stalled for 47s"; before #1, with no I/O at all.

## Files

- `nfsbug.md`: the full troubleshooting of #1 (root cause, packet and kernel
  trace evidence, the separate efs-utils watchdog `df` fix, open items).
- `BUGREPORT*.txt`, `bugreport_*.md`: the upstream bug reports.
- `*.md` next to each patch: the write-up of that patch.
- `vm-results/`: raw logs of the stock vs patched runs for #2 and #3.
- `scripts/`:
  - `badsession-proxy.py`: the first fault-injecting proxy; reproduced #1
    against a plain local nfsd. See `REPRODUCE.md`.
  - `REPRODUCE.md`: step-by-step reproduction of #1 without EFS.
  - `efs-reset-proxy.py`: mimics an EFS connection reset; drives #2 and #3.
    The test proxy in #6 is derived from it.
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
Without EFS, use the tests in #6 or `scripts/REPRODUCE.md`.
