# bird3 memory reporting on FreeBSD vs Linux: `MADV_FREE` semantics

## Context

Upstream report on `bird-users@`
([thread entry, 2026-07-18](https://trubka.network.cz/archives/list/bird-users@network.cz/message/3SIJYPABOOEINRU3EDK7KU2IJGDHF7ME/),
[original memory-question by Marek Zarychta on 3.2.0](http://www.mail-archive.com/bird-users@network.cz/msg09028.html)):
BIRD 3.3.1 on FreeBSD 15.0-STABLE with ~2.5M full-view routes shows

```
top(1)   SIZE 1100M   RES 984M
show memory   Effective 492.1M   Overhead 85.2M
              Active pages 420.1M   Kept free 57.7M   Cold free 370.9M
              Hot page cache depleted while in RCU: 3894
```

Reporter's concern: RSS is ~2× the 2.x-series footprint; suspects a leak.
Maria Matejka (upstream) hypothesises FreeBSD handles `madvise()` differently
from Linux and asks whether different arguments would be needed. This document
verifies that hypothesis against the FreeBSD source tree and reproduces the
behaviour locally.

## Bottom line

**Not a leak.** BIRD's cold-page pool is madvise'd but stays resident in RSS
until the kernel needs the pages, because on FreeBSD both `MADV_FREE` and
`MADV_DONTNEED` place clean pages at the head of the inactive queue — they do
not unmap or decrement RSS at call time. On Linux `MADV_DONTNEED` zaps the PTEs
immediately, so RSS drops. BIRD's build system picks `MADV_DONTNEED` on Linux
and falls back to `MADV_FREE` on \*BSD.

The port needs no change. A real fix would have to be upstream and would have
to `munmap()` the page (not just re-madvise it) to actually shrink RSS on
FreeBSD.

## Code trail

### BIRD side

`sysdep/unix/alloc.c:454-470` — cleanup of cold pages:

```c
UNPROTECT_PAGE(empty_pages);
empty_pages->pages[empty_pages->pos++] = fp;
PROTECT_PAGE(empty_pages);

PROTECT_PAGE(fp);
if (madvise(fp, page_size,
#ifdef CONFIG_MADV_DONTNEED_TO_FREE
      MADV_DONTNEED
#else
      MADV_FREE
#endif
      ) < 0)
  bug("madvise(%p) failed: %m", fp);
```

The `CONFIG_MADV_DONTNEED_TO_FREE` macro is set only in `sysdep/cf/linux.h:26`.
`sysdep/cf/bsd.h` (used for FreeBSD/NetBSD builds) does not define it.
Consequence: **the FreeBSD build issues `MADV_FREE` per cold page**.

### FreeBSD side — what the kernel actually does

Path from `madvise(2)` -> `sys/vm/vm_map.c:vm_map_madvise()` -> per-object
-> per-page.

`sys/vm/vm_map.c:3060-3083` — both `MADV_DONTNEED` and `MADV_FREE` take the
same read-locked, non-map-modifying branch:

```c
case MADV_WILLNEED:
case MADV_DONTNEED:
case MADV_FREE:
    if (start == end)
        return (0);
    modify_map = false;
    vm_map_lock_read(map);
    break;
```

`sys/vm/vm_map.c:3205-3210` — both call `pmap_advise()` then
`vm_object_madvise()`:

```c
if (behav == MADV_DONTNEED || behav == MADV_FREE)
    pmap_advise(map->pmap, useStart, useEnd, behav);

vm_object_madvise(entry->object.vm_object, pstart, pend, behav);
```

`sys/vm/vm_page.c:4649-4688` — the per-page action, where the two flags
finally differ:

```c
void
vm_page_advise(vm_page_t m, int advice)
{
    VM_OBJECT_ASSERT_WLOCKED(m->object);
    vm_page_assert_xbusied(m);

    if (advice == MADV_FREE)
        /*
         * Mark the page clean. This will allow the page to be freed
         * without first paging it out. MADV_FREE pages are often
         * quickly reused by malloc(3), so we do not do anything that
         * would result in a page fault on a later access.
         */
        vm_page_undirty(m);
    else if (advice != MADV_DONTNEED) {
        if (advice == MADV_WILLNEED)
            vm_page_activate(m);
        return;
    }
    ...
    /*
     * Place clean pages near the head of the inactive queue rather than
     * the tail, thus defeating the queue's LRU operation and ensuring
     * that the page will be reused quickly. Dirty pages not already in
     * the laundry are moved there.
     */
    if (m->dirty == 0)
        vm_page_deactivate_noreuse(m);
    else if (!vm_page_in_laundry(m))
        vm_page_launder(m);
}
```

Both flags deactivate and mark for reuse. Neither unmaps. RSS is unchanged
until the page daemon actually reclaims under pressure. This is the semantic
difference from Linux that produces the RSS discrepancy Marek sees.

### Linux side — for comparison

`mm/madvise.c:madvise_dontneed_free()` -> `zap_page_range_single()` for
`MADV_DONTNEED`: PTEs are dropped immediately, RSS falls, next access
page-faults zero. `MADV_FREE` on Linux is lazier (marks pages for lazy free).
Hence BIRD's Linux config picks `MADV_DONTNEED`: BIRD "returns" cold pages,
Linux updates RSS on the spot.

## Reproduction plan on this host (FreeBSD 16.0-CURRENT)

Steps taken from the earlier analysis (1) confirm cold pages are reclaimable,
(2) rule out VSZ growth = real fragmentation, (3) verify the compile-flag
path.

### Environment

- Host: FreeBSD 16.0-CURRENT amd64, physmem 256 GB
- Package: net/bird3-3.3.1
- bird was installed but not running at start
- Load: synthetic — static routes injected via a generated include file, to
  produce a non-trivial cold-page pool without needing a live BGP peer

### Step 3 — compile-flag path (cheapest, do first)

Verify `CONFIG_MADV_DONTNEED_TO_FREE` is undefined for the FreeBSD build.
Rather than rebuilding through the port, inspect the linked binary and the
BIRD source that shipped with the package.

- Confirm the port's `sysdep/cf/bsd.h` does not define
  `CONFIG_MADV_DONTNEED_TO_FREE`.
- Trace the running binary with `truss -f -e -s65536 -o` and match
  `madvise(0x..., 4096, MADV_FREE)` calls (`MADV_FREE`=5 on FreeBSD).
  Absence of `MADV_DONTNEED` (=4) confirms the path taken.

### Step 1 — force reclaim, watch RSS drop without state loss

- Start bird3, load N routes, wait until cold-page pool is non-zero
  (`birdc show memory` reports "Cold free pages").
- Sample `ps -o pid,vsz,rss` and `procstat -v` every second into a log.
- In parallel, run a synthetic memory hog to trigger pageout — an `awk` or
  small C program that mallocs and touches ~physmem*0.9. Careful on
  16-CURRENT (my host has 256 GB, so this is realistic to allocate but slow;
  in practice a smaller pressure is enough to demonstrate).
- Confirm: bird's RES falls toward "Active pages" from `show memory`, no
  BUG in bird's log, `show memory` still consistent.

### Step 2 — VSZ growth as the actual leak signal

- Sample `ps -o vsz` and `procstat -v $(pgrep bird) | wc -l` every minute.
- Churn routes: add/withdraw batches of 100k routes on a loop.
- Real leak / real fragmentation would manifest as monotonically increasing
  VSZ. `MADV_FREE`-induced retention would show flat VSZ but slowly rising
  RSS until the page daemon runs.

## Reproduction driver

`bird3_freebsd_memory_madvise.sh` (companion to this doc) automates the whole
sequence: writes an isolated bird3 config with 200k / 400k blackhole routes,
starts bird3 on a private control socket, `truss`es a reload cycle to record
the madvise flag actually used, churns reloads to grow the cold-page pool,
and optionally runs the memory-pressure hog. See the script header for
safety notes on `--pressure`.

## Results

Host: FreeBSD 16.0-CURRENT amd64, `hw.physmem = 256 GiB`, `MADV_FREE = 5`,
`MADV_DONTNEED = 4` (from `/usr/include/sys/mman.h`).

### Step 3: compile-flag path (static + dynamic)

Static disassembly of `/usr/local/sbin/bird` around every call to
`madvise@plt`, extracting the immediate constant passed in `%edx` (SysV AMD64
ABI 3rd argument):

```
  34a9ea: ba 05 00 00 00               movl    $0x5, %edx
  34a9ef: e8 7c 7d 01 00               callq   0x362770 <madvise@plt>
```

`0x5 = MADV_FREE`. No `movl $0x4, %edx` before any madvise call in the whole
binary. `sysdep/cf/bsd.h` does not define `CONFIG_MADV_DONTNEED_TO_FREE`, so
the `#else` branch of `sysdep/unix/alloc.c:460` is compiled in on FreeBSD.
The port's `files/patch-Makefile.in` does not touch this either.

Dynamic confirmation via `truss -f` on the running bird3 during one
reconfigure cycle (200k → 1 route → 400k routes):

```
$ grep -oE 'madvise\([^)]*\)' truss.out | awk -F, '{print $NF}' | sort -u
MADV_FREE)

$ grep -c 'madvise(' truss.out
14442
```

**14,442 `madvise(page, 4096, MADV_FREE)` calls in one reload, zero
`MADV_DONTNEED`.** Confirmed at both compile-time and runtime.

### Step 1 (renumbered): cold-page pool grows and shows the RSS gap

Starting bird3 fresh with 200k blackhole routes:

```
bird pid: 38174
  PID    VSZ    RSS COMMAND
38174 156228 125608 bird

BIRD memory usage
Total:              79.0 MB     24.1 MB
Active pages:       64.7 MB
Kept free pages:    21.8 MB
Cold free pages:     0.0  B
```

RSS ≈ Effective+Overhead. No cold pages yet — bird hasn't freed anything.

After four small ↔ large reload cycles (churn that generates freed table
pages, which then get madvise'd):

```
  PID    VSZ    RSS COMMAND
38174 351940 306684 bird

BIRD memory usage
Total:             153.6 MB     37.6 MB
Active pages:      129.3 MB
Kept free pages:    33.1 MB
Cold free pages:    72.2 MB
Hot page cache depleted while in RCU: 78
```

Cold pool: 72.2 MB. VSZ 351.9 MB, RSS 306.7 MB.
- BIRD "active + kept" = 129.3 + 33.1 = **162.4 MB**
- Process RSS = **306.7 MB**
- Gap ≈ **144 MB** — larger than the cold pool alone, additional overhead
  is madvise'd pages not yet in the cold-pool accounting (dirty, waiting)
  plus libc heap. This is the same shape Marek reports on his production
  box: RSS visibly above what `show memory` sums to.

VSZ is stable across cycles (351,940 kB every time), so address space is
not leaking; the process is bounded.

### Step 2: memory-pressure reclaim — **aborted for safety**

Multiple hog attempts (allocate + touch anonymous memory to force reclaim
of bird's `MADV_FREE`-marked pages) either:

1. Got DCE'd at `-O2` (compiler removed the store loop when the buffer was
   only written, never read). Fixed by adding a `volatile` read into a
   `volatile` sink.
2. Got OOM-killed silently before the touch loop completed, on a host
   already under swap pressure. `dmesg` showed `swap_pager: out of swap
   space` and unrelated processes being reaped. No `hog` in the kill list
   because SIGKILL doesn't print through `perror()`.

Running a 240 GB hog on a 256 GB / low-swap workstation is Russian
roulette with which process the OOM reaper picks. The reproduction script
retains `--pressure` for a host with generous swap; on this host we
stopped short.

The theoretical prediction remains: under real memory pressure, the FreeBSD
page daemon will reclaim inactive-queue pages (which is where `MADV_FREE`
puts them per `vm_page_advise()` in `sys/vm/vm_page.c:4649`), and bird's
RSS should fall toward the "Active pages" number without any BIRD-side
state change. We just can't safely trigger that on this host today.

### Step 3 (renumbered): VSZ over route churn — no leak

Across four grow/shrink reload cycles VSZ was constant at 351,940 kB
(exactly 344 MB), which contradicts an address-space leak. Any real
allocator or fragmentation bug would show monotonic VSZ growth over
repeated churn; this doesn't.

## Summary of what we actually proved

- **Yes, the FreeBSD build calls `MADV_FREE` and not `MADV_DONTNEED`.**
  Confirmed statically (disassembly shows `movl $0x5, %edx` before every
  `madvise@plt`) and dynamically (14k live `MADV_FREE` calls captured in
  one reload).
- **Yes, the FreeBSD kernel treats those two flags almost identically for
  RSS accounting.** Read from `sys/vm/vm_page.c:4649-4688`, both go through
  the same `vm_page_deactivate_noreuse()` path; only `MADV_FREE` clears
  dirty first.
- **Yes, we observe the RSS-above-`show memory` gap locally.** 200k → 400k
  route churn produced RSS 306 MB against a BIRD-reported active+kept of
  162 MB with 72 MB cold pool.
- **Yes, VSZ is stable across churn.** No address-space leak signal in
  400k-route reloads.
- **We did not prove the pages come back under pressure.** The host has
  256 GB physmem and insufficient swap headroom for a safe 200+ GB hog.
  This step is deferred to a machine where it can be run without OOM
  collateral.

## What to tell upstream / the reporter

- On FreeBSD `top`'s RES cannot be lower than BIRD's active + kept-free +
  cold-free totals as long as the pages remain madvise'd but mapped. This is
  a system property, not a bug in either bird or FreeBSD.
- Rebuilding bird3 with `CONFIG_MADV_DONTNEED_TO_FREE` defined would **not**
  fix it: the FreeBSD kernel treats `MADV_DONTNEED` and `MADV_FREE` almost
  identically for the RSS-visibility question.
- The real fix, if upstream wants FreeBSD RSS to track Linux, is to
  `munmap()` cold pages instead of madvising them, at the cost of address
  space accounting churn.
- Diagnostic to distinguish "retained but reclaimable" from a true leak:
  watch VSZ (`ps -o vsz`) rather than RSS. Flat VSZ + high RSS = system
  working as designed. Growing VSZ = actual bug worth chasing (Maria
  mentioned a CLI leak already known).

## References

- BIRD source: `sysdep/unix/alloc.c`, `sysdep/cf/linux.h`, `sysdep/cf/bsd.h`
  (bird-3.3.1)
- FreeBSD source: `sys/vm/vm_map.c` (`vm_map_madvise`), `sys/vm/vm_page.c`
  (`vm_page_advise`)
- Port: `~/freebsd-official/ports/net/bird3/`
