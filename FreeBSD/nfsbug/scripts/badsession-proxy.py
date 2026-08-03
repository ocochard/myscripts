#!/usr/bin/env python3
"""
badsession-proxy.py - NFSv4.1 fault-injecting TCP proxy to reproduce the FreeBSD
client permanent-wedge bug WITHOUT EFS.

It sits between a FreeBSD NFSv4.1 client and any real NFSv4.1 server (e.g. a
localhost nfsd export). It forwards everything transparently until "armed", at
which point it rewrites replies to mimic exactly what EFS does to trigger the bug:

  * SEQUENCE  (op 53) reply status -> NFS4ERR_BADSESSION   (10052)
  * CREATE_SESSION (op 43) reply status -> NFS4ERR_STALE_CLIENTID (10022)

Repeatedly arming (a "storm") drives the client's recovery path and, given enough
cycles with concurrent I/O, into the defunct-session dead end (WCHAN=nfsbadse,
permanent D-state). See ../README.md for the root cause.

This reproduces the *client* bug (mishandling repeated, legitimate BADSESSION),
independent of *why* a real server sends it.

Wire format handled:
  RPC-over-TCP record marking: each record = 4-byte big-endian (last_frag<<31 | len)
  followed by len bytes. We reassemble full records both directions.
  A record's RPC message: xid(4) mtype(4). For replies mtype==1.
  Reply body: reply_stat(4)=MSG_ACCEPTED(0); verf: flavor(4) len(4) + len bytes
  (rounded to 4); accept_stat(4)=SUCCESS(0). Then the NFSv4 COMPOUND4res:
  status(4) tag(len4+bytes,pad) numres(4); then each op: resop(4) then op body,
  where the first 4 bytes of most op bodies is that op's nfsstat4.

To inject: find the COMPOUND, read the first resop; if it is the target op,
overwrite the COMPOUND status AND that op's status with the error, and set numres=1
truncating trailing ops (RFC 5661: on error the compound stops at the failing op).

Usage:
  python3 badsession-proxy.py --listen 127.0.0.1:2050 --server 127.0.0.1:2049 \
      --arm-interval 30 --arm-duration 3

Then mount through the proxy:
  sudo mount_nfs -o nfsv4,minorversion=1,... 127.0.0.1:/ /mnt  (port=2050)

--arm-interval N : every N seconds, arm fault injection
--arm-duration D : keep it armed for D seconds each cycle (long enough for the
                   renew thread + a foreground op to both hit it -> race)
"""
import argparse
import selectors
import socket
import struct
import sys
import threading
import time

# NFSv4 op numbers
OP_CREATE_SESSION = 43
OP_SEQUENCE = 53
# NFSv4 error codes
NFS4ERR_BADSESSION = 10052
NFS4ERR_STALE_CLIENTID = 10022

# RPC
CALL = 0
REPLY = 1
MSG_ACCEPTED = 0
ACCEPT_SUCCESS = 0

_armed = False


def log(msg):
    sys.stderr.write("[%s] %s\n" % (time.strftime("%H:%M:%S"), msg))
    sys.stderr.flush()


def arm_timer(interval, duration):
    global _armed
    while True:
        time.sleep(max(1, interval - duration))
        _armed = True
        log("ARMED: injecting BADSESSION/STALE_CLIENTID for %ds" % duration)
        time.sleep(duration)
        _armed = False
        log("disarmed")


def _pad4(n):
    return (n + 3) & ~3


