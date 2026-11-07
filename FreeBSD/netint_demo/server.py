#!/usr/bin/env python3
"""NETINT Quadra live demo: a web page starts a hardware transcode (HLS) and
shows card, CPU and RAM load.

Python standard library only. Listens on 127.0.0.1: put a TLS reverse proxy
in front of it. Users can only pick from fixed presets; nothing they send is
ever put on a command line.
"""
import ipaddress
import json
import os
import re
import secrets
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

BASE = Path(__file__).resolve().parent
VIDEO_DIR = Path(os.environ.get("DEMO_VIDEOS", BASE / "videos"))
HLS_ROOT = Path(os.environ.get("DEMO_HLS", "/tmp/netint_demo"))
FFMPEG = os.environ.get("DEMO_FFMPEG", "/usr/local/bin/ffmpeg-netint")
FFPROBE = os.environ.get("DEMO_FFPROBE", "/usr/local/bin/ffprobe")
NI_RSRC_MON = os.environ.get("DEMO_NI_RSRC_MON", "/usr/local/bin/ni_rsrc_mon")
BIND = os.environ.get("DEMO_BIND", "::")  # "::" = IPv6 and IPv4
PORT = int(os.environ.get("DEMO_PORT", "8080"))
MAX_SESSIONS = int(os.environ.get("DEMO_MAX_SESSIONS", "20"))
MAX_4K_OUT = int(os.environ.get("DEMO_MAX_4K_OUT", "2"))  # 2160p output
MAX_4K = int(os.environ.get("DEMO_MAX_4K", "6"))  # sources above 1080p
MODELS = Path(os.environ.get("DEMO_MODELS", BASE / "models"))
MAX_AI = int(os.environ.get("DEMO_MAX_AI", "6"))
# 0 = no time limit: a session lasts as long as the video (played once).
SESSION_SECONDS = int(os.environ.get("DEMO_SESSION_SECONDS", "0"))
# A session whose video reached the end keeps its files this long (seconds
# without a request) so the player can finish its buffer.
FINISHED_GRACE = int(os.environ.get("DEMO_FINISHED_GRACE", "120"))
IDLE_SECONDS = int(os.environ.get("DEMO_IDLE_SECONDS", "30"))
# Trust X-Forwarded-For only when the TCP peer is the local reverse proxy.
IFACE = os.environ.get("DEMO_IFACE", "re0")
LINK_MBPS = int(os.environ.get("DEMO_LINK_MBPS", "1000"))
MAX_CONNECTIONS = int(os.environ.get("DEMO_MAX_CONNECTIONS", "200"))
PER_IP = int(os.environ.get("DEMO_PER_IP", "1"))
TRUST_PROXY = os.environ.get("DEMO_TRUST_PROXY", "0") == "1"

# name -> (output height, video bitrate)
QUALITY = {
    "360p": (360, "800k"),
    "720p": (720, "2500k"),
    "1080p": (1080, "5000k"),
    "2160p": (2160, "15000k"),
}
# id -> (label, description shown on the page)
FILTERS = {
    "none": ("No filter",
             "Hardware decode, scale and encode only. The baseline to compare "
             "the other filters against."),
    "hvsplus": ("AI enhance (hvsplus)",
                "NETINT's built-in AI filter, run by the card's AI engine "
                "(level 2 of 3, no model file needed). It modifies the "
                "picture; compare sharpness and noise with 'No filter'. At "
                "2160p it runs at 1080p first, then the result is upscaled."),
    "ai_pre": ("AI pre-process (GentleAIEnhance)",
               "A neural network (GentleAIEnhance) loaded into the card's AI "
               "engine, applied before encoding. The network works at "
               "1280x720 only, so the picture is scaled to 720p, enhanced, "
               "then scaled to the chosen quality."),
    "roi": ("AI region of interest (YOLOv4)",
            "A YOLOv4 object-detection network finds objects (people, "
            "cars...) and the encoder spends more bits there while keeping "
            "the same total bitrate. Detected areas keep more detail, the "
            "rest looks softer. Best seen at 360p or 720p, where bitrate is "
            "scarce."),
    "flip": ("Horizontal flip",
             "Mirrors the picture. Runs on the card, no AI: shows that simple "
             "filters are done in hardware too."),
}
AI_FILTERS = {"hvsplus", "ai_pre", "roi"}  # use the card AI engine
# id -> (label, card encoder, extra args). hvc1 tag: Safari needs it.
CODECS = {
    "h264": ("H.264", "h264_ni_quadra_enc", []),
    "h265": ("H.265 (HEVC)", "h265_ni_quadra_enc", ["-tag:v", "hvc1"]),
    "av1": ("AV1", "av1_ni_quadra_enc", []),
}
DECODERS = {"h264": "h264_ni_quadra_dec", "hevc": "h265_ni_quadra_dec",
            "vp9": "vp9_ni_quadra_dec"}
