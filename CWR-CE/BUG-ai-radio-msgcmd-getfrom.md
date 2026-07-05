# Bug: AI radio queue holds commands with mismatched `GetFrom()` (C02 "Battlefields")

**Status:** root cause confirmed 2026-07-02 via instrumented build on ser6fbsd.
The `AI_ERROR(msgCmd->GetFrom() == this)` invariant is **invalid by construction**
when the group's scan runs against the shared per-side `AICenter` radio
channel. This is an upstream bug, not FreeBSD-specific.

**Branch:** `ai-radio-getfrom-fix` (off `main`) — currently carries the
instrumentation commit `b9803f3`. The actual fix has not been written yet.

**Companion doc:** `upstream-issue-ai-msg-routing.md` — the upstream-facing
write-up. Kept separate because it is framed for filing an issue on
`ofpisnotdead-com/CWR-CE`; this doc is the internal engineering log.

---

## Root cause

`engine/Poseidon/AI/AIGroupImpl.cpp` line 205 (and the analogous lines at
the other 7 sites) picks the radio channel to scan based on `channelCenter`:

```cpp
RadioChannel& radio = channelCenter ? GetCenter()->GetRadio() : GetRadio();
```

- `channelCenter == false` → the group's own radio → every message in
  the queue was posted by this group, so `msgCmd->GetFrom() == this` holds.
- `channelCenter == true`  → the **per-side `AICenter` shared channel** →
  every group on the side broadcasts into the same queue, so
  `msgCmd->GetFrom() == this` is only true for the caller's own messages
  and is false for everyone else's. The assertion fires once per foreign
  message per scan pass.

The two loops that hit in the observed session
(`AIGroupImpl.cpp:203`/`FindPrevMessage` and `:216`/`GetActualMessage`)
are both inside the `CommandSent(to, msg, bool channelCenter)` overload
that takes `channelCenter` as a parameter. The invariant is copy-pasted
from the per-group channel path and was never valid on the center path.

The `msgCmd->IsTo(to) && msgCmd->GetCmdMessage() == message` check that
follows already filters foreign messages harmlessly (a foreign command
addressed to someone else doesn't match `to`), so the AI logic itself
does the right thing — the `AI_ERROR` is what's wrong.

## Evidence from the ser6fbsd replay (2026-07-02)

Instrumented build (branch tip `b9803f3`) shipped as `CWR-CE-3.01_2` from
the local poudriere jail, installed on ser6fbsd, campaign C02 replayed
until player death, log grepped for the `LOG_ERROR` fmt string:

- **2908 firings** of `AIGroup radio queue holds foreign command`.
- Only **2 of 8 instrumented sites** fired: `CommandSent(to,msg,bool)/FindPrevMessage`
  and `CommandSent(to,msg,bool)/GetActualMessage`. The other 6 sites (the
  `channelCenter == false` paths) never fired — consistent with the
  invariant being valid there.
- All hits carried `msgType=0` = `RMTCommand`
  (`engine/Poseidon/AI/AIRadio.hpp:11`, first enum value).
- **5 distinct senders**: EAST Alpha Black, EAST Echo Black, WEST Bravo
  Black, WEST Charlie Black, WEST Echo Black.
- **20 distinct scanner groups** on both EAST and WEST sides — i.e. the
  cross-talk is per-side (as expected for `AICenter::GetRadio()` which
  is one channel per side), not cross-side.

## Fix strategy

Two viable shapes, pick one on the branch:

1. **Guard the assertion** — keep instrumentation on the per-group
   channel where it catches real invariant violations, drop it on the
   shared channel where it's meaningless:
   ```cpp
   if (!channelCenter && msgCmd->GetFrom() != this) { AI_ERROR(...); }
   ```
   Applies only to the 2 sites inside `CommandSent(to, msg, bool)`.
   The other 6 sites don't consult `channelCenter`, keep them as-is.
2. **Drop the assertion entirely** at the two center-channel sites.
   `msgCmd->IsTo(to)` already filters, and the "own-message" property
   isn't load-bearing for the loop's return value.

Option 1 is safer — it preserves signal for the per-group case in case a
real leak appears there later. Option 2 is minimal-change.

The instrumentation commit currently on the branch replaces all 8 sites
with a shared `CheckMsgCmdFrom` helper. That helper is fine to keep as
a diagnostic — the fix just needs to skip the call on the two center
sites (option 1) or delete it there (option 2).

## Secondary: `SoldierOldMove.cpp:1009 PoseidonAssert(_brain)`

Not yet investigated in the new build. 34 fires in the same window in
the original session; may or may not be linked. The `PoseidonAssert` on
line 1009 is immediately followed by `if (!_brain) return;` on line
1010 — the assert and the guard contradict each other, and one of them
is wrong.

Working assumption until proven otherwise: independent bug. Fix in a
separate commit / PR.

## Files that will change (fix commit)

- `engine/Poseidon/AI/AIGroupImpl.cpp` — narrow the invariant to the
  per-group path (2 sites) or drop it there.
- `engine/Poseidon/World/Entities/Infantry/SoldierOldMove.cpp:1009` —
  separate commit, reconcile assert with the early-return guard.

## What the port currently ships

- `games/CWR-CE/Makefile` PATCHFILES applies the merged `freebsd+GOG`
  compare-URL patch (base `9abbdf2` → tip `55e7032`) plus the
  instrumentation patch `files/patch-engine_Poseidon_AI_AIGroupImpl.cpp`
  layered on top.
- The instrumentation patch is a diagnostic scaffold only. Once the
  real fix lands on the branch, either fold the fix into the compare
  patch and drop `files/patch-*`, or replace `files/patch-*` with the
  fix-only diff.

## Reproduction

See `upstream-issue-ai-msg-routing.md` for the invocation and log
recipe. On the instrumented build the burst is deterministic — every
mission with a shared side channel produces thousands of hits within
the first few minutes. Two of five attempts on the *un*-instrumented
build showed the burst — but that reflects log-level defaults, not
reproducibility of the underlying condition.

## Tooling

`~/myscripts/CWR-CE/cwr-logstat` — identifies mission/chapter from log
paths, counts and templates ERRR/WARN lines. Run against any future
trace log to confirm which mission an attempt actually played.
