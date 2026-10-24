#!/usr/bin/env python3
"""Bulk-download the media of one Ursus Adventures booking gallery.

The gallery lives behind a Joomla login (component ``com_ora``), so the tool
needs an authenticated session. Three ways to give it one, in order of
convenience:

  1. ``--cookie`` / ``URSUS_COOKIE``: paste the session cookie from a browser
     that is already logged in (Devtools > Application > Cookies).
  2. ``--user`` + ``URSUS_PASS``: log in with the site credentials.
  3. ``--from-html``: skip the network for the gallery page entirely and parse
     a copy saved from the browser ("Save page as", HTML only).

Typical run::

    export URSUS_PASS='...'
    ./ursus-media-dl.py --user myaccount --id 945 --list      # inspect first
    ./ursus-media-dl.py --user myaccount --id 945 -o ./photos # then download

The tool downloads whatever the logged-in account is served: it has no way to
unlock media the account has not paid for. Run ``--list`` first to see which
variants the page actually exposes.
"""

from __future__ import annotations

import argparse
import base64
import concurrent.futures as futures
import getpass
import gzip
import html
import http.cookiejar as cookiejar
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
import zlib
from dataclasses import dataclass

BASE = "https://www.ursusadventures.it/booking/"
LOGIN_URL = BASE + "index.php?option=com_ora&view=public&tpl=login&Itemid=108"
GALLERY_TMPL = BASE + "en/user-area?view=registered&tpl=buyMedia&id={id}"
UA = "Mozilla/5.0 (X11; FreeBSD amd64; rv:128.0) Gecko/20100101 Firefox/128.0"

MEDIA_EXT = ("jpg", "jpeg", "png", "webp", "gif", "heic", "mp4", "mov", "m4v", "avi")
MEDIA_RE = re.compile(
    r"""(?:https?://[^\s"'()<>\\]+|/[^\s"'()<>\\]*)\.(?:%s)(?:\?[^\s"'()<>\\]*)?"""
    % "|".join(MEDIA_EXT),
    re.IGNORECASE,
)
# Substrings that mark a derived/preview rendition rather than the original.
PREVIEW_HINTS = ("thumb", "thumbnail", "preview", "small", "medium", "watermark",
                 "_wm", "-wm", "resize", "crop", "icon", "logo", "placeholder")


# --------------------------------------------------------------------------- http


class Session:
    """Cookie-keeping HTTP client with transparent decompression."""

    def __init__(self, verbose: bool = False):
        self.jar = cookiejar.CookieJar()
        self.opener = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(self.jar),
            urllib.request.HTTPRedirectHandler(),
        )
        self.verbose = verbose

    def add_raw_cookie(self, raw: str) -> None:
        """Seed the jar from a browser cookie header ('a=1; b=2')."""
        for part in raw.split(";"):
            part = part.strip()
            if not part or "=" not in part:
                continue
            name, value = part.split("=", 1)
            self.jar.set_cookie(
                cookiejar.Cookie(
                    version=0, name=name.strip(), value=value.strip(),
                    port=None, port_specified=False,
                    domain="www.ursusadventures.it", domain_specified=True,
                    domain_initial_dot=False, path="/", path_specified=True,
                    secure=True, expires=None, discard=True, comment=None,
                    comment_url=None, rest={}, rfc2109=False,
                )
            )

    def open(self, url: str, data: bytes | None = None, referer: str | None = None):
        req = urllib.request.Request(url, data=data, method="POST" if data else "GET")
        req.add_header("User-Agent", UA)
        req.add_header("Accept-Language", "en-GB,en;q=0.9,it;q=0.8")
        req.add_header("Accept-Encoding", "gzip, deflate")
        if referer:
            req.add_header("Referer", referer)
        if data:
            req.add_header("Content-Type", "application/x-www-form-urlencoded")
        if self.verbose:
            print(f"  {req.get_method()} {url}", file=sys.stderr)
        return self.opener.open(req, timeout=60)

    def get_text(self, url: str, data: bytes | None = None, referer: str | None = None):
        with self.open(url, data=data, referer=referer) as resp:
            body = _decompress(resp.read(), resp.headers.get("Content-Encoding", ""))
            charset = resp.headers.get_content_charset() or "utf-8"
            return body.decode(charset, "replace"), resp.geturl()


def _decompress(raw: bytes, encoding: str) -> bytes:
    encoding = encoding.lower()
    if encoding == "gzip":
        return gzip.decompress(raw)
    if encoding == "deflate":
        try:
            return zlib.decompress(raw)
        except zlib.error:
            return zlib.decompress(raw, -zlib.MAX_WBITS)
    return raw


# -------------------------------------------------------------------------- login


