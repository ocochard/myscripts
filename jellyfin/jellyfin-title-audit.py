#!/usr/bin/env python3
"""
jellyfin-title-audit.py — Audit and fix Jellyfin Name vs OriginalTitle.

Displays a side-by-side table of every item's title vs original title, flagging
Names that look like raw release filenames (release tags, codecs, resolutions)
rather than actual localized titles.

Fix mode (--fix) proposes a cleaned Name per row and, on confirmation, writes
it back via the Jellyfin HTTP API with Name added to LockedFields so future
metadata refreshes don't clobber the correction.

Usage:
  python3 jellyfin-title-audit.py                    # movies where Name != OriginalTitle
  python3 jellyfin-title-audit.py --all              # every movie
  python3 jellyfin-title-audit.py --junk-only        # only Names that look like filenames
  python3 jellyfin-title-audit.py --type all         # include episodes/videos
  python3 jellyfin-title-audit.py --path /NAS/films/Francais
  python3 jellyfin-title-audit.py --csv              # tab-separated
  python3 jellyfin-title-audit.py --fix              # interactive review + API write
  python3 jellyfin-title-audit.py --fix --host https://nas:8920 --token XXXX

Requires the Jellyfin DB to be readable locally (default /var/db/jellyfin/data).
Fix mode also needs HTTP access to a running Jellyfin instance. If --token is
omitted, one is read from the Devices table of the DB.
"""

import argparse
import csv
import json
import os
import re
import sqlite3
import ssl
import sys
import urllib.error
import urllib.request
from pathlib import Path

JELLYFIN_DB   = "/var/db/jellyfin/data/jellyfin.db"
JELLYFIN_HOST = "https://localhost:8920"

TYPE_MOVIE   = "MediaBrowser.Controller.Entities.Movies.Movie"
TYPE_EPISODE = "MediaBrowser.Controller.Entities.TV.Episode"
TYPE_VIDEO   = "MediaBrowser.Controller.Entities.Video"

# Same heuristic as jellyfin-mkv-audit.py — spot release-tag garbage in a title.
_JUNK_RE = re.compile(
    r"0{4,}\d|webrip|bluray|bdrip|brrip|web-dl|webdl|"
    r"dvdrip|hdtv|remux|vof|vff|vfq|vfi|truefrench|"
    r"multi|sdr|hdr|\bdv\b|cnlp|x26[45]|hevc|h264|"
    r"\b\d{3,4}p\b|\b2160p\b|\b4k\b|dts|atmos|truehd|"
    r"\bqtz\b|\bpulse\b|\bgaia\b|"
    r"\bvideo\b|\bbrd\b|\bkbps\b|www\.\S+|extreme-down",
    re.IGNORECASE,
)

# For proposing a cleaned title: cut Name at the earliest of a year (19xx/20xx),
# a parenthesized token containing a year, or a release tag. Whichever appears
# first wins — the rest is release-tag garbage.
_CUT_RE = re.compile(
    r"[\s/\\\[({]*"                       # whitespace/slash/bracket/paren before junk
    r"(?:"
    r"[\(\[]?(?:19|20)\d{2}[\)\]]?"       # 2008, (2008), [2008]
    r"|\("                                # any parenthesized junk we'll drop
    r"|www\.\S+"                          # URL prefix consumes rest of token
    r"|\b(?:blu[- ]?ray|webrip|bdrip|brrip|web[- ]?dl|"
    r"dvdrip|hdtv|remux|vof|vff|vfq|vfi|truefrench|multi|"
    r"hybrid|sdr|hdr|dv|cnlp|hevc|h264|"
    r"\d{3,4}p|2160p|4k|4klight|dts|atmos|truehd|"
    r"10bit|8bit|qtz|pulse|gaia|"
    r"video|brd|kbps|extreme-down)\b"
    r"|x26[45]"                           # boundary-free: matches x264_L4.1 too
    r")",
    re.IGNORECASE,
)