CARD_KEYS = {"decoders", "encoders", "uploaders", "scalers", "AIs"}
VIDEO_EXT = {".mp4", ".mkv", ".mov", ".webm", ".ts"}
ID_RE = re.compile(r"^[0-9a-f]{16}$")
FILE_RE = re.compile(r"^(index\.m3u8|init\.mp4|seg[0-9]{1,6}\.m4s)$")

lock = threading.Lock()
sessions = {}
videos = {}
stats = {"card": None, "cpu": None, "ram": None, "net": None}


def read_kenv(name):
    try:
        r = subprocess.run(["kenv", name], capture_output=True, text=True,
                           timeout=5)
    except (OSError, subprocess.SubprocessError):
        return ""
    return r.stdout.strip() if r.returncode == 0 else ""


HOST = {}


def log(msg):
    print(time.strftime("%H:%M:%S"), msg, file=sys.stderr, flush=True)


# --------------------------------------------------------------- videos

def scan_videos():
    """Keep only files the card can decode (8-bit 4:2:0 H.264/HEVC/VP9)."""
    found = {}
    if not VIDEO_DIR.is_dir():
        return found
    for p in sorted(VIDEO_DIR.iterdir()):
        if p.suffix.lower() not in VIDEO_EXT:
            continue
        try:
            out = subprocess.run(
                [FFPROBE, "-v", "error", "-select_streams", "v:0",
                 "-show_entries", "stream=codec_name,width,height,pix_fmt:format=duration",
                 "-of", "json", str(p)],
                capture_output=True, text=True, timeout=20, check=True).stdout
            probe = json.loads(out)
            s = probe["streams"][0]
            dur = float(probe.get("format", {}).get("duration") or 0)
        except (subprocess.SubprocessError, OSError, KeyError, IndexError,
                ValueError):
            log(f"skip {p.name}: ffprobe failed")
            continue
        if s["codec_name"] not in DECODERS or s.get("pix_fmt") not in (
                "yuv420p", "yuvj420p"):
            log(f"skip {p.name}: {s['codec_name']} {s.get('pix_fmt')} "
                "not supported")
            continue
        found[p.stem] = {"path": p, "codec": s["codec_name"],
                         "w": int(s["width"]), "h": int(s["height"]), "dur": dur}
    return found


# ------------------------------------------------------------- sessions

