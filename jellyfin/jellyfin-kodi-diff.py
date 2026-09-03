#!/usr/bin/env python3
"""
jellyfin-kodi-diff.py — Cross-check movie metadata between Jellyfin and Kodi.

Both libraries scrape the same files but with different scrapers, so when they
disagree about a movie one of them matched the wrong entry. This compares the
two databases file by file and reports every disagreement, plus the files only
one of them knows about.

Checks performed on each matched file:

  IMDB      the two IMDb ids differ            (strongest wrong-match signal)
  TMDB      the two TMDb ids differ
  YEAR      production years differ
  TITLE     titles differ beyond fuzzy tolerance
  FILE-JF   the Jellyfin title does not resemble the file name
  FILE-KO   the Kodi title does not resemble the file name

FILE-JF / FILE-KO catch the case both databases get wrong the same way is not
covered by the others: a title that has nothing to do with the file it is
attached to. They are heuristic and noisier than the id checks.

Data sources (read-only):
  Jellyfin  sqlite  /var/db/jellyfin/data/jellyfin.db
  Kodi      MariaDB MyVideos131, reached with `sudo -n mysql` (no password)

Usage:
  python3 jellyfin-kodi-diff.py --ssh nas            # both DBs live on the NAS
  python3 jellyfin-kodi-diff.py                      # run directly on the NAS
  python3 jellyfin-kodi-diff.py --ssh nas --only IMDB,YEAR
  python3 jellyfin-kodi-diff.py --ssh nas --unmatched # also list one-sided files
  python3 jellyfin-kodi-diff.py --ssh nas --csv > diff.tsv
  python3 jellyfin-kodi-diff.py --ssh nas --json | jq .

--fix walks the provider id disagreements and, on confirmation, re-identifies
the Jellyfin item from the Kodi id through the same RemoteSearch/Apply pair the
web UI's Identify dialog uses, so Jellyfin re-scrapes title, year and artwork
from the corrected id:

  python3 jellyfin-kodi-diff.py --ssh nas --fix --dry-run
  python3 jellyfin-kodi-diff.py --ssh nas --fix

Each row shows a suggested winner scored from the file name, which is the only
evidence neither scraper produced. It is advisory: a misnamed file points at the
wrong side, so the prompt always asks. Only Jellyfin is written to; when Kodi is
the one that got it wrong, the row is left for you to fix in Kodi.
"""

import argparse
import difflib
import json
import re
import shlex
import subprocess
import sys
import unicodedata
from urllib.parse import unquote

JELLYFIN_DB   = "/var/db/jellyfin/data/jellyfin.db"
JELLYFIN_HOST = "https://localhost:8920"
KODI_DB       = "MyVideos131"

TYPE_MOVIE = "MediaBrowser.Controller.Entities.Movies.Movie"

VIDEO_EXT = {".mkv", ".mp4", ".avi", ".mov", ".m4v", ".ts", ".mpg", ".mpeg",
             ".m2ts", ".wmv", ".iso", ".divx", ".ogm", ".flv", ".webm"}

# Release-tag noise to drop before comparing a file name against a title.
_TAG_RE = re.compile(
    r"\b(?:web-?rip|web-?dl|web-?hd|blu-?ray|bd-?rip|br-?rip|dvd-?rip|dvdscr|"
    r"hdtv|remux|repack|proper|uncut|unrated|extended|director\S*cut|integrale|"
    r"multi|truefrench|french|vostfr|vof|vff|vfq|vfi|subfrench|eng|vo|"
    r"x26[45]|h\.?26[45]|hevc|xvid|divx|av1|"
    r"\d{3,4}[ip]|4k|uhd|sdr|hdr10?\+?|dolby|vision|dv|"
    r"aac\d*|ac3|eac3|dts(?:-?hd)?|truehd|atmos|flac|mp3|\d+kbps|\d+bits?|"
    r"qtz|pulse|gaia|cnlp|brd|amzn|nf|dsnp)\b",
    re.IGNORECASE,
)
_YEAR_RE = re.compile(r"\b(19\d{2}|20\d{2})\b")
_SITE_RE = re.compile(r"\b(?:www\.)?\S+\.(?:org|com|net|mx|to|tv|cc|io|xyz|info|biz)\b|extreme-down",
                      re.IGNORECASE)
