# The filter-zero guard in FreeBSD `kevent(2)`

*Why one line that looks like dead code is actually stopping an
out-of-bounds array read, and all the theory a first-year student needs
to see it.*

> **Status: teaching note.** This walks through a real exchange. A bounded
> model checker (CBMC) pointed at `kqueue_kevent()` flagged that a change
> with filter 0 is silently skipped, which kqueue.2 arguably should report
> as `EINVAL`. The VM/kernel maintainer markj@ replied that the skip
> "comes from commit 69cd28dacb8e7 ... it can probably be dropped." But
> reading the code shows dropping it is **not** safe as-is: the skip is
> what prevents an out-of-bounds access. The point of this note is to
> teach you enough that you can see that for yourself. Line numbers are
> from `main` around October 2026 and drift; re-`grep` if they do not line
> up.

---

## 0. What you will learn

From first principles:

1. what `kqueue`/`kevent` are, in one paragraph;
2. what a "filter" is and how FreeBSD numbers them;
3. how a negative filter number is turned into an array index with the
   bitwise-NOT operator `~`, and what two's-complement means here;
4. how an array bound check can be *almost* right and still let one bad
   value through;
5. why `if (!kevp->filter) continue;` is load-bearing, not dead code;
6. why "just delete the redundant-looking line" is the wrong fix, and
   what the right one-liner is;
7. the general lesson: a guard far from the code it protects looks
   removable until you trace what it protects.

You need to be comfortable reading a few lines of C and willing to do a
little arithmetic with negative numbers.

---

## 1. kqueue and kevent in one paragraph

`kqueue(2)` creates a kernel queue that a program uses to wait for
events: "tell me when this socket is readable", "when this timer fires",
"when this process exits". `kevent(2)` is the system call that both
*registers* what you care about (the **changelist**) and *collects*
events that have fired (the **eventlist**). Each item is a `struct
kevent`, and one of its fields, `filter`, says what *kind* of event this
is about.

```c
struct kevent {
	uintptr_t ident;   /* e.g. a file descriptor */
	short     filter;  /* EVFILT_READ, EVFILT_TIMER, ... */
	u_short   flags;   /* EV_ADD, EV_DELETE, EV_RECEIPT, ... */
	...
};
```

This note is about one thing: what happens when `filter` is **0**.

---

## 2. How FreeBSD numbers its filters

The filter kinds are defined in `sys/sys/event.h`, and they are all
**negative**:

```c
#define EVFILT_READ      (-1)
#define EVFILT_WRITE     (-2)
#define EVFILT_TIMER     (-7)
...
#define EVFILT_JAILDESC  (-15)
#define EVFILT_SYSCOUNT  15      /* how many there are */
```

So valid filters run from `-1` down to `-15`, and `EVFILT_SYSCOUNT` is
15, the count. `0` is **not** a valid filter — there is no
`EVFILT_something == 0`.

The kernel keeps a table of handlers for these filters:

```c
static struct {
	const struct filterops *for_fop;
	...
} sysfilt_ops[EVFILT_SYSCOUNT];        /* 15 entries: indices 0..14 */
```

Fifteen entries, indices 0 through 14. Now: the filters are -1..-15, but
the array indices are 0..14. How do you turn one into the other?

---

## 3. Turning a negative filter into an array index with `~`

The kernel uses the **bitwise NOT** operator, written `~`. For an
integer `x`, `~x` flips every bit. On a two's-complement machine (every
machine FreeBSD runs on), flipping all the bits of `x` gives exactly
`-x - 1`. So:

```
~(-1)  = 0
~(-2)  = 1
~(-7)  = 6
~(-15) = 14
```

That maps the valid filters -1..-15 neatly onto the array indices 0..14.
You can see it in the table initialiser itself:

```c
sysfilt_ops[~EVFILT_READ]  = { &file_filtops, 1 },   /* [~(-1)] = [0]  */
sysfilt_ops[~EVFILT_WRITE] = { &file_filtops, 1 },   /* [~(-2)] = [1]  */
```

Good. Now watch what `~` does to the one value that should not be here:

```
~0 = -1
```

Flipping all the bits of 0 gives all-ones, which in two's complement is
`-1`. So if filter `0` ever reaches `sysfilt_ops[~filt]`, it reads
`sysfilt_ops[-1]` — **one element before the start of the array.** That
is an out-of-bounds access: reading memory the array does not own.

Hold onto that: *filter 0 indexes `sysfilt_ops[-1]`.*

---

## 4. The bound check that is almost right

Before indexing the table, the kernel validates the filter in
`kqueue_fo_find()` (`sys/kern/kern_event.c`):

```c
static struct filterops *
kqueue_fo_find(int filt)
{
	if (filt > 0 || filt + EVFILT_SYSCOUNT < 0)
		return NULL;          /* reject: unknown filter */

	... sysfilt_ops[~filt] ...     /* otherwise index the table */
}
```

Read the guard. It returns `NULL` (meaning "no such filter", which the
caller turns into `EINVAL`) when:

- `filt > 0` — a positive filter number, which does not exist; or
- `filt + EVFILT_SYSCOUNT < 0` — i.e. `filt < -15`, more negative than
  the smallest real filter.

So it correctly rejects `1`, `2`, ... and `-16`, `-17`, .... Check the
boundaries:

- `filt = -15` (the last real filter): `-15 > 0`? no. `-15 + 15 = 0 < 0`?
  no. Passes → `sysfilt_ops[~(-15)] = [14]`. Correct, last valid slot.
- `filt = -1`: passes → `[0]`. Correct, first slot.
- `filt = 0`: `0 > 0`? **no.** `0 + 15 = 15 < 0`? **no.** So the guard
  lets 0 through → `sysfilt_ops[~0] = sysfilt_ops[-1]`. **Out of bounds.**

