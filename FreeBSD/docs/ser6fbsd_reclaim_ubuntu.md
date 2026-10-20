# ser6fbsd: reclaim Ubuntu partition, grow FreeBSD ZFS

Executed 2026-07-03. Small NVMe (466G), triple-boot Windows / FreeBSD / Ubuntu.
FreeBSD ZFS pool (`nda0p6`, 29G) was 95% full. Ubuntu (`nda0p4`, 166G) was
unused. Reclaimed the Ubuntu space, ended with a single 195G FreeBSD ZFS
partition. Total elapsed migration time: under 15 minutes.

## Layout before

```
1  efi              100M
2  ms-reserved      128M
3  ms-basic-data    268G  (Windows)
4  linux-data       166G  (Ubuntu — DELETED)
6  freebsd-zfs       29G  (zroot — MIGRATED FROM)
5  ms-recovery      1.7G
```

Note: `p6` was not adjacent to freed `p4` space, so a plain `gpart resize -i 6`
could not grow it. Solution: create a new freebsd-zfs partition in `p4`'s slot,
mirror the pool onto it, detach the old vdev, then delete `p6` and grow the
new partition into the freed 29G.

## Bootloader

rEFInd on the ESP (`nda0p1`), configured at `/boot/efi/EFI/refind/refind.conf`.
FreeBSD entry loads `/EFI/FreeBSD/loader.efi` from the ESP. The FreeBSD EFI
loader finds the pool by name (`zroot`) and its `bootfs` property. Since we
kept the pool name and just swapped the underlying vdev via mirror/detach,
**no rEFInd or ESP changes were needed for the migration itself**.

The Ubuntu rEFInd menuentry, ESP directory (`/boot/efi/EFI/ubuntu/`), and
EFI boot var (`Boot0000* Ubuntu`) were cleaned up after.

## Approach: attach mirror, detach old

Preferred over `zfs send | recv` because:
- pool keeps the same name, no rename dance
- both halves are bootable during migration (rollback = pick "FreeBSD" in
  rEFInd, which will find whichever vdev is present)
- no snapshot orchestration; ZFS handles it via resilver
- current pool has `gpt/zroot` label — labels move with the partition; new
  partition gets a temporary label `zroot_new` to keep both distinguishable

Downside: current pool was 95% full, so resilver copied 18.0G (ZFS
compressed/deduped: 27.7G "USED" mapped to 18.0G resilvered — no problem,
finished in 2:39 on NVMe).

## Runbook

All commands run on ser6fbsd as root (`sudo -i` or prefix each with sudo).

### Phase 0 — snapshot

```sh
# Recursive snapshot as a local safety net
zfs snapshot -r zroot@pre-migrate-$(date +%Y%m%d)
zfs list -t snapshot | tail
```

**Off-box backup — decide before running.** The runbook originally suggested
`zfs send -R … | ssh bigone "zstd > file"`. On this run we **skipped** the
off-box backup by user choice. Rationale: the mirror-and-detach approach
keeps the source vdev intact and bootable through Phase 5, so real
data-loss exposure only begins at Phase 7 (`gpart delete -i 6`). If Phase 6
were `zfs send`-based instead, off-box backup would be non-optional.

**IMPORTANT if you do stream off-box:** killing an `ssh` pipeline locally
does NOT kill the remote side. If you abort a send mid-flight, verify with
`ps auxww | grep zfs` on the source and `ps auxww | grep zstd` (or whatever
consumer) on the destination — orphaned processes will keep pounding the
disk, which showed up as resilver throughput dropping from 379M/s to
20M/s during this migration. Kill remotely with `sudo pkill -f "zfs send"`.

### Phase 1 — verify Ubuntu is truly unused

```sh
# Confirm no FreeBSD process references nda0p4
fstat -f 2>&1 | grep -i nda0p4 || echo "no refs — good"

# Confirm the partition table matches expectations
gpart show nda0
# Expect p4 = linux-data 166G, p6 = freebsd-zfs 29G
```

**Optional check:** reboot into Windows once from rEFInd before touching
anything, just to confirm the ESP entry works. Return to FreeBSD. (Skipped
on this run — Windows lives on p3 which we never touch, so risk is low.)

### Phase 2 — delete p4, create new freebsd-zfs in its place

```sh
gpart delete -i 4 nda0
gpart show nda0                              # p4 should now be free space

# Create new freebsd-zfs partition in the freed slot
# -i 4 reuses the index; -t sets type; -l sets a temporary GPT label
gpart add -i 4 -t freebsd-zfs -l zroot_new -a 1M nda0
gpart show -l nda0

# New device visible via GPT label
ls -l /dev/gpt/zroot_new
```

