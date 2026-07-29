# bmake META_MODE: missing relative-path writes (root cause + patch)

## Symptom

`installworld` (or `beinstall.sh`) fails partway through with:

```
install: /usr/obj/usr/src/<arch>/share/zoneinfo/builddir/Africa/Abidjan: No such file or directory
*** [install-zoneinfo] Error code 71
```

`buildworld` finished without error. The relevant obj layout shows
`zonefiles` and `zonefiles.meta` present, but `builddir/` is gone.

Other targets with the same shape (a "manifest" file pointing at a
directory of build outputs, where the build chdirs into a subdir to
produce them) can fail the same way; zoneinfo is just the most
visible.

## Root cause

FreeBSD enables `WITH_META_MODE=yes` in `/etc/src-env.conf`. In
META_MODE, bmake records each target's filemon trace in a `.meta`
file (recipe commands, reads, writes, chdirs, forks, renames, ...).
On a subsequent build, `meta_oodate()` re-reads that `.meta` to
decide whether the recipe can be skipped.

When filemon records a Write (`W`) or reName (`M`) whose target
is a relative path - because the writing process was running under
a `chdir()` (`C` record) into a build subdirectory - the upstream
`meta_oodate()` in `contrib/bmake/meta.c` short-circuits:

```c
case 'W':                /* Write */
check_write:
    ...
    /* ignore non-absolute paths */
    if (*p != '/')
        break;
```

So writes performed inside a `chdir`'d subshell are dropped on the
floor. The same applies to the rename and unlink (`D`/`M`) handlers,
which only run their `missingFiles` cleanup when the source path is
absolute.

The classic share/zoneinfo recipe is:

```make
zonefiles: ${TDATA}
    mkdir -p ${TZBUILDDIR}
    (cd ${TZBUILDDIR}; mkdir -p ${TZBUILDSUBDIRS})
    (umask 022; cd ${.CURDIR}; \
        ${ZIC} -D -d ${TZBUILDDIR} ${ZICFLAGS} -m ${NOBINMODE} \
            ${LEAPFILE} ${TZFILES})
    ...
    (cd ${TZBUILDDIR} && find * -type f | LC_ALL=C sort) > ${.TARGET}
```

`zic` writes `Africa/.zicXXX` then renames to `Africa/Abidjan` -
both **relative**, because zic chdir'd into `builddir/`. Filemon
faithfully records them as relative; upstream meta_oodate then
ignores them.

Failure sequence:

1. An earlier successful run produced `builddir/` and `zonefiles*`.
2. Something later removed `builddir/` but left `zonefiles` and
   `zonefiles.meta` in place. Triggers: a previous failed
   installworld, manual cleanup, partial `make cleandir`, ZFS
   snapshot rollback of `/usr/obj`, etc.
3. The next buildworld parses `zonefiles.meta`. The recorded inputs
   (`${TDATA}`) are unchanged. The `W`/`M` records pointing at the
   now-missing files are silently skipped. Verdict: "up-to-date".
4. `buildworld.log` therefore contains **no `zic` activity** for
   this run.
5. `installworld` runs the `install-zoneinfo` recipe:

   ```make
   for f in `cat zonefiles`; do \
       ${INSTALL} ... ${TZBUILDDIR}/$${f} ${DESTDIR}/usr/share/zoneinfo/$${f}; \
   done
   ```

   The first iteration tries to copy
   `/usr/obj/.../share/zoneinfo/builddir/Africa/Abidjan` and fails.

This is a META_MODE staleness bug, not a tzdata or makefile bug.

## Diagnostic check

If you see the error and want to confirm it's this bug (rather than
a real build failure), three quick checks:

