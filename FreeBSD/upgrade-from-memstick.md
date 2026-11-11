# Upgrade an installed system from a memstick, into a new boot environment

This method boots a newer memstick in live mode and upgrades the FreeBSD installed on the internal disk.
It uses only the distribution sets on the memstick (`/usr/freebsd-dist/*.txz`).
No source tree, no network and no `pkg` are needed.

It does what `tools/build/beinstall.sh` does, adapted to tarballs:

| beinstall.sh | memstick method |
|---|---|
| `bectl create` (clones the running BE) | `bectl -r POOL/ROOT create -e default` (the running system is the memstick) |
| `make installkernel installworld DESTDIR=` | `tar -xpf kernel.txz base.txz ...` into the mounted BE |
| `etcupdate -p` then `etcupdate -s /usr/src -BF` | `etcupdate -F -t` with the stock tree shipped inside `base.txz` |
| `bectl activate` | `bectl activate -t` (one trial boot, falls back to the old BE) |
| `pkg upgrade` in a chroot | not done: run it after the first boot |

Tested 2026-11-11 on a laptop: 16.0-CURRENT n283376 (2026-02) upgraded to n290939 (2026-11) from a memstick built on the same builder.

## Prerequisites

- The installed system is root-on-ZFS with a `POOL/ROOT/<be>` layout.
- `/usr` and `/var` are `canmount=off`, so `/usr/bin`, `/usr/lib*` and `/var/db/etcupdate` live inside the BE. Check with `zfs list -o name,canmount -r POOL`.
- The installed system was installed from distribution sets, not pkgbase (`pkg -r /mnt info` lists no `FreeBSD-*` packages).
- `/var/db/etcupdate/current` exists on the installed system. Without it, etcupdate has no old tree and cannot do a 3-way merge.

On the memstick, `/tmp` is a 20 MB tmpfs: stage everything inside the new BE, never in `/tmp`.

## Procedure

Run every step as root on the live memstick system.
The example uses pool `zbook`, old BE `default` and new BE `n290939`.

### 1. Import the pool and create the new BE

```sh
zpool import -f -N -R /mnt zbook
bectl -r zbook/ROOT create -e default n290939
mkdir -p /tmp/be
bectl -r zbook/ROOT mount n290939 /tmp/be
BE=/tmp/be
D=/usr/freebsd-dist
```

`-N` imports without mounting anything.
`bectl mount` uses the given path as is, without the `/mnt` altroot prefix: check with `mount | grep zbook`.

### 2. Install the kernel

```sh
mv $BE/boot/kernel $BE/boot/kernel.old
tar -xpf $D/kernel.txz -C $BE
```

### 3. Install the userland

The `schg` flag on files such as `libc.so.7` and `init` makes tar fail.
Clear it first; `tar -p` sets it again from the archive.

```sh
chflags -R noschg $BE/bin $BE/sbin $BE/lib $BE/libexec \
    $BE/usr/bin $BE/usr/sbin $BE/usr/lib $BE/usr/libexec $BE/usr/lib32
for s in base lib32 tests; do
    tar -xpf $D/$s.txz -C $BE --exclude ./etc --exclude ./var --exclude ./root
done
```

Extract only the sets that are already installed (`ls -d $BE/usr/lib32 $BE/usr/tests`).
The excludes keep your configuration: etcupdate updates it in step 4.
`/boot/loader.conf` and `/boot/loader.conf.local` are not in `base.txz` and stay as they are.
`/boot/device.hints` is in `base.txz`: if you edited it, add `--exclude ./boot/device.hints`.

### 4. Merge /etc with etcupdate

`etcupdate -t` extracts its tarball into the "new" tree and compares it with `/var/db/etcupdate/current` (the old stock tree) and the live files.
`base.txz` ships the new stock tree at `./var/db/etcupdate/current`, so feed etcupdate that tree:

