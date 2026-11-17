# #54 UPS slice — measured, shipped nothing (2026-11-17)

## Decision
The planned hoist of distance math out of `haul_plan.match`'s sort comparators was implemented and
measured, but **reverted**: it does not clear the ship gate (≥5% improvement, ≤0.01 ms spread).
No production code is changed on this branch. The only deliverable is
`tests/haul_plan_equiv_test.lua`, an oracle-equivalence regression test retained so a future
refactor of these comparators has a pinned definition of "same behaviour".

## Evidence

Baseline save built with `TICKS=1800 scripts/bench-colony.sh` on the unmodified tree
(500 colonists, 2000 machines, working town + ore-demand town). Every number is `script ms/tick`
from `scripts/bench-once.sh <save> 1800`, 3 runs each, same saved town, same machine:

| save | baseline runs | baseline median | optimized runs | optimized median | delta |
|---|---|---|---|---|---|
| ore-demand | 0.622 / 0.619 / 0.620 | **0.620** | 0.608 / 0.610 / 0.616 | **0.610** | −1.6% |
| working | 0.633 / 0.638 / 0.613 | **0.633** | 0.625 / 0.632 / 0.640 | **0.632** | −0.2% |

The whole-town gate run on the baseline tree (1800 ticks) reported worst colony Lua
0.815 ms/tick (working town), 0.635 ms/tick (demand) — **PASS** under the 1.0 ms budget,
so #54 is not currently failing. The differences above are inside run-to-run noise
(the Colony script column itself varies ±0.012 ms/tick across identical runs).

## Gates run on the optimized tree before reverting
- `scripts/test.sh`: 418 passed, 0 failed (baseline 409 + 9 new equivalence cases)
- `scripts/lint-determinism.sh`: determinism lint ok
- `scripts/typecheck.sh`: Diagnosis completed, no problems found
- `luajit -bl` on `haul_plan.lua` + the new test: OK
- `scripts/determinism.sh`: checksum **2960604716**, DETERMINISM: PASS, m1_colony 116/116
- `scripts/save-load.sh`: SAVE/LOAD: PASS

## Why the payoff was small
`haul_plan.match` is already called on a per-evaluation cadence, and the comparators' two
extra `math.sqrt` calls per comparison are dwarfed by the table construction and the global
candidate sort. Hoisting the distances removed work but did not change the algorithmic cost.
This confirms the planner's fallback condition: re-attribute on the current working-town save
before committing to another micro-optimisation.

## Retained test
`tests/haul_plan_equiv_test.lua` copies the pre-refactor `match` as an oracle and compares the
winning task signature across 9 scenarios: exact distance ties (both insertion orders),
near-equal float distances, nil hauler position, `.entity.position`/origin fallbacks,
storage-priority interactions, shared provider/storage tables, rank tie-breaks, collect/compost
candidates, and a multi-requester global sort. This is a definition of correctness for any
future attempt at the same refactor; it is not a performance test.
