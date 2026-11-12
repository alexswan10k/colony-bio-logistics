# PROGRESS

Running log of completed slices, newest first. One line per slice: what it is, the issue, the
commit, and the headline fact a future reader shouldn't have to re-derive. Detailed decisions
live on the GitHub issue and in `AGENTS.md`.

## 2026-11-12 — #46 geographic specialisation scoring (land-based hut composition)

Worker-free town specialty. Each type (coast / fertile / forest / industrial) is scored 0..1 from
the *hut composition the player placed* (docks/fuel pans -> coast; farm huts -> fertile;
woodcutters/foresters/hunters -> forest; 3+ miner huts -> industrial), a tie yields nothing (#46
is a claim, not a forced identity). A claimed specialty adds **one extra item per matching
work trip** — fishing, wood, ore, harvest. Land that is only grass scores fertile 1.0 and would
beat everything, so scoring from terrain directly produced "fertile everywhere"; counting what
the player built near the terrain is the faithful reading of the issue and ties are honest.
Spike `m2_specialization` (13 checks) claims all four towns. Commit `m2_specialization` (hash).

## 2026-11-12 — #96 Water tower (pipes half) + Townhouse

Two halves of #96 (playtest note: brick-and-metal housing between Homestead and Apartment,
plus pipes). Townhouse is Tier 3 (12 colonists, 3x3 box, wood-free, `colony-town-life` tech,
before concrete). The pipes half landed as a **Water Tower** instead of per-house plumbing:
worker-free assembling machine with a fixed `colony-water-bottling` recipe, 100 fluid water ->
10 colony-water, fed by vanilla pipes from an offshore pump. Houses whose water isn't met and
with a tower within 24 tiles drink straight from it at evaluation time, nearest tower first —
Tavern-shaped rule, no hauler trips, no fluid boxes on houses. `m2_tower` 14/14.

## 2026-11-12 — #45 Cold chain (late food)

Cannery (preservation into cans, iron tin + water -> 4 h shelf life), Refrigerated Warehouse (3x3,
a new crate kind `refrigerator`), Refrigerated Wagon (cargo-wagon clone, cold on rails). `LuaItemStack.spoil_percent`
is the one engine lever — write down to 0 to revive a near-spoiled stack (`spoil_tick` is read-write
but the engine refuses extending it). `s15_spoil` 13/13 decided it. `m2_cold` 24/24.

## 2026-11-12 — #98 preserved Frontier Charters: recipe variants, not a new item

Renamed the preserved-pack recipes, added `recipe-description`, and added `tech_audit` rule 7 so
the tech tree can never again contain a buildable pack that nothing consumes.

## 2026-11-12 — #92 Colony Ledger

1x1 constant-combinator clone the colony writes its own totals onto every 60 ticks; stock/shortfall
modes; up to 40 item signals; stale slots cleared; `s14_circuit` proved the 2.1 section API
(`parameters` is gone; the wire reads a filter's `min`; `LuaWireConnector` methods are bound, not
colon-methods). `m2_ledger` 46/46.

## 2026-11-12 — #97 Forester's Hut

The forest replants itself: woodcutters were a one-way drain. One wood out of the hut's own chest
per tree; planted tree is worth 4 wood to the next woodcutter. `m1_forest` 38/38.

## 2026-11-12 — #98 / #96 / #45 / #92 / #97 pushed, all gates green

383 unit tests (incl. locale audit), `m1_colony` 116/116, `m2_cold` 24/24, `s14_circuit` 31/31,
`m1_tech` 13/13, save/load round-trip schema 37, determinism checksum 2304208958 (m1_colony,
19500 ticks), `lint-determinism` ok.

## Next

- #48 remainder: Scenic Appeal score + Theatres + Inspired buff research-speed half.
- #52 install: crate-pair Freight Link — blocked on design choice recorded on the issue.
- #54 M2 gate, blocked on quiet re-baseline of #22 UPS bench; in-game checklist lives on #85.
- #51 tourism economy, blocked on decision needed on #21.