_PLACEHOLDER_NAMES = {"video", "movie", "film", "untitled", "unknown"}


def is_placeholder(name: str) -> bool:
    """True when Name is a bare generic like 'Video' or 'Untitled'."""
    return bool(name) and name.strip().lower() in _PLACEHOLDER_NAMES


_TRAILING_YEAR_RE = re.compile(r"[\s\-_.·]+[\(\[]?(?:19|20)\d{2}[\)\]]?\s*$")


def is_junk(name: str) -> bool:
    return bool(name) and (
        is_placeholder(name)
        or _has_no_letters(name)
        or _is_dotted_filename(name)
        or bool(_JUNK_RE.search(name))
        or bool(_TRAILING_YEAR_RE.search(name))
    )


def _has_no_letters(name: str) -> bool:
    """True when Name has fewer than 2 letters — '^^', '---', '???', '1080P'."""
    return sum(1 for c in name if c.isalpha()) < 2


def _is_dotted_filename(name: str) -> bool:
    """True when Name has no spaces but has dots/underscores between word chars.

    Matches 'A.Silent.Voice', 'The_Matrix', 'Le.voyage.de.Chihiro' — the shape
    Jellyfin falls back to when it copies the filename verbatim into Name.
    Leaves 'R.I.F.' alone (that stringHAS spaces? no — but leaves single
    all-letter tokens like 'E.T.' by requiring at least two dot separators).
    """
    if " " in name:
        return False
    # Interior dot/underscore between word chars — 'A.B' shape.
    return bool(re.search(r"\w[._]\w", name))


def propose_fix(name: str, original: str) -> tuple[str, str]:
    """Return (proposed_name, reason). Empty proposed_name means give up."""
    if not name:
        return (original or "", "empty Name")

    if is_placeholder(name):
        return (original, "placeholder Name") if original else ("", "no usable title")

    m = _CUT_RE.search(name)
    if m:
        cut = _rstrip_tail_junk(name[: m.start()])
        cut = _despace(cut)
        if _looks_like_title(cut):
            # If OriginalTitle has the same letters/digits (differing only in
            # punctuation, accents, or case), prefer it — it's the properly
            # punctuated form.
            if original:
                co, cc = _canon(original), _canon(cut)
                if co and cc == co:
                    return (original, "matched OriginalTitle (punctuation/accents)")
                # Junk-prefix / trailing-debris case: strip result still
                # contains the OriginalTitle in canonical form, wrapped in
                # noise (e.g. "ZEST - zest le grimoire d arkandias 720"
                # canonically contains "legrimoiredarkandias").
                if co and len(co) >= 6 and co in cc:
                    return (original, "OriginalTitle inside noisy strip")
            reason = "stripped junk suffix"
            if _is_shouty(cut):
                reason += " — all-caps, edit needed"
            return (cut, reason)

    # No junk found but caller flagged it — usually because the whole Name is
    # a single junk token like "1080P" or a punctuation-stripped filename.
    if _looks_like_title(name):
        despaced = _despace(name)
        if despaced != name:
            return (despaced, "de-dotted filename-style Name")
        return (name, "kept as-is (no clear junk boundary)")

    if original:
        return (original, "fell back to OriginalTitle")

    return ("", "no usable title")


def _is_shouty(s: str) -> bool:
    letters = [c for c in s if c.isalpha()]
    return len(letters) >= 4 and sum(1 for c in letters if c.isupper()) / len(letters) > 0.9


def _rstrip_tail_junk(s: str) -> str:
    """Peel trailing punctuation, dangling brackets, and orphan short tokens.

    The strip point sits before a junk word, but its opening context may
    remain: '... - Les origines [UHD (QTZ™) dts' → cut before 'dts' leaves
    '... - Les origines [UHD (QTZ™)' → we still need to drop the trailing
    '(QTZ™)' bracket group, then the ' [UHD' orphan, then trailing dash.
    """
    prev = None
    while s != prev:
        prev = s
        s = s.rstrip(" \t-_.·:/\\©™♥·⋆★·|+&")
        # Balanced trailing bracket group: (…) or [ … ] or { … }
        s = re.sub(r"[\[\(\{][^\[\](){}]*[\]\)\}]\s*$", "", s)
        # Orphan opening bracket + up to next whitespace: '[UHD', '(FRENCH'
        s = re.sub(r"[\[\(\{]\S*\s*$", "", s)
    return s


