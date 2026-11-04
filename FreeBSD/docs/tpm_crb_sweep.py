#!/usr/bin/env python3
"""Sweep the gap between read-only TPM2_GetRandom commands on /dev/tpm0."""
import argparse
import collections
import os
import re
import struct
import subprocess
import time

ap = argparse.ArgumentParser(
    description="Send COUNT TPM2_GetRandom commands to /dev/tpm0 for each GAP_MS, "
    "and report how many fail with EIO and which tpmcrb0 kernel messages appear. "
    "TPM2_GetRandom changes no persistent TPM state. Run as root.",
    epilog="example: %(prog)s 2000 0 0 0 0 0.5 1 2 5 10 50  "
    "(repeat 0: the failure rate swings a lot between runs)")
ap.add_argument("count", type=int, metavar="COUNT", help="commands sent per run")
ap.add_argument("gaps", type=float, nargs="+", metavar="GAP_MS",
                help="sleep before each command in ms, one run per value; 0 = back-to-back")
args = ap.parse_args()
N = args.count
fd = os.open("/dev/tpm0", os.O_RDWR)
c = struct.pack(">HIIH", 0x8001, 12, 0x17B, 32)
PAT = re.compile(r"^tpmcrb0: (Failed to transition to (idle|ready) state|Failed to obtain locality|Device has Error bit set)")


def msgs():
    out = subprocess.run(["dmesg"], capture_output=True, text=True).stdout
    return collections.Counter(m.group(1) for m in map(PAT.match, out.splitlines()) if m)


print("gap_ms | n | fails | fail% | ms between cmds | fail durations | new kernel messages")
for gap_ms in args.gaps:
    before = msgs()
    fails, durations, real_gaps = 0, collections.Counter(), []
    last_end = None
    for _ in range(N):
        if gap_ms:
            time.sleep(gap_ms / 1000)
        t = time.monotonic()
        if last_end is not None:
            real_gaps.append(t - last_end)
        try:
            os.write(fd, c)
            os.read(fd, 4096)
        except OSError:
            fails += 1
            durations[round((time.monotonic() - t) * 10) / 10] += 1
        last_end = time.monotonic()
    real_gaps.sort()
    delta = msgs() - before
    print(f"{gap_ms:g} | {N} | {fails} | {100 * fails / N:.2f} | "
          f"{real_gaps[len(real_gaps) // 2] * 1e3:.2f} | {dict(sorted(durations.items()))} | {dict(delta)}", flush=True)
