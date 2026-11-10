#!/usr/bin/env python3
"""Time TPM2_CreatePrimary (RSA 2048) on /dev/tpm0 to test long commands."""
import argparse
import os
import struct
import time

ap = argparse.ArgumentParser(
    description="Send COUNT TPM2_CreatePrimary commands for a transient RSA 2048 "
    "storage key under the owner hierarchy (empty owner auth), flush each key, "
    "and print each duration and response code. Nothing is written to TPM NV. "
    "A random 'unique' field forces a new key search every time. Run as root.")
ap.add_argument("count", type=int, nargs="?", default=5, metavar="COUNT")
args = ap.parse_args()

TPM_RH_OWNER, TPM_RS_PW = 0x40000001, 0x40000009


def create_primary():
    auth = struct.pack(">IHBH", TPM_RS_PW, 0, 0, 0)
    sensitive = struct.pack(">HH", 0, 0)
    unique = os.urandom(32)
    public = struct.pack(">HHIH", 0x0001, 0x000B, 0x00030072, 0)
    public += struct.pack(">HHH", 0x0006, 128, 0x0043)  # AES-128-CFB
    public += struct.pack(">HHI", 0x0010, 2048, 0)  # no scheme, 2048, e=65537
    public += struct.pack(">H", len(unique)) + unique
    body = struct.pack(">II", TPM_RH_OWNER, len(auth)) + auth
    body += struct.pack(">H", len(sensitive)) + sensitive
    body += struct.pack(">H", len(public)) + public
    body += struct.pack(">HI", 0, 0)  # outsideInfo, creationPCR
    return struct.pack(">HII", 0x8002, 10 + len(body), 0x131) + body


def xfer(fd, cmd):
    os.write(fd, cmd)
    rsp = os.read(fd, 4096)
    return rsp, struct.unpack(">HII", rsp[:10])[2]


fd = os.open("/dev/tpm0", os.O_RDWR)
for i in range(args.count):
    t = time.monotonic()
    try:
        rsp, rc = xfer(fd, create_primary())
    except OSError as e:
        print(f"{i} | {(time.monotonic() - t) * 1e3:.0f} ms | {e}", flush=True)
        continue
    ms = (time.monotonic() - t) * 1e3
    print(f"{i} | {ms:.0f} ms | rc {rc:#x}", flush=True)
    if rc == 0:
        handle = struct.unpack(">I", rsp[10:14])[0]
        _, frc = xfer(fd, struct.pack(">HIII", 0x8001, 14, 0x165, handle))
        if frc != 0:
            print(f"FlushContext {handle:#x} rc {frc:#x}")
