#!/usr/bin/env python3
"""List NFSv4.1 RPCs in a plaintext pcap (the lo0 side of efs-proxy).

One line per RPC: time, direction, xid, op names, session id prefix,
slot/seqid of the SEQUENCE op, and for replies the compound and first-op
status. Pure stdlib; reads classic pcap (DLT_NULL or Ethernet).

usage: nfs41-pcap-ops.py file.pcap [--from HH:MM:SS] [--to HH:MM:SS] [--port N]
"""
import struct
import sys
import time

OPS = {3: "ACCESS", 4: "CLOSE", 5: "COMMIT", 6: "CREATE", 7: "DELEGPURGE",
       8: "DELEGRETURN", 9: "GETATTR", 10: "GETFH", 11: "LINK", 12: "LOCK",
       13: "LOCKT", 14: "LOCKU", 15: "LOOKUP", 16: "LOOKUPP", 17: "NVERIFY",
       18: "OPEN", 19: "OPENATTR", 20: "OPEN_CONFIRM", 21: "OPEN_DOWNGRADE",
       22: "PUTFH", 23: "PUTPUBFH", 24: "PUTROOTFH", 25: "READ",
       26: "READDIR", 27: "READLINK", 28: "REMOVE", 29: "RENAME",
       30: "RENEW", 31: "RESTOREFH", 32: "SAVEFH", 33: "SECINFO",
       34: "SETATTR", 37: "VERIFY", 38: "WRITE", 39: "RELEASE_LOCKOWNER",
       40: "BACKCHANNEL_CTL", 41: "BIND_CONN_TO_SESSION", 42: "EXCHANGE_ID",
       43: "CREATE_SESSION", 44: "DESTROY_SESSION", 45: "FREE_STATEID",
       47: "GETDEVICEINFO", 50: "LAYOUTGET", 52: "SECINFO_NO_NAME",
       53: "SEQUENCE", 54: "SET_SSV", 55: "TEST_STATEID", 56: "WANT_DELEGATION",
       57: "DESTROY_CLIENTID", 58: "RECLAIM_COMPLETE"}
CB_OPS = {3: "CB_GETATTR", 4: "CB_RECALL", 5: "CB_LAYOUTRECALL",
          6: "CB_NOTIFY", 11: "CB_SEQUENCE"}
NFS_PROG, CB_PROG_MIN = 100003, 0x40000000


class X:
    """Minimal XDR reader."""
    def __init__(self, b, o=0):
        self.b, self.o = b, o

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


def decode_call(x, xid):
    x.u32()                                  # rpcvers
    prog, vers, proc = x.u32(), x.u32(), x.u32()
    x.u32(); x.opaque()                      # cred
    x.u32(); x.opaque()                      # verf
    if proc == 0:
        return f"call xid={xid:08x} prog={prog} NULL"
    x.opaque()                               # tag
    minor, nops = x.u32(), x.u32()
    names, extra = [], ""
    table = CB_OPS if prog >= CB_PROG_MIN else OPS
    for i in range(nops):
        op = x.u32()
        names.append(table.get(op, f"op{op}"))
        if op in (53, 11) and i == 0:        # SEQUENCE / CB_SEQUENCE
            sid = x.raw(16)
            seq, slot = x.u32(), x.u32()
            extra = f" sess={sid.hex()[:16]} slot={slot} seq={seq}"
            x.u32(); x.u32() if op == 53 else None
            if op == 11:
                break
        elif op == 22:                       # PUTFH
            x.opaque()
        elif op == 42:                       # EXCHANGE_ID client_owner4
            verf = x.raw(8)
            owner = x.opaque()
            extra += f" verf={verf.hex()} owner={owner.hex()}"
            break
        elif op == 43:                       # CREATE_SESSION
            extra += f" clid={x.raw(8).hex()}"
            break
        elif op == 44:                       # DESTROY_SESSION
            extra += f" sess={x.raw(16).hex()[:16]}"
            break
        elif op == 57:                       # DESTROY_CLIENTID
            extra += f" clid={x.raw(8).hex()}"
            break
        elif op in (24, 10, 31, 32, 16):     # no args
            continue
        else:
            break                            # rest not decoded
    more = "" if len(names) == nops else f",+{nops - len(names)}"
    side = "CB " if prog >= CB_PROG_MIN else ""
    return f"{side}call xid={xid:08x} [{','.join(names)}{more}]{extra}"