class Session:
    def __init__(self, ip, name, quality, flt, codec):
        self.id = secrets.token_hex(8)
        self.ip, self.name, self.quality, self.flt = ip, name, quality, flt
        self.codec = codec
        self.dir = HLS_ROOT / self.id
        self.start = self.last_seen = time.time()
        self.state = "starting"
        self.fps = 0.0
        self.sent = deque()  # (time, bytes) delivered to the client
        self.errors = deque(maxlen=10)
        self.proc = None
        self.stopping = False
        self.out4k = QUALITY[quality][0] > 1080  # 4K encode: ~12% of the card
        self.heavy = videos[name]["h"] > 1080  # 4K decode: ~7% of the card

    def add_sent(self, n):
        self.sent.append((time.time(), n))

    def mbps(self, window=12):
        """Average delivered bitrate over the last `window` seconds."""
        now = time.time()
        while self.sent and now - self.sent[0][0] > window:
            self.sent.popleft()
        total = sum(n for _, n in list(self.sent))
        return round(total * 8 / min(window, max(1, now - self.start)) / 1e6,
                     2)

    def command(self):
        v = videos[self.name]
        height, bitrate = QUALITY[self.quality]
        width = max(2, round(height * v["w"] / v["h"] / 2) * 2)
        scale = f"ni_quadra_scale={width}:{height}"
        enc_params = []
        if self.flt == "hvsplus":
            if height > 1080:
                # The AI engine cannot sustain 30 fps at 2160p (about 25 fps,
                # and a second stream drops to 22): enhance at 1080p, upscale.
                w1 = max(2, round(1080 * v["w"] / v["h"] / 2) * 2)
                vf = (f"ni_quadra_scale={w1}:1080,ni_quadra_hvsplus=level=2,"
                      + scale)
            else:
                vf = scale + ",ni_quadra_hvsplus=level=2"
        elif self.flt == "ai_pre":
            vf = ("ni_quadra_scale=1280:720,ni_quadra_ai_pre=nb="
                  + str(MODELS / "GentleAIEnhance_1280x720.nb"))
            if (width, height) != (1280, 720):
                vf += "," + scale
        elif self.flt == "roi":
            vf = (scale + ",ni_quadra_roi=nb="
                  + str(MODELS / "network_binary_yolov4_head.nb")
                  + ":qpoffset=-0.6")
            # The encoder only applies the ROI map with RoiEnable=1, and
            # keeps the target bitrate only with RcEnable=1.
            enc_params = ["-xcoder-params", "RoiEnable=1:RcEnable=1"]
        elif self.flt == "flip":
            vf = scale + ",ni_quadra_flip=flip_type=0"
        else:
            vf = scale
        return [
            FFMPEG, "-hide_banner", "-loglevel", "error",
            "-progress", "pipe:1", "-nostats",
            # Real-time input, but the first 12 s are read at full speed: two
            # 6 s segments exist at once, so the player starts with a ~12 s
            # cushion. With plain -re the player sits one segment behind the
            # live edge and stalls every segment.
            "-readrate", "1", "-readrate_initial_burst", "12",
            "-c:v", DECODERS[v["codec"]], "-xcoder-params", "out=hw",
            "-i", str(v["path"]), "-an", "-sn", "-vf", vf,
            "-c:v", CODECS[self.codec][1], *CODECS[self.codec][2],
            *enc_params, "-b:v", bitrate,
            "-force_key_frames", "expr:gte(t,n_forced*2)",
            "-f", "hls", "-hls_time", "6",
            "-hls_segment_type", "fmp4", "-hls_fmp4_init_filename", "init.mp4",
            "-hls_list_size", "5",
            "-hls_flags", "delete_segments+independent_segments",
            "-hls_segment_filename", str(self.dir / "seg%d.m4s"),
            str(self.dir / "index.m3u8"),
        ]

    def run(self):
        self.dir.mkdir(parents=True, mode=0o700)
        self.proc = subprocess.Popen(
            self.command(), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True, start_new_session=True)
        threading.Thread(target=self._read_progress, daemon=True).start()
        threading.Thread(target=self._read_stderr, daemon=True).start()

    def _read_progress(self):
        for line in self.proc.stdout:
            k, _, val = line.strip().partition("=")
            if k == "fps":
                try:
                    self.fps = float(val)
                except ValueError:
                    pass
            elif k == "progress" and self.state == "starting":
                self.state = "running"
        self.proc.wait()
        rc = self.proc.returncode
        log(f"session {self.id} ended rc={rc} "
            f"{self.errors[-1] if self.errors else ''}")
        if rc == 0 and not self.stopping:
            # Reached the end of the video: the card is free already, keep
            # the files so the player can play its remaining segments.
            self.state = "finished"
            return
        self.state = "ended"
        self.cleanup()

    def cleanup(self):
        with lock:
            sessions.pop(self.id, None)
        shutil.rmtree(self.dir, ignore_errors=True)

    def _read_stderr(self):
        for line in self.proc.stderr:
            self.errors.append(line.strip()[:200])

    def stop(self):
        p = self.proc
        if self.state == "finished":
            self.cleanup()
            return
        if p is None or p.poll() is not None or self.stopping:
            return
        self.stopping = True
        # ffmpeg-netint ignores SIGTERM; "q" on stdin is the clean stop that
        # also releases the card sessions. Signals are only a fallback.
        try:
            p.stdin.write("q\n")
            p.stdin.flush()
        except (OSError, ValueError):
            pass

        def _escalate():
            for sig, wait in ((signal.SIGTERM, 6), (signal.SIGKILL, 0)):
                try:
                    p.wait(timeout=wait or 1)
                    return
                except subprocess.TimeoutExpired:
                    pass
                try:
                    os.killpg(p.pid, sig)
                except ProcessLookupError:
                    return
        threading.Thread(target=_escalate, daemon=True).start()


