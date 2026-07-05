# PR draft — `Man::KilledBy`: null-brain corpses are a legitimate reachable state

**Branch:** `soldier-killedby-brain-assert-fix` (single commit `f25fc93`, off `main`, sibling of `ai-radio-getfrom-fix` and `vehicle-supply-assert-fix`)

**Files changed:**
- `engine/Poseidon/World/Entities/Infantry/SoldierOldMove.cpp` (+3/-1)
- `engine/Poseidon/World/Entities/Vehicles/TransportCore.cpp` (+5/-4)

---

## Title

```
Man::KilledBy: null-brain corpses are a legitimate reachable state
```

## Body

```markdown
## Summary

`Man::KilledBy()` in `engine/Poseidon/World/Entities/Infantry/SoldierOldMove.cpp:1009` asserts that the soldier still has a brain pointer, then the very next line guards against it being null:

```cpp
void Man::KilledBy(EntityAI* owner)
{
    PoseidonAssert(_brain);   // ← fires
    if (!_brain)
    {
        return;               // ← already handles the case
    }
    ...
}
```

The guard exists for a reason. `NetworkClient::HandleRespawn` (`engine/Poseidon/Network/NetworkClient.cpp:350-355`) transfers the `AIUnit` brain from the dying body to the new Soldier and *nulls the old body's brain*. The old body persists on the map — and if the respawn happened while the soldier was riding a vehicle, the brainless corpse stays in the vehicle's `_manCargo`. Any subsequent damage delivered to that vehicle iterates over cargo and calls `Man::KilledBy` on the corpse, tripping the assert. The `if (!_brain) return;` was the intended handling; the `PoseidonAssert` above it is stale.

## Evidence

From a 2-hour C02 "Battlefields" session with trace logging (FreeBSD 16-CURRENT, GL33 backend). 34 fires total, in dense bursts synchronized with vehicle damage events:

```
[2026-07-02 12:10:39.331] [ERRR] [CORE] SoldierOldMove.cpp(1009) : Assertion failed '_brain'
[2026-07-02 12:10:43.192] [ERRR] [CORE] SoldierOldMove.cpp(1009) : Assertion failed '_brain'
[2026-07-02 12:10:45.603] [ERRR] [CORE] SoldierOldMove.cpp(1009) : Assertion failed '_brain'
[2026-07-02 12:12:33.254] [ERRR] [CORE] SoldierOldMove.cpp(1009) : Assertion failed '_brain'
[2026-07-02 12:12:33.254] [ERRR] [CORE] SoldierOldMove.cpp(1009) : Assertion failed '_brain'
[2026-07-02 12:12:33.254] [ERRR] [CORE] SoldierOldMove.cpp(1009) : Assertion failed '_brain'
[2026-07-02 12:12:33.267] [ERRR] [CORE] SoldierOldMove.cpp(1009) : Assertion failed '_brain'
[2026-07-02 12:12:33.267] [ERRR] [CORE] SoldierOldMove.cpp(1009) : Assertion failed '_brain'
[2026-07-02 12:12:33.267] [ERRR] [CORE] SoldierOldMove.cpp(1009) : Assertion failed '_brain'
...
[2026-07-02 12:17:20.050]   4 hits in same ms
[2026-07-02 12:17:28.811]   4 hits in same ms
[2026-07-02 12:17:32.524]   4 hits in same ms
```

The 3-4-hit clusters within a single millisecond are the tell: `Transport::DammageCrew` iterates over driver + gunner + commander + all cargo (`_manCargo`), and when a vehicle is hit each occupant is dispatched to `KilledBy` in the same frame. If several occupants happen to be post-respawn corpses, each one fires the assert.

## Fix

Two changes:

1. **Drop the stale assert** in `Man::KilledBy` and document why null is a legitimate reachable state. The existing `if (!_brain) return;` remains as the correct handling.

   ```cpp
   void Man::KilledBy(EntityAI* owner)
   {
       // _brain is null on respawn transfer (NetworkClient.cpp moves the brain
       // to the new Soldier and nulls the old body's brain). A brainless
       // corpse taking damage lands here; nothing to do.
       if (!_brain)
       {
           return;
       }
       ...
   }
   ```

2. **Guard the four `Transport::DammageCrew` dispatch sites** in `engine/Poseidon/World/Entities/Vehicles/TransportCore.cpp:353,362,369,376` so brainless corpses are skipped entirely rather than making the round-trip into `KilledBy` just to hit the early-return.

   ```cpp
   // Skip brainless corpses (post-respawn bodies still riding as cargo).
   if (man && man->Brain())
   {
       man->KilledBy(killer);
   }
   ```

   (Same guard applied to `_driver`, `_gunner`, `_commander`.)

## Verification

Rebuilt and replayed on the same host — 4-hour session across the full C02 mission arc: **0 `SoldierOldMove.cpp` assert fires** (48.3M log lines total, 0 `[ERRR]`, 0 `[CRIT]`). Down from 34 fires per 2-hour session pre-fix.

## Same shape as recent fixes

This is the second assert in this codebase where a `PoseidonAssert` was contradicted by a defensively-correct line right next to it (the first: the AI radio queue's `msgCmd->GetFrom() == this` on the shared center channel). Both are cosmetic invariant violations, not functional bugs — but they were drowning the trace log and hiding real signal.
```