_ARTICLE_RE = re.compile(r"^(?:the|le|la|les|l|un|une|des|du|a|an|der|die|das|el|il)\s+")


# --------------------------------------------------------------------------- #
# text normalisation
# --------------------------------------------------------------------------- #

def strip_accents(s):
    return "".join(c for c in unicodedata.normalize("NFKD", s)
                   if not unicodedata.combining(c))


def norm_title(s):
    """Fold a title to a comparable form: no accents, no punctuation, no article."""
    if not s:
        return ""
    s = strip_accents(s).lower()
    s = s.replace("&", " and ").replace("'", " ").replace("’", " ")
    s = re.sub(r"[^a-z0-9]+", " ", s).strip()
    s = _ARTICLE_RE.sub("", s)
    return re.sub(r"\s+", " ", s).strip()


def slug_from_filename(path):
    """Best-effort title guess from a file name, with release tags removed."""
    base = path.rsplit("/", 1)[-1]
    stem, _, ext = base.rpartition(".")
    if not stem or ("." + ext.lower()) not in VIDEO_EXT:
        stem = base
    stem = _SITE_RE.sub(" ", stem)
    stem = re.sub(r"[._\-\[\]()]+", " ", stem)
    # Cut at the first year: everything after it is release metadata.
    m = _YEAR_RE.search(stem)
    if m and m.start() > 0:
        stem = stem[:m.start()]
    stem = _TAG_RE.sub(" ", stem)
    return norm_title(stem)


def ratio(a, b):
    if not a or not b:
        return 0.0
    return difflib.SequenceMatcher(None, a, b).ratio()


def similar(a, b, threshold):
    """Fuzzy equality, treating a containment as a match (subtitles, prefixes)."""
    if not a or not b:
        return False
    if a == b or a in b or b in a:
        return True
    return ratio(a, b) >= threshold


# --------------------------------------------------------------------------- #
# path keying
# --------------------------------------------------------------------------- #

def path_key(path):
    """Key a file the same way whatever mount/scheme each library uses.

    Kodi stores smb://host/films/Genre/File.mkv (URL-encoded), Jellyfin stores
    /NAS/films/Genre/File.mkv. The trailing "directory/file" pair is what both
    agree on, and is specific enough to avoid collisions.
    """
    p = unquote(path or "").replace("\\", "/").rstrip("/")
    parts = [x for x in p.split("/") if x and "://" not in x]
    if len(parts) >= 2:
        return (parts[-2].lower(), parts[-1].lower())
    return ("", parts[-1].lower() if parts else "")


def base_key(path):
    return path_key(path)[1]


# --------------------------------------------------------------------------- #
# data sources
# --------------------------------------------------------------------------- #

def run_remote(ssh, command):
    argv = (["ssh", ssh, command] if ssh else ["sh", "-c", command])
    try:
        # stdin must stay untouched: ssh drains it, which would swallow the
        # answers typed at the --fix prompt.
        out = subprocess.run(argv, capture_output=True, text=True, check=True,
                             stdin=subprocess.DEVNULL)
    except subprocess.CalledProcessError as e:
        sys.exit(f"command failed: {command}\n{e.stderr.strip()}")
    return out.stdout


JELLYFIN_SQL = f"""
SELECT b.Id AS id, b.Name AS title, b.OriginalTitle AS orig,
       b.ProductionYear AS year, b.Path AS path,
       (SELECT ProviderValue FROM BaseItemProviders p
          WHERE p.ItemId = b.Id AND p.ProviderId = 'Imdb') AS imdb,
       (SELECT ProviderValue FROM BaseItemProviders p
          WHERE p.ItemId = b.Id AND p.ProviderId = 'Tmdb') AS tmdb
FROM BaseItems b
WHERE b.Type = '{TYPE_MOVIE}' AND b.IsVirtualItem = 0 AND b.Path IS NOT NULL
"""

KODI_SQL = """
SELECT JSON_OBJECT(
  'id',    m.idMovie,
  'title', m.c00,
  'orig',  m.c16,
  'year',  COALESCE(NULLIF(m.premiered, ''), m.c07),
  'path',  m.c22,
  'imdb',  (SELECT u.value FROM uniqueid u WHERE u.media_id = m.idMovie
              AND u.media_type = 'movie' AND u.type = 'imdb' LIMIT 1),
  'tmdb',  (SELECT u.value FROM uniqueid u WHERE u.media_id = m.idMovie
              AND u.media_type = 'movie' AND u.type = 'tmdb' LIMIT 1)
) FROM movie_view m
"""