The bug in the bound is that it uses `filt > 0`, which allows 0, instead
of `filt >= 0`, which would reject it. The check is off by exactly one
value: zero.

So `kqueue_fo_find()` on its own is **not** safe against filter 0. If a
filter-0 change ever reached it, it would read `sysfilt_ops[-1]`.

---

## 5. The guard that actually saves it

Why has this never crashed? Because filter 0 never reaches
`kqueue_fo_find()`. One line upstream, in `kqueue_kevent()`
(`sys/kern/kern_event.c`), stops it:

```c
for (i = 0; i < n; i++) {
	kevp = &changes[i];
	if (!kevp->filter)          /* filter == 0: skip this change */
		continue;
	kevp->flags &= ~EV_SYSFLAGS;
	error = kqueue_register(kq, kevp, td, M_WAITOK);  /* -> fo_find */
	...
}
```

`if (!kevp->filter) continue;` means "if the filter is zero, skip this
change entirely." Because of it, a filter-0 change is silently ignored
and `kqueue_register()` — and therefore `kqueue_fo_find()` and the
`sysfilt_ops[-1]` access — is never reached for filter 0.

That is the whole mechanism. The line looks like a minor convenience
("don't bother with empty changes"), but it is the only thing standing
between a filter-0 change and an out-of-bounds array read.

---

## 6. Why "just drop the redundant line" is the wrong fix

The CBMC observation was: kqueue.2 lists `EINVAL` for "the specified ...
filter is invalid", yet filter 0 (which is invalid) produces no error —
it is silently skipped. Should it return `EINVAL` instead?

The maintainer's first instinct was that the skip "can probably be
dropped" — i.e. delete the `if (!kevp->filter) continue;` so filter 0
falls through to `kqueue_register()`, which rejects unknown filters with
`EINVAL`. That *reads* reasonable: let the normal rejection path handle
it.

But trace it. If you remove the skip, filter 0 flows into
`kqueue_register()` → `kqueue_fo_find(0)` → and, from section 4, that
passes the `filt > 0` guard and reads `sysfilt_ops[-1]`. You would have
turned a harmless silent no-op into an **out-of-bounds read**. The skip
is not redundant; it is compensating for the off-by-one in
`kqueue_fo_find()`'s bound.

So the correct change is two coordinated parts, not one deletion:

1. Fix the bound so `kqueue_fo_find()` itself rejects 0:
   ```c
   -	if (filt > 0 || filt + EVFILT_SYSCOUNT < 0)
   +	if (filt >= 0 || filt + EVFILT_SYSCOUNT < 0)
   		return NULL;
   ```
2. *Then* drop `if (!kevp->filter) continue;`, so filter 0 falls through
   to `kqueue_register()`, gets `fops == NULL`, and returns `EINVAL`
   safely.

Do only step 2 and you add a bug. Do step 1 first and the code is safe
either way.

### The compatibility caveat

Even done correctly, this is a **behaviour change**, and the maintainer
flagged it: "There's a small possibility that some userspace code is
relying on the current behaviour." Today a program that puts filter 0 in
its changelist gets silent success; afterwards it would get `EINVAL` (or,
with `EV_RECEIPT`/an eventlist, an `EV_ERROR` event with `EINVAL`). If
some program sends zero-filled `struct kevent` slots on purpose as "no
change here", it would start failing. That is why this is a judgement
call for the maintainer, not an obvious fix: the *safety* is clear, the
*compatibility* is not.

---

## 7. The general lesson

Three things worth taking away, all bigger than this one line:

- **A guard can live far from the thing it guards.** The `continue` is in
  `kqueue_kevent()`; the out-of-bounds access it prevents is two function
  calls away in `kqueue_fo_find()`. Deleting code because it "looks
  redundant where it is" misses what it protects elsewhere. Always trace
  what a check is standing in for before removing it.

- **Off-by-one lives at the boundary value.** `filt > 0` versus
  `filt >= 0` differ on exactly one input, 0 — the one value that is
  neither a valid filter nor caught by the lower bound. Boundary values
  (0, the max, the min, the empty case) are where these bugs hide, and
  where tests and model checkers earn their keep.

- **A model checker finds the input, not the fix.** CBMC correctly
  flagged "filter 0 is skipped without an error." It could not tell you
  that the skip is load-bearing, or that the naive fix introduces a worse
  bug. That judgement comes from reading the code and knowing the system.
  The tool narrows where to look; the engineer decides what it means.

---

## 8. Glossary

- **kqueue / kevent** — FreeBSD's event-notification queue and the system
  call that registers interest and collects events.
- **filter** — the kind of event (`EVFILT_READ`, `EVFILT_TIMER`, ...);
  encoded as a small negative number.
- **changelist / eventlist** — the array of changes you register, and the
  array into which fired events are written; both `struct kevent`.
- **`sysfilt_ops`** — the kernel's table of per-filter handler ops, 15
  entries indexed 0..14.
- **`~` (bitwise NOT)** — flips every bit; on two's-complement machines
  `~x == -x - 1`, which maps filters -1..-15 to indices 0..14, and maps
  the invalid 0 to -1.
- **two's complement** — the standard way signed integers are stored, in
  which `~x` equals `-x - 1`.
- **out-of-bounds access** — reading or writing memory outside an array's
  real extent; here `sysfilt_ops[-1]`.
- **`EINVAL`** — the "invalid argument" error code kevent should return
  for an invalid filter.
- **CBMC** — a bounded model checker that explores all inputs up to a
  size limit and checks assertions.
