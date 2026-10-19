#!/usr/bin/env python3
"""
efs-reset-proxy.py - NFSv4.1 TCP proxy that mimics an Amazon EFS connection reset.

On each reset, EFS RSTs the client's TCP connection and forgets that client:
the old session answers NFS4ERR_BADSESSION and the old ClientID answers
NFS4ERR_STALE_CLIENTID; a new EXCHANGE_ID gets a new ClientID. This proxy does
the same in front of a plain nfsd:

  * learns the ClientID (EXCHANGE_ID reply) and session (CREATE_SESSION reply)
  * on reset: marks both dead and RSTs the client connection
  * answers SEQUENCE/DESTROY_SESSION on a dead session with BADSESSION, and
    CREATE_SESSION with a dead ClientID with STALE_CLIENTID, itself (nfsd
    would still accept them); everything else, EXCHANGE_ID included, is
    forwarded

Resets come in pairs, --gap seconds apart, every --period seconds, starting
--start seconds after launch. A pair closer than nfsc_renew (lease/2) drives
the client into its CreateSession-only recovery path. SIGUSR1 forces a reset.

usage: efs-reset-proxy.py --listen 127.0.0.1:2050 --server 127.0.0.1:2049 \
           [--start 30] [--period 120] [--gap 15]
"""
import argparse
import signal
import socket
import struct
import threading
import time

OP_EXCHANGE_ID, OP_CREATE_SESSION, OP_DESTROY_SESSION, OP_SEQUENCE = 42, 43, 44, 53
NFS4ERR_STALE_CLIENTID, NFS4ERR_BADSESSION = 10022, 10052

lock = threading.Lock()
state = {"clientid": None, "session": None}
dead_clientids, dead_sessions = set(), set()
conns = []                                   # live (client, server) sockets


def log(msg):
    print(time.strftime("%H:%M:%S ") + msg, flush=True)


class X:
    def __init__(self, b):
        self.b, self.o = b, 0

    def u32(self):
        v = struct.unpack_from(">I", self.b, self.o)[0]
        self.o += 4
        return v

    def raw(self, n):
        v = self.b[self.o:self.o + n]
        if len(v) < n:
            raise IndexError
        self.o += n
        return v

    def opaque(self):
        n = self.u32()
        v = self.raw(n)
        self.o += (4 - n % 4) % 4
        return v


def parse_call(rec):
    """Return (xid, tag, first op, op argument bytes) or None."""
    x = X(rec)
    xid, mtype = x.u32(), x.u32()
    if mtype != 0:
        return None
    x.u32()
    prog, _, proc = x.u32(), x.u32(), x.u32()
    if prog != 100003 or proc != 1:
        return None
    x.u32(); x.opaque()                      # cred
    x.u32(); x.opaque()                      # verf
    tag = x.opaque()
    x.u32()                                  # minorversion
    if x.u32() == 0:
        return None
    op = x.u32()
    if op in (OP_SEQUENCE, OP_DESTROY_SESSION):
        return xid, tag, op, x.raw(16)
    if op == OP_CREATE_SESSION:
        return xid, tag, op, x.raw(8)
    return xid, tag, op, b""


def learn_reply(rec):
    """Track the ClientID and session handed out by the server."""
    x = X(rec)
    x.u32()
    if x.u32() != 1 or x.u32() != 0:
        return
    x.u32(); x.opaque()                      # verf
    if x.u32() != 0:
        return
    x.u32(); x.opaque()                      # compound status, tag
    if x.u32() == 0:
        return
    op, st = x.u32(), x.u32()
    if st != 0:
        return
    with lock:
        if op == OP_EXCHANGE_ID:
            state["clientid"] = x.raw(8)
            log(f"learn clientid {state['clientid'].hex()}")
        elif op == OP_CREATE_SESSION:
            state["session"] = x.raw(16)
            log(f"learn session {state['session'].hex()[:16]}")


def error_reply(xid, tag, op, err):
    pad = (4 - len(tag) % 4) % 4
    body = (struct.pack(">IIIIII", xid, 1, 0, 0, 0, 0) +
            struct.pack(">II", err, len(tag)) + tag + b"\0" * pad +
            struct.pack(">III", 1, op, err))
    return struct.pack(">I", 0x80000000 | len(body)) + body


def records(sock):
    buf = b""
    while True:
        data = sock.recv(65536)
        if not data:
            return
        buf += data
        while len(buf) >= 4:
            n = struct.unpack(">I", buf[:4])[0] & 0x7fffffff
            if len(buf) < 4 + n:
                break
            yield buf[:4 + n]
            buf = buf[4 + n:]


def client_to_server(client, server, wlock):
    try:
        for rec in records(client):
            try:
                call = parse_call(rec[4:])
            except (IndexError, struct.error):
                call = None
            err = None
            if call:
                xid, tag, op, arg = call
                with lock:
                    if op in (OP_SEQUENCE, OP_DESTROY_SESSION) and arg in dead_sessions:
                        err = NFS4ERR_BADSESSION
                    elif op == OP_CREATE_SESSION and arg in dead_clientids:
                        err = NFS4ERR_STALE_CLIENTID
            if err:
                log(f"inject {err} for op {op} xid {xid:08x}")
                with wlock:
                    client.sendall(error_reply(xid, tag, op, err))
            else:
                server.sendall(rec)
    except OSError:
        pass
    finally:
        for s in (client, server):
            try:
                s.close()
            except OSError:
                pass


def server_to_client(client, server, wlock):
    try:
        for rec in records(server):
            try:
                learn_reply(rec[4:])
            except (IndexError, struct.error):
                pass
            with wlock:
                client.sendall(rec)
    except OSError:
        pass


def reset(*_):
    with lock:
        if state["clientid"]:
            dead_clientids.add(state["clientid"])
        if state["session"]:
            dead_sessions.add(state["session"])
        victims = list(conns)
        conns.clear()
    log(f"RESET: {len(victims)} connection(s), clientid "
        f"{state['clientid'].hex() if state['clientid'] else None} now stale")
    for client, server in victims:
        try:
            client.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER,
                              struct.pack("ii", 1, 0))
            client.close()                   # RST, like EFS
            server.close()
        except OSError:
            pass


def scheduler(start, period, gap):
    time.sleep(start)
    while True:
        reset()
        time.sleep(gap)
        reset()
        time.sleep(max(period - gap, 1))


def hostport(s):
    h, p = s.rsplit(":", 1)
    return h, int(p)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--listen", default="127.0.0.1:2050")
    ap.add_argument("--server", default="127.0.0.1:2049")
    ap.add_argument("--start", type=float, default=30)
    ap.add_argument("--period", type=float, default=120)
    ap.add_argument("--gap", type=float, default=15)
    a = ap.parse_args()
    signal.signal(signal.SIGUSR1, reset)
    lsock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    lsock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    lsock.bind(hostport(a.listen))
    lsock.listen(16)
    log(f"listening on {a.listen} -> {a.server}; resets: start {a.start}s, "
        f"period {a.period}s, gap {a.gap}s")
    threading.Thread(target=scheduler, args=(a.start, a.period, a.gap),
                     daemon=True).start()
    while True:
        client, peer = lsock.accept()
        server = socket.create_connection(hostport(a.server))
        log(f"connection from {peer[0]}:{peer[1]}")
        wlock = threading.Lock()
        with lock:
            conns.append((client, server))
        threading.Thread(target=client_to_server, args=(client, server, wlock),
                         daemon=True).start()
        threading.Thread(target=server_to_client, args=(client, server, wlock),
                         daemon=True).start()


if __name__ == "__main__":
    main()