def _despace(s: str) -> str:
    """Turn filename-style separators (dots/underscores between words) into spaces.

    Only fires when the string has no spaces at all but does have interior dots
    or underscores between word characters — the "Mary.et.Max" shape. Leaves
    strings that already contain spaces alone.
    """
    if " " in s:
        return s
    if not re.search(r"\w[._]\w", s):
        return s
    return re.sub(r"[._]+", " ", s).strip()


def _canon(s: str) -> str:
    """Alphanumeric-only, accent-stripped, lowercased — for fuzzy equality."""
    import unicodedata
    nfkd = unicodedata.normalize("NFKD", s)
    stripped = "".join(c for c in nfkd if not unicodedata.combining(c))
    return "".join(c for c in stripped.lower() if c.isalnum())


def _looks_like_title(s: str) -> bool:
    if not s or len(s) < 3:
        return False
    if _JUNK_RE.search(s):
        return False
    # Must contain at least two letters.
    return sum(1 for c in s if c.isalpha()) >= 2


# ---------------------------------------------------------------------------
# Database
# ---------------------------------------------------------------------------

def open_db(path: str) -> sqlite3.Connection:
    return sqlite3.connect(f"file:{path}?immutable=1", uri=True)


def type_where(t: str) -> str:
    match t:
        case "movie":   return f"Type = '{TYPE_MOVIE}'"
        case "episode": return f"Type = '{TYPE_EPISODE}'"
        case "video":   return f"Type = '{TYPE_VIDEO}'"
        case _:         return (f"Type IN ('{TYPE_MOVIE}', '{TYPE_EPISODE}', '{TYPE_VIDEO}')")


def load_rows(db_path: str, type_filter: str, path_prefix: str | None):
    con = open_db(db_path)
    q = (f"SELECT Id, Name, OriginalTitle, ProductionYear, Path "
         f"FROM BaseItems WHERE Path LIKE '%.mkv' AND {type_where(type_filter)}")
    params: list = []
    if path_prefix:
        q += " AND Path LIKE ?"
        params.append(path_prefix + "%")
    q += " ORDER BY Path"
    rows = con.execute(q, params).fetchall()
    con.close()
    return rows


def get_admin_token(db_path: str) -> str:
    """Pick the most-recent AccessToken belonging to an admin user.

    Writes require admin; a random token from Devices (a non-admin's browser
    session) will fail POST with HTTP 403. Admin flag lives in Permissions
    (Kind=0 == IsAdministrator, Value=1).
    """
    con = open_db(db_path)
    row = con.execute("""
        SELECT d.AccessToken
        FROM Devices d
        JOIN Permissions p ON p.UserId = d.UserId
        WHERE p.Kind = 0 AND p.Value = 1
        ORDER BY d.DateCreated DESC LIMIT 1
    """).fetchone()
    con.close()
    if not row or not row[0]:
        sys.exit("No admin AccessToken found in Devices table — pass --token explicitly.\n"
                 "  Log into Jellyfin as an admin user once, then re-run.")
    return row[0]


# ---------------------------------------------------------------------------
# Display
# ---------------------------------------------------------------------------

def trunc(s: str, n: int) -> str:
    s = s or ""
    return s if len(s) <= n else s[: n - 1] + "…"


