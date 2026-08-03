# EFS on FreeBSD: NFSv4.1 client wedges on a dead session

Two independent problems:

1. **FreeBSD kernel NFSv4.1 client bug (the real cause of `/efs` becoming unreadable, not fixable in
   userspace).** When the EFS server invalidates the client's session, the client does not recover:
   it replays the doomed op forever and every process touching the mount blocks in uninterruptible
   D-state (`WCHAN=nfsbadse`). Proven at the packet level below.
2. **efs-utils watchdog `df` health check (fixed).** It false-positives on backend slowness and, on
   FreeBSD, hard-kills efs-proxy mid-RPC — one way to provoke problem #1. Replaced with a direct
   proxy socket-liveness probe.

## Environment

- Host: `i-xxx`, FreeBSD 16.0-CURRENT amd64, `__FreeBSD_version` 1600019,
- EFS `fs-xxx` (us-east-1, IAM), mounted at `/efs` with `-o tls,iam`. efs-proxy
  listens on a loopback TLS port (`<tlsport>`, e.g. 20669); the kernel NFS client connects to it.
- Mount options: `soft,nfsv4,minorversion=1,rsize=1048576,wsize=1048576,timeo=600,retrans=2,`
  `noresvport,oneopenown,retrycnt=1,port=<tlsport>`.
- `/etc/hostid` is generated per boot and is unique here (`kern.hostuuid` == `smbios.system.uuid`);
  a duplicate-hostid cause is disproven for this host.

## Problem 1: NFSv4.1 client does not recover from a dead session

Proven, no assumptions:

1. **Wedge is real.** `ps -o pid,stat,wchan,command` shows processes touching `/efs` in `D` state
   with `WCHAN=nfsbadse` (NFSv4.1 "bad session"). They are unkillable.

2. **Transport is healthy.** `tcpdump -i lo0 port <tlsport>` shows a fully ESTABLISHED,
   bidirectional loopback connection between the kernel NFS client and efs-proxy — no RST, no proxy
   exit, no loss. The client sends a 320-byte request once per second; the proxy replies with a
   56-byte packet each time. efs-proxy stays alive throughout.

3. **The server returns a session error, not a hang.** Decoding a reply payload (`tcpdump -X`)
   shows a well-formed RPC `MSG_ACCEPTED` reply whose NFSv4 GETATTR compound carries a bad/dead
   session status, once per second, matching the `nfsbadse` wchan. (Confirm the exact RFC 5661 code
   with an NFS dissector, e.g. `tshark`; the byte decode + wchan + counters below already establish
   it is a session error, not a transport failure.)

4. **The client never recovers.** `nfsstat -c` shows `ExchangeId=2, CreateSess=4`, and these stay
   pinned across many freshly triggered GETATTRs that each get a dead-session reply. A correct
   client would answer a bad/dead session with a new `EXCHANGE_ID` + `CREATE_SESSION`; the flat
   counters prove it does not. It replays the doomed op on the dead session forever -> permanent
   D-state.

Conclusion: the defect is in the FreeBSD NFSv4.1 client's session-recovery path
(`sys/fs/nfsclient`). It is reached whenever the EFS server invalidates the client's session; the
reason for that invalidation is not yet proven (candidates: a prior transport reset, an EFS
server-side session timeout, or a client-id collision). No userspace change fixes this — the client
must re-establish the session on `NFS4ERR_BADSESSION`.

### Root cause in the source (confirmed with a live NFSCL_DEBUG trace)

Reproduced on `i-xxx` with `sysctl vfs.nfs.debuglevel=1`, streaming the kernel debug
lines to a file via syslog (`kern.debug` -> `/var/log/messages`). Mounted healthy
(`ExchangeId=1, CreateSess=1`) at 06:09; ran ~8.5 h; wedged permanently at 14:49. Two decoded wire
errors, both confirmed against `nfs_commonkrpc.c:1136-1147` (`fop`=op number, `fst`=status):

- `fop=53 fst=10052` — op 53 = **SEQUENCE**, status 10052 = **NFS4ERR_BADSESSION**. The server
  (EFS) spontaneously invalidates the session; this is the trigger.
- `fop=43 fst=10022` — op 43 = **CREATE_SESSION**, status 10022 = **NFS4ERR_STALE_CLIENTID**. The
  server has also discarded the ClientID, so recovery's "CreateSession with the extant ClientID"
  cannot work.