def _hidden_inputs(form_html: str) -> dict[str, str]:
    fields = {}
    for tag in re.findall(r"<input\b[^>]*>", form_html, re.IGNORECASE):
        if not re.search(r'type\s*=\s*["\']?hidden', tag, re.IGNORECASE):
            continue
        name = re.search(r'name\s*=\s*["\']([^"\']+)', tag, re.IGNORECASE)
        value = re.search(r'value\s*=\s*["\']([^"\']*)', tag, re.IGNORECASE)
        if name:
            fields[html.unescape(name.group(1))] = html.unescape(value.group(1) if value else "")
    return fields


def login(sess: Session, user: str, password: str, gallery_id: str) -> None:
    """Joomla com_users login; raises SystemExit on failure."""
    page, final_url = sess.get_text(LOGIN_URL)
    form = re.search(
        r'<form\b[^>]*\bclass\s*=\s*["\'][^"\']*mod-login[^"\']*["\'][^>]*>(.*?)</form>',
        page, re.IGNORECASE | re.DOTALL)
    if not form:
        form = re.search(r"<form\b[^>]*>(?:(?!</form>).)*?name=[\"']password[\"'].*?</form>",
                         page, re.IGNORECASE | re.DOTALL)
        if not form:
            sys.exit("login: no login form found; the site layout changed. "
                     "Use --cookie or --from-html instead.")
    form_html = form.group(0)
    action = re.search(r'action\s*=\s*["\']([^"\']*)', form_html, re.IGNORECASE)
    post_url = urllib.parse.urljoin(final_url, html.unescape(action.group(1)) if action else "")

    fields = _hidden_inputs(form_html)
    fields["username"] = user
    fields["password"] = password
    # Come back straight to the gallery so we can tell success from failure.
    target = f"index.php?view=registered&tpl=buyMedia&id={gallery_id}&option=com_ora&Itemid=128"
    fields["return"] = base64.b64encode(target.encode()).decode()

    body, landed = sess.get_text(post_url, data=urllib.parse.urlencode(fields).encode(),
                                 referer=final_url)
    if "tpl=login" in landed or re.search(r"name=[\"']password[\"']", body):
        sys.exit("login: rejected (wrong credentials, or the account is locked).")


def fetch_gallery(sess: Session, gallery_id: str) -> tuple[str, str]:
    url = GALLERY_TMPL.format(id=gallery_id)
    body, landed = sess.get_text(url, referer=BASE)
    if "tpl=login" in landed:
        sys.exit(f"gallery {gallery_id}: redirected to the login page - the session is not "
                 "authenticated. Pass --user/URSUS_PASS, a fresh --cookie, or --from-html.")
    return body, landed


# ------------------------------------------------------------------------ parsing


@dataclass
class Media:
    url: str
    name: str
    preview: bool

    @property
    def key(self) -> str:
        """Identity of the depicted photo, ignoring the rendition suffix."""
        stem = re.sub(r"\.[^.]+$", "", self.name)
        stem = re.sub(r"[-_]?(?:%s)\b" % "|".join(PREVIEW_HINTS), "", stem, flags=re.IGNORECASE)
        stem = re.sub(r"[-_]\d{2,4}x\d{2,4}$", "", stem)
        return stem.lower()


def extract_media(page: str, page_url: str) -> list[Media]:
    """Pull every media URL out of the page: attributes, inline JS and JSON alike."""
    found: dict[str, Media] = {}
    for raw in MEDIA_RE.findall(page):
        raw = html.unescape(raw).replace("\\/", "/")
        url = urllib.parse.urljoin(page_url, raw)
        if urllib.parse.urlparse(url).scheme not in ("http", "https"):
            continue
        path = urllib.parse.urlparse(url).path
        name = urllib.parse.unquote(os.path.basename(path)) or "media"
        low = url.lower()
        preview = any(h in low for h in PREVIEW_HINTS) or bool(
            re.search(r"\d{2,4}x\d{2,4}", low))
        found.setdefault(url, Media(url=url, name=name, preview=preview))
    return sorted(found.values(), key=lambda m: (m.preview, m.name))


def pick_originals(items: list[Media]) -> list[Media]:
    """One entry per photo: the non-preview rendition when the page offers both."""
    by_key: dict[str, Media] = {}
    for m in items:
        cur = by_key.get(m.key)
        if cur is None or (cur.preview and not m.preview):
            by_key[m.key] = m
    return sorted(by_key.values(), key=lambda m: m.name)


# ---------------------------------------------------------------------- download


def unique_path(directory: str, name: str) -> str:
    candidate = os.path.join(directory, name)
    if not os.path.exists(candidate):
        return candidate
    stem, ext = os.path.splitext(name)
    n = 2
    while os.path.exists(os.path.join(directory, f"{stem}-{n}{ext}")):
        n += 1
    return os.path.join(directory, f"{stem}-{n}{ext}")


