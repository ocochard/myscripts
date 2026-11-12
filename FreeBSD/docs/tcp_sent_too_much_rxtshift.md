# `tcp_do_segment: sent too much`: a TCP assertion that was wrong after a timeout

*How a kernel dump showed that TCP sent two segments where an assertion
allowed only one, why the sending was correct and the assertion was
not, and all the TCP a first-year student needs to follow the
arithmetic.*

*Author: Claude (Anthropic Claude Opus 5.5)*

> **Status: DRAFT, NOT PEER-REVIEWED.** Written by the agent while
> debugging the crash, reviewed only by Olivier Cochard. The dump
> values, the packetdrill reproducer, the patch and the A/B runs in a
> bhyve guest are real and can be checked again. The explanations
> (the TCP background, the reading of the code) are *plausible* but
> not *validated by the FreeBSD transport maintainers*. Line numbers
> are from `main` of 2026-11-11; they drift, so `grep` for the code
> if they do not match.

- **Platform:** FreeBSD 16.0-CURRENT, default TCP stack (`freebsd`),
  NewReno congestion control.
- **Symptom:** `panic: tcp_do_segment: sent too much: 2720>1360` on a
  server with a debug kernel (`options INVARIANTS`).
- **Bug class:** a sanity check (`KASSERT`) built on a premise that
  is false in one case. Kernels without `INVARIANTS` do not check it
  and behave correctly.
- **Upstream history:** FreeBSD PR 282605, open since 2024; three fixes
  went in, this case is not covered by any of them.
- **Files:** patch [`tcp_sent_too_much_rxtshift.patch`](tcp_sent_too_much_rxtshift.patch),
  reproducer [`tcp_sent_too_much_rxtshift.pkt`](tcp_sent_too_much_rxtshift.pkt).

---

## Table of contents