**Recovery works — every time it runs.** Over the 8.5 h the log shows recovery fire and succeed
**four times** (07:34, 12:05, 12:30, 12:31), each an identical burst:

```
Got badsession / Marked defunct / Initiate recovery
create session for extant ClientID=10022      (extant-ClientID CreateSession fails: STALE_CLIENTID)
exchangeid err=0 / aft exch=0 / aft createsess=0   (ExchangeID + CreateSession fallback SUCCEEDS)
```

So the earlier `retok`-skips-ExchangeID hypothesis is **disproven**: every recovery reached and
completed the full ExchangeID+CreateSession fallback (`aft createsess=0`), and `/efs` became
readable again after each of the first three.

**The wedge is a defunct-session dead end reached after a back-to-back double recovery.** The last
two recoveries were only 45 s apart (12:30:43 and 12:31:28 — 45 s = `nfsc_renew` = lease/2). After
12:31:28, the current MDS session (`NFSMNT_MDSSESSION(nmp)`) is left with `nfsess_defunct = 1` and no
successful replacement swapped in as the live session. From that state there is no exit, proven by
the log:

1. **Recovery is never re-triggered again — for 2 h 17 min.** From 12:31:28 to the permanent loop at
   14:49:07 there is not one `Marked defunct` / `Initiate recovery` / `create session` line, even
   though the renew thread hits `fop=53 fst=10052` (SEQUENCE -> BADSESSION) like clockwork **every
   45 s** (14:40:31, 14:41:16, 14:42:01, ... exactly one `nfsc_renew` apart). The re-trigger block
   is guarded by `sep->nfsess_defunct == 0` (`nfs_commonkrpc.c:1281-1283`); `defunct` is already 1,
   so the guard is false forever and the renew thread is never woken to recover.

2. **Foreground ops then spin the fast loop.** At 14:49:07 a process touches `/efs`; Getattr has
   `loopbadsess = 1` (`nfsv4_opflag[]`), so `nfsv4_sequencelookup(nmp, sep, ...)` is called to get a
   slot — and it returns `NFSERR_BADSESSION` immediately whenever `sep->nfsess_defunct != 0`
   (`nfs_commonsubs.c:5400-5406`) -> `Badsession looping` (`nfs_commonkrpc.c:1335`) -> `tryagain` ->
   `Got badsession` -> repeat, at the 1 s `mtx_sleep(..., "nfsbadsess", hz)` cadence. `nfsstat`
   freezes (here `ExchangeId=4, CreateSess=8`) and every process touching `/efs` wedges D-state until
   reboot.

Deadlock, precisely: once the live MDS session is stuck `defunct` with no successful replacement,
nothing can clear it — the badsession handler will not re-trigger recovery (guarded by
`defunct == 0`) and `nfsv4_sequencelookup` will not hand out a slot on a defunct session. The two
guards that individually prevent recovery storms together form a trap with no escape.

The bug is the **transition into that stuck state**: a recovery (or the second of two back-to-back
recoveries within one `nfsc_renew`) leaves `nfsess_defunct = 1` on the session that remains the live
MDS session, without a pending retry. The kernel fix must ensure the badsession handler can
re-initiate recovery for an *already-defunct* live session (or that recovery never leaves a defunct
session installed as live without arming another `NFSCLFLAGS_RECOVER`), so the every-45 s BADSESSION
from the renew thread drives a fresh recovery instead of being silently swallowed by the
`defunct == 0` guard.

### Diagnostic commands (run from a fresh SSH session; do NOT `cd` into `/efs`)

```
# prove the wedge and its wchan
ps -o pid,stat,wchan,command -a | grep -iE 'nfsbadse|nfscl'

# watch session recovery counters (CreateSess stays flat == no recovery)
nfsstat -c -E | grep -A1 ExchangeId

# prove transport is healthy and see the 1s request/reply loop
sudo tcpdump -i lo0 -n -c 40 'port <tlsport>'

# decode the reply payload to see the NFS session error
sudo tcpdump -i lo0 -n -c 6 -vvv -X 'src port <tlsport> and greater 100'

# trigger one bounded access without wedging the shell
( timeout 8 stat /efs/. >/dev/null 2>&1 ) &
```

### Recovery (no reboot permitted)

