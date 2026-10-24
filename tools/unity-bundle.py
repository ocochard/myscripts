#!/usr/bin/env python3
"""List or extract the entries of a Unity asset bundle (UnityFS format).

No Python dependency: uses the system liblz4 through ctypes when present,
otherwise a slow pure-Python LZ4 decoder. LZMA bundles are not supported.

Typical entries: CAB-<hash> (serialized objects), .resS (texture/mesh data),
.resource (audio/video, e.g. concatenated MP4s). Object names and types live
in the CAB file; reading them needs UnityPy.

Usage:
  unity-bundle.py FILE.bundle             # list entries
  unity-bundle.py -x OUTDIR FILE.bundle   # extract entries into OUTDIR
"""
import argparse
import ctypes
import ctypes.util
import os
import struct
import sys

COMPRESSION = {0: 'none', 1: 'LZMA', 2: 'LZ4', 3: 'LZ4HC'}
FLAG_INDEX_AT_END = 0x80
FLAG_BLOCKS_ALIGNED = 0x200

_lib = ctypes.util.find_library('lz4')
_lz4 = ctypes.CDLL(_lib) if _lib else None


def lz4_block_py(src, size):
    out, i = bytearray(), 0
    while i < len(src):
        tok = src[i]
        i += 1
        n = tok >> 4
        if n == 15:
            while True:
                b = src[i]
                i += 1
                n += b
                if b != 255:
                    break
        out += src[i:i + n]
        i += n
        if i >= len(src) or len(out) >= size:
            break
        off = src[i] | src[i + 1] << 8
        i += 2
        m = tok & 15
        if m == 15:
            while True:
                b = src[i]
                i += 1
                m += b
                if b != 255:
                    break
        for _ in range(m + 4):
            out.append(out[-off])
    return bytes(out)


def lz4_block(src, size):
    if not _lz4:
        return lz4_block_py(src, size)
    dst = ctypes.create_string_buffer(size)
    n = _lz4.LZ4_decompress_safe(src, dst, len(src), size)
    if n != size:
        sys.exit(f'LZ4 error {n}')
    return dst.raw


def decompress(raw, size, flags, what):
    comp = flags & 0x3f
    if comp == 0:
        return raw
    if comp in (2, 3):
        return lz4_block(raw, size)
    sys.exit(f'{what} compression {COMPRESSION.get(comp, comp)} not supported')


def cstr(b, p):
    e = b.index(b'\0', p)
    return b[p:e].decode(), e + 1


def read_index(f):
    h = f.read(4096)
    sig, p = cstr(h, 0)
    if sig != 'UnityFS':
        sys.exit('not a UnityFS bundle')
    ver, = struct.unpack_from('>I', h, p)
    p += 4
    _player, p = cstr(h, p)
    engine, p = cstr(h, p)
    _size, csz, usz, flags = struct.unpack_from('>QIII', h, p)
    p += 20
    if ver >= 7:
        p = (p + 15) & ~15
    if flags & FLAG_INDEX_AT_END:
        f.seek(-csz, 2)
        data_start = p
    else:
        f.seek(p)
        data_start = p + csz
    if ver >= 7 and flags & FLAG_BLOCKS_ALIGNED:
        data_start = (data_start + 15) & ~15
    info = decompress(f.read(csz), usz, flags, 'index')

    q = 16  # skip uncompressed data hash
    nblk, = struct.unpack_from('>I', info, q)
    q += 4
    blocks = [struct.unpack_from('>IIH', info, q + i * 10) for i in range(nblk)]
    q += nblk * 10
    nfiles, = struct.unpack_from('>I', info, q)
    q += 4
    entries = []
    for _ in range(nfiles):
        off, sz, _fl = struct.unpack_from('>QQI', info, q)
        q += 20
        name, q = cstr(info, q)
        entries.append((off, sz, name))
    return engine, ver, data_start, blocks, entries


def extract(f, data_start, blocks, entries, outdir):
    os.makedirs(outdir, exist_ok=True)
    outs = [(off, off + sz, open(os.path.join(outdir, name), 'wb'))
            for off, sz, name in entries]
    f.seek(data_start)
    pos = 0
    for usize, csize, bflags in blocks:
        data = decompress(f.read(csize), usize, bflags, 'block')
        end = pos + usize
        for start, stop, fh in outs:
            lo, hi = max(start, pos), min(stop, end)
            if lo < hi:
                fh.write(data[lo - pos:hi - pos])
        pos = end
    for *_, fh in outs:
        fh.close()


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('-x', metavar='OUTDIR', help='extract entries into OUTDIR')
    ap.add_argument('bundle')
    args = ap.parse_args()

    with open(args.bundle, 'rb') as f:
        engine, ver, data_start, blocks, entries = read_index(f)
        algos = sorted({COMPRESSION.get(b[2] & 0x3f, '?') for b in blocks})
        print(f'Unity {engine}, format {ver}, {len(blocks)} blocks '
              f'({",".join(algos)}), {sum(b[0] for b in blocks)} bytes uncompressed')
        print(f'{"size":>12}  {"offset":>12}  name')
        for off, sz, name in entries:
            print(f'{sz:>12}  {off:>12}  {name}')
        if args.x:
            extract(f, data_start, blocks, entries, args.x)
            print(f'extracted {len(entries)} files to {args.x}')


if __name__ == '__main__':
    main()