def start_session(ip, name, quality, flt, codec):
    """Returns (session, None) or (None, (http_status, message))."""
    with lock:
        mine = sorted((s for s in sessions.values() if s.ip == ip),
                      key=lambda s: s.start)
        evict = mine[:max(0, len(mine) - PER_IP + 1)]
        for s in evict:
            sessions.pop(s.id, None)
    for s in evict:
        s.stop()
    with lock:
        live = [x for x in sessions.values() if x.state != "finished"]
        if len(live) >= MAX_SESSIONS:
            return None, (503, f"busy: {MAX_SESSIONS}/{MAX_SESSIONS} streams "
                               "in use, retry in a minute")
        if flt in AI_FILTERS and sum(
                1 for x in live if x.flt in AI_FILTERS) >= MAX_AI:
            return None, (503, "AI filter slots are busy, try another "
                               "filter or retry in a minute")
        if videos[name]["h"] > 1080 and sum(
                1 for x in live if x.heavy) >= MAX_4K:
            return None, (503, "4K video slots are busy, try a 1080p video "
                               "or retry in a minute")
        if QUALITY[quality][0] > 1080 and sum(
                1 for x in live if x.out4k) >= MAX_4K_OUT:
            return None, (503, "2160p output slots are busy, try 1080p "
                               "or retry in a minute")
        s = Session(ip, name, quality, flt, codec)
        sessions[s.id] = s
    try:
        s.run()
    except OSError as e:
        with lock:
            sessions.pop(s.id, None)
        return None, (500, f"cannot start encoder: {e.strerror}")
    log(f"session {s.id} start {name} {quality} {flt} {codec}")
    return s, None


def reaper():
    while True:
        time.sleep(2)
        now = time.time()
        with lock:
            snapshot = list(sessions.values())
        for s in snapshot:
            idle = now - s.last_seen
            if s.state == "finished":
                if idle > FINISHED_GRACE:
                    s.cleanup()
            elif (SESSION_SECONDS and now - s.start > SESSION_SECONDS) or \
                    idle > IDLE_SECONDS:
                s.stop()


# ---------------------------------------------------------------- stats

def sysctl(*names):
    out = subprocess.run(["sysctl", "-n", *names], capture_output=True,
                         text=True, timeout=5).stdout.split()
    return out


def read_cp_time():
    return [int(x) for x in sysctl("kern.cp_time")]


def read_card():
    out = subprocess.run([NI_RSRC_MON, "-S", "-o", "json", "-l", "none"],
                         capture_output=True, text=True, timeout=15).stdout
    i = out.find("{")
    if i < 0:
        return None
    data, _ = json.JSONDecoder().raw_decode(out[i:])
    card = {}
    for key, entries in data.items():
        if key not in CARD_KEYS or not isinstance(entries, list) \
                or not entries:
            continue
        card[key] = {
            "load": max(int(e.get("LOAD", 0)) for e in entries),
            "inst": sum(int(e.get("INST", 0)) for e in entries),
            "max_inst": sum(int(e.get("MAX_INST", 0)) for e in entries),
        }
    first = next((v[0] for k, v in data.items()
                  if k in CARD_KEYS and isinstance(v, list) and v), {})
    card["temp"] = first.get("TEMP")
    m = re.match(r"(\d+)", str(first.get("POWER", "")))
    card["power_mw"] = int(m.group(1)) if m else None
    return card


def read_net():
    """(rx_bytes, tx_bytes) of IFACE from the link-level netstat row."""
    out = subprocess.run(["netstat", "-ibn", "-I", IFACE],
                         capture_output=True, text=True,
                         timeout=5).stdout.splitlines()
    for line in out[1:]:
        f = line.split()
        if len(f) >= 11 and f[2].startswith("<Link"):
            return int(f[7]), int(f[10])
    return None


