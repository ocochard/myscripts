#!/usr/bin/env python3
"""
jellyfin-mkv-audit.py — Audit and sync metadata between Jellyfin DB and MKV files.

Reads from Jellyfin SQLite DB:
  title, original title, sort title, year, overview (synopsis), tagline,
  age rating, community rating, genres, studios, countries, IMDB/TMDB/TVDB IDs,
  directors, writers, actors (up to 10), producers, composers.

Compares with embedded MKV Matroska tags (read via ffprobe).

Usage:
  python3 jellyfin-mkv-audit.py                    # dry-run: report all differences
  python3 jellyfin-mkv-audit.py --only-missing      # only files with zero embedded tags
  python3 jellyfin-mkv-audit.py --path /NAS/films/Francais
  python3 jellyfin-mkv-audit.py --type all          # include episodes
  python3 jellyfin-mkv-audit.py --update            # write DB metadata into MKV files (bulk)
  python3 jellyfin-mkv-audit.py --interactive       # review + confirm each file before writing

Requirements (FreeBSD):
  pkg install ffmpeg mkvtoolnix py311-sqlite3
"""

import sqlite3
import subprocess
import json
import re
import os
import sys
import argparse
import tempfile
from pathlib import Path
from dataclasses import dataclass, field

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

JELLYFIN_DB  = "/var/db/jellyfin/data/jellyfin.db"
FFPROBE      = "ffprobe"
MKVPROPEDIT  = "mkvpropedit"

TYPE_MOVIE   = "MediaBrowser.Controller.Entities.Movies.Movie"
TYPE_EPISODE = "MediaBrowser.Controller.Entities.TV.Episode"
TYPE_VIDEO   = "MediaBrowser.Controller.Entities.Video"

MAX_ACTORS = 10  # cap actor list embedded in MKV to avoid bloat

LIST_FIELDS = frozenset({
    "genres", "studios", "countries",
    "directors", "writers", "actors", "producers", "composers",
})

FIELD_LABELS = {
    "title":          "Title",
    "original_title": "Original title",
    "sort_title":     "Sort title",
    "year":           "Year",
    "overview":       "Description",
    "tagline":        "Tagline",
    "law_rating":     "Age rating",
    "rating":         "Community rating",
    "imdb":           "IMDB ID",
    "tmdb":           "TMDB ID",
    "tvdb":           "TVDB ID",
    "content_type":   "Content type",
    "genres":         "Genres",
    "studios":        "Studios",
    "countries":      "Countries",
    "directors":      "Directors",
    "writers":        "Writers",
    "actors":         "Actors",
    "producers":      "Producers",
    "composers":      "Composers",
}

# ffprobe tag key → Meta field name
TAG_TO_FIELD = {
    "title":          "title",
    "TITLE":          "title",
    "ORIGINAL":       "original_title",
    "SORT_WITH":      "sort_title",
    "DATE_RELEASED":  "year",
    "DESCRIPTION":    "overview",
    "SUBTITLE":       "tagline",
    "LAW_RATING":     "law_rating",
    "RATING":         "rating",
    "IMDB":           "imdb",
    "TMDB":           "tmdb",
    "TVDB":           "tvdb",
    "CONTENT_TYPE":   "content_type",
    "GENRE":          "genres",
    "STUDIO":         "studios",
    "COUNTRY":        "countries",
    "DIRECTOR":       "directors",
    "WRITTEN_BY":     "writers",
    "ACTOR":          "actors",
    "PRODUCER":       "producers",
    "COMPOSER":       "composers",
}

# Meta field name → MKV Matroska tag name
FIELD_TO_TAG = {
    "title":          "TITLE",
    "original_title": "ORIGINAL",
    "sort_title":     "SORT_WITH",
    "year":           "DATE_RELEASED",
    "overview":       "DESCRIPTION",
    "tagline":        "SUBTITLE",
    "law_rating":     "LAW_RATING",
    "rating":         "RATING",
    "imdb":           "IMDB",
    "tmdb":           "TMDB",
    "tvdb":           "TVDB",
    "content_type":   "CONTENT_TYPE",
    "genres":         "GENRE",
    "studios":        "STUDIO",
    "countries":      "COUNTRY",
    "directors":      "DIRECTOR",
    "writers":        "WRITTEN_BY",
    "actors":         "ACTOR",
    "producers":      "PRODUCER",
    "composers":      "COMPOSER",
}

