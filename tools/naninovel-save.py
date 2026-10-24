#!/usr/bin/env python3
"""List and modify variables in Naninovel (Unity) save files (*.nson).

A .nson file is raw DEFLATE over UTF-8 (BOM) JSON. Variables live in:
  - GameSaveNNN.nson: CustomVariableManager LocalVariableMap (+ rollback snapshots)
  - GlobalSave.nson:  CustomVariableManager GlobalVariableMap (G_* names)
  - gameInfo (game-specific, optional): exposed as gameInfo.<key>[.<subkey>]

Usage:
  naninovel-save.py list FILE [SUBSTRING]
  naninovel-save.py set FILE NAME=VALUE [NAME=VALUE ...]

'set' writes a timestamped FILE.<date>.bak before overwriting FILE.
"""

import argparse
import json
import os
import shutil
import sys
import time
import zlib

VARMGR = "Naninovel.CustomVariableManager+"
MAPS = ("LocalVariableMap", "GlobalVariableMap")


def load(path):
    with open(path, "rb") as f:
        return json.loads(zlib.decompress(f.read(), -15).decode("utf-8-sig"))


def save(path, data):
    raw = ("﻿" + json.dumps(data, ensure_ascii=False,
                                 separators=(",", ":"))).encode("utf-8")
    c = zlib.compressobj(9, zlib.DEFLATED, -15)
    tmp = path + ".tmp"
    with open(tmp, "wb") as f:
        f.write(c.compress(raw) + c.flush())
    os.replace(tmp, path)


def var_maps(state):
    """Yield (objectJsonMap, index, mapname, decoded) for each variable map."""
    m = state.get("objectJsonMap", {})
    for i, key in enumerate(m.get("keys", [])):
        if not key.startswith(VARMGR):
            continue
        decoded = json.loads(m["values"][i])
        for name in MAPS:
            if name in decoded:
                yield m, i, name, decoded


def read_vars(state):
    out = {}
    for _, _, name, decoded in var_maps(state):
        vm = decoded[name]
        out.update(zip(vm["keys"], vm["values"]))
    gi = state.get("gameInfo")
    if isinstance(gi, str) and gi:
        for k, v in json.loads(gi).items():
            sub = _try_json(v)
            if isinstance(sub, dict):
                for sk, sv in sub.items():
                    if sv is None or isinstance(sv, (str, int, float, bool)):
                        out["gameInfo.%s.%s" % (k, sk)] = sv
            else:
                out["gameInfo." + k] = v
    return out


def _try_json(s):
    if not isinstance(s, str):
        return None
    try:
        return json.loads(s)
    except ValueError:
        return None


def _coerce(old, new):
    """Convert the string NEW to the JSON type of OLD."""
    if isinstance(old, bool):
        return new.lower() in ("1", "true", "yes")
    if isinstance(old, int):
        return int(new)
    if isinstance(old, float):
        return float(new)
    return new


def write_vars(state, changes):
    """Apply changes to one state; return the set of names actually changed."""
    done = set()
    for m, i, name, decoded in var_maps(state):
        vm = decoded[name]
        hit = False
        for j, k in enumerate(vm["keys"]):
            if k in changes:
                vm["values"][j] = changes[k]
                done.add(k)
                hit = True
        if hit:
            m["values"][i] = json.dumps(decoded, ensure_ascii=False,
                                        separators=(",", ":"))
    gi = state.get("gameInfo")
    gchanges = {k[9:]: v for k, v in changes.items()
                if k.startswith("gameInfo.")}
    if gchanges and isinstance(gi, str) and gi:
        info = json.loads(gi)
        for path, val in gchanges.items():
            k, _, sk = path.partition(".")
            if k not in info:
                continue
            if not sk:
                info[k] = val
                done.add("gameInfo." + path)
                continue
            sub = _try_json(info[k])
            if isinstance(sub, dict) and sk in sub:
                sub[sk] = _coerce(sub[sk], val)
                # Keep the Newtonsoft-style indentation the game wrote.
                info[k] = json.dumps(sub, indent=2,
                                     ensure_ascii=False).replace("\n", "\r\n")
                done.add("gameInfo." + path)
        state["gameInfo"] = json.dumps(info, ensure_ascii=False,
                                       separators=(",", ":"))
    return done


def rollback_states(data):
    rb = data.get("rollbackStackJson")
    if not rb:
        return None, []
    stack = json.loads(rb)
    return stack, stack.get("List", [])


def cmd_list(args):
    data = load(args.file)
    for k, v in read_vars(data).items():
        if args.filter is None or args.filter.lower() in k.lower():
            print("%s=%s" % (k, v))


def cmd_set(args):
    changes = {}
    for a in args.assign:
        if "=" not in a:
            sys.exit("bad assignment (want NAME=VALUE): %s" % a)
        k, v = a.split("=", 1)
        changes[k] = v
    data = load(args.file)
    current = read_vars(data)
    unknown = [k for k in changes if k not in current]
    if unknown:
        sys.exit("unknown variable(s): %s" % ", ".join(unknown))

    write_vars(data, changes)
    # Rollback snapshots hold older copies of the same state; patch them too
    # so rolling back after loading does not resurrect the old values.
    stack, states = rollback_states(data)
    for st in states:
        write_vars(st, changes)
    if states:
        data["rollbackStackJson"] = json.dumps(stack, ensure_ascii=False,
                                               separators=(",", ":"))

    bak = "%s.%s.bak" % (args.file, time.strftime("%Y%m%d-%H%M%S"))
    shutil.copy2(args.file, bak)
    save(args.file, data)
    after = read_vars(load(args.file))
    for k in changes:
        print("%s: %s -> %s" % (k, current[k], after[k]))
    print("backup: %s" % bak)


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    pl = sub.add_parser("list", help="list variables and values")
    pl.add_argument("file")
    pl.add_argument("filter", nargs="?", help="case-insensitive substring")
    pl.set_defaults(func=cmd_list)
    ps = sub.add_parser("set", help="modify variables")
    ps.add_argument("file")
    ps.add_argument("assign", nargs="+", metavar="NAME=VALUE")
    ps.set_defaults(func=cmd_set)
    args = p.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