def collector():
    prev = read_cp_time()
    net_hist = deque(maxlen=6)  # ~10 s of (time, rx, tx) samples
    first = read_net()
    if first:
        net_hist.append((time.monotonic(), *first))
    page = int(sysctl("hw.pagesize")[0])
    phys = int(sysctl("hw.physmem")[0])
    while True:
        time.sleep(2)
        try:
            cur = read_cp_time()
            d = [c - p for c, p in zip(cur, prev)]
            prev = cur
            total = sum(d) or 1
            cpu = round(100 * (1 - d[4] / total), 1)
            free, inactive = (int(x) for x in sysctl(
                "vm.stats.vm.v_free_count", "vm.stats.vm.v_inactive_count"))
            used_pct = round(100 * (1 - (free + inactive) * page / phys), 1)
            with lock:
                pids = [s.proc.pid for s in sessions.values() if s.proc]
            rss_kb = 0
            if pids:
                ps = subprocess.run(
                    ["ps", "-o", "rss=", "-p", ",".join(map(str, pids))],
                    capture_output=True, text=True, timeout=5).stdout.split()
                rss_kb = sum(int(x) for x in ps)
            card = read_card()
            net = None
            cur_net = read_net()
            if cur_net:
                net_hist.append((time.monotonic(), *cur_net))
            if len(net_hist) >= 2:
                dt = net_hist[-1][0] - net_hist[0][0]
                net = {"iface": IFACE, "link_mbps": LINK_MBPS,
                       "rx_mbps": round((net_hist[-1][1] - net_hist[0][1])
                                        * 8 / dt / 1e6, 2),
                       "tx_mbps": round((net_hist[-1][2] - net_hist[0][2])
                                        * 8 / dt / 1e6, 2)}
            with lock:
                stats["net"] = net
                stats["cpu"] = cpu
                stats["ram"] = {"used_pct": used_pct,
                                "streams_mb": round(rss_kb / 1024)}
                stats["card"] = card
        except (subprocess.SubprocessError, OSError, ValueError) as e:
            log(f"stats error: {e}")


# ----------------------------------------------------------------- http

CSP = ("default-src 'none'; script-src 'self'; style-src 'self' "
       "'unsafe-inline'; connect-src 'self'; media-src 'self' blob:; "
       "worker-src 'self' blob:; img-src 'self' data:")
STATIC = {
    "/": ("index.html", "text/html; charset=utf-8"),
    "/app.js": ("app.js", "text/javascript; charset=utf-8"),
    "/hls.min.js": ("hls.min.js", "text/javascript; charset=utf-8"),
}


def ip_key(addr):
    """Per-visitor key: IPv4-mapped addresses are unwrapped, IPv6 clients
    are grouped by /64 (one subscriber owns a whole /64)."""
    try:
        ip = ipaddress.ip_address(addr)
    except ValueError:
        return addr
    if ip.version == 6 and ip.ipv4_mapped:
        return str(ip.ipv4_mapped)
    if ip.version == 6:
        return str(ipaddress.ip_network(f"{ip}/64", strict=False))
    return str(ip)