`/efs` is wedged; a bounded `timeout 30 umount -f /efs` also hangs (it blocks on the same dead
session). If force-unmount hangs, kill the umount attempt (safe — our own process) and stop: no
bounded userspace unmount can clear it and the host needs a reboot at a maintenance window. Stuck
`df`/`ls`/`stat`/`umount` remain D-state until the mount is cleared; cosmetic once `/efs` is gone.

## Problem 2: watchdog `df` health check (fixed)

`check_stunnel_health()` runs `df <mountpoint>` every interval and treats a 30s timeout as "tunnel
unhealthy", then `SIGKILL`s efs-proxy and restarts it. `df` measures the whole path
(loopback -> efs-proxy -> TLS -> EFS backend), so its latency is dominated by the backend, not the
tunnel: a slow/throttled backend trips the timeout while efs-proxy is healthy. On FreeBSD, SIGKILLing
the proxy mid-RPC tears the transport out from under the NFS client and can provoke problem #1; the
next `df` then wedges in D-state, read as another failure -> endless SIGKILL/restart churn. efs-proxy
already self-monitors and exits on unrecoverable faults, so an external `df` probe is unnecessary.

**Fix (FreeBSD only; Linux/macOS `df` path unchanged):** probe efs-proxy directly. It is healthy iff
its loopback port shows an ESTABLISHED tcp4 socket in `sockstat -4` (NFS-over-TCP holds a persistent
connection). Restart only when BOTH signals agree the proxy is gone: no ESTABLISHED socket AND the
process not running. A slow backend keeps the socket ESTABLISHED, so it never triggers a kill; a
live-but-not-serving proxy is left alone; if `sockstat` cannot run, do nothing. No `df` is spawned
on FreeBSD, so the D-state `df` leak is structurally impossible. The same `sockstat` check also
dedups a mountpoint that has more than one state file/port pair (cold-start mount retry leaves a
stale proxy), keeping only the port with the ESTABLISHED connection.

**Validation:** on this host the mount hit problem #1 while the watchdog had run zero health checks —
no `df` spawned, no proxy killed, no churn; efs-proxy stayed alive. The fix behaves correctly through
a real wedge but does not (and cannot) make `/efs` reachable again.

## Open items

1. **File a FreeBSD kernel bug.** Root cause confirmed end-to-end (live `NFSCL_DEBUG` trace above,
   8.5 h run): recovery succeeds 4x via the ExchangeID fallback, but after a back-to-back double
   recovery (two within one `nfsc_renew`) the live MDS session is left `nfsess_defunct = 1` with no
   replacement; from then on the `defunct == 0` guard (`nfs_commonkrpc.c:1281-1283`) suppresses every
   re-trigger and `nfsv4_sequencelookup` refuses a slot on the defunct session
   (`nfs_commonsubs.c:5400-5406`), so the every-45 s renew-thread BADSESSION is silently swallowed and
   the mount is stranded until reboot. Attach: the full `/tmp/nfsdbg.log` (shows the 4 successful
   recoveries, the 45 s renew-thread BADSESSION cadence with no recovery for 2 h 17 min, then the 1 s
   `Badsession looping`), frozen `nfsstat` (`ExchangeId=4, CreateSess=8`), and the decoded wire errors
   (SEQUENCE->BADSESSION 10052, CREATE_SESSION->STALE_CLIENTID 10022).
2. **Investigate the back-to-back double recovery (12:30:43 + 12:31:28, 45 s apart)** as the likely
   entry into the stuck state — whether the second recovery races the first's session swap and leaves
   the defunct session installed as the live one. This is the transition to fix; the two guards above
   are what make it permanent.
3. Server-side (EFS) question: why does the session go BADSESSION spontaneously every ~45 min–hours,
   and why is the ClientID also stale (10022)? A more forgiving EFS would keep the ClientID valid so
   the extant-ClientID CreateSession path could recover without a full ExchangeID. Out of FreeBSD's
   control but worth raising with AWS.
4. aarch64 build + mount re-verification of the fixed efs-utils package.

Status: fixed. The kernel fix is in `badsession.patch` (drop the `nfsess_defunct == 0` term from
the recovery re-trigger in the BADSESSION handler of `newnfs_request`), and the upstream report is
in `BUGREPORT.txt`. Validated with the EFS-free reproducer (`scripts/`): a patched kernel ran a
continuous BADSESSION/STALE_CLIENTID storm for ~6 h with recovery re-firing throughout, the mount
readable across arm windows, and no permanent `Badsession looping` or `nfsbadse` D-state.