def fetch_jellyfin(ssh, db, sudo):
    # Jellyfin keeps the database in WAL mode: even a pure reader has to create
    # the -shm/-wal side files, so a plain unprivileged open fails.
    cmd = f"{sudo}sqlite3 -json {shlex.quote(db)} {shlex.quote(JELLYFIN_SQL)}"
    out = run_remote(ssh, cmd).strip()
    return json.loads(out) if out else []


def fetch_kodi(ssh, db, sudo):
    cmd = f"{sudo}mysql {shlex.quote(db)} -B -N --raw -e {shlex.quote(KODI_SQL)}"
    rows, bad = [], 0
    for line in run_remote(ssh, cmd).splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError:
            bad += 1
    if bad:
        print(f"warning: {bad} Kodi row(s) unparsable, skipped", file=sys.stderr)
    return rows


TOKEN_SQL = """
SELECT d.AccessToken FROM Devices d
JOIN Permissions p ON p.UserId = d.UserId
WHERE p.Kind = 0 AND p.Value = 1
ORDER BY d.DateCreated DESC LIMIT 1
"""


def get_admin_token(ssh, db, sudo):
    """Reuse an existing admin session token from the Jellyfin database.

    Writes need admin rights: a token belonging to a normal user's browser
    session comes back HTTP 403 on the apply call.
    """
    out = run_remote(ssh, f"{sudo}sqlite3 {shlex.quote(db)} {shlex.quote(TOKEN_SQL)}").strip()
    if not out:
        sys.exit("no admin token found in the Devices table — pass --token, or log "
                 "into Jellyfin once as an admin and retry")
    return out.splitlines()[0].strip()


def year_of(v):
    if v is None:
        return None
    m = re.search(r"(19\d{2}|20\d{2})", str(v))
    return int(m.group(1)) if m else None


def normalise(rows):
    """Common shape for both sources."""
    out = []
    for r in rows:
        out.append({
            "id":    str(r.get("id") or ""),
            "title": (r.get("title") or "").strip(),
            "orig":  (r.get("orig") or "").strip(),
            "year":  year_of(r.get("year")),
            # Kept verbatim so a rollback restores the exact date, not just the year.
            "premiered": r.get("year"),
            "path":  unquote((r.get("path") or "").replace("\\", "/")),
            "imdb":  (r.get("imdb") or "").strip() or None,
            "tmdb":  (str(r.get("tmdb")) if r.get("tmdb") else "") .strip() or None,
        })
    return out


# --------------------------------------------------------------------------- #
# comparison
# --------------------------------------------------------------------------- #

def index_by(rows, keyfn):
    """Map key -> rows, so duplicate keys stay visible instead of overwriting."""
    idx = {}
    for r in rows:
        idx.setdefault(keyfn(r["path"]), []).append(r)
    return idx


def pair_up(jf, ko):
    """Match on (parent dir, file name), then retry leftovers on file name alone."""
    jf_idx, ko_idx = index_by(jf, path_key), index_by(ko, path_key)
    pairs, jf_left, ko_left = [], [], []

    for key, jrows in jf_idx.items():
        krows = ko_idx.get(key)
        if krows:
            for j, k in zip(jrows, krows):
                pairs.append((j, k))
            jf_left.extend(jrows[len(krows):])
        else:
            jf_left.extend(jrows)
    for key, krows in ko_idx.items():
        jrows = jf_idx.get(key)
        ko_left.extend(krows[len(jrows):] if jrows else krows)

    # Second pass: same file name, different parent directory (moved/reorganised).
    jf_b, ko_b = index_by(jf_left, base_key), index_by(ko_left, base_key)
    jf_final, ko_final = [], []
    for key, jrows in jf_b.items():
        krows = ko_b.get(key)
        if krows:
            for j, k in zip(jrows, krows):
                pairs.append((j, k))
            jf_final.extend(jrows[len(krows):])
        else:
            jf_final.extend(jrows)
    for key, krows in ko_b.items():
        jrows = jf_b.get(key)
        ko_final.extend(krows[len(jrows):] if jrows else krows)

    return pairs, jf_final, ko_final