# Ordered list of all fields for consistent display
ALL_FIELDS = list(FIELD_LABELS.keys())


# ---------------------------------------------------------------------------
# Data model
# ---------------------------------------------------------------------------

@dataclass
class Meta:
    title:          str       = ""
    original_title: str       = ""
    sort_title:     str       = ""
    year:           str       = ""
    overview:       str       = ""
    tagline:        str       = ""
    law_rating:     str       = ""
    rating:         str       = ""
    imdb:           str       = ""
    tmdb:           str       = ""
    tvdb:           str       = ""
    content_type:   str       = ""
    genres:         list[str] = field(default_factory=list)
    studios:        list[str] = field(default_factory=list)
    countries:      list[str] = field(default_factory=list)
    directors:      list[str] = field(default_factory=list)
    writers:        list[str] = field(default_factory=list)
    actors:         list[str] = field(default_factory=list)
    producers:      list[str] = field(default_factory=list)
    composers:      list[str] = field(default_factory=list)

    def is_empty(self) -> bool:
        return not any(
            getattr(self, f) for f in ALL_FIELDS
        )


# ---------------------------------------------------------------------------
# Database
# ---------------------------------------------------------------------------

def _split_pipe(s: str | None) -> list[str]:
    if not s:
        return []
    return [x.strip() for x in s.split("|") if x.strip()]


_JUNK_SORT_RE = re.compile(r"0{4,}\d|webrip|bluray|bdrip|brrip|web-dl|webdl|"
                            r"dvdrip|hdtv|remux|vof|vff|vfq|vfi|truefrench|"
                            r"multi|sdr|hdr|dv\b|cnlp|\bx26[45]\b|hevc|h264|"
                            r"\b\d{3,4}p\b|\b2160p\b|\b4k\b",
                            re.IGNORECASE)

def _clean_sort_title(s: str | None) -> str:
    """Return the sort title only if it looks like a real title, not a mangled filename."""
    if not s:
        return ""
    if _JUNK_SORT_RE.search(s):
        return ""
    return s


def _open_db(db_path: str) -> sqlite3.Connection:
    return sqlite3.connect(f"file:{db_path}?immutable=1", uri=True)


def load_items(db_path: str, type_filter: str) -> list[tuple[str, str, str]]:
    """Return list of (id, name, path) for MKV items."""
    match type_filter:
        case "movie":
            where = f"type = '{TYPE_MOVIE}'"
        case "episode":
            where = f"type = '{TYPE_EPISODE}'"
        case "video":
            where = f"type = '{TYPE_VIDEO}'"
        case _:
            where = (f"type IN ('{TYPE_MOVIE}', '{TYPE_EPISODE}', '{TYPE_VIDEO}')")

    con = _open_db(db_path)
    rows = con.execute(
        f"SELECT Id, Name, Path FROM BaseItems "
        f"WHERE Path LIKE '%.mkv' AND {where} ORDER BY Path"
    ).fetchall()
    con.close()
    return rows


