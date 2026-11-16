#!/usr/bin/env python3
"""Compare FastFlowLM speed across hosts with fixed prompts.

Usage: flm-bench.py MODEL [PORT] [RUNS]
Needs a running "flm serve MODEL --port PORT".  Prints, per prompt, the
median prefill and decode tok/s that FastFlowLM reports.
"""
import json
import statistics
import sys
import urllib.request

model = sys.argv[1]
port = int(sys.argv[2]) if len(sys.argv) > 2 else 52625
runs = int(sys.argv[3]) if len(sys.argv) > 3 else 3

filler = ("The FreeBSD project develops a complete operating system with a "
          "kernel, a userland, documentation and a ports collection. ") * 55
prompts = {
    "short": ("/no_think In two sentences, what is FreeBSD?", 200),
    "long": ("/no_think Count how many times the word kernel appears, then "
             "write a 150 word story. " + filler, 256),
}

for name, (text, max_tokens) in prompts.items():
    pre, dec, pt, ct = [], [], [], []
    for i in range(runs):
        # A distinct first word defeats FastFlowLM's prefix cache.
        content = f"Run {i}: {text}"
        body = json.dumps({"model": model, "max_tokens": max_tokens,
                           "messages": [{"role": "user", "content": content}]})
        req = urllib.request.Request(
            f"http://127.0.0.1:{port}/v1/chat/completions",
            data=body.encode(), headers={"Content-Type": "application/json"})
        u = json.load(urllib.request.urlopen(req, timeout=900))["usage"]
        pre.append(u["prefill_speed_tps"])
        dec.append(u["decoding_speed_tps"])
        pt.append(u["prompt_tokens"])
        ct.append(u["completion_tokens"])
    print(f"{model} {name}: prompt {pt[0]} tok, out {min(ct)}-{max(ct)} tok, "
          f"prefill {statistics.median(pre):.1f} tok/s, "
          f"decode {statistics.median(dec):.1f} tok/s "
          f"(decode range {min(dec):.1f}-{max(dec):.1f})")