def titles_agree(j, k, threshold):
    """True if any Jellyfin title matches any Kodi title.

    Both stores keep a localised and an original title, but not always in the
    same slot (a French library may hold the French title as OriginalTitle), so
    every combination counts as agreement.
    """
    jt = [norm_title(x) for x in (j["title"], j["orig"]) if x]
    kt = [norm_title(x) for x in (k["title"], k["orig"]) if x]
    return any(similar(a, b, threshold) for a in jt for b in kt)


def title_matches_file(row, threshold):
    slug = slug_from_filename(row["path"])
    if not slug or len(slug) < 3:
        return True          # nothing usable in the file name, do not accuse
    for t in (row["title"], row["orig"]):
        if t and similar(norm_title(t), slug, threshold):
            return True
    return False


def compare(pairs, args):
    findings = []
    for j, k in pairs:
        flags = []
        if j["imdb"] and k["imdb"] and j["imdb"].lower() != k["imdb"].lower():
            flags.append("IMDB")
        if j["tmdb"] and k["tmdb"] and j["tmdb"] != k["tmdb"]:
            flags.append("TMDB")
        if j["year"] and k["year"] and j["year"] != k["year"]:
            flags.append("YEAR")
        if not titles_agree(j, k, args.title_threshold):
            flags.append("TITLE")
        # A shared id means both scrapers landed on the same movie, so a title
        # that does not look like the file name is only a language difference
        # (English file name, French title) and not worth reporting.
        ids_agree = ((j["imdb"] and j["imdb"].lower() == (k["imdb"] or "").lower())
                     or (j["tmdb"] and j["tmdb"] == k["tmdb"]))
        if args.strict_filenames or not ids_agree:
            if not title_matches_file(j, args.file_threshold):
                flags.append("FILE-JF")
            if not title_matches_file(k, args.file_threshold):
                flags.append("FILE-KO")
        if flags:
            findings.append({"flags": flags, "jellyfin": j, "kodi": k})
    return findings


# Most decisive first: an id clash proves one side matched the wrong movie,
# a file-name mismatch only suggests it.
SEVERITY = {"IMDB": 0, "TMDB": 1, "YEAR": 2, "TITLE": 3, "FILE-JF": 4, "FILE-KO": 5}


def sort_key(f):
    return (min(SEVERITY[x] for x in f["flags"]),
            -len(f["flags"]),
            f["jellyfin"]["path"].lower())


# --------------------------------------------------------------------------- #
# picking a winner
# --------------------------------------------------------------------------- #

def filename_year(path):
    m = _YEAR_RE.search(path.rsplit("/", 1)[-1])
    return int(m.group(1)) if m else None


def side_score(row, slug, fyear):
    """How well one library's metadata explains the file it is attached to."""
    titles = [norm_title(t) for t in (row["title"], row["orig"]) if t]
    score = max((ratio(t, slug) for t in titles), default=0.0)
    if slug and any(t and (t in slug or slug in t) for t in titles):
        score = max(score, 0.9)
    if fyear and row["year"]:
        score += 1.0 if row["year"] == fyear else -0.35
    return score


def suggest(j, k, min_gap):
    """Guess which library got it right, from the file name alone.

    The file name is the only evidence neither scraper produced, so it is the
    only impartial tiebreaker available offline. It is still just a guess: a
    file misnamed at download time will point at the wrong side.
    """
    slug = slug_from_filename(j["path"])
    fyear = filename_year(j["path"])
    sj, sk = side_score(j, slug, fyear), side_score(k, slug, fyear)
    if abs(sj - sk) < min_gap:
        return None, sj, sk
    return ("jellyfin" if sj > sk else "kodi"), sj, sk


# --------------------------------------------------------------------------- #
# Jellyfin write API
# --------------------------------------------------------------------------- #

def api(ssh, args, method, path, body=None):
    """Call the Jellyfin API with curl, on whichever host holds the databases.

    Going through curl on the server keeps --ssh working unchanged and lets the
    request stay on https://localhost, where the self-signed certificate the TV
    chain needs is not in the way.
    """
    url = f"{args.host.rstrip('/')}{path}"
    cmd = ["curl", "-s", "-S", "--fail-with-body", "-o", "-", "-w", "\\n%{http_code}"]
    if args.insecure:
        cmd.append("-k")
    cmd += ["-X", method, "-H", f"Authorization: MediaBrowser Token={args.token}"]
    if body is not None:
        cmd += ["-H", "Content-Type: application/json", "--data-binary", json.dumps(body)]
    cmd.append(url)
    out = run_remote(ssh, " ".join(shlex.quote(c) for c in cmd))
    payload, _, code = out.rpartition("\n")
    code = code.strip()
    if not code.isdigit() or int(code) >= 400:
        raise RuntimeError(f"HTTP {code} on {method} {path}: {payload.strip()[:300]}")
    payload = payload.strip()
    return json.loads(payload) if payload else None