def render_table(rows, col_widths):
    W_T, W_O, W_Y, W_F = col_widths
    sep = f"  {'─' * W_T}  {'─' * W_O}  {'─' * W_Y}  {'─' * W_F}"
    hdr = f"  {'Title':<{W_T}}  {'Original title':<{W_O}}  {'Year':<{W_Y}}  {'File':<{W_F}}"
    print(hdr)
    print(sep)
    for _id, name, orig, year, path in rows:
        marker = "⚠ " if is_junk(name) else "  "
        line = (f"{marker}{trunc(name or '', W_T):<{W_T}}  "
                f"{trunc(orig or '', W_O):<{W_O}}  "
                f"{trunc(str(year or ''), W_Y):<{W_Y}}  "
                f"{trunc(Path(path).name, W_F):<{W_F}}")
        print(line)


def render_csv(rows) -> None:
    w = csv.writer(sys.stdout, delimiter="\t", lineterminator="\n")
    w.writerow(["junk", "id", "title", "original_title", "year", "path"])
    for _id, name, orig, year, path in rows:
        w.writerow([int(is_junk(name)), _id, name or "", orig or "", year or "", path or ""])


# ---------------------------------------------------------------------------
# Jellyfin HTTP API
# ---------------------------------------------------------------------------

def _api_ctx(insecure: bool) -> ssl.SSLContext | None:
    if not insecure:
        return None
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def _item_url(host: str, item_id: str) -> str:
    return f"{host.rstrip('/')}/Items/{item_id.replace('-', '')}"


