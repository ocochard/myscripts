# Draft — upstream issue for ofpisnotdead-com/CWR-CE

**Title:** `AI_ERROR(msgCmd->GetFrom() == this)` fires thousands of times per mission — invariant is invalid on the shared `AICenter` radio channel (`AIGroupImpl.cpp:203/216`)

---

## Summary

`AIGroupImpl::CommandSent(to, msg, bool channelCenter)` picks its radio
channel from `channelCenter`:

```cpp
// engine/Poseidon/AI/AIGroupImpl.cpp — around line 205 / 218
RadioChannel& radio = channelCenter ? GetCenter()->GetRadio() : GetRadio();
while (true)
{
    RadioMessage* msg = radio.FindPrevMessage(RMTCommand, index);
    if (!msg) break;
    AI_ERROR(dynamic_cast<RadioMessageCommand*>(msg));
    RadioMessageCommand* msgCmd = static_cast<RadioMessageCommand*>(msg);
    AI_ERROR(msgCmd);
    AI_ERROR(msgCmd->GetFrom() == this);         // ← fires
    if (msgCmd->IsTo(to) && msgCmd->GetCmdMessage() == message) return true;
}
```

When `channelCenter == false`, the channel is the group's own radio and
`msgCmd->GetFrom() == this` is a valid invariant. When
`channelCenter == true`, the channel is the per-side `AICenter` radio,
which is *shared by every group on that side*. Every foreign message on
that shared queue trips the assertion.

The assertion is copy-pasted from the per-group path and was never
correct on the center path. The immediately following
`msgCmd->IsTo(to) && msgCmd->GetCmdMessage() == message` check already
filters foreign messages, so the actual AI logic is fine — only the
assertion is wrong.

The same pattern exists at two sites (the `FindPrevMessage` loop at
line 203 and the `GetActualMessage` check at line 216); both are inside
the `channelCenter`-parameterised overload.

## Evidence

Instrumented build (added a helper that logs both group identities
instead of the bare `AI_ERROR`), 10-minute campaign session on C02
"Battlefields":

- **2908 firings** of `msgCmd->GetFrom() != this`.
- Only the two `channelCenter`-parameterised sites fire (lines 203, 216).
  The other 6 `AI_ERROR(msgCmd->GetFrom() == this)` sites in the file —
  which do not consult a `channelCenter` flag — never fire.
- All hits carry `msgType == RMTCommand`
  (`engine/Poseidon/AI/AIRadio.hpp:11`, first enum value).
- 5 distinct sender groups, 20 distinct scanner groups, all within the
  same side per hit (no cross-side leakage) — consistent with
  `AICenter::GetRadio()` being one channel per side.

Example log lines (instrumented):
```
[ERRR] [AI] AIGroup radio queue holds foreign command at CommandSent(to,msg,bool)/FindPrevMessage:
    this=WEST Alpha Black (0x...), from=WEST Bravo Black (0x...), msgType=0
[ERRR] [AI] AIGroup radio queue holds foreign command at CommandSent(to,msg,bool)/GetActualMessage:
    this=WEST Alpha Black (0x...), from=WEST Charlie Black (0x...), msgType=0
```

## Suggested fix

Either narrow the invariant to the per-group path:

```cpp
if (!channelCenter && msgCmd->GetFrom() != this) { AI_ERROR(...); }
```

or drop the assertion at the two center-channel sites entirely — the
`msgCmd->IsTo(to)` check already provides the semantic filter.

## Environment

- CWR-CE `9abbdf2` (upstream `main` at time of build).
- FreeBSD 16.0-CURRENT / clang 21.1.8 / gl33 backend, AMD Radeon 680M.
- GOG retail campaign data.
- Invocation:
  ```
  cwr-ce --log-level trace --log-categories AI,Core,World,Mission,Config \
      --log-file /tmp/cwr.log --log-format text
  ```

## Related but not conflated

A separate `PoseidonAssert(_brain)` at
`engine/Poseidon/World/Entities/Infantry/SoldierOldMove.cpp:1009` fires
tens of times in the same window. The assert contradicts the
`if (!_brain) return;` on the very next line — one of them is wrong.
Reported here for visibility; happy to file separately.

Also unrelated to issue #29 (mission-load null derefs on 2001-era data)
and to the X11 DRI3 SwapBuffers hang seen on some sessions.
