# PR draft — `VehicleSupply::SupplyStarted`: drop stale duplicate-entry assert

**Branch:** `vehicle-supply-assert-fix` (single commit `30e2240`, off `main`, sibling of `ai-radio-getfrom-fix` and `soldier-killedby-brain-assert-fix`)

**Files changed:** `engine/Poseidon/World/Entities/Vehicles/Transport.cpp` (+4/-1)

---

## Title

```
VehicleSupply::SupplyStarted: drop stale duplicate-entry assert
```

## Body

```markdown
## Summary

`VehicleSupply::SupplyStarted()` in `engine/Poseidon/World/Entities/Vehicles/Transport.cpp:1594` asserts that a unit is not already being supplied by this vehicle:

```cpp
void VehicleSupply::SupplyStarted(AIUnit* unit)
{
    LOG_DEBUG(Physics, "{} SupplyStarted for {}", ...);
    PoseidonAssert(_supplyUnits.Find(unit) < 0);  // ← fires
    _supplyUnits.AddUnique(unit);
}
```

The FSM state pair in `engine/Poseidon/AI/AISubgroupFSMSupply.inc` (`SupplyEnter` at 792, `SupplyExit` at 832) is the only caller of `WaitForSupply` (which calls `SupplyStarted`) and `SupplyFinished`. When a client drifts out of the supplier's supply radius mid-supply, `SSupplySupply → SSupplyMove → SSupplySupply` fires — re-entering `SupplyEnter` without having gone through `SupplyExit`. On that re-entry `SupplyStarted` is called for a unit already present in `_supplyUnits`, tripping the assert.

The `AddUnique` on the very next line already handles the case correctly (idempotent add), and `SupplyFinished`'s list walk stops at the first match so removal remains correct. Nothing observably breaks — the assert is stale.

## Evidence

From a 30-minute C02 "Battlefields" session with trace logging (FreeBSD 16-CURRENT, GL33 backend). Multiple *different* clients being supplied by the same vehicle in parallel is normal and never trips the check:

```
20:30:16.904  EAST Charlie Black:5 SupplyStarted for EAST Alpha Black:7
20:30:18.566  EAST Charlie Black:5 SupplyStarted for EAST Bravo Black:5
20:30:19.585  EAST Charlie Black:5 SupplyStarted for EAST Foxtrot Black:6
    ...
20:30:21.448  EAST Charlie Black:5 SupplyFinished for EAST Alpha Black:7
20:30:22.954  EAST Charlie Black:5 SupplyFinished for EAST Bravo Black:5
```

The one assertion fire in the session, isolated:

```
20:33:24.040  WEST Echo Black:5 SupplyStarted for WEST Golf Black:1
20:33:36.172  WEST Echo Black:5 SupplyStarted for WEST Golf Black:1   ← assert fires here
20:33:39.642  WEST Echo Black:5 SupplyFinished for WEST Golf Black:3  (unrelated unit)
20:33:40.330  WEST Echo Black:5 SupplyFinished for WEST Golf Black:1
[ERRR] [CORE] engine/Poseidon/World/Entities/Vehicles/Transport.cpp(1594) :
              Assertion failed '_supplyUnits.Find(unit) < 0'
```

12 seconds between the two `SupplyStarted` for the same `(supplier=Echo Black:5, unit=Golf Black:1)` pair, with no intervening `SupplyFinished` — consistent with the FSM re-entering `SSupplySupply` after a short excursion into `SSupplyMove`. The final `SupplyFinished` at `20:33:40.330` closes the pair correctly.

## Fix

Remove the assert and document the legitimate FSM re-entry path. `AddUnique` continues to guard the list.

```cpp
void VehicleSupply::SupplyStarted(AIUnit* unit)
{
    LOG_DEBUG(Physics, "{} SupplyStarted for {}", ...);
    // A re-entry of the supply FSM state (e.g. Supply->Move->Supply when the
    // client drifts out of range and comes back) can call SupplyStarted for
    // a unit that never emitted a matching SupplyFinished. AddUnique below
    // handles the duplicate; the assert is stale.
    _supplyUnits.AddUnique(unit);
}
```

## Same shape as recent fixes

This is the third assert in this codebase where a `PoseidonAssert` was contradicted by a defensively-correct line right next to it (the other two: `Man::KilledBy` `PoseidonAssert(_brain)` immediately followed by `if (!_brain) return;`, and the AI radio queue's `msgCmd->GetFrom() == this` on the shared center channel). All three are cosmetic invariant violations, not functional bugs — but they were drowning the trace log (thousands of hits per session) and hiding real signal.
```
