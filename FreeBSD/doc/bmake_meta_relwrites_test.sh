#!/bin/sh
#
# Quick A/B test for bmake_meta_relwrites.patch.
#
# Reproduces the META_MODE staleness bug on share/zoneinfo, applies the
# patch to /usr/src, builds a side-by-side patched make at
# /usr/local/bin/make-patched, and verifies three properties:
#
#   STALE       patched make wants to rebuild zonefiles after
#               builddir/ is deleted (stock make says "up to date")
#   REBUILD     patched make actually regenerates builddir/Africa/Abidjan
#   IDEMPOTENT  a second run does not re-trigger the rebuild
#
# Requires:
#   - WITH_META_MODE=yes in /etc/src-env.conf
#   - a fully built /usr/obj for /usr/src
#   - root (uses sudo)
#
# Does NOT touch /usr/bin/make.  To promote the fix system-wide after a
# successful run: cd /usr/src/usr.bin/bmake && sudo make install

set -eu

PATCH=${PATCH:-$(cd "$(dirname "$0")" && pwd)/bmake_meta_relwrites.patch}
SRC=${SRC:-/usr/src}
# obj path uses <MACHINE>.<MACHINE_ARCH> on FreeBSD (e.g. arm64.aarch64);
# fall back to a glob if both are the same (amd64.amd64 collapses to amd64).
MACHINE=$(uname -m)
MACHINE_ARCH=$(uname -p)
if [ "$MACHINE" = "$MACHINE_ARCH" ]; then
    OBJ_ARCH=$MACHINE
else
    OBJ_ARCH=${MACHINE}.${MACHINE_ARCH}
fi
OBJ=/usr/obj${SRC}/${OBJ_ARCH}/share/zoneinfo
PATCHED=/usr/local/bin/make-patched

die() { echo "FAIL: $*" >&2; exit 1; }
say() { printf '\n==> %s\n' "$*"; }

[ -r "$PATCH" ] || die "patch not found: $PATCH (override with PATCH=)"
[ -d "$SRC/contrib/bmake" ] || die "no bmake source at $SRC/contrib/bmake"
grep -q '^WITH_META_MODE=yes' /etc/src-env.conf 2>/dev/null \
    || die "WITH_META_MODE=yes not set in /etc/src-env.conf"
[ -f "$OBJ/zonefiles.meta" ] \
    || die "no zonefiles.meta at $OBJ - run buildworld first"

say "Applying patch to $SRC (idempotent: reverts first if already applied)"
if (cd "$SRC" && sudo git apply --reverse --check "$PATCH" 2>/dev/null); then
    echo "patch already applied, leaving as-is"
else
    (cd "$SRC" && sudo git apply "$PATCH") \
        || die "git apply failed - tree may be modified"
fi

say "Building patched bmake"
(cd "$SRC/usr.bin/bmake" && sudo make obj >/dev/null && sudo make all >/dev/null) \
    || die "bmake build failed"
sudo install -o root -g wheel -m 555 \
    "/usr/obj${SRC}/${OBJ_ARCH}/usr.bin/bmake/make" "$PATCHED"
echo "installed: $PATCHED"

say "TEST 1/4  stock make on stale tree (expected: bug repro - 'up to date')"
sudo rm -rf "$OBJ/builddir"
stock_out=$(cd "$SRC/share/zoneinfo" && sudo /usr/bin/make -n zonefiles 2>&1)
echo "$stock_out" | head -3
echo "$stock_out" | grep -q 'is up to date' \
    && echo "  OK  stock make wrongly says up-to-date (bug reproduced)" \
    || echo "  NOTE  stock make already wants to rebuild - bug not reproduced on this tree"

say "TEST 2/4  patched make on stale tree (expected: queues zic rebuild)"
sudo rm -rf "$OBJ/builddir"
patched_out=$(cd "$SRC/share/zoneinfo" && sudo "$PATCHED" -n zonefiles 2>&1)
echo "$patched_out" | grep -E 'zic |Africa' | head -2
echo "$patched_out" | grep -qE 'zic -D -d.*builddir' \
    || die "patched make did NOT detect staleness"
echo "  OK  patched make detected missing builddir"

say "TEST 3/4  patched make rebuilds (expected: Africa/Abidjan regenerated)"
(cd "$SRC/share/zoneinfo" && sudo "$PATCHED" zonefiles >/dev/null) \
    || die "rebuild failed"
[ -f "$OBJ/builddir/Africa/Abidjan" ] \
    || die "Abidjan not regenerated at $OBJ/builddir/Africa/Abidjan"
echo "  OK  $OBJ/builddir/Africa/Abidjan present"

say "TEST 4/4  idempotency (expected: 'up to date' on second run)"
idem_out=$(cd "$SRC/share/zoneinfo" && sudo "$PATCHED" -n zonefiles 2>&1)
echo "$idem_out"
echo "$idem_out" | grep -q 'is up to date' \
    || die "patched make wrongly wants to rebuild a fresh tree"
echo "  OK  no false-positive rebuild"

say "ALL PASS"
echo
echo "To promote system-wide:"
echo "  cd $SRC/usr.bin/bmake && sudo make install"
echo
echo "To revert the source patch:"
echo "  (cd $SRC && sudo git apply --reverse $PATCH)"