class Server(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 128

    def __init__(self, addr, handler):
        self.address_family = (socket.AF_INET6 if ":" in addr[0]
                               else socket.AF_INET)
        self.slots = threading.BoundedSemaphore(MAX_CONNECTIONS)
        super().__init__(addr, handler)

    def server_bind(self):
        if self.address_family == socket.AF_INET6:
            self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        super().server_bind()

    def process_request(self, request, client_address):
        if not self.slots.acquire(blocking=False):
            self.shutdown_request(request)  # over the connection cap
            return
        super().process_request(request, client_address)

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.slots.release()


class Handler(BaseHTTPRequestHandler):
    server_version = "niquadra-demo"
    sys_version = ""
    timeout = 10  # seconds per socket operation: drops idle/slow clients

    def log_message(self, *args):
        pass

    def client_ip(self):
        peer = self.client_address[0]
        if TRUST_PROXY and ip_key(peer) in ("127.0.0.1", "::1/128"):
            fwd = self.headers.get("X-Forwarded-For", "")
            if fwd:
                return ip_key(fwd.split(",")[-1].strip())
        return ip_key(peer)

    def send_bytes(self, code, body, ctype, cache="no-store"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", cache)
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Content-Security-Policy", CSP)
        self.end_headers()
        self.wfile.write(body)

    def send_json(self, code, obj):
        self.send_bytes(code, json.dumps(obj).encode(), "application/json")

    def do_GET(self):
        path, _, query = self.path.partition("?")
        if path in STATIC:
            name, ctype = STATIC[path]
            try:
                body = (BASE / "static" / name).read_bytes()
            except OSError:
                return self.send_json(404, {"error": "not found"})
            return self.send_bytes(200, body, ctype, "max-age=300")
        if path == "/api/videos":
            return self.send_json(200, {
                "videos": list(videos),
                "codecs": {k: v[0] for k, v in CODECS.items()},
                "quality": list(QUALITY),
                "filters": {k: {"label": v[0], "desc": v[1]}
                            for k, v in FILTERS.items()},
                "max": MAX_SESSIONS, "host": HOST})
        if path == "/api/stats":
            return self.api_stats(query)
        m = re.match(r"^/hls/([0-9a-f]{16})/([^/]+)$", path)
        if m and ID_RE.match(m.group(1)) and FILE_RE.match(m.group(2)):
            return self.serve_hls(m.group(1), m.group(2))
        self.send_json(404, {"error": "not found"})

    def api_stats(self, query):
        sid = dict(p.split("=", 1) for p in query.split("&")
                   if "=" in p).get("s", "")
        with lock:
            s = sessions.get(sid) if ID_RE.match(sid) else None
            out = {"streams": sum(1 for x in sessions.values()
                                   if x.state != "finished"),
                   "max": MAX_SESSIONS,
                   "cpu": stats["cpu"], "ram": stats["ram"],
                   "card": stats["card"], "net": stats["net"],
                   "session": None}
        if s is not None:
            s.last_seen = time.time()
            out["session"] = {
                "state": s.state, "fps": s.fps, "mbps": s.mbps(),
                "target": QUALITY[s.quality][1],
                "remaining": max(0, int(videos[s.name]["dur"] -
                                        (time.time() - s.start))),
                "error": s.errors[-1] if s.errors else ""}
        elif ID_RE.match(sid):
            out["session"] = {"state": "ended"}
        self.send_json(200, out)

    def serve_hls(self, sid, fname):
        with lock:
            s = sessions.get(sid)
        if s is None:
            return self.send_json(404, {"error": "no such session"})
        s.last_seen = time.time()
        try:
            body = (s.dir / fname).read_bytes()
        except OSError:
            return self.send_json(404, {"error": "not ready"})
        ctype = ("application/vnd.apple.mpegurl" if fname.endswith(".m3u8")
                 else "video/mp4")
        self.send_bytes(200, body, ctype)
        s.add_sent(len(body))

    def read_json(self):
        try:
            n = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            n = 0
        if not 0 < n <= 512:
            return None
        try:
            obj = json.loads(self.rfile.read(n))
        except ValueError:
            return None
        return obj if isinstance(obj, dict) else None

    def do_POST(self):
        req = self.read_json()
        if req is None:
            return self.send_json(400, {"error": "bad request"})
        if self.path == "/api/start":
            name, q, f = req.get("video"), req.get("quality"), req.get(
                "filter")
            codec = req.get("codec", "h264")
            if name not in videos or q not in QUALITY or f not in FILTERS \
                    or codec not in CODECS:
                return self.send_json(400, {"error": "bad parameters"})
            s, err = start_session(self.client_ip(), name, q, f, codec)
            if err:
                return self.send_json(err[0], {"error": err[1]})
            return self.send_json(200, {"id": s.id})
        if self.path == "/api/stop":
            sid = req.get("id", "")
            with lock:
                s = sessions.get(sid) if isinstance(sid, str) and \
                    ID_RE.match(sid) else None
            if s is not None:
                s.stop()
            return self.send_json(200, {"ok": True})
        self.send_json(404, {"error": "not found"})


def shutdown(*_):
    with lock:
        snapshot = list(sessions.values())
    for s in snapshot:
        s.stop()
    time.sleep(2)
    shutil.rmtree(HLS_ROOT, ignore_errors=True)
    os._exit(0)


def main():
    global videos
    shutil.rmtree(HLS_ROOT, ignore_errors=True)
    HLS_ROOT.mkdir(parents=True, mode=0o700, exist_ok=True)
    HOST.update({k: v for k, v in (
        ("system", read_kenv("smbios.system.product")),
        ("cpu", read_kenv("smbios.processor.version"))) if v})
    videos = scan_videos()
    if not videos:
        sys.exit(f"no usable video in {VIDEO_DIR}")
    log(f"videos: {', '.join(videos)}")
    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)
    threading.Thread(target=reaper, daemon=True).start()
    threading.Thread(target=collector, daemon=True).start()
    srv = Server((BIND, PORT), Handler)
    log(f"listening on [{BIND}]:{PORT}, max {MAX_SESSIONS} sessions, "
        f"{MAX_CONNECTIONS} connections")
    srv.serve_forever()


if __name__ == "__main__":
    main()
