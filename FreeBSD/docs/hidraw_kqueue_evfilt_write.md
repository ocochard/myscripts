# Adding `EVFILT_WRITE` support to FreeBSD `hidraw(4)`

*Why tokio-based Rust programs cannot open a HID device on FreeBSD, and
what the kernel fix looks like.*

> **Status: DRAFT — the diagnosis is measured, the patch is untested.**
> The problem statement in sections 1–3 is verified two ways: empirically
> against a real `/dev/hidraw*` node on FreeBSD 16.0-CURRENT, and by
> reading `sys/dev/hid/hidraw.c`. The proposed patch in section 5 has
> **not** been compiled or booted. Line numbers are from
> 16.0-CURRENT (`main-n289139-372b94623ca4`) and drift between
> checkouts — treat them as "look here", re-`grep` if they don't line up.

---

## 1. The symptom

A Rust program that registers a `/dev/hidraw*` descriptor with tokio the
idiomatic way — `tokio::io::unix::AsyncFd::new` — fails on FreeBSD, while
the equivalent `async-io` code works. This is what
[`async-hid`](https://github.com/sidit77/async-hid) hit with its `tokio`
feature:

```
Error: Other(Os { code: 22, kind: InvalidInput, message: "Invalid argument" })
```

`EINVAL`, on a node that `cat` can read fine as root.

The failure is not in the crate. It is `hidraw(4)` refusing a kqueue
registration. A workaround exists (section 2.2) and `async-hid` now uses
it, so this document is about removing a trap rather than unblocking a
dead end.

## 2. Root cause

`hidraw_kqfilter()` accepts exactly one filter
(`sys/dev/hid/hidraw.c:973-994`):

```c
	switch(kn->kn_filter) {
	case EVFILT_READ:
		if (sc->sc_fflags & FREAD) {
			kn->kn_fop = &hidraw_filterops_read;
			break;
		}
		/* FALLTHROUGH */
	default:
		return(EINVAL);
	}
```

There is one `filterops` struct in the file, and it is read-only
(`hidraw.c:181-186`):

```c
static const struct filterops hidraw_filterops_read = {
	.f_isfd =	1,
	.f_detach =	hidraw_kqdetach,
	.f_event =	hidraw_kqread,
	.f_copy =	knote_triv_copy,
};
```

So `EVFILT_WRITE` on a hidraw fd returns `EINVAL`. Confirmed directly
with a raw `kevent()` call against `/dev/hidraw2`:

```
EVFILT_READ on /dev/hidraw2: OK
EVFILT_WRITE on /dev/hidraw2: FAILED Os { code: 22, ... "Invalid argument" }
```

### 2.1 Why this breaks tokio specifically

tokio registers file descriptors through `mio`, whose kqueue selector
submits **both** filters in a single `kevent()` change list when
read+write interest is requested
(`mio-1.2.1/src/sys/unix/selector/kqueue.rs`, `register()`):

```rust
if interests.is_writable() {
    let kevent = kevent!(fd, libc::EVFILT_WRITE, flags, token.0);
    ...
}
if interests.is_readable() {
    let kevent = kevent!(fd, libc::EVFILT_READ, flags, token.0);
    ...
}
```

`tokio::io::unix::AsyncFd::new()` requests read+write, so the
`EVFILT_WRITE` half fails and the whole registration fails. `mio` only
special-cases `EPIPE` (a macOS pipe quirk); `EINVAL` propagates.

`async-io` is unaffected because it does not demand a write filter to
register a descriptor.

### 2.2 There *is* a userland workaround, but it is not free

tokio can register a descriptor with read interest only, which hidraw
accepts. Measured on ser6 against `/dev/hidraw0`:

```
AsyncFd::new (read+write):            FAILED Invalid argument (os error 22)
AsyncFd::with_interest(READABLE):     OK
with_interest(READABLE) on rw fd:     OK
```

So a consumer can use `AsyncFd::with_interest(fd, Interest::READABLE)`
and then perform writes directly rather than awaiting write readiness —
an `Interest::WRITABLE` wait on a hidraw fd never completes:

```
attempting WRITABLE interest wait...
WRITABLE wait: TIMED OUT (never becomes ready)
```

This is what `async-hid` now does on FreeBSD, and it is sound rather than
merely expedient, for the reason in section 3: hidraw writes cannot block.
With that in place, the tokio feature is fully functional on FreeBSD —
enumerate, `watch()`, reading input reports and writing output reports all
verified on hardware.

The cost is that every consumer must know this. The obvious, idiomatic
call (`AsyncFd::new`) fails with an opaque `EINVAL`, and the natural way
to write (`async_io(Interest::WRITABLE, ...)`) hangs forever instead of
erroring. Both failures point away from the real cause. Fixing the kernel
removes that trap for every future consumer, which is the argument for
section 5 even though userland can cope today.

## 3. Why this is a kernel gap, not a driver design choice

`hidraw_poll()` **already** answers write-readiness
(`hidraw.c:947-969`):

```c
	if (events & (POLLOUT | POLLWRNORM) && (sc->sc_fflags & FWRITE))
		revents |= events & (POLLOUT | POLLWRNORM);
```

Unconditionally ready when the fd was opened for writing. That is
correct, because `hidraw_write()` does not queue — it calls
`hid_write()` synchronously and returns its error
(`hidraw.c`, `hidraw_write`):

```c
	error = uiomove(buf + buf_offset, uio->uio_resid, uio);
	if (error == 0)
		error = hid_write(sc->sc_dev, buf, size);
```

There is no output queue to fill, so a hidraw fd opened `FWRITE` is
*always* writable. The semantics needed by `EVFILT_WRITE` therefore
already exist and are already expressed via `poll(2)`. Only the kqueue
path is missing them.

That asymmetry is the bug: `poll(2)` and `kevent(2)` disagree about the
same device.

## 4. The in-tree model to copy

`sys/dev/usb/usb_dev.c` is the closest analogue — same USB subsystem,
same character-device shape — and it implements both filters
(`usb_dev.c:1230-1290`):

```c
static const struct filterops usb_filtops_write = {
	.f_isfd = 1,
	.f_detach = usb_filter_detach,
	.f_event = usb_filter_write,
	.f_copy = knote_triv_copy,
};
```

with the dispatch shaped as:

```c
	switch (kn->kn_filter) {
	case EVFILT_WRITE:
		if (fflags & FWRITE) {
			f = refs.txfifo;
			kn->kn_fop = &usb_filtops_write;
			err = 0;
		}
		break;
	case EVFILT_READ:
		...
	default:
		err = EOPNOTSUPP;
		break;
	}
```

Two details worth carrying over:

1. Each filter is gated on the matching open mode (`FWRITE` / `FREAD`),
   so registering for write on a read-only fd still fails.
2. The `default` arm returns `EOPNOTSUPP`, not `EINVAL`. `EOPNOTSUPP` is
   the better answer for a filter the device does not implement at all
   (for example `EVFILT_VNODE`); `hidraw` currently returns `EINVAL` for
   everything. Changing the default is optional and is a separate
   behavioural change from adding the write filter — consider splitting
   it into its own commit.

Other in-tree examples, if a second opinion helps:
`sys/dev/sound/pcm/dsp.c`, `sys/dev/null/null.c`,
`sys/dev/netmap/netmap_freebsd.c`.

## 5. Proposed patch

Untested. Three pieces.

### 5.1 Declare the write filter

Next to the existing `hidraw_filterops_read` (`hidraw.c:181`):

```c
static int		hidraw_kqwrite(struct knote *, long);

static const struct filterops hidraw_filterops_write = {
	.f_isfd =	1,
	.f_detach =	hidraw_kqdetach,
	.f_event =	hidraw_kqwrite,
	.f_copy =	knote_triv_copy,
};
```

`hidraw_kqdetach` is reusable as-is: it calls
`knlist_remove(&sc->sc_rsel.si_note, kn, 0)`, and the write knote is
registered on that same knlist below.

### 5.2 The event handler

Mirrors what `hidraw_poll()` reports for `POLLOUT`, plus the
detach-while-open check that `hidraw_kqread()` performs:

```c
static int
hidraw_kqwrite(struct knote *kn, long hint)
{
	struct hidraw_softc *sc;

	sc = kn->kn_hook;

	mtx_assert(&sc->sc_mtx, MA_OWNED);

	if (sc->dev->si_drv1 == NULL) {
		kn->kn_flags |= EV_EOF;
		return (1);
	}

	/*
	 * hidraw_write() calls hid_write() synchronously; there is no
	 * output queue that can fill, so a writable fd is always ready.
	 */
	return (1);
}
```

### 5.3 Accept the filter

```c
	switch(kn->kn_filter) {
	case EVFILT_READ:
		if (sc->sc_fflags & FREAD) {
			kn->kn_fop = &hidraw_filterops_read;
			break;
		}
		return (EINVAL);
	case EVFILT_WRITE:
		if (sc->sc_fflags & FWRITE) {
			kn->kn_fop = &hidraw_filterops_write;
			break;
		}
		return (EINVAL);
	default:
		return (EINVAL);
	}
	kn->kn_hook = sc;

	knlist_add(&sc->sc_rsel.si_note, kn, 0);
	return (0);
```

Note the `/* FALLTHROUGH */` on the read arm has to go: with a second
case present, falling through from `EVFILT_READ` would land in
`EVFILT_WRITE` rather than `default`. Return `EINVAL` explicitly
instead. This is the easiest thing to get wrong in the whole patch.

### 5.4 Open questions for review

Answer these before sending the patch anywhere:

- **Is one knlist correct for both filters?** `sc_rsel.si_note` is woken
  by `hidraw_notify()` on *input* data. An always-ready write filter
  does not need wakeups (kqueue evaluates `f_event` at registration and
  on each `kevent()` scan), so sharing looks safe. Confirm against
  `kern/kern_event.c` rather than trusting this note. `usb_dev.c` uses
  *separate* selinfos per direction because its writes really can block.
- **`EV_CLEAR` interaction.** `mio` registers with
  `EV_CLEAR | EV_RECEIPT | EV_ADD`. An edge-triggered, always-ready
  filter reports once and then stays quiet until re-armed. Verify tokio
  does not stall waiting for a second write-readiness edge that never
  comes. This is the most likely way for the patch to "work" but hang.
- **`sc_state.sel`.** `hidraw_poll()` sets it before `selrecord()`;
  the read kqfilter path does not touch it. Check whether the write path
  should.

## 6. Verifying a fix

The raw filter check, which needs no Rust — should print OK for both
after the patch:

```c
/* cc -o kqchk kqchk.c ; ./kqchk /dev/hidraw0 */
#include <sys/types.h>
#include <sys/event.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>

int
main(int argc, char **argv)
{
	struct kevent ev;
	int fd, kq, i;
	const int filts[] = { EVFILT_READ, EVFILT_WRITE };
	const char *names[] = { "EVFILT_READ", "EVFILT_WRITE" };

	fd = open(argv[1], O_RDWR | O_NONBLOCK);
	if (fd < 0) {
		perror("open");
		return (1);
	}
	for (i = 0; i < 2; i++) {
		kq = kqueue();
		EV_SET(&ev, fd, filts[i], EV_ADD, 0, 0, NULL);
		if (kevent(kq, &ev, 1, NULL, 0, NULL) < 0)
			printf("%s: FAILED %s\n", names[i], strerror(errno));
		else
			printf("%s: OK\n", names[i]);
		close(kq);
	}
	return (0);
}
```

Then the real consumer. Build `async-hid` with the tokio feature and an
explicit runtime — note that the crate's bundled examples all use
`#[pollster::main]`, which has no tokio reactor and therefore cannot
exercise this path on any platform:

```rust
fn main() -> HidResult<()> {
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all().build().unwrap();
    rt.block_on(async {
        let backend = HidBackend::default();
        let mut dev = backend.enumerate().await?
            .find(|i| i.usage_page == 0x01 && i.usage_id == 0x02)
            .await.expect("no mouse")
            .open_readable().await?;      /* EINVAL before the fix */
        let mut buf = [0u8; 64];
        let n = dev.read_input_report(&mut buf).await?;
        println!("-> ({} bytes) {:02x?}", n, &buf[..n]);
        Ok(())
    })
}
```

Build it against the FreeBSD target and run on the test box:

```sh
cargo build --example tok_test --no-default-features --features tokio \
    --target x86_64-unknown-freebsd
```

Pass condition: no `EINVAL`, reports arrive, and — because of the
`EV_CLEAR` question in 5.4 — a *write* under tokio completes rather than
hanging. Test a write path too (an output report to a keyboard LED, for
example), not just reads.

## 7. Runtime prerequisites

Easy to lose an afternoon to these; none are build problems.

| Requirement | Check | Fix |
|---|---|---|
| `hidraw` module loaded | `kldstat \| grep hidraw` | `hidraw_load="YES"` in `/boot/loader.conf` |
| usbhid enabled | `sysctl hw.usb.usbhid.enable` | `hw.usb.usbhid.enable=1` |
| node permissions | `ls -l /dev/hidraw*` | `0600 root:operator` by default — add the user to `operator`, or a `devfs.rules(5)` entry |

Without the first two, `/dev/hidraw*` does not exist at all and
enumeration silently returns nothing. Without the third, enumeration
also returns nothing, because a device whose info cannot be read is
dropped from the stream rather than raising an error.

## 8. Scope note

Only `hidraw(4)` is analysed here. `u2f(4)`
(`sys/dev/hid/u2f.c`) has no kqueue write filter either and may have the
same gap; it was not tested. Other `sys/dev/hid/` drivers
(`hkbd`, `hms`, `hmt`, …) expose evdev or console interfaces rather than
a raw cdev and are out of scope.
