# Reproduce the FreeBSD NFSv4.1 BADSESSION wedge WITHOUT EFS

`badsession-proxy.py` reproduces the *client-side* kernel bug against a plain local
`nfsd` export, by injecting the same errors a real server (EFS) sends: SEQUENCE ->
`NFS4ERR_BADSESSION`, CREATE_SESSION -> `NFS4ERR_STALE_CLIENTID`. This isolates the
FreeBSD client defect from the question of *why* EFS sends BADSESSION — a correct
client must survive a server legitimately invalidating a session.

## DEMONSTRATED 2026-08-03 on a FreeBSD 16.0-CURRENT amd64 test instance

Confirmed working end-to-end with NO EFS: local nfsd + this proxy wedged the client
in ~3 minutes. Proxy injected 92x SEQUENCE->BADSESSION + 10x CREATE_SESSION->
STALE_CLIENTID; client did 5 recoveries then froze (`nfsstat` ExchangeId/CreateSess
stuck at 9/12), `Badsession looping` at ~1/s, `/mnt/t` unreadable, reboot to clear.
Identical signature to the EFS capture.

Two server prerequisites (else `mount_nfs` -> "Permission denied"):
  sudo sysctl vfs.nfsd.nfs_privport=0            # allow proxy's high source port
  sudo sysctl vfs.nfsd.server_max_minorversion4=2

The permanent wedge is a race (renew-thread recovery vs foreground badsession retry),
so it is probabilistic: the proxy makes it likely by storming BADSESSION on a timer
while concurrent I/O runs. Expect minutes, not one shot.

## Setup (all on one FreeBSD test box; needs root)

1. Export something over NFSv4.1 locally:
   ```
   sysctl vfs.nfsd.server_max_minorversion4=2
   mkdir -p /export/t && echo hi > /export/t/FILE
   cat >> /etc/exports <<'EOF'
   V4: /export
   /export -maproot=root 127.0.0.1
   EOF
   service nfsd onestart      # or: service nfsd restart
   sysctl vfs.nfsd.nfs_privport=0   # REQUIRED: proxy connects from a high port
   rpcinfo -p | grep nfs      # confirm nfsd on 2049
   ```

2. Turn on client recovery tracing (so you see the same lines as the EFS capture):
   ```
   sysctl vfs.nfs.debuglevel=1
   ```

3. Start the fault-injector proxy in front of nfsd. Short arm-interval speeds it up:
   ```
   python3 badsession-proxy.py --listen 127.0.0.1:2050 --server 127.0.0.1:2049 \
       --arm-interval 20 --arm-duration 4
   ```

4. Mount NFSv4.1 THROUGH the proxy (port 2050), same options as efs-utils uses:
   ```
   mkdir -p /mnt/t
   mount_nfs -o nfsv4,minorversion=1,hard,retrans=2,port=2050 127.0.0.1:/ /mnt/t
   cat /mnt/t/t/FILE        # confirm it works before the storm bites
   ```

5. Drive concurrent I/O so a foreground op and the renew thread both hit an armed
   window (this is what creates the double-recovery race):
   ```
   while true; do ls -la /mnt/t >/dev/null 2>&1; sleep 1; done &
   ```

## Watch for the wedge

```
sh watch-wedge.sh /mnt/t         # or watch nfsstat + dmesg directly
```

Signature of the permanent wedge (identical to the EFS case):
- `nfsstat -c -E` : `ExchangeId`/`CreateSess` stop advancing (frozen).
- kernel log      : `Got badsession` / `Badsession looping` once per second, forever,
                    with NO `Marked defunct` / `Initiate recovery` between them.
- `ps -o pid,stat,wchan,command` : the I/O process in `D` + `WCHAN=nfsbadse`.
- `/mnt/t` unreadable; only a reboot clears it.

Summarize a captured trace with `sh decode-trace.sh /tmp/nfsdbg.log` (the timeline it
produces is described in `../nfsbug.md`).

## Notes

- If it self-heals every window (transient) and never strands, lengthen
  `--arm-duration` (give the renew thread AND a foreground op time to both recover
  inside one window) and/or add more concurrent I/O loops.
- The proxy only rewrites the FIRST op of a reply's COMPOUND (SEQUENCE is always
  first in v4.1 client compounds; CREATE_SESSION stands alone). That is sufficient.
- Pure stdlib Python 3, no deps. Runs on FreeBSD base python (lang/python3).
- This does not need EFS, TLS, efs-proxy, or AWS credentials.
