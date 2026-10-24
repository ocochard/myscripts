#!/usr/bin/env python3
"""List and modify store variables in Ren'Py save files (*.save).

A .save file is a zip; the game state is the "log" member, a pickle of
(roots, rollback_log). roots maps "store.<name>" to its value. The pickle
references Ren'Py classes, so it is never unpickled here: the opcode stream
is scanned and scalar values (int, float, bool, None, str) are patched in place.

Only roots is patched: rollback snapshots key variables without the "store."
prefix and are left alone, so rolling back in-game may restore an old value.

Usage:
  renpy-save.py list FILE [SUBSTRING]
  renpy-save.py find FILE VALUE
  renpy-save.py set FILE NAME=VALUE [NAME=VALUE ...]

NAME may omit the "store." prefix. 'set' writes a timestamped FILE.<date>.bak
before overwriting FILE. Ren'Py >= 8.1 signs saves: a patched save triggers
a one-time "created on another device" prompt, answer yes to load it.
"""

import argparse
import ast
import os
import pickletools
import shutil
import struct
import sys
import time
import zipfile

STRING_OPS = ("SHORT_BINSTRING", "BINSTRING", "STRING", "SHORT_BINUNICODE",
              "BINUNICODE", "BINUNICODE8", "UNICODE")
PUT_OPS = ("BINPUT", "LONG_BINPUT", "PUT", "MEMOIZE")
GET_OPS = ("BINGET", "LONG_BINGET", "GET")
INT_OPS = ("BININT1", "BININT2", "BININT", "INT", "LONG1", "LONG4", "LONG")
FLOAT_OPS = ("BINFLOAT", "FLOAT")
CONST_OPS = {"NEWTRUE": True, "NEWFALSE": False, "NONE": None}


def load(path):
    with zipfile.ZipFile(path) as z:
        return [(i, z.read(i.filename)) for i in z.infolist()]


def save(path, members, log):
    tmp = path + ".tmp"
    with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as z:
        for info, data in members:
            z.writestr(info, log if info.filename == "log" else data)
    os.replace(tmp, path)


def get_log(members):
    for info, data in members:
        if info.filename == "log":
            return data
    sys.exit("error: no 'log' member, not a Ren'Py save")


def scan(log):
    """Yield (name, value, start, end, opname) for each store.<name> scalar.

    start/end delimit the value opcode in log. A value is recognised when it
    directly follows a "store.*" key (literal or memo reference), optionally
    with a memo PUT in between.
    """
    ops = list(pickletools.genops(log))
    if any(op.name == "FRAME" for op, _, _ in ops):
        sys.exit("error: framed pickle (protocol 4+) not supported")
    memo = {}
    nmemo = 0
    for k, (op, arg, pos) in enumerate(ops):
        # Track memoized strings so BINGET keys resolve to their names
        if op.name in PUT_OPS:
            prev = ops[k - 1]
            idx = nmemo if op.name == "MEMOIZE" else arg
            nmemo += 1
            if prev[0].name in STRING_OPS:
                memo[idx] = prev[1]
            continue
        if op.name in STRING_OPS:
            key = arg
        elif op.name in GET_OPS:
            key = memo.get(arg)
        else:
            continue
        if not isinstance(key, str) or not key.startswith("store."):
            continue
        j = k + 1
        if j < len(ops) and ops[j][0].name in PUT_OPS:
            j += 1
        if j >= len(ops):
            continue
        vop, varg, vpos = ops[j]
        end = ops[j + 1][2] if j + 1 < len(ops) else len(log)
        name = key[len("store."):]
        if vop.name in INT_OPS or vop.name in FLOAT_OPS or vop.name in STRING_OPS:
            yield name, varg, vpos, end, vop.name
        elif vop.name in CONST_OPS:
            yield name, CONST_OPS[vop.name], vpos, end, vop.name
        elif vop.name in GET_OPS and isinstance(memo.get(varg), str):
            # Shared string: patching swaps the reference for a fresh literal
            yield name, memo[varg], vpos, end, "BINUNICODE"


def roots_vars(log):
    """First occurrence of each variable: the roots dict (pickled first)."""
    out = {}
    for name, value, _, _, _ in scan(log):
        out.setdefault(name, value)
    return out


