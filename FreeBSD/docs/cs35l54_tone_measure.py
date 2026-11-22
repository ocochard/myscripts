#!/usr/bin/env python3
# Measure how long a 440 Hz tone is audible in a mono s16le 48 kHz
# recording (cs35l54_tone_record.sh): 440 Hz energy per 50 ms window
# (Goertzel), above 3 times the quiet floor.
import math, struct, sys

d = open(sys.argv[1] if len(sys.argv) > 1 else "cs-rec.raw", "rb").read()
n = len(d) // 2
x = struct.unpack("<%dh" % n, d[:n * 2])
fs, w = 48000, 2400

def goertzel(seg, f):
    k = 2 * math.cos(2 * math.pi * f / fs)
    s1 = s2 = 0.0
    for v in seg:
        s1, s2 = v + k * s1 - s2, s1
    return math.sqrt(max(s1 * s1 + s2 * s2 - k * s1 * s2, 0)) / len(seg)

p = [goertzel(x[i:i + w], 440) for i in range(0, n - w, w)]
thr = 3 * sorted(p)[len(p) // 4]
start = None
for i, v in enumerate(p + [0]):
    if v > thr and start is None:
        start = i
    elif v <= thr and start is not None:
        if i - start >= 3:
            print("440 Hz: %.2f s -> %.2f s  (%.2f s)" %
                (start * .05, i * .05, (i - start) * .05))
        start = None