def download(sess: Session, item: Media, outdir: str, referer: str,
             overwrite: bool) -> tuple[str, str]:
    dest = os.path.join(outdir, item.name)
    if os.path.exists(dest) and not overwrite:
        return ("skip", dest)
    if os.path.exists(dest):
        dest = unique_path(outdir, item.name)
    tmp = dest + ".part"
    try:
        with sess.open(item.url, referer=referer) as resp, open(tmp, "wb") as fh:
            encoding = resp.headers.get("Content-Encoding", "")
            if encoding:
                fh.write(_decompress(resp.read(), encoding))
            else:
                while True:
                    chunk = resp.read(1 << 16)
                    if not chunk:
                        break
                    fh.write(chunk)
    except (urllib.error.URLError, OSError) as exc:
        if os.path.exists(tmp):
            os.unlink(tmp)
        return ("fail", f"{item.url}: {exc}")
    os.replace(tmp, dest)
    return ("ok", dest)


# --------------------------------------------------------------------------- cli


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Download the media of an Ursus Adventures booking gallery.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__.split("Typical run", 1)[0])
    ap.add_argument("--id", help="gallery id, the 'id=' value in the buyMedia URL")
    ap.add_argument("-u", "--user", help="site username (password via URSUS_PASS or prompt)")
    ap.add_argument("--cookie", default=os.environ.get("URSUS_COOKIE"),
                    help="cookie header copied from a logged-in browser ('name=value; ...')")
    ap.add_argument("--from-html", metavar="FILE",
                    help="parse this saved gallery page instead of fetching it")
    ap.add_argument("-o", "--out", default=None, metavar="DIR",
                    help="output directory (default: ursus-<id>)")
    ap.add_argument("-l", "--list", action="store_true",
                    help="list what the page exposes, download nothing")
    ap.add_argument("-a", "--all", action="store_true",
                    help="download every rendition, not just the best one per photo")
    ap.add_argument("-j", "--jobs", type=int, default=4, help="parallel downloads (default 4)")
    ap.add_argument("-f", "--force", action="store_true", help="re-download existing files")
    ap.add_argument("--dump-html", metavar="FILE", help="save the fetched gallery HTML")
    ap.add_argument("-v", "--verbose", action="store_true", help="log every request")
    args = ap.parse_args()

    if not args.from_html and not args.id:
        ap.error("--id is required unless --from-html is used")

    sess = Session(verbose=args.verbose)
    if args.cookie:
        sess.add_raw_cookie(args.cookie)

    if args.from_html:
        with open(args.from_html, "r", encoding="utf-8", errors="replace") as fh:
            page = fh.read()
        page_url = GALLERY_TMPL.format(id=args.id) if args.id else BASE
    else:
        if args.user:
            password = os.environ.get("URSUS_PASS") or getpass.getpass("Password: ")
            login(sess, args.user, password, args.id)
        elif not args.cookie:
            ap.error("need one of --user, --cookie or --from-html to reach the gallery")
        page, page_url = fetch_gallery(sess, args.id)
        if args.dump_html:
            with open(args.dump_html, "w", encoding="utf-8") as fh:
                fh.write(page)
            print(f"saved gallery HTML to {args.dump_html}", file=sys.stderr)

    items = extract_media(page, page_url)
    if not items:
        print("no media URLs found in the page.", file=sys.stderr)
        print("Re-run with --dump-html /tmp/gallery.html and inspect it: the media may be "
              "loaded by a separate XHR that this tool does not follow yet.", file=sys.stderr)
        return 1

    targets = items if args.all else pick_originals(items)

    if args.list:
        for m in items:
            mark = "preview" if m.preview else "full   "
            chosen = " *" if m in targets else "  "
            print(f"{chosen}{mark}  {m.url}")
        print(f"\n{len(items)} media URL(s), {len(targets)} selected "
              f"(* = would be downloaded; -a downloads all).", file=sys.stderr)
        return 0

    outdir = args.out or f"ursus-{args.id or 'gallery'}"
    os.makedirs(outdir, exist_ok=True)

    ok = skipped = 0
    failures: list[str] = []
    with futures.ThreadPoolExecutor(max_workers=max(1, args.jobs)) as pool:
        jobs = {pool.submit(download, sess, m, outdir, page_url, args.force): m
                for m in targets}
        for i, fut in enumerate(futures.as_completed(jobs), 1):
            status, detail = fut.result()
            if status == "ok":
                ok += 1
                print(f"[{i}/{len(targets)}] {detail}")
            elif status == "skip":
                skipped += 1
                print(f"[{i}/{len(targets)}] exists, skipped: {detail}")
            else:
                failures.append(detail)
                print(f"[{i}/{len(targets)}] FAILED {detail}", file=sys.stderr)

    print(f"\n{ok} downloaded, {skipped} skipped, {len(failures)} failed -> {outdir}/",
          file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
