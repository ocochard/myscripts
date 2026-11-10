#!/usr/bin/env python3
"""Match tpm_stall_probe gaps against TPM command times recorded by dtrace."""
import argparse
import collections

ap = argparse.ArgumentParser(
    description="Find stalls seen by at least MIN_CPUS CPUs at once, and say "
    "whether each one overlaps a TPM command.")
ap.add_argument("gaps", help="tpm_stall_probe output: start_ns cpu gap_us")
ap.add_argument("tpm", help="dtrace output: start_ns end_ns, one TPM command per line")
ap.add_argument("--min-cpus", type=int, default=8)
ap.add_argument("--slack-ms", type=float, default=5,
                help="widen each TPM command window by this much")
args = ap.parse_args()

gaps = []
for line in open(args.gaps):
    s, cpu, us = map(int, line.split())
    gaps.append((s, s + us * 1000, cpu))
cmds = [tuple(map(int, l.split())) for l in open(args.tpm) if l.strip()]
slack = int(args.slack_ms * 1e6)


def in_tpm(s, e):
    return any(s < ce + slack and e > cs - slack for cs, ce in cmds)


# Group overlapping gaps; a group touching MIN_CPUS distinct CPUs is a stall.
gaps.sort()
groups, cur, cur_end = [], [], 0
for g in gaps:
    if cur and g[0] > cur_end:
        groups.append(cur)
        cur = []
    if not cur:
        cur_end = g[1]
    cur.append(g)
    cur_end = max(cur_end, g[1])
if cur:
    groups.append(cur)

stalls = [g for g in groups if len({c for _, _, c in g}) >= args.min_cpus]
print(f"{len(gaps)} gaps, {len(cmds)} TPM commands, "
      f"{len(stalls)} stalls on >= {args.min_cpus} CPUs")
hist = collections.Counter()
for g in stalls:
    s, e = min(x[0] for x in g), max(x[1] for x in g)
    shortest = min((x[1] - x[0]) for x in g) / 1e3
    tag = "during TPM command" if in_tpm(s, e) else "no TPM command"
    hist[tag] += 1
    print(f"  {s} cpus={len({c for _, _, c in g})} "
          f"span={(e - s) / 1e3:.0f} us shortest={shortest:.0f} us {tag}")
print(dict(hist))
per_cpu = collections.Counter()
for s, e, _ in gaps:
    per_cpu["during TPM command" if in_tpm(s, e) else "no TPM command"] += 1
print("all gaps:", dict(per_cpu))
