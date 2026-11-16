#!/usr/bin/env python3
"""Average every amdgpu gpu_metrics v3 field over a period, as JSON.

Usage: gpu_metrics_idle.py [seconds]   (default 20, one sample a second)
Reads /sys/class/drm/card*/device/gpu_metrics on Linux and
sysctl sys.device.drmn0.gpu_metrics on FreeBSD.  Compare two systems with
"diff" or a small script on the JSON output.
"""
import json
import os
import statistics
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gpu_metrics  # noqa: E402


def raw():
    if sys.platform.startswith("freebsd"):
        return gpu_metrics.sysctl_raw()
    return open(gpu_metrics.path(), "rb").read()


secs = int(sys.argv[1]) if len(sys.argv) > 1 else 20
samples = []
for _ in range(secs):
    samples.append(gpu_metrics.decode_all(raw()))
    time.sleep(1)

avg = {}
for k, v in samples[0].items():
    if k in ("structure_size", "format_revision", "content_revision",
             "system_clock_counter"):
        continue
    if isinstance(v, list):
        avg[k] = [round(statistics.mean(s[k][i] for s in samples), 1)
                  for i in range(len(v))]
    else:
        avg[k] = round(statistics.mean(s[k] for s in samples), 1)
print(json.dumps(avg))
