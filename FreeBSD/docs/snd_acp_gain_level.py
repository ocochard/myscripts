# snd_acp_gain_level.py FILE: per channel, 440 Hz level (Goertzel) and broadband RMS, in dBFS, of stereo S32_LE, skipping 0.2 s.
import struct, sys, math
d = open(sys.argv[1], 'rb').read()
n = len(d) // 4
v = struct.unpack('<%di' % n, d[:n * 4])[9600 * 2:]
out = []
for c in (0, 1):
    x = [s / 2**31 for s in v[c::2]]
    m = sum(x) / len(x)
    x = [s - m for s in x]
    rms = math.sqrt(sum(s * s for s in x) / len(x))
    k = 2 * math.cos(2 * math.pi * 440 / 48000)
    s1 = s2 = 0.0
    for s in x:
        s1, s2 = s + k * s1 - s2, s1
    amp = 2 * math.sqrt(max(s1 * s1 + s2 * s2 - k * s1 * s2, 0)) / len(x)
    peak = max(abs(s) for s in x)
    db = lambda a: 20 * math.log10(a) if a > 0 else -999
    out.append("ch%d 440Hz %6.1f rms %6.1f peak %6.1f" % (c, db(amp / math.sqrt(2)), db(rms), db(peak)))
print(" | ".join(out))