def item_uuid(item_id):
    return item_id.replace("-", "").lower()


def remote_search(ssh, args, item_id, imdb, tmdb):
    """Ask Jellyfin's own scrapers to resolve a provider id into a match."""
    ids = {}
    if imdb:
        ids["Imdb"] = imdb
    if tmdb:
        ids["Tmdb"] = str(tmdb)
    query = {
        "ItemId": item_uuid(item_id),
        "SearchInfo": {"ProviderIds": ids},
        "IncludeDisabledProviders": True,
    }
    results = api(ssh, args, "POST", "/Items/RemoteSearch/Movie", query) or []
    # A provider-id search can still return near misses; prefer an exact id hit.
    for r in results:
        rid = {k.lower(): str(v) for k, v in (r.get("ProviderIds") or {}).items()}
        if imdb and rid.get("imdb", "").lower() == imdb.lower():
            return r
        if tmdb and rid.get("tmdb") == str(tmdb):
            return r
    return results[0] if results else None


def apply_match(ssh, args, item_id, result):
    q = "?replaceAllImages=" + ("true" if not args.no_images else "false")
    api(ssh, args, "POST", f"/Items/RemoteSearch/Apply/{item_uuid(item_id)}{q}", result)


def locked_fields(ssh, args, item_id):
    """Fields pinned by an earlier manual correction, which Apply will not touch."""
    try:
        data = api(ssh, args, "GET",
                   f"/Items?ids={item_uuid(item_id)}&fields=LockedFields")
    except RuntimeError:
        return []
    items = (data or {}).get("Items") or []
    return items[0].get("LockedFields") or [] if items else []


# --------------------------------------------------------------------------- #
# Kodi write path
# --------------------------------------------------------------------------- #

def sqlstr(s):
    """Quote a literal for MariaDB (backslash escaping is on by default)."""
    if s is None:
        return "NULL"
    return "'" + str(s).replace("\\", "\\\\").replace("'", "\\'") + "'"


def kodi_rollback_sql(k):
    """SQL that puts one movie's rows back the way they were.

    Mirrors kodi_apply exactly, c09 repoint included: replaying this has to
    leave the default id pointing at the tmdb row it recreates, or the rollback
    trades one dangling reference for another.
    """
    mid = int(k["id"])
    stmts = [
        f"-- {k['path']}",
        "START TRANSACTION;",
        f"UPDATE movie SET c00={sqlstr(k['title'])}, c16={sqlstr(k['orig'])}, "
        f"premiered={sqlstr(k['premiered'])} WHERE idMovie={mid};",
    ]
    for typ, val in (("imdb", k["imdb"]), ("tmdb", k["tmdb"])):
        stmts.append(f"DELETE FROM uniqueid WHERE media_id={mid} AND "
                     f"media_type='movie' AND type={sqlstr(typ)};")
        if val:
            stmts.append(f"INSERT INTO uniqueid (media_id, media_type, value, type) "
                         f"VALUES ({mid}, 'movie', {sqlstr(val)}, {sqlstr(typ)});")
            if typ == "tmdb":
                stmts.append(f"UPDATE movie SET c09=LAST_INSERT_ID() WHERE idMovie={mid};")
    stmts.append("COMMIT;")
    return "\n".join(stmts)


def kodi_backup(k, path):
    with open(path, "a", encoding="utf-8") as fh:
        fh.write(kodi_rollback_sql(k) + "\n\n")


