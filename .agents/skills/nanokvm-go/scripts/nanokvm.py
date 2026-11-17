#!/usr/bin/env python3
"""Drive a Sipeed NanoKVM-Go (firmware application 0.2.x) from the shell.

Subcommands:
  shot OUT.png [--secs N] [--width W]   screenshot (last frame of N seconds)
  record OUT_PREFIX --secs N [--fps F] [--width W]
                                        record N seconds, save F frames/s as
                                        OUT_PREFIX_001.png ... and the .h264
  paste TEXT                            type TEXT ("\\n" = Enter) via the KVM
  key COMBO [COMBO ...]                 press keys, e.g. enter ctrl+alt+f2 up
  login                                 check the credentials, print OK

Configuration from the environment (never hard-code it):
  NANOKVM_HOST  address or name of the KVM (required)
  NANOKVM_USER  web UI user (required)
  NANOKVM_PASS  web UI password (required)

Needs python3 with the 'websockets' module, and ffmpeg for shot/record.
"""
import argparse
import asyncio
import json
import os
import ssl
import struct
import subprocess
import sys
import time
import urllib.request

import websockets

HOST = os.environ.get('NANOKVM_HOST')
USER = os.environ.get('NANOKVM_USER')
PASS = os.environ.get('NANOKVM_PASS')

CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE     # the KVM uses a self-signed certificate

# HID boot keyboard usage IDs (USB HID Usage Tables, page 0x07).
KEYS = {
    'enter': 0x28, 'esc': 0x29, 'escape': 0x29, 'backspace': 0x2a,
    'tab': 0x2b, 'space': 0x2c, 'minus': 0x2d, 'equal': 0x2e,
    'capslock': 0x39, 'printscreen': 0x46, 'scrolllock': 0x47,
    'pause': 0x48, 'insert': 0x49, 'home': 0x4a, 'pageup': 0x4b,
    'delete': 0x4c, 'end': 0x4d, 'pagedown': 0x4e, 'right': 0x4f,
    'left': 0x50, 'down': 0x51, 'up': 0x52,
}
for _i, _c in enumerate('abcdefghijklmnopqrstuvwxyz'):
    KEYS[_c] = 0x04 + _i
for _i, _c in enumerate('1234567890'):
    KEYS[_c] = 0x1e + _i
for _i in range(12):
    KEYS['f%d' % (_i + 1)] = 0x3a + _i
MODS = {'ctrl': 0x01, 'shift': 0x02, 'alt': 0x04, 'meta': 0x08,
        'rctrl': 0x10, 'rshift': 0x20, 'ralt': 0x40, 'rmeta': 0x80}


def die(msg):
    print('nanokvm: ' + msg, file=sys.stderr)
    sys.exit(1)


def login():
    if not (HOST and USER and PASS):
        die('set NANOKVM_HOST, NANOKVM_USER and NANOKVM_PASS')
    req = urllib.request.Request(
        'https://%s/api/auth/login' % HOST,
        data=json.dumps({'username': USER, 'password': PASS}).encode(),
        headers={'Content-Type': 'application/json'})
    reply = json.load(urllib.request.urlopen(req, context=CTX, timeout=10))
    token = (reply.get('data') or {}).get('token')
    if not token:
        die('login failed: %s' % reply)
    return token


def post(token, path, body):
    # POSTs are rejected ("csrf validation failed") without Origin/Referer.
    req = urllib.request.Request(
        'https://%s%s' % (HOST, path), data=json.dumps(body).encode(),
        headers={'Content-Type': 'application/json',
                 'Cookie': 'nano-kvm-token=' + token,
                 'Origin': 'https://' + HOST,
                 'Referer': 'https://%s/' % HOST})
    return json.load(urllib.request.urlopen(req, context=CTX, timeout=10))


async def read_stream(token, secs):
    """H.264 messages of the direct stream for 'secs' seconds."""
    chunks = []
    async with websockets.connect(
            'wss://%s/api/stream/h264/direct' % HOST, ssl=CTX,
            additional_headers={'Cookie': 'nano-kvm-token=' + token},
            max_size=None) as ws:
        loop = asyncio.get_running_loop()
        end = loop.time() + secs
        while loop.time() < end:
            try:
                m = await asyncio.wait_for(ws.recv(), timeout=end - loop.time())
            except (asyncio.TimeoutError, websockets.ConnectionClosed):
                break
            if isinstance(m, bytes):
                chunks.append(m)
    return b''.join(chunks)


