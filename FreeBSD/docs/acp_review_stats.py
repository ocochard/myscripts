# acp_review_stats.py FILE [window_ms]: stereo S32_LE; zero-sample count, peak, and DC per window of channel 0 (after 0.2 s).
import struct, sys, math
d = open(sys.argv[1], 'rb').read(); n = len(d) // 4
v = struct.unpack('<%di' % n, d[:n * 4])
x = v[0::2][9600:]
db = lambda a: 20 * math.log10(abs(a) / 2**31) if a else -999
peak = max(abs(s) for s in x) if x else 0
print("bytes %d zeros %d/%d peak %.1f dBFS" % (len(d), sum(1 for s in v if s == 0), len(v), db(peak)))
if len(sys.argv) > 2:
    w = int(48 * int(sys.argv[2]))
    print("  DC per %s ms: %s" % (sys.argv[2], " ".join("%.0f" % db(sum(x[i:i+w]) / w) for i in range(0, len(x) - w + 1, w))))
