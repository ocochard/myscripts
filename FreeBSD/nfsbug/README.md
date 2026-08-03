# FreeBSD NFSv4.1 EFS wedge — `NFS4ERR_BADSESSION` permanent hang

FreeBSD NFSv4.1 client permanently wedges (`WCHAN=nfsbadse`, D-state, needs reboot) after an
EFS-initiated session invalidation, once a recovery leaves the live MDS session marked defunct with
no replacement. Not an efs-utils bug — a FreeBSD kernel `sys/fs/nfsclient` bug. Reproduced and
proven end-to-end on a live EC2 instance.

Status: fixed. The kernel fix is in `badsession.patch` and the upstream report in `BUGREPORT.txt`.
Validated with the EFS-free reproducer (`scripts/`): a patched kernel survived a ~6 h continuous
BADSESSION/STALE_CLIENTID storm with recovery re-firing throughout, the mount readable across arm
windows, and no permanent `Badsession looping` or `nfsbadse` D-state. The root cause and source
references below describe the pre-fix code (they match the diff in `badsession.patch`).

## Layout

- `nfsbug.md` — the full troubleshooting writeup (root cause, packet + kernel-trace evidence, the
  separate efs-utils watchdog `df` fix, open items). This is the document to file the bug from.
- `BUGREPORT.txt` — the upstream FreeBSD bug report (Base System / kern), ready to file.
- `badsession.patch` — the kernel fix, `git diff` against main; applies with `git apply` or
  `patch -p1`.
- The original capture evidence (8.5 h EFS NFSCL_DEBUG trace, loopback pcap, frozen `nfsstat`
  snapshot, and the EFS-free reproduction logs) is summarized in `nfsbug.md`; the raw files are
  regenerated on demand by the `scripts/` below (they write to `/tmp/nfsdbg.log` and
  `/tmp/efs_lo0.pcap*` on the test box).
- `scripts/`
  - `badsession-proxy.py` — **NFSv4.1 fault-injecting TCP proxy; reproduces the bug WITHOUT EFS**
    against a plain local nfsd. Rewriter unit-tested; demonstrated wedging a real client. See
    `REPRODUCE.md`.
  - `REPRODUCE.md` — step-by-step EFS-free reproduction recipe (nfsd export + proxy + mount).
  - `capture-setup.sh` — arm the trace+pcap capture and mount EFS (run on the instance, sudo).
  - `watch-wedge.sh` — poll for the wedge; distinguishes transient (self-heals) vs permanent.
  - `decode-trace.sh` — summarize an `nfsdbg.log` into the proving timeline.

## Root cause (one paragraph)

EFS returns `NFS4ERR_BADSESSION` (10052) on SEQUENCE, spontaneously, every so often; the ClientID is
also stale (`NFS4ERR_STALE_CLIENTID` 10022), so recovery must do a full ExchangeID+CreateSession —
which it does, and which succeeds. But when two recoveries land within one `nfsc_renew` (= lease/2,
~45 s; observed 12:30:43 + 12:31:28), the live MDS session is left `nfsess_defunct = 1` with no
successful replacement installed. From there it is a closed trap:
`nfs_commonkrpc.c:1281-1283` only re-initiates recovery when `nfsess_defunct == 0`, so the every-45 s
renew-thread BADSESSION is silently swallowed (2 h 17 min with zero `Initiate recovery`); and
`nfsv4_sequencelookup` (`nfs_commonsubs.c:5400-5406`) returns `NFS4ERR_BADSESSION` for any op on a
defunct session, so foreground ops spin the 1 s `Badsession looping` loop forever. Nothing clears
`nfsess_defunct` except a successful recovery that is never attempted again.

## Key source locations (FreeBSD `sys/fs/`)

- `nfs/nfs_commonkrpc.c:1255-1338` — BADSESSION handler; re-trigger guarded by `defunct == 0`
  (`:1281-1283`); the `Badsession looping` / `tryagain` loop (`:1313-1338`).
- `nfs/nfs_commonkrpc.c:1136-1147` — decodes the failing SEQUENCE op; source of `fop=`/`fst=` /
  `failed seq=` debug lines.
- `nfs/nfs_commonsubs.c:5400-5406` — `nfsv4_sequencelookup` returns BADSESSION on a defunct session.
- `nfs/nfs_commonsubs.c:135-184` — `nfsv4_opflag[]`; Getattr has `loopbadsess = 1` (line ~145).
- `nfsclient/nfs_clstate.c:2164-2224` — `nfscl_recover`; `:2806-2811` the `retok` (create-session-only
  once per `nfsc_renew`) gate in `nfscl_renewthread`.
- `nfsclient/nfs_clrpcops.c:1040-1182` — `nfsrpc_setclient`; extant-ClientID CreateSession then the
  ExchangeID fallback (`:1107-1124`). NB the `retok`-skips-ExchangeID path (`:1101-1102`) was
  suspected but **disproven** — every recovery completed the fallback.
- Error/op numbers: `nfs/nfsproto.h` (`NFSERR_BADSESSION 10052`); op 53 = SEQUENCE, 43 = CREATE_SESSION.

## Environment

Host `i-xxx`, FreeBSD 16.0-CURRENT amd64,
`__FreeBSD_version` 1600019. EFS `fs-xxx` (us-east-1, IAM), `-o tls,iam`,
efs-utils 3.2.0. `/etc/hostid` unique (duplicate-hostid cause disproven). Captured 2026-08-03.

## Reproduce

On a fresh instance: `sudo sh scripts/capture-setup.sh fs-xxx /efs`, then
`sh scripts/watch-wedge.sh`. Wedges within minutes–hours. Analyze with
`sh scripts/decode-trace.sh /tmp/nfsdbg.log`. Recover only by reboot.