def api_get_item(host: str, token: str, item_id: str, insecure: bool) -> dict:
    """Fetch one item's full BaseItemDto.

    Prefers GET /Items/{Id}. Some items trip a Jellyfin bug in DtoService
    (AttachGenreItems null-deref when Genres is null) and return HTTP 400.
    Fall back to the list endpoint /Items?ids=... which uses a different DTO
    code path and handles those items correctly.
    """
    hdr = {"Authorization": f"MediaBrowser Token={token}"}
    ctx = _api_ctx(insecure)

    req = urllib.request.Request(_item_url(host, item_id), headers=hdr)
    try:
        with urllib.request.urlopen(req, context=ctx, timeout=15) as r:
            return json.loads(r.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        if e.code != 400:
            raise

    # Fallback: list endpoint with explicit field list so LockedFields comes back.
    fields = "LockedFields,Genres,Studios,Tags,ProviderIds,DateCreated,OriginalTitle,Overview"
    url = (f"{host.rstrip('/')}/Items"
           f"?ids={item_id.replace('-', '')}&fields={fields}")
    req = urllib.request.Request(url, headers=hdr)
    with urllib.request.urlopen(req, context=ctx, timeout=15) as r:
        data = json.loads(r.read().decode("utf-8"))
    items = data.get("Items") or []
    if not items:
        raise RuntimeError(f"item {item_id} not found via list endpoint")
    return items[0]


def api_update_name(host: str, token: str, item_id: str, new_name: str,
                    insecure: bool) -> None:
    item = api_get_item(host, token, item_id, insecure)
    item["Name"] = new_name
    locked = set(item.get("LockedFields") or [])
    locked.add("Name")
    item["LockedFields"] = sorted(locked)
    body = json.dumps(item).encode("utf-8")
    req = urllib.request.Request(
        _item_url(host, item_id),
        data=body,
        method="POST",
        headers={
            "Authorization": f"MediaBrowser Token={token}",
            "Content-Type":  "application/json",
        },
    )
    with urllib.request.urlopen(req, context=_api_ctx(insecure), timeout=30) as r:
        code = r.getcode()
        if code >= 400:
            raise RuntimeError(f"HTTP {code}: {r.read().decode('utf-8', 'replace')[:200]}")


# ---------------------------------------------------------------------------
# Interactive fix
# ---------------------------------------------------------------------------

def interactive_fix(rows, host: str, token: str, insecure: bool) -> None:
    print(f"\n{'=' * 72}")
    print(f"Fix mode — {len(rows)} candidate(s). Writes go to {host}")
    print(f"  Keys:  y=accept  o=use OriginalTitle  e=edit  n=skip  q=quit\n")

    ok_n = skip_n = err_n = 0
    for idx, (item_id, name, orig, year, path) in enumerate(rows, 1):
        proposed, reason = propose_fix(name or "", orig or "")

        print(f"\n  [{idx}/{len(rows)}] {Path(path).name}")
        print(f"    current    : {name or '(empty)'}")
        print(f"    original   : {orig  or '(empty)'}")
        print(f"    proposed   : {proposed or '(none)'}   [{reason}]")
        if year:
            print(f"    year       : {year}")

        while True:
            try:
                ans = input("    action [y/o/e/n/q]: ").strip().lower()
            except EOFError:
                ans = "q"

            if ans == "q":
                print(f"\n  Aborted — {ok_n} written, {skip_n} skipped, {err_n} errors.")
                return

            if ans in ("", "n"):
                skip_n += 1
                break

            new_name = None
            if ans == "y":
                if not proposed:
                    print("    (no proposal — enter a value with 'e' or skip with 'n')")
                    continue
                new_name = proposed
            elif ans == "o":
                if not orig:
                    print("    (no OriginalTitle — enter a value with 'e' or skip)")
                    continue
                new_name = orig
            elif ans == "e":
                try:
                    edited = input(f"    new name   : ").strip()
                except EOFError:
                    edited = ""
                if not edited:
                    print("    (empty — skipping)")
                    skip_n += 1
                    break
                new_name = edited
            else:
                print("    unknown key — y/o/e/n/q")
                continue

            try:
                api_update_name(host, token, item_id, new_name, insecure)
                print(f"    ✓ wrote: {new_name}")
                ok_n += 1
            except (urllib.error.HTTPError, urllib.error.URLError,
                    RuntimeError, TimeoutError) as e:
                print(f"    ✗ FAILED: {e}")
                err_n += 1
            break

    print(f"\n  Done — {ok_n} written, {skip_n} skipped, {err_n} errors.")


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.strip().splitlines()[0])
    ap.add_argument("--db",       default=JELLYFIN_DB,
                    help=f"Jellyfin DB path (default: {JELLYFIN_DB})")
    ap.add_argument("--type",     default="movie",
                    choices=["movie", "episode", "video", "all"],
                    help="Item type (default: movie)")
    ap.add_argument("--path",     metavar="PREFIX",
                    help="Only items whose Path starts with PREFIX")
    ap.add_argument("--all",      action="store_true",
                    help="Show every item (default: only where Name != OriginalTitle)")
    ap.add_argument("--junk-only", action="store_true",
                    help="Only items whose Name looks like a raw release filename")
    ap.add_argument("--csv",      action="store_true",
                    help="Output as TSV")
    ap.add_argument("--fix",      action="store_true",
                    help="Interactive fix: review each item, write via Jellyfin HTTP API")
    ap.add_argument("--host",     default=JELLYFIN_HOST,
                    help=f"Jellyfin base URL (default: {JELLYFIN_HOST})")
    ap.add_argument("--token",    help="API token (default: read from Devices table)")
    ap.add_argument("--insecure", action="store_true",
                    help="Skip TLS verification (self-signed certs)")
    args = ap.parse_args()

    if not os.path.exists(args.db):
        sys.exit(f"Database not found: {args.db}")

    rows = load_rows(args.db, args.type, args.path)

    if not args.all:
        rows = [r for r in rows if (r[2] or "") and (r[1] or "") != (r[2] or "")]
    if args.junk_only or args.fix:
        rows = [r for r in rows if is_junk(r[1] or "")]

    if args.csv:
        render_csv(rows)
        return

    junk_n = sum(1 for r in rows if is_junk(r[1] or ""))
    print(f"  {len(rows)} items ({junk_n} with junk-looking title)\n")

    if not rows:
        return

    render_table(rows, col_widths=(40, 40, 4, 40))
    print()
    print(f"  {len(rows)} items — ⚠ marks {junk_n} title(s) that look like raw filenames.")

    if args.fix:
        token = args.token or get_admin_token(args.db)
        interactive_fix(rows, args.host, token, args.insecure)


if __name__ == "__main__":
    main()