```sh
# 1. buildworld did NOT actually rebuild zoneinfo - no zic activity
grep -E 'zoneinfo|zic ' /usr/buildworld.log
# (empty output = META_MODE skipped it)

# 2. The manifest is present but the directory it points into is gone
ls /usr/obj/usr/src/<arch>/share/zoneinfo/zonefiles*
ls /usr/obj/usr/src/<arch>/share/zoneinfo/builddir/Africa/Abidjan
# (zonefiles present, Abidjan missing)

# 3. META_MODE is on
grep META_MODE /etc/src-env.conf
```

## Reproducing the bug from scratch (no waiting)

You do not need to hit the natural sequence; you can synthesize it
in seconds on any FreeBSD source tree with `WITH_META_MODE=yes`:

```sh
# Assume a successful buildworld has been done, so the obj tree is
# fully populated.
OBJ=/usr/obj/usr/src/$(uname -p)/share/zoneinfo

# 1. Confirm a healthy state
ls $OBJ/builddir/Africa/Abidjan          # present
sudo make -C /usr/src/share/zoneinfo -n zonefiles
# -> "`zonefiles' is up to date."

# 2. Simulate the failure mode: delete builddir, leave manifest
sudo rm -rf $OBJ/builddir

# 3. Ask the stock make what it would do
sudo make -C /usr/src/share/zoneinfo -n zonefiles
# -> "`zonefiles' is up to date."   <-- BUG: should want to rebuild

# 4. The install step then explodes
sudo make -C /usr/src/share/zoneinfo install DESTDIR=/tmp/zi-test
# -> install: .../builddir/Africa/Abidjan: No such file or directory
```

Step 3 is the smoking gun: stock bmake declares the target fresh
even though every output file is gone.

## The fix

Patch `contrib/bmake/meta.c` so that `meta_oodate()`:

1. When a `W` (Write) or `M` (reName target) record has a relative
   path, resolve it against `latestdir`, then `lcwd`, then `cwd`,
   and `stat()` each candidate. If none exist, mark the node oodate
   (via `missingFiles`).
2. When a `D` (unlink) or `M` (reName source) record has a relative
   path, resolve it against `latestdir` so the matching
   `missingFiles` entry added by the prior `W` is cleared. This is
   what makes the rename cycle (`W Africa/.zicXXX` then
   `M Africa/.zicXXX -> Africa/Abidjan`) self-balance instead of
   permanently flagging the temp file as missing.

`cwd` (the make process's own cwd) is needed as a fallback because
a freshly-exec'd top-level shell with no recorded fork (`F`) record
inherits make's cwd, not the previous pid's `latestdir`. This is
exactly what happens with shell redirections like
`(cd subdir && cmd) > outfile` - the shell opens `outfile` in
make's cwd before chdir'ing into `subdir/`.

The bailiwick / tmpdir filters that gate absolute-path writes do not
apply: those exist to ignore writes outside the build's scope, but
a relative-path write recorded in our own `.meta` is by definition
inside our scope.

Patch: see `bmake_meta_relwrites.patch` in this directory.

## Testing the patch on a single target

### Fastest path: the bundled test script

`bmake_meta_relwrites_test.sh` in this directory does everything
below in one shot. Drop both files on the target host and run:

```sh
sh bmake_meta_relwrites_test.sh
```

It applies the patch (idempotent - skips if already applied), builds
a side-by-side `/usr/local/bin/make-patched`, deletes `builddir/`,
and runs four checks:

1. stock `/usr/bin/make` lies about the stale target ("up to date")
2. patched make detects the missing `builddir/` and queues the zic
   rebuild
3. patched make actually regenerates `Africa/Abidjan`
4. a second run is a no-op (no false-positive rebuild)

Exits non-zero on any failure. Does NOT touch `/usr/bin/make` -
promoting the fix system-wide is one command, printed at the end.

Requirements: `WITH_META_MODE=yes`, a populated `/usr/obj`, sudo.

### Manual steps

```sh
# 0. Save the patch alongside the source tree
sudo cp /path/to/bmake_meta_relwrites.patch /tmp/

