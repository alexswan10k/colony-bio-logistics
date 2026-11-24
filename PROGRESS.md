# PROGRESS

Running log of completed slices, newest first. One line per slice: what it is, the issue, the
commit, and the headline fact a future reader shouldn't have to re-derive. Detailed decisions
live on the GitHub issue and in `AGENTS.md`.

## 2026-11-17 — #58 Command Whistle (RTS orders, first slice)

A selection-tool whistle plus right-click/X custom inputs issue leased Move / Attack / Attack-Move orders; the
lease parks the unit in `commanded` (protected from `work.assign` and the alarm sweep) and hands it back on
completion, expiry or nightfall. `model/command.lua` is pure; per-player selection/markers/lease ownership live
in `storage.command` (schema 38) with disconnect cleanup. `s18_command` (18 checks) proved the engine facts: no
`attack_move` (use `attack_area` = 5), unit groups suppress per-unit completion, `set_multi_command` wants a
destination, and 200 `set_command`s cost 0.24 ms. Determinism re-baselined to **328728317** (new prototypes,
behaviour unchanged); 465 unit tests, m1_colony 116/116, m1_tech 13/13, save/load PASS.

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

## 2026-11-22 — #48 complete: Theatres and Scenic Plazas (schema 45)

The research-speed half landed earlier; this closes the last two buildings on the issue. A worker-free,
consumable-free 3x3 Theatre inspires houses within 16 tiles at quality 1.5 (work 480→320, research beats
Tavern rate for the same scholar cohort); a 1x1 Scenic Plaza adds +0.2 scenic each inside the hall's
40-tile sample, capped at +0.4. Both unlock on the existing Recreation tech, with new art. The plaza term
is added after the existing scenic sum so untouched towns are bit-identical.

581 unit tests, 25-check `m2_recreation`, 19-check `m1_tavern`, 13-check `s20_inspired_research`,
19-check `m1_desirability`, 116-check `m1_colony`, save/load PASS on schema 45, determinism checksum
4237111034 (moved from 3759486083 on the new prototypes; existing-town behaviour unchanged),
bench 0.612 ms/tick PASS, typecheck clean. An adversarial review caught two defects the green gates
missed — a wrapper around the advice facts (all new tooltips said "idle") and max-instead-of-average
quality in mixed Tavern/Theatre research — both fixed and pinned.

## 2026-11-23 — M4 first slice: Swamp Fever and spore emissions (#70 remainder)

On a Gleba/spore surface, on-duty colonists can catch Swamp Fever (4% at full exposure, fatal after
24 untreated evaluations, Clinic-curable). Spore pollution no longer masquerades as Smoker's Lung,
children/idle/sheltered/travelers are explicitly excluded, and mining no longer emits unmodelled spores
on spore surfaces. A real Gleba-fruit Smokehouse trip emits 15 spores (2-arg `surface.pollute`) — the
mod has no yumako trees or Nauvis forage patches on Gleba, so the chop/forage emission path alone was dead.

No prototypes, no schema bump: schema stays 45 and the determinism checksum stays 4237111034.
589 unit tests, 15-check `s21_gleba_spores` engine probe, 34-check `m4_swamp_fever` (natural catch and
natural emission with a Nauvis control), 12-check `m1_illness`, 27-check `s17_gleba`, 17-check `m2_gleba`,
116-check `m1_colony`, save/load PASS, bench 0.636 ms/tick PASS, typecheck clean.

## 2026-11-24 — #63 spike-first: Habitat Dome engine facts

`s22_dome` (23 checks, 91 probes) found a blocker: our housing clones inherit a vanilla chest surface
condition `gravity >= 0.1`, while a space platform has gravity 0, so no colony building can currently be
placed on platform foundation. Domes need an explicit `surface_conditions` override. All four planets
create associated surfaces headlessly and have no build gate for our housing; `surface.platform` is the
platform test, off-Gleba pollutant is nil, and there is no script-readable temperature/oxygen API.
The O(1) chunk index in the design doc was deleted in schema 19, and the issue/design doc disagree on
Tier 4 vs Tier 5. Outcome recorded on #63; no game code changed pending an owner decision on scope.

## 2026-11-24 — #63 complete: full Habitat Dome

Owner decisions: Tier 5 (Apartment stays Tier 4), extend the radius scan (no O(1) chunk index), all in one pass.
A 4x4 Habitat Dome is both a 32-bed house and a 64-tile territory emitter. `colony.hall` is now the colony's
"core entity" alias: a dome can found a colony on Vulcanus/Fulgora/Aquilo or a platform where a Town Hall is
refused, and all stock/force/surface/messaging paths keep working. The only platform-build fix needed is
clearing the inherited `gravity >= 0.1` surface condition on the dome prototype; players must grow the starter
platform deck with foundation tiles first. Second domes extend beds/territory; core death promotes the
lowest-unit-number live dome on the same surface and force.

605 unit tests, 25-check `s24_dome_platform`, 54-check `m4_dome`, 8-check `s23_dome_build`,
23-check `s22_dome`, 13-check `m1_tech`, 34-check `m1_blueprint`, 116-check `m1_colony`, save/load with a
persisted dome-founded colony, determinism 1398514768 (prototype hash move), bench 0.562 ms/tick,
typecheck/lint/package all green. Adversarial review fixed three lifecycle bugs (missing `hall_un` on
hall-founded towns, a sink-dependent force guard, and a clobbered housing tooltip).

## Next

- M4 follow-ups: #64 Enviro-Suits, #65 Nurseries, #66 cryo pods, #67 orbital domes, #68 EVA, #69 tech tiers, #70 other planets.
- Residual #63 scope: other buildings on platforms, platform construction-robot/player-walk proof, luxury upkeep.
- M4 continues: #63 Habitat Domes (the keystone for hostile worlds), then #65/#66/#64/#67/#68.
- #70 stays open for Vulcanus / Fulgora / Aquilo integration.
- #54 M2 gate: playtest/balance and UPS/MP regression; in-game checklist lives on #85.
- #85 onboarding: tooltips, alerts, carry sprites, hall workshop.
- M4 per-planet slices (#63-#70) and tech tier 3/4 (#69).