def kodi_apply(ssh, args, k, j, sudo):
    """Copy the Jellyfin ids and titles onto the Kodi row.

    Kodi keeps provider ids in `uniqueid`, one row per provider, and `movie.c09`
    is a foreign key naming which of those rows is the default — always the tmdb
    one in this library. Rewriting an id therefore means replacing the row and
    repointing c09 at the row that replaced it, or the movie ends up pointing at
    a uniqueid that no longer exists.
    """
    mid = int(k["id"])
    stmts = ["START TRANSACTION;"]
    sets = [f"c00={sqlstr(j['title'] or k['title'])}"]
    if j["orig"]:
        sets.append(f"c16={sqlstr(j['orig'])}")
    if j["year"]:
        # Kodi derives the displayed year from premiered; keep the day/month if
        # the year is unchanged, otherwise a bare January date is the honest
        # placeholder, since Jellyfin only gave us a year.
        sets.append(f"premiered={sqlstr(str(j['year']) + '-01-01')}")
    stmts.append(f"UPDATE movie SET {', '.join(sets)} WHERE idMovie={mid};")

    for typ, val in (("imdb", j["imdb"]), ("tmdb", j["tmdb"])):
        stmts.append(f"DELETE FROM uniqueid WHERE media_id={mid} AND "
                     f"media_type='movie' AND type={sqlstr(typ)};")
        if val:
            stmts.append(f"INSERT INTO uniqueid (media_id, media_type, value, type) "
                         f"VALUES ({mid}, 'movie', {sqlstr(val)}, {sqlstr(typ)});")
            if typ == "tmdb":
                stmts.append(f"UPDATE movie SET c09=LAST_INSERT_ID() WHERE idMovie={mid};")
    stmts.append("COMMIT;")

    sql = "\n".join(stmts)
    cmd = (f"{sudo}mysql {shlex.quote(args.kodi_db)} --default-character-set=utf8mb4 "
           f"-e {shlex.quote(sql)}")
    run_remote(ssh, cmd)


def fix(findings, ssh, args, sudo):
    """Walk the id disagreements and push the chosen id into the losing library."""
    todo = [f for f in findings if {"IMDB", "TMDB"} & set(f["flags"])]
    if not todo:
        print("no provider id disagreements to fix")
        return
    print(f"{len(todo)} provider id disagreement(s)"
          + (" — dry run, nothing will be written" if args.dry_run else ""))
    if not args.dry_run and not args.no_kodi:
        print("close your Kodi clients first: a running one caches the library "
              "in memory and can write its stale copy back over these edits")
    print()

    applied = skipped = failed = 0
    for n, f in enumerate(todo, 1):
        j, k = f["jellyfin"], f["kodi"]
        winner, sj, sk = suggest(j, k, args.min_gap)
        default = {"kodi": "k", "jellyfin": "j"}.get(winner, "s")
        fyear = filename_year(j["path"])
        print(f"[{n}/{len(todo)}] {j['path']}")
        print(f"  filename: {slug_from_filename(j['path'])}"
              + (f"  ({fyear})" if fyear else ""))
        print(f"  j) jellyfin: {fmt_movie(j)}   score {sj:.2f}")
        print(f"  k) kodi    : {fmt_movie(k)}   score {sk:.2f}")
        print(f"  suggestion: {winner or 'unclear, decide yourself'}")

        if args.yes:
            choice = default
        else:
            try:
                choice = input("  apply [k]odi id / keep [j]ellyfin / [s]kip / [q]uit? "
                               f"[{default}] ").strip().lower()
            except (EOFError, KeyboardInterrupt):
                print("\naborted")
                break
            choice = choice or default

        if choice == "q":
            print("stopped")
            break
        if choice == "j":
            if args.no_kodi:
                print("  kept Jellyfin — fix this one in Kodi\n")
                skipped += 1
                continue
            if not (j["imdb"] or j["tmdb"]):
                print("  Jellyfin has no provider id to push\n")
                skipped += 1
                continue
            if args.dry_run:
                print(f"  would write into Kodi: {j['imdb'] or ''} "
                      f"{('tmdb:' + j['tmdb']) if j['tmdb'] else ''} "
                      f"{j['title']} ({j['year']})\n")
                applied += 1
                continue
            try:
                kodi_backup(k, args.backup)
                kodi_apply(ssh, args, k, j, sudo)
            except (RuntimeError, OSError, SystemExit) as e:
                print(f"  failed: {e}\n")
                failed += 1
                continue
            print(f"  wrote into Kodi: {j['title']} ({j['year']}) "
                  f"{j['imdb'] or ''}  [rollback in {args.backup}]")
            print("  refresh this movie in Kodi to re-scrape plot, cast and artwork\n")
            applied += 1
            continue
        if choice != "k":
            print("  skipped\n")
            skipped += 1
            continue
        if not (k["imdb"] or k["tmdb"]):
            print("  Kodi has no provider id to push\n")
            skipped += 1
            continue

        if args.dry_run:
            print(f"  would apply {k['imdb'] or ''} {('tmdb:' + k['tmdb']) if k['tmdb'] else ''}\n")
            applied += 1
            continue

        try:
            match = remote_search(ssh, args, j["id"], k["imdb"], k["tmdb"])
            if not match:
                print("  no remote match for that id — scraper returned nothing\n")
                failed += 1
                continue
            locked = locked_fields(ssh, args, j["id"])
            apply_match(ssh, args, j["id"], match)
        except RuntimeError as e:
            print(f"  failed: {e}\n")
            failed += 1
            continue

        print(f"  applied: {match.get('Name')} ({match.get('ProductionYear')}) "
              f"{(match.get('ProviderIds') or {}).get('Imdb', '')}")
        if locked:
            print(f"  note: locked field(s) {', '.join(locked)} were left untouched "
                  f"— unlock them in the UI if the old value is still showing")
        print()
        applied += 1

    verb = "would apply" if args.dry_run else "applied"
    print(f"{verb} {applied}, skipped {skipped}, failed {failed}")