### Phase 3 — attach as mirror, wait for resilver

```sh
# Attach the new partition as a mirror of the existing vdev
zpool attach zroot gpt/zroot gpt/zroot_new

zpool status zroot                           # should show mirror + resilvering

# Poll for completion — 18.0G resilvered in ~2:39 on this NVMe
while zpool status zroot | grep -q "resilver in progress"; do
  zpool status zroot | grep -E "scanned|resilvered|to go"
  sleep 15
done
zpool status zroot                           # both ONLINE, no errors
```

**CHECK**: `zpool status` shows two vdevs `ONLINE`, no `DEGRADED`,
`errors: No known data errors`. If not, STOP and investigate.

### Phase 4 — verify bootfs, reboot test on the mirror

```sh
# Confirm bootfs is already set (bsdinstall + bectl maintain this)
zpool get bootfs zroot
# Expected: zroot/ROOT/<current-BE>  SOURCE=local
# Only set explicitly if empty:
# zpool set bootfs=zroot/ROOT/<BE-name> zroot

# Sanity: root dataset should be canmount=noauto, mountpoint=/
zfs get canmount,mountpoint zroot/ROOT/<current-BE>

reboot
```

After reboot, log back in and confirm:

```sh
zpool status zroot                           # still mirror, both ONLINE
uname -a                                     # kernel matches BE
bectl list                                   # active BE unchanged
```

Note: on this run, BE "space" dropped from 27.9G to 17.6G after resilver.
This is ZFS accounting reconciling with the fresh vdev — same data. Not a
concern.

### Phase 5 — detach the old vdev (p6)

```sh
zpool detach zroot gpt/zroot
zpool status zroot                           # single vdev: gpt/zroot_new
```