def load_db_meta(db_path: str, item_id: str) -> Meta:
    """Load all available metadata for one item from Jellyfin DB."""
    con = _open_db(db_path)

    row = con.execute("""
        SELECT Name, OriginalTitle, SortName, ProductionYear, PremiereDate,
               Overview, Tagline, OfficialRating, CommunityRating,
               Genres, Studios, ProductionLocations, Type
        FROM BaseItems WHERE Id = ?
    """, (item_id,)).fetchone()

    if not row:
        con.close()
        return Meta()

    (name, orig, sort, year, premiere, overview, tagline,
     official_rating, community_rating, genres, studios, countries, itype) = row

    # External provider IDs — first occurrence wins per provider
    providers: dict[str, str] = {}
    for pid, pval in con.execute(
        "SELECT ProviderId, ProviderValue FROM BaseItemProviders WHERE ItemId = ?",
        (item_id,)
    ).fetchall():
        if pid not in providers:
            providers[pid] = pval

    # People, ordered by their sort/list order
    people_rows = con.execute("""
        SELECT p.Name, p.PersonType, pm.Role
        FROM Peoples p
        JOIN PeopleBaseItemMap pm ON p.Id = pm.PeopleId
        WHERE pm.ItemId = ?
        ORDER BY pm.SortOrder, pm.ListOrder
    """, (item_id,)).fetchall()

    con.close()

    # Build people lists
    directors, writers, actors, producers, composers = [], [], [], [], []
    for pname, ptype, role in people_rows:
        if not pname:
            continue
        match ptype:
            case "Director":
                directors.append(pname)
            case "Writer":
                writers.append(pname)
            case "Actor":
                entry = f"{pname} ({role})" if role else pname
                actors.append(entry)
            case "Producer":
                producers.append(pname)
            case "Composer":
                composers.append(pname)

    # Year: prefer full PremiereDate, fallback to ProductionYear
    year_str = premiere[:4] if premiere else (str(year) if year else "")

    # IMDB must match tt\d+
    imdb = providers.get("Imdb", "")
    if not re.match(r"^tt\d+$", imdb):
        imdb = ""

    # Community rating: one decimal place
    rating_str = f"{community_rating:.1f}" if community_rating else ""

    content_type = "Episode" if TYPE_EPISODE in (itype or "") else "Movie"

    return Meta(
        title          = name or "",
        original_title = orig or "",
        sort_title     = _clean_sort_title(sort),
        year           = year_str,
        overview       = overview or "",
        tagline        = tagline or "",
        law_rating     = official_rating or "",
        rating         = rating_str,
        imdb           = imdb,
        tmdb           = str(providers.get("Tmdb", "") or ""),
        tvdb           = str(providers.get("Tvdb", "") or ""),
        content_type   = content_type,
        genres         = _split_pipe(genres),
        studios        = _split_pipe(studios),
        countries      = _split_pipe(countries),
        directors      = directors,
        writers        = writers,
        actors         = actors[:MAX_ACTORS],
        producers      = producers,
        composers      = composers,
    )


# ---------------------------------------------------------------------------
# MKV tag reading (ffprobe)
# ---------------------------------------------------------------------------

def read_mkv_meta(path: str) -> Meta:
    """Read embedded Matroska tags via ffprobe."""
    try:
        r = subprocess.run(
            [FFPROBE, "-v", "quiet", "-print_format", "json", "-show_format", path],
            capture_output=True, text=True, timeout=15,
        )
        tags = json.loads(r.stdout).get("format", {}).get("tags", {})
    except Exception:
        return Meta()

    m = Meta()
    for raw_key, value in tags.items():
        fname = TAG_TO_FIELD.get(raw_key) or TAG_TO_FIELD.get(raw_key.upper())
        if not fname or not value:
            continue
        value = value.strip()
        attr = getattr(m, fname)
        if isinstance(attr, list):
            # ffprobe may join multiple values with newlines
            for v in re.split(r"\n", value):
                v = v.strip()
                if v and v not in attr:
                    attr.append(v)
        elif not attr:  # first occurrence wins (title vs TITLE)
            setattr(m, fname, value)

    return m


# ---------------------------------------------------------------------------
# MKV tag writing (mkvpropedit)
# ---------------------------------------------------------------------------

def _xml_escape(s: str) -> str:
    return (s.replace("&", "&amp;")
             .replace("<",  "&lt;")
             .replace(">",  "&gt;")
             .replace('"',  "&quot;"))


def build_tags_xml(m: Meta) -> str:
    """Build a Matroska tags XML document from a Meta object."""
    lines = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<!DOCTYPE Tags SYSTEM "matroskatags.dtd">',
        "<Tags>",
        "  <Tag>",
        "    <Targets><TargetTypeValue>50</TargetTypeValue></Targets>",
    ]

    def add(tag_name: str, value: str) -> None:
        if value:
            lines.append(
                f"    <Simple><Name>{tag_name}</Name>"
                f"<String>{_xml_escape(value)}</String></Simple>"
            )

    for fname in ALL_FIELDS:
        tag_name = FIELD_TO_TAG[fname]
        value    = getattr(m, fname)
        if isinstance(value, list):
            for v in value:
                add(tag_name, v)
        else:
            add(tag_name, value)

    lines += ["  </Tag>", "</Tags>"]
    return "\n".join(lines)