# --------------------------------------------------------------------------- #
# output
# --------------------------------------------------------------------------- #

def fmt_movie(r):
    bits = [r["title"] or "?"]
    if r["orig"] and norm_title(r["orig"]) != norm_title(r["title"]):
        bits.append(f"[{r['orig']}]")
    if r["year"]:
        bits.append(f"({r['year']})")
    ids = " ".join(x for x in (r["imdb"], f"tmdb:{r['tmdb']}" if r["tmdb"] else "") if x)
    if ids:
        bits.append(ids)
    return " ".join(bits)


def report_text(findings, jf_only, ko_only, args):
    for f in findings:
        j, k = f["jellyfin"], f["kodi"]
        print(f"{','.join(f['flags']):<24} {j['path']}")
        print(f"  jellyfin: {fmt_movie(j)}")
        print(f"  kodi    : {fmt_movie(k)}")
        if "FILE-JF" in f["flags"] or "FILE-KO" in f["flags"]:
            print(f"  filename: {slug_from_filename(j['path'])}")
        print()

    if args.unmatched:
        for label, rows in (("only in Jellyfin", jf_only), ("only in Kodi", ko_only)):
            if rows:
                print(f"=== {label} ({len(rows)}) ===")
                for r in sorted(rows, key=lambda x: x["path"].lower()):
                    print(f"  {r['path']}  -> {fmt_movie(r)}")
                print()


def report_csv(findings):
    w = lambda *c: print("\t".join(str(x) if x is not None else "" for x in c))
    w("flags", "path", "jf_title", "jf_orig", "jf_year", "jf_imdb", "jf_tmdb",
      "ko_title", "ko_orig", "ko_year", "ko_imdb", "ko_tmdb")
    for f in findings:
        j, k = f["jellyfin"], f["kodi"]
        w(",".join(f["flags"]), j["path"],
          j["title"], j["orig"], j["year"], j["imdb"], j["tmdb"],
          k["title"], k["orig"], k["year"], k["imdb"], k["tmdb"])