```sh
mkdir $BE/var/db/upg-new
tar -xpf $D/base.txz -C $BE/var/db/upg-new ./var/db/etcupdate/current
tar -cf $BE/var/db/upg-new.tar -C $BE/var/db/upg-new/var/db/etcupdate/current .
etcupdate -F -D $BE -t $BE/var/db/upg-new.tar
etcupdate status -D $BE
```

`-F` ignores files that differ only by their `$FreeBSD$` line, as `beinstall.sh` does.

If `status` lists conflicts (`C`), find out whether you edited the file.
Diff the old stock copy against the file in the old BE:

```sh
mkdir -p /tmp/def
mount -t zfs -o ro zbook/ROOT/default /tmp/def
diff -u $BE/var/db/etcupdate/old/etc/rc.subr /tmp/def/etc/rc.subr
```

- The diff shows only upstream changes: take the new stock file (`tf`, theirs-full).
- The diff shows your edits: merge by hand (`e`) or keep yours (`mf`).

```sh
etcupdate resolve -D $BE
```

`resolve` reads one answer per conflict, so `printf 'tf\n%.0s' 1 2 3 4 5 6 | etcupdate resolve -D $BE` takes the stock file for 6 conflicts.

Remove the staging files.
`var/empty` is `schg` and blocks a plain `rm -rf`:

```sh
chflags -R noschg $BE/var/db/upg-new
rm -rf $BE/var/db/upg-new $BE/var/db/upg-new.tar
umount /tmp/def
```

Quick checks:

```sh
chroot $BE /bin/freebsd-version -u
chroot $BE /usr/bin/ldd /bin/sh
ls -lo $BE/lib/libc.so.7        # flags must show schg again
```

### 5. Update the loader on the ESP

The loader on the ESP is shared by all BEs: it is the only part of the upgrade that the old BE does not isolate.
Keep a copy of the old loader.

```sh
mkdir -p /tmp/esp
mount -t msdosfs /dev/nda0p1 /tmp/esp
cp /tmp/esp/EFI/FreeBSD/loader.efi /tmp/esp/EFI/FreeBSD/loader.efi.old
cp $BE/boot/loader.efi /tmp/esp/EFI/FreeBSD/loader.efi
md5 $BE/boot/loader.efi /tmp/esp/EFI/FreeBSD/loader.efi
umount /tmp/esp
```

On a disk shared with Windows or Linux, check the ESP path first (`find /tmp/esp/EFI -maxdepth 2`).

### 6. Activate for one boot, then export

```sh
bectl -r zbook/ROOT umount n290939
bectl -r zbook/ROOT activate -t n290939
bectl -r zbook/ROOT list          # new BE shows "T"
zpool export zbook
```

`activate -t` writes a one-time `nextboot` entry (`zfsbootcfg -z zbook` shows it) and leaves `bootfs` on the old BE.
If the new BE fails to boot, the next reboot goes back to `default`.

Remove the memstick and reboot.

## After the first boot

When the new BE works, make it permanent:

```sh
bectl activate n290939
```

Then upgrade the packages (`pkg upgrade`) and the ports kernel modules (drm-kmod and similar): `beinstall.sh` does this in a chroot, this method does not.

## Rollback

- New BE does not boot: reboot, the trial activation falls back to `default`. Or select the BE in the loader menu.
- New loader does not start: boot the memstick, mount the ESP and copy `loader.efi.old` back to `loader.efi`.
- Remove the failed BE: `bectl destroy -F n290939`.

## Limits

- Files removed from base between the two versions stay in the new BE.
  `make delete-old delete-old-libs` needs a source tree; run it later with `DESTDIR` from a matching `/usr/src`.
- Do not run `zpool upgrade` after the first boot until you no longer need the old BE: an older kernel may not import the upgraded pool.
- The method needs `/var/db/etcupdate/current`. If the previous upgrade did not refresh it, etcupdate reports conflicts on stock files you never edited (`rc.subr`, `mtree/*.dist`, `pkg/FreeBSD.conf`). Diff them as shown in step 4 before you answer.