At this point the pool lives entirely on nda0p4. `zpool detach` on a 2-way
mirror reverts the pool to a single-vdev pool automatically — no reconfig,
no export/import. `zpool list` will show `EXPANDSZ` = the size difference
between the current pool and the underlying partition (136G here, since
partition is already 166G but pool still thinks it's 29G). That expansion
happens in Phase 7.

p6 is still a freebsd-zfs partition with intact ZFS labels but no longer
part of any imported pool.

### Phase 6 — SKIPPED: relabel new partition to "zroot"

The runbook originally offered a Phase 6 to `gpart modify -i 4 -l zroot
nda0` for cosmetic tidiness. **Skipped on this run** — the pool works fine
with `gpt/zroot_new` as its device name, and renaming a GPT label under a
live pool adds risk right before the destructive Phase 7. The label spelling
does not affect boot or functionality; only pool name (`zroot`) matters.

If you want to rename later, `gpart modify -i 4 -l zroot nda0` should Just
Work once the pool has been operating stably.

### Phase 7 — destroy old p6, grow p4, expand pool

**Point of no return.** After this, the old vdev is gone.

```sh
# Wipe ZFS labels on old partition first (prevents any future zpool import
# from ever picking up the ghost)
zpool labelclear -f /dev/nda0p6

# Delete old freebsd-zfs partition
gpart delete -i 6 nda0
gpart show nda0                              # p6 gone; 29G free after p4

# Grow p4 into the freed space (up to just before p5, ms-recovery)
gpart resize -i 4 nda0
gpart show -l nda0                           # p4 should now be ~195G

# Tell ZFS the underlying vdev grew
zpool online -e zroot gpt/zroot_new
zpool list zroot                             # SIZE should now be ~195G
df -h /
```

Result on this run:
- Pool: 29G → 195G
- Root FS avail: 403M → 172G

### Phase 8 — clean up Ubuntu remnants

```sh
# Back up refind.conf, then rewrite without the Ubuntu menuentry
cp /boot/efi/EFI/refind/refind.conf /boot/efi/EFI/refind/refind.conf.bak
# Edit refind.conf to drop the Ubuntu menuentry block

# Remove the Ubuntu EFI boot variable
efibootmgr -B -b 0000

# Scrub the Ubuntu directory from the ESP
rm -rf /boot/efi/EFI/ubuntu

# Verify
efibootmgr -v | grep -i ubuntu               # empty
cat /boot/efi/EFI/refind/refind.conf         # no Ubuntu entry
```

Then destroy the pre-migrate snapshot if the system is proven working:

```sh
zfs destroy -r zroot@pre-migrate-$(date +%Y%m%d)
```

### Phase 9 — zpool upgrade + update ESP loader.efi

Only if `zpool status` reports "Some supported and requested features are
not enabled on the pool" and you actually want the new features.

**Critical:** after `zpool upgrade`, the on-disk format may use features
the ESP `loader.efi` doesn't understand. The `zpool upgrade` output warns:
`Pool 'zroot' has the bootfs property set, you might need to update the
boot code. See gptzfsboot(8) and loader.efi(8) for details.`

On this run, the ESP loader (`/boot/efi/EFI/FreeBSD/loader.efi`, dated
January) was 5 months older than the running kernel's loader
(`/boot/loader.efi`, dated with the kernel). Features enabled by the
upgrade included `fast_dedup`, `physical_rewrite`, `large_microzap`,
`longname`, `block_cloning_endian`, `draid_failure_domains`,
`raidz_expansion`, `redaction_list_spill` — some recent enough that the
old ESP loader might not parse them, risking a non-boot situation.

Update the ESP loader to match the running system BEFORE the next reboot:

```sh
# Verify they differ
cmp /boot/efi/EFI/FreeBSD/loader.efi /boot/loader.efi

# Backup old ESP loader, install current one
cp /boot/efi/EFI/FreeBSD/loader.efi /boot/efi/EFI/FreeBSD/loader.efi.bak
cp /boot/loader.efi /boot/efi/EFI/FreeBSD/loader.efi
cmp /boot/efi/EFI/FreeBSD/loader.efi /boot/loader.efi && echo "match"
```

Then perform the upgrade:

```sh
zpool upgrade zroot
zpool status zroot                           # warning gone
```

**Reboot to verify the new loader boots the upgraded pool.** If it fails,
recover with a FreeBSD USB stick: mount ESP, restore `loader.efi.bak`.

Note: `bsdinstall` and system upgrades don't automatically copy the freshly
built `loader.efi` onto the ESP — the ESP copy is only updated when you do
it manually, or via a full re-install. So drift between `/boot/loader.efi`
and `/boot/efi/EFI/FreeBSD/loader.efi` is normal on long-running systems.
Worth checking before every `zpool upgrade`.

## Rollback

- Between Phase 3 (attach) and Phase 5 (detach): rollback is trivial — the
  old vdev is still fully populated. Reboot into rEFInd; FreeBSD loader
  will find whichever vdev is available.
- After Phase 5 (detach), before Phase 7: the old p6 has stale but intact
  ZFS labels. Could be re-imported with `zpool import -f zroot`, but that
  would clobber the new pool. Do NOT try to re-import p6 unless the new
  pool is destroyed.
- After Phase 7 (`gpart delete -i 6`): no rollback except from off-box
  backup — which on this run was intentionally not made. In practice: no
  rollback.
- After Phase 9 (`zpool upgrade`): pool is on the new feature set. Cannot
  be imported by older FreeBSD versions. Not reversible.

## Final layout

```
1  efi              100M
2  ms-reserved      128M
3  ms-basic-data    268G  (Windows)
4  freebsd-zfs      195G  (zroot — label: zroot_new)
5  ms-recovery      1.7G
```

## Lessons learned

- **`TaskStop` / killing an ssh pipeline is not a real kill.** SIGTERM to
  the local ssh client does not propagate to the remote side of an
  interactive pipe. Always verify with `ps` on both source and destination
  when aborting a `zfs send | ssh …` job, and `pkill` explicitly.
- **`rm` on a file being written to is only a partial cleanup.** The
  process keeps writing to the deleted inode; space is only freed when
  the writer closes the fd (or is killed).
- **Disk contention from a background `zfs send` will slow a live
  resilver massively** — visible as resilver throughput dropping by an
  order of magnitude.
- **`bootfs` is maintained by `bectl`** on BE-aware systems; the runbook's
  "set bootfs if empty" step almost always turns out to be unnecessary.
- **`zpool detach` on a 2-way mirror silently converts to single-vdev.**
  No export/import. Just works.
- **`EXPANDSZ` in `zpool list`** shows the underlying vdev has grown but
  ZFS hasn't picked it up yet; `zpool online -e` claims it.
- **ESP `loader.efi` drifts** from the running system's `/boot/loader.efi`
  over time. `zpool upgrade` is the classic scenario where this bites you
  — check with `cmp` before rebooting.
- **rEFInd is dead simple**: `refind.conf` is human-readable, menuentries
  are self-contained, changes take effect on next boot. Delete the entry,
  delete the ESP dir, `efibootmgr -B` the boot var. Done.