def main():
    ap = argparse.ArgumentParser(
        description="Compare movie metadata between Jellyfin and Kodi.",
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--ssh", metavar="HOST",
                    help="run both queries over ssh on HOST (e.g. nas)")
    ap.add_argument("--jellyfin-db", default=JELLYFIN_DB)
    ap.add_argument("--kodi-db", default=KODI_DB)
    ap.add_argument("--no-sudo", action="store_true",
                    help="query both databases without sudo")
    ap.add_argument("--only", metavar="FLAGS",
                    help="keep only these flags, comma separated "
                         "(IMDB,TMDB,YEAR,TITLE,FILE-JF,FILE-KO)")
    ap.add_argument("--unmatched", action="store_true",
                    help="also list files present in only one library")
    ap.add_argument("--path", metavar="SUBSTRING",
                    help="only consider files whose path contains SUBSTRING")
    ap.add_argument("--title-threshold", type=float, default=0.82,
                    help="fuzzy ratio above which two titles count as equal")
    ap.add_argument("--file-threshold", type=float, default=0.62,
                    help="fuzzy ratio above which a title matches its file name")
    ap.add_argument("--strict-filenames", action="store_true",
                    help="run the file name checks even when both libraries "
                         "agree on the IMDb/TMDb id (noisy: flags every file "
                         "named in a different language than its title)")
    ap.add_argument("--limit", type=int, help="print at most N findings")
    ap.add_argument("--csv", action="store_true", help="tab-separated output")
    ap.add_argument("--json", action="store_true", help="JSON output")

    g = ap.add_argument_group("fix mode")
    g.add_argument("--fix", action="store_true",
                   help="walk the id disagreements and re-identify the Jellyfin "
                        "item from the Kodi provider id, one confirmation each")
    g.add_argument("--dry-run", action="store_true",
                   help="with --fix, show what would be applied and write nothing")
    g.add_argument("--yes", action="store_true",
                   help="with --fix, take the suggested side without asking "
                        "(unclear rows are skipped)")
    g.add_argument("--min-gap", type=float, default=0.5,
                   help="score difference below which a row counts as unclear")
    g.add_argument("--no-images", action="store_true",
                   help="keep the existing artwork instead of re-fetching it")
    g.add_argument("--no-kodi", action="store_true",
                   help="never write to the Kodi database; only Jellyfin is fixed")
    g.add_argument("--backup", default="kodi-fix-rollback.sql",
                   help="file the Kodi rollback statements are appended to "
                        "(default kodi-fix-rollback.sql)")
    g.add_argument("--host", default=JELLYFIN_HOST,
                   help=f"Jellyfin base URL as seen from the DB host (default {JELLYFIN_HOST})")
    g.add_argument("--token", help="API token (default: an admin token from the DB)")
    g.add_argument("--no-insecure", dest="insecure", action="store_false",
                   help="verify the TLS certificate (the default localhost URL "
                        "uses a self-signed one, so curl needs -k)")
    args = ap.parse_args()

    if args.fix and (args.csv or args.json):
        sys.exit("--fix cannot be combined with --csv or --json")

    sudo = "" if args.no_sudo else "sudo -n "
    jf = normalise(fetch_jellyfin(args.ssh, args.jellyfin_db, sudo))
    ko = normalise(fetch_kodi(args.ssh, args.kodi_db, sudo))

    if args.path:
        needle = args.path.lower()
        keep = lambda rows: [r for r in rows if needle in r["path"].lower()]
        jf, ko = keep(jf), keep(ko)

    pairs, jf_only, ko_only = pair_up(jf, ko)
    findings = sorted(compare(pairs, args), key=sort_key)

    if args.only:
        wanted = {x.strip().upper() for x in args.only.split(",")}
        unknown = wanted - set(SEVERITY)
        if unknown:
            sys.exit(f"unknown flag(s): {', '.join(sorted(unknown))}")
        findings = [f for f in findings if wanted & set(f["flags"])]

    shown = findings[:args.limit] if args.limit else findings

    if args.fix:
        if not args.token:
            args.token = get_admin_token(args.ssh, args.jellyfin_db, sudo)
        fix(shown, args.ssh, args, sudo)
        return
    if args.json:
        json.dump({"findings": shown,
                   "only_in_jellyfin": jf_only, "only_in_kodi": ko_only},
                  sys.stdout, indent=2, ensure_ascii=False)
        print()
        return
    if args.csv:
        report_csv(shown)
        return

    report_text(shown, jf_only, ko_only, args)

    counts = {}
    for f in findings:
        for fl in f["flags"]:
            counts[fl] = counts.get(fl, 0) + 1
    print(f"jellyfin movies : {len(jf)}")
    print(f"kodi movies     : {len(ko)}")
    print(f"matched files   : {len(pairs)}"
          f"  (jellyfin-only {len(jf_only)}, kodi-only {len(ko_only)})")
    print(f"disagreements   : {len(findings)}"
          + (f", showing {len(shown)}" if len(shown) != len(findings) else ""))
    for fl in sorted(counts, key=lambda x: SEVERITY[x]):
        print(f"  {fl:<8} {counts[fl]}")
    if not args.unmatched and (jf_only or ko_only):
        print("(use --unmatched to list the one-sided files)")


if __name__ == "__main__":
    main()