def decode_reply(x, xid):
    if x.u32() != 0:
        return f"reply xid={xid:08x} DENIED"
    x.u32(); x.opaque()                      # verf
    if x.u32() != 0:
        return f"reply xid={xid:08x} accept_stat!=0"
    try:
        status = x.u32()
    except struct.error:
        return f"reply xid={xid:08x} (void)"
    x.opaque()
    nres = x.u32()
    if nres == 0:
        return f"reply xid={xid:08x} status={status}"
    op, st = x.u32(), x.u32()
    extra = ""
    if st == 0 and op in (53, 43):
        extra = f" sess={x.raw(16).hex()[:16]}"
    elif st == 0 and op == 42:
        extra = f" clid={x.raw(8).hex()}"
    return (f"reply xid={xid:08x} status={status} "
            f"{OPS.get(op, op)}={st}{extra}")


def packets(path):
    f = open(path, "rb")
    gh = f.read(24)
    magic = struct.unpack("<I", gh[:4])[0]
    e = "<" if magic in (0xa1b2c3d4, 0xa1b23c4d) else ">"
    nano = magic in (0xa1b23c4d, 0x4d3cb2a1)
    link = struct.unpack(e + "I", gh[20:24])[0]
    while True:
        h = f.read(16)
        if len(h) < 16:
            return
        sec, frac, incl, _ = struct.unpack(e + "IIII", h)
        data = f.read(incl)
        off = 4 if link == 0 else 14 if link == 1 else 0
        ip = data[off:]
        if not ip or ip[0] >> 4 != 4:
            continue
        ihl = (ip[0] & 15) * 4
        if ip[9] != 6:
            continue
        src, dst = ip[12:16], ip[16:20]
        tcp = ip[ihl:]
        sp, dp, seq = struct.unpack(">HHI", tcp[:8])
        flags = tcp[13]
        thl = (tcp[12] >> 4) * 4
        ts = sec + frac / (1e9 if nano else 1e6)
        yield ts, (src, sp, dst, dp), seq, flags, tcp[thl:]


def main():
    args = sys.argv[1:]
    path = args[0]
    lo = args[args.index("--from") + 1] if "--from" in args else "00:00:00"
    hi = args[args.index("--to") + 1] if "--to" in args else "99:99:99"
    port = int(args[args.index("--port") + 1]) if "--port" in args else None
    bufs, nxt = {}, {}
    for ts, flow, seq, flags, payload in packets(path):
        hms = time.strftime("%H:%M:%S", time.gmtime(ts))
        src, sp, dst, dp = flow
        if port and port not in (sp, dp):
            continue
        tag = f"{sp}->{dp}"
        if flags & 0x07:                     # FIN/SYN/RST
            if lo <= hms <= hi:
                kind = "".join(n for b, n in ((1, "FIN"), (2, "SYN"), (4, "RST"))
                               if flags & b)
                print(f"{hms}.{int(ts % 1 * 1e3):03d} {tag:13} tcp {kind}")
            if flags & 0x02:
                nxt[flow] = seq + 1
                bufs[flow] = b""
            continue
        if not payload:
            continue
        if flow in nxt and seq != nxt[flow]:
            if (seq - nxt[flow]) & 0xffffffff > 0x7fffffff:
                continue                     # retransmit
        nxt[flow] = (seq + len(payload)) & 0xffffffff
        buf = bufs.get(flow, b"") + payload
        while len(buf) >= 4:
            mark = struct.unpack(">I", buf[:4])[0]
            n = mark & 0x7fffffff
            # Capture started mid-record: slide until a plausible record
            # mark followed by an RPC header (msgtype 0/1).
            if not mark & 0x80000000 or n > (2 << 20) or (
                    len(buf) >= 12 and
                    struct.unpack(">I", buf[8:12])[0] not in (0, 1)):
                buf = buf[1:]
                continue
            if len(buf) < 4 + n:
                break
            rec, buf = buf[4:4 + n], buf[4 + n:]
            if not lo <= hms <= hi:
                continue
            try:
                x = X(rec)
                xid, mtype = x.u32(), x.u32()
                line = decode_call(x, xid) if mtype == 0 else decode_reply(x, xid)
            except (IndexError, struct.error):
                line = f"undecodable record len={n}"
            print(f"{hms}.{int(ts % 1 * 1e3):03d} {tag:13} {line}")
        bufs[flow] = buf


if __name__ == "__main__":
    main()