def write_mkv_meta(path: str, m: Meta) -> tuple[bool, str]:
    """Write segment title + all tags to an MKV file via mkvpropedit."""
    xml = build_tags_xml(m)
    with tempfile.NamedTemporaryFile(
        mode="w", suffix=".xml", delete=False, encoding="utf-8"
    ) as f:
        f.write(xml)
        tmp = f.name

    try:
        r = subprocess.run(
            [MKVPROPEDIT, path,
             "--edit", "info", "--set", f"title={m.title}",
             "--tags", f"all:{tmp}"],
            capture_output=True, text=True,
        )
        return r.returncode == 0, (r.stderr or r.stdout).strip()
    finally:
        os.unlink(tmp)


# ---------------------------------------------------------------------------
# Comparison
# ---------------------------------------------------------------------------

def diff_meta(db: Meta, mkv: Meta) -> dict[str, tuple]:
    """Return {field_name: (db_value, mkv_value)} for differing fields."""
    diffs = {}
    for fname in ALL_FIELDS:
        db_val  = getattr(db,  fname)
        mkv_val = getattr(mkv, fname)
        if isinstance(db_val, list):
            if sorted(db_val) != sorted(mkv_val):
                diffs[fname] = (db_val, mkv_val)
        else:
            if db_val.strip() != mkv_val.strip():
                diffs[fname] = (db_val, mkv_val)
    return diffs


# ---------------------------------------------------------------------------
# Display
# ---------------------------------------------------------------------------

def _fmt(v) -> str:
    if isinstance(v, list):
        return " | ".join(v) if v else "(none)"
    return v if v else "(none)"


def _trunc(s: str, n: int = 60) -> str:
    return s[:n - 1] + "…" if len(s) > n else s


def _osc8(url: str, text: str) -> str:
    """Wrap text in an OSC 8 terminal hyperlink (clickable in iTerm2, Kitty, etc.)."""
    return f"\033]8;;{url}\033\\{text}\033]8;;\033\\"


def print_diff(path: str, diffs: dict, db_meta: Meta | None = None) -> None:
    print(f"\n  {path}")
    if db_meta and db_meta.imdb:
        url = f"https://www.imdb.com/title/{db_meta.imdb}/"
        print(f"    IMDB  {_osc8(url, url)}")
    if db_meta and db_meta.tmdb:
        url = f"https://www.themoviedb.org/movie/{db_meta.tmdb}"
        print(f"    TMDB  {_osc8(url, url)}")
    if not diffs:
        print("    ✓ all tags match")
        return
    w = max(len(FIELD_LABELS.get(k, k)) for k in diffs) + 1
    for fname, (db_val, mkv_val) in diffs.items():
        label = FIELD_LABELS.get(fname, fname)
        print(f"    {label:<{w}}  DB : {_trunc(_fmt(db_val))}")
        print(f"    {'':<{w}}  MKV: {_trunc(_fmt(mkv_val))}")