def ffmpeg(args):
    r = subprocess.run(['ffmpeg', '-loglevel', 'error', '-y', '-f', 'h264']
                       + args, capture_output=True, text=True)
    return r.returncode


def cmd_shot(token, a):
    raw = asyncio.run(read_stream(token, a.secs))
    if not raw:
        die('no video (screen static, display off, or KVM link down)')
    h264 = a.out + '.h264'
    open(h264, 'wb').write(raw)
    vf = ['-vf', 'scale=%d:-1' % a.width] if a.width else []
    ffmpeg(['-i', h264, '-update', '1'] + vf + [a.out])
    if not os.path.exists(a.out):
        die('could not decode a frame from %s' % h264)
    os.remove(h264)
    print(a.out)


def cmd_record(token, a):
    raw = asyncio.run(read_stream(token, a.secs))
    if not raw:
        die('no video')
    h264 = a.out + '.h264'
    open(h264, 'wb').write(raw)
    vf = 'fps=%g' % a.fps + (',scale=%d:-1' % a.width if a.width else '')
    ffmpeg(['-i', h264, '-vf', vf, a.out + '_%03d.png'])
    print('%s (%d bytes); frames %s_NNN.png (frame time is the stream\'s, '
          'not wall clock)' % (h264, len(raw), a.out))


def cmd_paste(token, a):
    text = a.text.encode().decode('unicode_escape')
    reply = post(token, '/api/hid/paste', {'content': text})
    if reply.get('code', 0) != 0:
        die('paste failed: %s' % reply)
    print('OK')


def parse_combo(combo):
    mods, usage = 0, 0
    for part in combo.lower().split('+'):
        if part in MODS:
            mods |= MODS[part]
        elif part in KEYS:
            usage = KEYS[part]
        else:
            die('unknown key %r (see KEYS/MODS in this script)' % part)
    return mods, usage


async def send_keys(token, combos):
    """Keyboard state frames on /api/ws, as the web UI's virtual keyboard."""
    seq = 0

    def frame(report):
        nonlocal seq
        seq = (seq + 1) & 0xffffffff
        # InputRouter=3, version 1, source VirtualKeyboard=16,
        # type KeyboardState=1, flags 0, sequence, time stamp (ms).
        hdr = struct.pack('<BBBBBII', 3, 1, 16, 1, 0, seq,
                          int(time.monotonic() * 1000) & 0xffffffff)
        return hdr + bytes(report)

    async with websockets.connect(
            'wss://%s/api/ws' % HOST, ssl=CTX,
            additional_headers={'Cookie': 'nano-kvm-token=' + token,
                                'Origin': 'https://' + HOST}) as ws:
        for combo in combos:
            mods, usage = parse_combo(combo)
            await ws.send(frame([mods, 0, usage, 0, 0, 0, 0, 0]))
            await asyncio.sleep(0.05)
            await ws.send(frame([0] * 8))
            await asyncio.sleep(0.05)


def cmd_key(token, a):
    asyncio.run(send_keys(token, a.combos))
    print('OK')


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawTextHelpFormatter)
    sub = p.add_subparsers(dest='cmd', required=True)
    s = sub.add_parser('shot')
    s.add_argument('out')
    s.add_argument('--secs', type=float, default=4)
    s.add_argument('--width', type=int, default=960)
    r = sub.add_parser('record')
    r.add_argument('out')
    r.add_argument('--secs', type=float, required=True)
    r.add_argument('--fps', type=float, default=1)
    r.add_argument('--width', type=int, default=960)
    t = sub.add_parser('paste')
    t.add_argument('text')
    k = sub.add_parser('key')
    k.add_argument('combos', nargs='+')
    sub.add_parser('login')
    a = p.parse_args()

    token = login()
    if a.cmd == 'login':
        print('OK')
    else:
        globals()['cmd_' + a.cmd](token, a)


if __name__ == '__main__':
    main()