0. [What you will learn](#0-what-you-will-learn)
1. [The crash](#1-the-crash)
2. [Background: the TCP you need](#2-background-the-tcp-you-need)
3. [The code that panicked](#3-the-code-that-panicked)
4. [Reading the dump in kgdb](#4-reading-the-dump-in-kgdb)
5. [Rebuilding the 2720 bytes](#5-rebuilding-the-2720-bytes)
6. [Why the assertion is wrong, not the sending](#6-why-the-assertion-is-wrong-not-the-sending)
7. [The patch](#7-the-patch)
8. [The packetdrill reproducer](#8-the-packetdrill-reproducer)
9. [Validating the patch](#9-validating-the-patch)
10. [What PR 282605 already fixed](#10-what-pr-282605-already-fixed)
11. [Exercises](#11-exercises)
12. [Glossary](#12-glossary)

---

## 0. What you will learn

1. what a `KASSERT` is, and why only debug kernels panic on it;
2. the TCP ideas this bug needs: segment size, congestion window,
   bytes in flight, retransmission timeout, duplicate ACK, SACK,
   limited transmit and silly window avoidance;
3. how to read the state of one TCP connection out of a kernel dump;
4. how two different "maximum segment size" values in the same
   function let 1360 bytes of window sit unused;
5. why an assertion must state its premise, and how to fix one that
   does not;
6. how to turn a dump into a deterministic test with packetdrill.

You need to read C and do additions. No prior TCP knowledge is needed.

---

## 1. The crash

The kernel printed this on the console, two and a half hours after boot:

```
panic: tcp_do_segment: sent too much: 2720>1360
cpuid = 16
KDB: stack backtrace:
vpanic() at vpanic+0x149
kassert_panic() at kassert_panic+0x190
tcp_do_segment() at tcp_do_segment+0x3cd5
tcp_input_with_port() at tcp_input_with_port+0x1099
tcp_input() at tcp_input+0xb
ip_input() at ip_input+0x484
netisr_dispatch_src() at netisr_dispatch_src+0xbf
ether_demux() at ether_demux+0x179
ether_nh_input() at ether_nh_input+0x3db
netisr_dispatch_src() at netisr_dispatch_src+0xbf
ether_input() at ether_input+0x155
tcp_lro_flush() at tcp_lro_flush+0x4ff
tcp_lro_flush_all() at tcp_lro_flush_all+0x15c
mlx5e_rx_cq_comp() at mlx5e_rx_cq_comp+0x15a0
...
```

Read it from the bottom up. A Mellanox network card (`mlx5e`) received
packets. LRO (large receive offload) handed them to Ethernet, then IP,
then TCP (`tcp_input`). TCP processed one segment in `tcp_do_segment()`,
and there a `KASSERT` failed: `kassert_panic()`. The message says TCP
sent 2720 bytes when it expected at most 1360.

### What a KASSERT is

`KASSERT(condition, (message))` is the kernel's `assert()`. It is
compiled only into kernels built with `options INVARIANTS`. If the
condition is false, the kernel panics with the message. Production
kernels leave `INVARIANTS` out: there the line does not exist, and the
code after it runs as usual. So this panic tells us one thing for
sure: **an assumption of the programmer was false**. It does not yet
tell us whether the code or the assumption is wrong. Most of this
document is about deciding that.

---

## 2. Background: the TCP you need

### 2.1 Segments and the maximum segment size

TCP cuts the byte stream of the application into **segments**. Each
segment travels in one IP packet. The peers agree on a **maximum
segment size** (MSS) during the connection handshake. FreeBSD stores it
in `tp->t_maxseg` (`tp` is the `struct tcpcb`, the TCP control block of
one connection).

A TCP header can carry **options** after its 20 fixed bytes, and the
options take space from the data. So the real room for data in one
segment is `t_maxseg` minus the options this segment carries.
`tcp_maxseg(tp)` (`sys/netinet/tcp_subr.c`) computes it:

```c
if ((tp->t_flags & TF_SACK_PERMIT) && tp->rcv_numsacks > 0) {
	optlen += TCPOLEN_SACKHDR;                  /* 2 */
	optlen += tp->rcv_numsacks * TCPOLEN_SACK;  /* 8 per block */
	optlen = PADTCPOLEN(optlen);                /* round up to 4 */
}
...
return (tp->t_maxseg - optlen);
```

Remember this: **`t_maxseg` and `tcp_maxseg(tp)` are two different
numbers.** When the segments we send carry SACK blocks (section 2.4),
`tcp_maxseg()` is smaller. In the crash, `t_maxseg` was 1380 and
`tcp_maxseg()` was 1360 (two SACK blocks: 2 + 16 = 18, padded to 20).

### 2.2 Congestion window and bytes in flight

The sender may not send as fast as it wants. It keeps a **congestion
window** (`snd_cwnd`, "cwnd"): the number of bytes it allows itself to
have sent but not yet acknowledged. Those bytes are the **flight size**:

```
flight size = snd_max - snd_una
```

- `snd_una`: the oldest byte not yet acknowledged ("unacknowledged");
- `snd_nxt`: the next byte to send;
- `snd_max`: the highest byte sent so far plus one.

Usually `snd_nxt == snd_max`. After a timeout, TCP goes back
(`snd_nxt = snd_una`) to send old data again, and then `snd_nxt` is
behind `snd_max`.

The congestion control module (NewReno here) grows cwnd when ACKs
arrive and cuts it when a loss is detected. `tcp_output()` sends new
data only while `snd_nxt - snd_una < cwnd`.

### 2.3 Retransmission timeout and `t_rxtshift`

When no ACK comes back for a long time, the **retransmission timer**
fires (an RTO). TCP sends the oldest segment again, sets cwnd to one
segment and doubles the timer. `tp->t_rxtshift` counts these
consecutive timeouts.

`t_rxtshift` goes back to 0 only when TCP measures a new round-trip
time. **Karn's algorithm** forbids measuring the round-trip time with a
segment that was sent twice: you cannot know which copy the ACK is for.
Without the TCP timestamp option, the next sample must wait for new
data sent after the timeout. So for a while after an RTO, data is
acknowledged again but `t_rxtshift` stays above 0.

### 2.4 Duplicate ACKs and SACK

The receiver acknowledges the highest byte it has **in order**. If a
segment is lost and the next ones arrive, the receiver sends the same
ACK number again: a **duplicate ACK**. With **SACK** (selective
acknowledgment, RFC 2018), the duplicate ACK also lists the blocks it
holds above the hole, for example `sack 1977:1983`.

SACK works in both directions. When **we** receive data with a hole,
our ACKs carry SACK blocks. Because TCP puts the ACK in every segment,
our data segments carry the same SACK blocks, which makes them shorter
(section 2.1). That is what `rcv_numsacks` counts.

Three duplicate ACKs start fast retransmit. The first and second ones
trigger **limited transmit** (RFC 3042): each duplicate ACK means a
segment has left the network, so the sender may send **one** new
segment for it.

### 2.5 Silly window avoidance

Sending many tiny segments wastes the network (the "silly window
syndrome"). So `tcp_output()` (`sys/netinet/tcp_output.c`) holds data
back when the room it has is smaller than a full segment, unless this
is the end of the data the application wrote:

```c
if (len) {
	if (len >= tp->t_maxseg)        /* a full segment: send */
		goto send;
	...
	if (... (idle || (tp->t_flags & TF_NODELAY)) &&
	    (uint32_t)len + (uint32_t)off >= sbavail(&so->so_snd) ...)
		goto send;                  /* end of the data: send */
	...
}
```

Note the comparison: **`len >= tp->t_maxseg`**, not `tcp_maxseg(tp)`.
That detail is the key to the crash (section 5).

`TF_NODELAY` is the `TCP_NODELAY` socket option: the application asks
TCP to turn off the Nagle algorithm, and to send the last partial
segment at once.

---

## 3. The code that panicked

The limited transmit branch of `tcp_do_segment()`
(`sys/netinet/tcp_input.c`, near line 2700), shortened:

```c
} else if (V_tcp_do_rfc3042) {
	cc_ack_received(tp, th, nsegs, CC_DUPACK);
	uint32_t oldcwnd = tp->snd_cwnd;
	tcp_seq oldsndmax = tp->snd_max;
	u_int sent;

	if (tp->t_dupacks == 1)
		tp->snd_limited = 0;
	if ((tp->snd_nxt == tp->snd_max) &&
	    (tp->t_rxtshift == 0))
		tp->snd_cwnd =                          /* (A) */
		    SEQ_SUB(tp->snd_nxt, tp->snd_una);
	tp->snd_cwnd +=                                 /* (B) */
	    (tp->t_dupacks - tp->snd_limited) * maxseg;
	tp->snd_cwnd -= tcp_sack_adjust(tp);            /* (C) */
	...
	(void) tcp_output(tp);
	sent = SEQ_SUB(tp->snd_max, oldsndmax);
	if (sent > maxseg) {
		KASSERT((tp->t_dupacks == 2 &&
		    tp->snd_limited == 0) ||
		   (sent == maxseg + 1 &&
		    tp->t_flags & TF_SENTFIN) ||
		   (sent < 2 * maxseg &&
		    tp->t_flags & TF_NODELAY),
		    ("%s: sent too much: %u>%u",
		    __func__, sent, maxseg));
		tp->snd_limited = 2;
	} else if (sent > 0) {
		++tp->snd_limited;
	}
	tp->snd_cwnd = oldcwnd;                         /* (D) */
	goto drop;
}
```

The plan of the code:

- **(A)** set cwnd to the flight size: "nothing more may be sent";
- **(B)** open it by one `maxseg` per duplicate ACK not yet used;
- **(C)** subtract the SACKed bytes, because `tcp_output()` adds them
  back (they have left the network);
- call `tcp_output()`, measure how far `snd_max` moved: that is `sent`;
- **(D)** put the real cwnd back.

The assertion then says: more than one `maxseg` may go out only

1. on the second duplicate ACK when the first one sent nothing
   (two segments are allowed), or
2. when the extra byte is a FIN, or
3. with `TCP_NODELAY`, if the total stays below `2 * maxseg` (one full
   segment plus the partial tail of the data).

Now look at (A) again. It runs **only if** `snd_nxt == snd_max` **and**
`t_rxtshift == 0`. If not, cwnd keeps its old value, which can be much
larger than the flight size. The three cases of the assertion are
correct only when (A) ran. Keep that in mind for section 6.

---

## 4. Reading the dump in kgdb

### 4.1 Getting the right kernel

A dump (`vmcore`) is only readable with the exact kernel that wrote it,
with its debug symbols (`kernel.debug`). Find the version in the dump
itself: the start of a minidump holds the kernel message buffer, which
holds the boot banner.

```sh
xz -dc vmcore.2.xz | head -c 170000000 > head.bin
strings head.bin | grep -m1 'FreeBSD 1[0-9]'
strings head.bin | grep -m1 panic
```

Then put the matching kernel and `/usr/lib/debug` in a directory (here
`sysroot/`, a read-only mount of the firmware image) and start gdb:

```sh
gdb -iex "set sysroot sysroot" \
    -iex "set debug-file-directory sysroot/usr/lib/debug" \
    -iex "set osabi FreeBSD/kernel" \
    -ex "target vmcore vmcore.2" \
    sysroot/boot/kernel.DEBUG/kernel
```

`kgdb(1)` does the same with fewer flags.

### 4.2 Finding the frame

```
(gdb) bt
...
#4  kassert_panic (fmt=0xffffffff8110196b "%s: sent too much: %u>%u")
#5  tcp_do_segment (tp=0xfffff83e50400000, ..., tlen=0, ...)
    at sys/netinet/tcp_input.c:2843
#6  tcp_input_with_port (...)
...
(gdb) frame 5
```

`tlen=0`: the segment carried no data. It was a pure ACK.

### 4.3 The local variables

```
(gdb) info locals
oldsndmax = 1862122234
oldcwnd = 4120
avail = 41765
sent = <unavailable>
maxseg = 1360
sack_changed = SACK_CHANGE
prev_sacked_bytes = 0
tiwin = 64768
```

`sent` was optimized out, but the panic message gives it: 2720.
`avail = 41765`: the application had plenty of data waiting.

### 4.4 The connection

```
(gdb) p tp->t_dupacks
$1 = 1
(gdb) p tp->snd_limited
$2 = 0
(gdb) p tp->t_rxtshift
$5 = 3
(gdb) p tp->t_maxseg
$6 = 1380
(gdb) p tp->snd_una
$7 = 1862119474
(gdb) p tp->snd_nxt
$8 = 1862124954
(gdb) p tp->snd_max
$9 = 1862124954
(gdb) p tp->snd_cwnd
$11 = 4108
(gdb) p tp->rcv_numsacks
$16 = 2
(gdb) p tp->sackhint.sacked_bytes
1372
(gdb) p/x tp->t_flags
$3 = 0x11008264
```

Decode `t_flags` with the `TF_*` values of `sys/netinet/tcp_var.h`.
The bits set are `TF_NODELAY`, `TF_REQ_SCALE`, `TF_RCVD_SCALE`,
`TF_SACK_PERMIT`, `TF_GPUTINPROG`, `TF_TSO` and `TF_LRD`. Two facts
matter: `TF_NODELAY` is on, and `TF_RCVD_TSTMP` is off (no
timestamps). `TF_SENTFIN` is off.

What each value tells us:

| value | meaning |
|---|---|
| `t_dupacks = 1`, `snd_limited = 0` | first duplicate ACK, nothing sent for it yet |
| `t_rxtshift = 3` | three RTOs, no round-trip time measured since |
| `t_maxseg = 1380`, `maxseg = 1360` | our segments carry 2 SACK blocks (`rcv_numsacks = 2`) |
| `snd_cwnd = 4108` | the temporary value of (B) and (C); `oldcwnd` = 4120 is the real one |
| `oldsndmax - snd_una = 2760` | flight size before `tcp_output()` |
| `sacked_bytes = 1372` | this ACK SACKed 1372 bytes (`prev_sacked_bytes = 0`) |

---

## 5. Rebuilding the 2720 bytes

Because `t_rxtshift = 3`, line (A) did **not** run. cwnd started at its
real value, 4120:

```
(B)  4120 + (1 - 0) * 1360 = 5480
(C)  5480 - 1372           = 4108     matches snd_cwnd in the dump
```

`tcp_output()` adds the SACKed bytes back (`sendwin = snd_cwnd +
tcp_sack_adjust(tp)`), so it may have up to `4108 + 1372 = 5480` bytes
in flight. There were 2760:

```
room = 5480 - 2760 = 2720 = 2 * 1360
```

TSO is on, so `tcp_output()` sent the 2720 bytes as one burst of two
1360-byte segments. 2720 is not below `2 * maxseg`, so the
`TF_NODELAY` case does not match, and nothing else does: panic.

### Why was there room left before this ACK?

Without the ACK, the room was `4120 - 2760 = 1360` bytes, and 41765
bytes were waiting. Why did TCP not send them earlier? Because of
section 2.5: `tcp_output()` would send one segment of
`tcp_maxseg() = 1360` bytes, but it checks `len >= t_maxseg`, and
1360 < 1380. 1360 bytes is not "the end of the data" either. So the
silly window rule held those 1360 bytes back, even though they fill a
segment.

The duplicate ACK then added 1360 more. 2720 ≥ 1380: send.

So four things had to happen at the same time:

1. our segments carry SACK blocks (we receive data with a hole), so
   `tcp_maxseg()` < `t_maxseg`;
2. an RTO not yet cleared (`t_rxtshift > 0`), so line (A) is skipped;
3. between `tcp_maxseg()` and `t_maxseg` bytes of cwnd free, held by
   the silly window rule, with more data waiting;
4. a first duplicate ACK with new SACK information.

---

## 6. Why the assertion is wrong, not the sending

Look at what TCP did from the network's point of view. Before the ACK,
its real cwnd (4120) allowed 1360 more bytes. The duplicate ACK says a
segment has left the network, worth one more segment. Sending
`1360 + 1360` is inside the limits that cwnd and limited transmit
give. Nothing was sent that the congestion control did not allow.

The assertion counts the bytes against the wrong reference. Its three
cases describe what happens **after line (A)**: cwnd equal to the
flight size, plus one or two segments. When (A) does not run, cwnd
can be larger than the flight size by any amount, and "more than one
segment" is a normal result. The assertion has a hidden premise, "(A)
ran", and the premise is false after an RTO (or when `snd_nxt` is
behind `snd_max`).

This is the same kind of problem as the one Michael Tuexen found in
2025 (PR 282605, comment 59): valid sending, too strict an assertion.
He relaxed it for `TCP_NODELAY` then (D49922). This is a second case.

Is line (A) itself wrong, then? It deliberately keeps the timeout
cwnd: after an RTO, NewReno's slow start sets cwnd, and limited
transmit should not override it. Changing that changes how TCP sends,
which is a decision for the transport maintainers. The assertion can
be corrected without touching behaviour.

---

## 7. The patch

[`tcp_sent_too_much_rxtshift.patch`](tcp_sent_too_much_rxtshift.patch),
against `main`:

```diff
 				tcp_seq oldsndmax = tp->snd_max;
 				u_int sent;
 				int avail;
+				bool cwnd_is_flight = false;
 
 				KASSERT(tp->t_dupacks == 1 ||
...
 				if ((tp->snd_nxt == tp->snd_max) &&
-				    (tp->t_rxtshift == 0))
+				    (tp->t_rxtshift == 0)) {
 					tp->snd_cwnd =
 					    SEQ_SUB(tp->snd_nxt, tp->snd_una);
+					cwnd_is_flight = true;
+				}
...
 				if (sent > maxseg) {
-					KASSERT((tp->t_dupacks == 2 &&
+					/*
+					 * Unless snd_cwnd was reset to the
+					 * flight size above, the old cwnd may
+					 * allow more than one segment.
+					 */
+					KASSERT(!cwnd_is_flight ||
+					   (tp->t_dupacks == 2 &&
```

Why this shape:

- **It writes the premise down.** The assertion now says "if cwnd was
  set to the flight size, then ...". A reader sees when it applies.
- **It keeps the check where it is valid.** In the normal case (no
  timeout, `snd_nxt == snd_max`) the three cases still catch a real
  bug, for example a wrong `snd_limited`.
- **It does not change what TCP sends.** Kernels without `INVARIANTS`
  compile to the same code except one unused flag; kernels with it
  stop panicking on valid traffic.
- **A flag, not a copy of the condition.** Testing `t_rxtshift > 0` in
  the assertion would read `tp` after `tcp_output()`, which can change
  `snd_nxt`. The flag records the decision taken at (A).

What it does not do: it does not change line (A), and it does not fix
the `t_maxseg` versus `tcp_maxseg()` mismatch of the silly window
rule (exercise 3).

---

## 8. The packetdrill reproducer

### 8.1 What packetdrill is

packetdrill (`net/packetdrill` in ports) tests a TCP stack with a
script. The script mixes three kinds of lines, each with a time:

- system calls run by the test on a real socket: `+0 write(4, ..., 988) = 988`;
- packets **injected** into the kernel as if a peer sent them:
  `<` lines;
- packets the kernel **must** send: `>` lines. If the kernel sends
  something else, or nothing within the tolerance, the script fails.

The fake peer lives behind a `tun(4)` interface, so no second machine
is needed.

### 8.2 The script

[`tcp_sent_too_much_rxtshift.pkt`](tcp_sent_too_much_rxtshift.pkt)
builds the four conditions of section 5 with an MSS of 1000:

| step | script | effect |
|---|---|---|
| handshake | `<mss 1000,sackOK>`, no timestamps; `TCP_NODELAY` | `t_maxseg` = 1000 |
| 1 | peer sends `1:101`, then `201:301` | a hole: our ACKs carry `sack 201:301`, `tcp_maxseg()` = 988 |
| 2 | write 988 bytes, the peer never ACKs, two RTOs | `t_rxtshift` = 2, cwnd = 1000 |
| 2 | peer ACKs byte 989 | no RTT sample (Karn), `t_rxtshift` stays 2; slow start: cwnd = 1988 |
| 3 | write 994 bytes | two segments, 988 + 6; flight = 994, room = 994 |
| 3 | write 1982 bytes | room 994 < `t_maxseg`, more data waits: nothing sent |
| 4 | duplicate ACK `ack 989 sack 1977:1983` | room = 994 + 988: 988 + 988 + 6 bytes go out |

`sent` = 1982 and `2 * maxseg` = 1976. 1982 is not below 1976: the
`TF_NODELAY` case does not match and the assertion fires. Without
TSO (the `tun` interface has none), the second full segment goes out
because it reaches the end of the written data, which the silly window
rule allows with `TCP_NODELAY`.

### 8.3 Running it

Never on your workstation with an `INVARIANTS` kernel: it panics. Use
a throwaway VM.

```sh
pkg install packetdrill
kldload cc_newreno      # main defaults to cubic; the crash used NewReno
packetdrill tcp_sent_too_much_rxtshift.pkt
```

On a kernel without `INVARIANTS` it passes, and shows the two full
segments on the first duplicate ACK. With `INVARIANTS` it panics.

Do not count on `debug.kassert.warn_only=1` to turn the panic into a
message. In `sys/sys/kassert.h`, `KASSERT()` calls `kassert_panic()`,
and without `options KASSERT_PANIC_OPTIONAL` that name is a macro for
`panic()`. GENERIC does not have the option, so the tunable exists but
nothing reads it, and the guest panicked with `debug.kassert.warn_only:
1`. The crashed server's kernel had the option: its backtrace shows
`kassert_panic()`.

---

## 9. Validating the patch

An A/B in a throwaway bhyve guest, with the harness of
[`../kern-test-vm/`](../kern-test-vm/). Two GENERIC kernels from
`main` at `6442a92a7d9c` (2026-11-11), with `INVARIANTS` and
`WITNESS`: `kernel.base` unchanged, `kernel.fix` with the patch. Both
load `cc_newreno.ko` built from the same tree. The guest runs:

```sh
kldload cc_newreno
./packetdrill tcp_sent_too_much_rxtshift.pkt
echo "packetdrill rc=$?"
```

**Without the patch**, the guest panics on the duplicate ACK of step 4,
with the numbers section 8.2 predicts:

```
net.inet.tcp.cc.algorithm: cubic -> newreno
net.inet.tcp.rfc3042: 1 -> 1
panic: tcp_do_segment: sent too much: 1982>988
KDB: stack backtrace:
vpanic() at vpanic+0x149
panic() at panic+0x43
tcp_do_segment() at tcp_do_segment+0x3352
tcp_input_with_port() at tcp_input_with_port+0x10ec
tcp_input() at tcp_input+0xb
ip_input() at ip_input+0x271
netisr_dispatch_src() at netisr_dispatch_src+0xbf
tunwrite() at tunwrite+0x2df
...
```

The stack is the same as on the server, except for the bottom. Here
the packet came from packetdrill writing to `tun(4)`, not from a
network card.

**With the patch**, every system call and every expected packet of the
script matches, and there is no panic:

```
KTVM-BEGIN kernel=/boot/kernel.fix/kernel FreeBSD 16.0-CURRENT #0 tcp-sent-too-much-rxt-n290968-6442a92a7d9c-dirty
net.inet.tcp.cc.algorithm: cubic -> newreno
net.inet.tcp.rfc3042: 1 -> 1
packetdrill rc=0
KTVM-END rc=0
```

`rc=0` matters more than "no panic". It means the patched kernel sent
exactly `988 + 988 + 6` bytes on the duplicate ACK, the same as an
unpatched kernel without `INVARIANTS` would send. The patch changed
the check, not the behaviour.

What this test does not cover: the normal case, where the assertion
still applies (`cwnd_is_flight` true), is not exercised by this
script. Exercise 5 builds that test.

Each kernel was checked on one complete boot. Further boots of the
unpatched kernel, meant to show the panic happens every time, did not
reach the test: the guest stalled before `rc` printed anything, or
bhyve exited at once with an empty console. That is a problem of the
VM harness with this kernel, not of the script. The script itself has
no randomness except the RTO times, which the `~` ranges accept.

---

## 10. What PR 282605 already fixed

FreeBSD PR 282605, "[tcp] panic: tcp_do_segment: sent too much", was
opened in November 2024. Several different causes give the same
message:

| change | what it fixed |
|---|---|
| D47541 (`8f5a2e216f4c`) | a bad interaction of the new transmission selection code with an RTO followed by SACK loss recovery |
| D49414 (`fbcf3b74e8f2`) and D48652 (`6f6c07813b38`) | wrong cwnd state after a spurious RTO |
| D49922 (`934caaec3afc`) | the assertion allows up to `2 * maxseg - 1` with `TCP_NODELAY` |
| D51426 (`2b5de4330ee1`) | RFC 6675 conditions for counting a duplicate ACK |

The crash of this document happened on a kernel with all of them. It
is a new case: `t_rxtshift > 0`, which none of them covers.

---

## 11. Exercises

1. The dump has `t_maxseg` = 1380 and `maxseg` = 1360. Using
   `tcp_maxseg()`, check that 2 SACK blocks without timestamps take 20
   bytes. How much data fits in a segment with 3 blocks? With
   timestamps on and 2 blocks?
2. Read `tcp_sack_adjust()` in `sys/netinet/tcp_sack.c`. Why does
   line (C) subtract it, when `tcp_output()` adds it back? Find the
   case where the two calls return different values. (Hint:
   `snd_nxt` moves during `tcp_output()`.)
3. With `t_rxtshift == 0`, line (A) sets the room to exactly one
   `tcp_maxseg()`. With SACK blocks in our segments, that room is
   smaller than `t_maxseg`. What does the silly window rule of
   section 2.5 do then? Does limited transmit still send anything?
   Is that a bug?
4. The patch uses a flag. Write the version that tests `t_rxtshift`
   in the assertion, and find an input where it gives a different
   answer than the flag.
5. Write a second script without the RTO of step 2 (`t_rxtshift`
   stays 0), so line (A) runs. What does the first duplicate ACK send
   now? Check that the patched kernel still evaluates the assertion
   in that case.
6. Change the reproducer so the fourth step sends 988 + 988 bytes and
   nothing more. Does the assertion still fire? Why, with
   `TCP_NODELAY` on?

---

## 12. Glossary

- **ACK**: the acknowledgment number, the next byte the receiver
  expects.
- **cwnd** (`snd_cwnd`): congestion window, how many bytes may be in
  flight.
- **duplicate ACK**: an ACK that does not move `snd_una`; with SACK it
  must carry new SACK information (RFC 6675).
- **flight size**: bytes sent and not acknowledged, `snd_max - snd_una`.
- **`INVARIANTS`**: kernel option that compiles in the `KASSERT`
  checks.
- **Karn's algorithm**: never measure the round-trip time on a
  segment sent more than once.
- **`KASSERT`**: the kernel `assert()`; panics on a debug kernel,
  absent from others.
- **limited transmit** (RFC 3042): one new segment per first and
  second duplicate ACK.
- **LRO**: large receive offload; the driver groups received packets
  before TCP sees them.
- **MSS**: maximum segment size. `t_maxseg` without options,
  `tcp_maxseg()` with the options of the current segment.
- **packetdrill**: script-driven TCP tester using a `tun(4)` peer.
- **RTO**: retransmission timeout; `t_rxtshift` counts the
  consecutive ones.
- **SACK**: selective acknowledgment, lists the received blocks above
  a hole.
- **silly window avoidance**: do not send small segments while more
  data waits.
- **TSO**: TCP segmentation offload; the card cuts one large send into
  segments.

---

## References

- Source: `sys/netinet/tcp_input.c` (limited transmit),
  `sys/netinet/tcp_output.c` (silly window rule),
  `sys/netinet/tcp_subr.c` (`tcp_maxseg()`),
  `sys/netinet/tcp_sack.c` (`tcp_sack_adjust()`),
  `sys/netinet/cc/cc_newreno.c`.
- FreeBSD PR 282605: <https://bugs.freebsd.org/bugzilla/show_bug.cgi?id=282605>
- RFC 3042 (limited transmit), RFC 5681 (congestion control),
  RFC 6298 (RTO and Karn's algorithm), RFC 6675 (SACK loss recovery),
  RFC 2018 (SACK), RFC 896 (Nagle).
- Test harness: [`../kern-test-vm/`](../kern-test-vm/).