# 1. Apply the patch
cd /usr/src
sudo git apply /tmp/bmake_meta_relwrites.patch
# or: sudo patch -p1 < /tmp/bmake_meta_relwrites.patch

# 2. Build the patched make into obj, install as a side-by-side
#    binary so you can A/B test without disturbing the system make
cd /usr/src/usr.bin/bmake
sudo make obj && sudo make all
sudo install -o root -g wheel -m 555 \
    /usr/obj/usr/src/$(uname -p)/usr.bin/bmake/make \
    /usr/local/bin/make-patched

# 3. Provoke the bug with the patched make
OBJ=/usr/obj/usr/src/$(uname -p)/share/zoneinfo
sudo rm -rf $OBJ/builddir
cd /usr/src/share/zoneinfo

# A. Stale detection - patched make MUST want to rebuild
sudo /usr/local/bin/make-patched -n zonefiles 2>&1 | grep -E 'zic |Africa' | head -2
# Expected: shows the `zic -D -d .../builddir ...` command line.
# Stock /usr/bin/make would say "`zonefiles' is up to date." here.

# B. Real rebuild - completes and recreates the output
sudo /usr/local/bin/make-patched zonefiles
ls $OBJ/builddir/Africa/Abidjan
# Expected: file present.

# C. Idempotency - a second run does NOT rebuild
sudo /usr/local/bin/make-patched -n zonefiles
# Expected: "`zonefiles' is up to date."

# D. Install path now works
sudo /usr/local/bin/make-patched install DESTDIR=/tmp/zi-test
ls /tmp/zi-test/usr/share/zoneinfo/Africa/Abidjan
sudo rm -rf /tmp/zi-test
```

If A is "up to date" instead of showing `zic`, the patch is not
having effect - check that `make-patched` is the binary you just
built (`sha256 /usr/local/bin/make-patched` vs the obj-tree binary).

## Promoting the patch system-wide

Once A-D pass, replace the installed make so installworld uses it
too:

```sh
cd /usr/src/usr.bin/bmake
sudo make install
# or, to also rebuild bootstrap-tools that ship a host bmake:
cd /usr/src && sudo make kernel-toolchain # or buildworld
```

A buildworld is the safest way to make sure every bootstrap copy of
bmake also picks up the fix, but for a one-shot installworld it is
enough to install the patched bmake to `/usr/bin/make` before
running `installworld`.

## Quick workaround if you can't apply the patch right now

You don't need the patch to unblock a single installworld - delete
the stale meta + manifest, rebuild only the zoneinfo subtree, then
resume:

```sh
ARCH=$(uname -p)
sudo rm -f /usr/obj/usr/src/$ARCH/share/zoneinfo/zonefiles \
           /usr/obj/usr/src/$ARCH/share/zoneinfo/zonefiles.meta
cd /usr/src/share/zoneinfo && sudo make obj && sudo make all
# Then re-run beinstall.sh / installworld.
```

This is the symptom fix, not the root-cause fix. The bug will come
back the next time `builddir/` is deleted out from under a stale
`zonefiles.meta`.

## Upstream

The relevant code lives in sjg/bmake (`contrib/bmake/meta.c` in the
FreeBSD tree, mirrored from sjg upstream). The flaw is present in
bmake 20260508 (and earlier). The fix should be sent upstream; in
the meantime FreeBSD can carry it as a local patch in
`contrib/bmake/`.

## References

- `contrib/bmake/meta.c` - `meta_oodate()` and the `W` / `M` / `D`
  record handlers
- `share/zoneinfo/Makefile` - the failing recipe
- `/etc/src-env.conf` - where `WITH_META_MODE=yes` is set
- The `.meta` file under `/usr/obj/.../share/zoneinfo/zonefiles.meta`
  - useful to inspect with `grep -E '^(C|W|M|D|F) '` to see the
  filemon trace and convince yourself which `W` records have
  relative paths.