def encode(value, oldop):
    if isinstance(value, bool):
        return b"\x88" if value else b"\x89"
    if value is None:
        return b"N"
    if isinstance(value, int):
        if 0 <= value < 0x100:
            return b"K" + struct.pack("<B", value)
        if 0 <= value < 0x10000:
            return b"M" + struct.pack("<H", value)
        if -0x80000000 <= value < 0x80000000:
            return b"J" + struct.pack("<i", value)
        raw = value.to_bytes((value.bit_length() + 8) // 8, "little", signed=True)
        return b"\x8a" + struct.pack("<B", len(raw)) + raw
    if isinstance(value, float):
        return b"G" + struct.pack(">d", value)
    if isinstance(value, str):
        # Keep py2 byte strings as byte strings (Ren'Py 7 str vs unicode)
        if oldop in ("SHORT_BINSTRING", "BINSTRING", "STRING"):
            raw = value.encode("latin-1")
            if len(raw) < 0x100:
                return b"U" + struct.pack("<B", len(raw)) + raw
            return b"T" + struct.pack("<I", len(raw)) + raw
        raw = value.encode("utf-8")
        return b"X" + struct.pack("<I", len(raw)) + raw
    raise ValueError("unsupported type %s" % type(value).__name__)


def parse_value(s):
    """Python literal (42, 1.5, True, None, 'txt'); anything else is a string."""
    try:
        v = ast.literal_eval(s)
    except (ValueError, SyntaxError):
        return s
    if v is None or isinstance(v, (bool, int, float, str)):
        return v
    return s


def coerce(old, new):
    # 95 into a float var stays a float; plain text into a str var stays text
    if isinstance(old, float) and isinstance(new, int) and not isinstance(new, bool):
        return float(new)
    if isinstance(old, str) and not isinstance(new, str):
        return str(new)
    return new


def cmd_list(args):
    for name, value in sorted(roots_vars(get_log(load(args.file))).items()):
        if args.substring is None or args.substring.lower() in name.lower():
            print("%s = %r" % (name, value))


def cmd_find(args):
    want = parse_value(args.value)
    for name, value in sorted(roots_vars(get_log(load(args.file))).items()):
        # Keep True/1 and False/0 distinct
        if (isinstance(value, bool) == isinstance(want, bool)) and value == want:
            print("%s = %r" % (name, value))


def cmd_set(args):
    changes = {}
    for item in args.assignments:
        if "=" not in item:
            sys.exit("error: expected NAME=VALUE, got %r" % item)
        name, value = item.split("=", 1)
        name = name.strip()
        if name.startswith("store."):
            name = name[len("store."):]
        changes[name] = parse_value(value.strip())

    members = load(args.file)
    log = get_log(members)
    current = roots_vars(log)
    missing = [n for n in changes if n not in current]
    if missing:
        sys.exit("error: unknown or non-scalar variable(s): %s" % ", ".join(missing))

    patches = []
    for name, value, start, end, op in scan(log):
        if name in changes:
            new = coerce(current[name], changes[name])
            patches.append((start, end, encode(new, op)))
    # Opcode lengths may change; pickle uses memo indices, not offsets, so
    # splicing back to front keeps every other opcode valid.
    buf = bytearray(log)
    for start, end, data in sorted(patches, reverse=True):
        buf[start:end] = data
    log = bytes(buf)

    after = roots_vars(log)
    for name in changes:
        print("%s: %r -> %r" % (name, current[name], after[name]))
    bak = "%s.%s.bak" % (args.file, time.strftime("%Y%m%d-%H%M%S"))
    shutil.copy2(args.file, bak)
    save(args.file, members, log)
    print("%d occurrence(s) patched, backup: %s" % (len(patches), bak))


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    pl = sub.add_parser("list", help="list scalar store variables")
    pl.add_argument("file")
    pl.add_argument("substring", nargs="?")
    pl.set_defaults(func=cmd_list)
    pf = sub.add_parser("find", help="list variables holding VALUE")
    pf.add_argument("file")
    pf.add_argument("value")
    pf.set_defaults(func=cmd_find)
    ps = sub.add_parser("set", help="modify variables")
    ps.add_argument("file")
    ps.add_argument("assignments", nargs="+", metavar="NAME=VALUE")
    ps.set_defaults(func=cmd_set)
    args = p.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
