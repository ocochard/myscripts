#!/usr/bin/env python3
"""Measure APU power and energy per token of an OpenAI-compatible LLM server.

Usage: npu-power-bench.py MODEL PORT [RUNS]
       npu-power-bench.py --idle SECONDS

Run as root.  Samples amdgpu's SMU metrics (gpu_metrics v3: socket,
NPU, GFX and CPU-core power, time-filtered by the SMU) every 0.2 s, and
reads the RAPL package energy counter (sysfs powercap on Linux, MSR
0xc001029b through cpuctl(4) on FreeBSD).  Energy per token uses RAPL:
the SMU averages lag on requests of a few seconds.  Prints the median of
RUNS runs per prompt.  Works for FastFlowLM ("flm serve") and llama.cpp
("llama-server").

With SHELLY=<address> in the environment, also reads the wall power of a
Shelly Gen2+ plug once a second (Switch.GetStatus, read-only: this
script never switches the plug).
"""
import glob
import json
import os
import statistics
import subprocess
import sys
import threading
import time
import urllib.request


sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gpu_metrics  # noqa: E402

FREEBSD = sys.platform.startswith("freebsd")


def metrics():
    if FREEBSD:
        return gpu_metrics.decode(gpu_metrics.sysctl_raw())
    return gpu_metrics.read()


SHELLY = os.environ.get("SHELLY")


def wall_w():
    """Wall power in W, or None when the plug is slow to answer."""
    url = f"http://{SHELLY}/rpc/Switch.GetStatus?id=0"
    try:
        return json.load(urllib.request.urlopen(url, timeout=2))["apower"]
    except (OSError, ValueError, KeyError):
        return None


POWERS = ("average_socket_power", "average_ipu_power", "average_gfx_power",
          "average_all_core_power")
RAPL = "/sys/class/powercap/intel-rapl:0/energy_uj"


def msr(reg):
    out = subprocess.run(["cpucontrol", "-m", hex(reg), "/dev/cpuctl0"],
                         capture_output=True, text=True, check=True).stdout
    hi, lo = out.split()[-2:]
    return (int(hi, 16) << 32) | int(lo, 16)


if FREEBSD:
    subprocess.run(["kldload", "-n", "cpuctl"], check=True)
    # MSR_RAPL_PWR_UNIT bits 12:8: energy unit is 1/2^ESU J.
    ESU_UJ = 1e6 / (1 << ((msr(0xc0010299) >> 8) & 0x1f))


def rapl_uj():
    if FREEBSD:
        # 32-bit counter; measure() handles one wrap.
        return (msr(0xc001029b) & 0xffffffff) * ESU_UJ
    return int(open(RAPL).read())


class Sampler(threading.Thread):
    def __init__(self):
        super().__init__(daemon=True)
        self.samples = []
        self.wall = []
        self.stop = threading.Event()

    def run(self):
        n = 0
        while not self.stop.is_set():
            m = metrics()
            self.samples.append([m[k] / 1000 for k in POWERS])
            if SHELLY and n % 5 == 0 and (w := wall_w()) is not None:
                self.wall.append(w)
            n += 1
            time.sleep(0.2)


def measure(fn):
    s = Sampler()
    e0, t0 = rapl_uj(), time.monotonic()
    s.start()
    result = fn()
    s.stop.set()
    s.join()
    e1, t1 = rapl_uj(), time.monotonic()
    if e1 < e0:
        e1 += (1 << 32) * ESU_UJ
    rapl_w = (e1 - e0) / 1e6 / (t1 - t0)
    smu = [statistics.mean(c) for c in zip(*s.samples)]
    smu.append(statistics.mean(s.wall) if s.wall else float("nan"))
    return result, smu, rapl_w, t1 - t0


if sys.argv[1] == "--idle":
    secs = float(sys.argv[2])
    _, smu, rapl, _ = measure(lambda: time.sleep(secs))
    print(f"idle {secs:.0f} s: RAPL {rapl:.1f} W, SMU socket {smu[0]:.1f} "
          f"NPU {smu[1]:.1f} GFX {smu[2]:.1f} cores {smu[3]:.1f} W, "
          f"wall {smu[4]:.1f} W")
    sys.exit(0)

model, port = sys.argv[1], int(sys.argv[2])
runs = int(sys.argv[3]) if len(sys.argv) > 3 else 3
filler = ("The FreeBSD project develops a complete operating system with a "
          "kernel, a userland, documentation and a ports collection. ") * 55
prompts = {
    "decode": ("/no_think Write a 700 word story about a lighthouse keeper.",
               768),
    "prefill": ("/no_think Count how many times the word kernel appears, "
                "then answer in one sentence. " + filler, 64),
}

for name, (text, max_tokens) in prompts.items():
    rows = []
    for i in range(runs):
        body = json.dumps({"model": model, "max_tokens": max_tokens,
                           "messages": [{"role": "user",
                                         "content": f"Run {i}: {text}"}]})
        req = urllib.request.Request(
            f"http://127.0.0.1:{port}/v1/chat/completions",
            data=body.encode(), headers={"Content-Type": "application/json"})
        d, smu, rapl, secs = measure(
            lambda: json.load(urllib.request.urlopen(req, timeout=900)))
        u = d["usage"]
        # Energy per generated token for decode, per prompt token for prefill.
        tok = u["completion_tokens"] if name == "decode" else u["prompt_tokens"]
        rows.append((rapl, secs, u["prompt_tokens"], u["completion_tokens"],
                     rapl * secs / tok, *smu))
        time.sleep(5)       # let power settle between runs
    med = [statistics.median(c) for c in zip(*rows)]
    print(f"{model} {name}: in {med[2]:.0f} out {med[3]:.0f} tok, "
          f"{med[1]:.1f} s, {med[3] / med[1] if name == 'decode' else med[2] / med[1]:.1f} tok/s, "
          f"RAPL {med[0]:.1f} W, {med[4]:.3f} J per "
          f"{'output' if name == 'decode' else 'prompt'} token; SMU socket "
          f"{med[5]:.1f} NPU {med[6]:.1f} GFX {med[7]:.1f} cores {med[8]:.1f} W"
          f", wall {med[9]:.1f} W, "
          f"{med[9] * med[1] / (med[3] if name == 'decode' else med[2]):.3f} J/token at the wall")