def rewrite_reply(rec):
    """Given one complete RPC record payload (without the 4-byte marker),
    if it is a reply whose COMPOUND's first op is SEQUENCE or CREATE_SESSION and
    we are armed, rewrite the status to the matching error and truncate to 1 op.
    Returns possibly-modified bytes."""
    if not _armed:
        return rec
    try:
        off = 0
        xid, mtype = struct.unpack_from(">II", rec, off)
        off += 8
        if mtype != REPLY:
            return rec
        reply_stat = struct.unpack_from(">I", rec, off)[0]
        off += 4
        if reply_stat != MSG_ACCEPTED:
            return rec
        # verifier: flavor(4) + len(4) + body(pad4)
        off += 4  # flavor
        vlen = struct.unpack_from(">I", rec, off)[0]
        off += 4 + _pad4(vlen)
        accept_stat = struct.unpack_from(">I", rec, off)[0]
        off += 4
        if accept_stat != ACCEPT_SUCCESS:
            return rec
        # COMPOUND4res: status(4) tag(len+bytes,pad) numres(4)
        comp_status_off = off
        off += 4  # compound status
        tlen = struct.unpack_from(">I", rec, off)[0]
        off += 4 + _pad4(tlen)
        numres_off = off
        numres = struct.unpack_from(">I", rec, off)[0]
        off += 4
        if numres < 1:
            return rec
        resop = struct.unpack_from(">I", rec, off)[0]
        op_status_off = off + 4  # first 4 bytes of op result = its nfsstat4
        if resop == OP_SEQUENCE:
            err = NFS4ERR_BADSESSION
        elif resop == OP_CREATE_SESSION:
            err = NFS4ERR_STALE_CLIENTID
        else:
            return rec
        b = bytearray(rec)
        struct.pack_into(">I", b, comp_status_off, err)   # compound status
        struct.pack_into(">I", b, op_status_off, err)     # first op status
        struct.pack_into(">I", b, numres_off, 1)          # keep only first op
        # truncate after the failing op's status word (op result = resop + status)
        new_len = op_status_off + 4
        del b[new_len:]
        log("injected err=%d into op=%d (xid=0x%x)" % (err, resop, xid))
        return bytes(b)
    except struct.error:
        return rec


def pump(src, dst, transform):
    """Reassemble RPC records from src, apply transform to each, write to dst.
    Records use RPC-over-TCP marking; a message may span multiple fragments."""
    buf = b""
    frags = []  # accumulated fragment payloads for the current message
    while True:
        try:
            data = src.recv(65536)
        except OSError:
            break
        if not data:
            break
        buf += data
        while len(buf) >= 4:
            marker = struct.unpack_from(">I", buf, 0)[0]
            last = marker & 0x80000000
            flen = marker & 0x7FFFFFFF
            if len(buf) < 4 + flen:
                break
            frag = buf[4:4 + flen]
            buf = buf[4 + flen:]
            frags.append(frag)
            if last:
                msg = b"".join(frags)
                frags = []
                msg = transform(msg)
                out = struct.pack(">I", 0x80000000 | len(msg)) + msg
                try:
                    dst.sendall(out)
                except OSError:
                    return
            # else: keep accumulating fragments for this message
    try:
        dst.shutdown(socket.SHUT_WR)
    except OSError:
        pass


def handle(client, server_addr):
    upstream = socket.create_connection(server_addr)
    # client->server: pass through unchanged (requests)
    t1 = threading.Thread(target=pump, args=(client, upstream, lambda m: m),
                          daemon=True)
    # server->client: rewrite replies
    t2 = threading.Thread(target=pump, args=(upstream, client, rewrite_reply),
                          daemon=True)
    t1.start()
    t2.start()
    t1.join()
    t2.join()
    for s in (client, upstream):
        try:
            s.close()
        except OSError:
            pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--listen", default="127.0.0.1:2050")
    ap.add_argument("--server", default="127.0.0.1:2049")
    ap.add_argument("--arm-interval", type=int, default=30,
                    help="seconds between injection windows")
    ap.add_argument("--arm-duration", type=int, default=3,
                    help="seconds each injection window stays armed")
    args = ap.parse_args()

    lhost, lport = args.listen.rsplit(":", 1)
    shost, sport = args.server.rsplit(":", 1)
    server_addr = (shost, int(sport))

    threading.Thread(target=arm_timer,
                     args=(args.arm_interval, args.arm_duration),
                     daemon=True).start()

    lsock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    lsock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    lsock.bind((lhost, int(lport)))
    lsock.listen(16)
    log("listening on %s -> %s; arm every %ds for %ds"
        % (args.listen, args.server, args.arm_interval, args.arm_duration))
    while True:
        client, _ = lsock.accept()
        threading.Thread(target=handle, args=(client, server_addr),
                         daemon=True).start()


if __name__ == "__main__":
    main()