def print_summary(report: list) -> None:
    if not report:
        return
    from collections import Counter
    field_counts: Counter = Counter()
    for _, diffs, _ in report:
        field_counts.update(diffs.keys())
    print(f"\n  Most common missing/mismatched fields:")
    for fname, count in field_counts.most_common(10):
        label = FIELD_LABELS.get(fname, fname)
        print(f"    {count:>5}×  {label}")


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    ap = argparse.ArgumentParser(
        description="Audit and sync metadata between Jellyfin DB and MKV Matroska tags."
    )
    ap.add_argument("--db",           default=JELLYFIN_DB,
                    help="Jellyfin DB path (default: %(default)s)")
    ap.add_argument("--type",         default="movie",
                    choices=["movie", "episode", "video", "all"],
                    help="Item type (default: movie)")
    ap.add_argument("--path",         metavar="PREFIX",
                    help="Only check files whose path starts with PREFIX")
    ap.add_argument("--update",       action="store_true",
                    help="Write DB metadata into MKV files (bulk, no prompt)")
    ap.add_argument("--interactive",  action="store_true",
                    help="Show diff + IMDB/TMDB links and ask y/n before each write")
    ap.add_argument("--only-missing", action="store_true",
                    help="Only process files with zero embedded Matroska tags")
    ap.add_argument("--summary",      action="store_true",
                    help="Print a field-frequency summary at the end")
    args = ap.parse_args()

    # Check required tools
    missing = [t for t in (FFPROBE, MKVPROPEDIT)
               if subprocess.run(["which", t], capture_output=True).returncode != 0]
    if missing:
        sys.exit(f"Missing required tools: {', '.join(missing)}\n"
                 f"  FreeBSD: pkg install ffmpeg mkvtoolnix")

    if not os.path.exists(args.db):
        sys.exit(f"Database not found: {args.db}")

    print(f"Loading items from {args.db}…")
    items = load_items(args.db, args.type)
    if args.path:
        items = [(i, n, p) for i, n, p in items if p.startswith(args.path)]
    total = len(items)
    print(f"  {total} items to scan ({args.type}).\n")

    report: list[tuple[str, dict, Meta]] = []

    for idx, (item_id, _name, path) in enumerate(items, 1):
        print(f"\r  [{idx:>5}/{total}] {Path(path).name[:72]:<72}", end="", flush=True)

        if not os.path.exists(path):
            continue

        mkv_meta = read_mkv_meta(path)

        if args.only_missing and not mkv_meta.is_empty():
            continue

        db_meta = load_db_meta(args.db, item_id)
        diffs   = diff_meta(db_meta, mkv_meta)

        if diffs:
            report.append((path, diffs, db_meta))

    print(f"\r  Scanned {total} — {len(report)} files with differences.{' ' * 30}\n")

    if not report:
        print("  Everything is in sync — nothing to do.")
        return

    for path, diffs, db_meta in report:
        print_diff(path, diffs, db_meta)

    if args.summary:
        print_summary(report)

    if args.interactive:
        _interactive_update(report)
        return

    if not args.update:
        print(f"\n  Run with --update to write, or --interactive to review each file.")
        return

    # Bulk update
    print(f"\n{'=' * 72}")
    print(f"Writing metadata to {len(report)} MKV files…\n")
    ok_n = err_n = 0
    for path, _diffs, db_meta in report:
        label = Path(path).name[:66]
        print(f"  {label:<66}", end="  ", flush=True)
        ok, msg = write_mkv_meta(path, db_meta)
        if ok:
            print("OK")
            ok_n += 1
        else:
            print(f"FAILED")
            print(f"    {msg[:70]}")
            err_n += 1

    print(f"\n  Done — {ok_n} updated, {err_n} errors.")


def _interactive_update(report: list) -> None:
    print(f"\n{'=' * 72}")
    print("Interactive mode — review each file before writing.")
    print("  [y] write   [n] skip   [a] write all remaining   [q] quit\n")
    ok_n = err_n = skip_n = 0
    write_all = False

    for path, diffs, db_meta in report:
        if not write_all:
            print_diff(path, diffs, db_meta)
            while True:
                try:
                    ans = input("\n  Write tags to this file? [y/n/a/q]: ").strip().lower()
                except EOFError:
                    ans = "q"
                if ans in ("y", "n", "a", "q"):
                    break
                print("  Please enter y, n, a, or q.")

            if ans == "q":
                print(f"\n  Aborted — {ok_n} written, {skip_n} skipped so far.")
                return
            if ans == "n":
                skip_n += 1
                continue
            if ans == "a":
                write_all = True

        label = Path(path).name[:66]
        print(f"  {label:<66}", end="  ", flush=True)
        ok, msg = write_mkv_meta(path, db_meta)
        if ok:
            print("OK")
            ok_n += 1
        else:
            print("FAILED")
            print(f"    {msg[:70]}")
            err_n += 1

    print(f"\n  Done — {ok_n} written, {skip_n} skipped, {err_n} errors.")


if __name__ == "__main__":
    main()
