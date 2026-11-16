# PLAN — Docs & Issue Hygiene

Read-only plan. Worktree: `docs-hygiene` (branch `agent/docs-hygiene`, clean tree). No code/docs changed, no issue comments posted, no heavy harness run.

Evidence sources (all read, not inferred):
- Code: `mod/scripts/model/{specialization,recreation,garrison,commute,motor,scenic,alarm,labour,yields,milestones}.lua`, `mod/prototypes/technology.lua`, `mod/scripts/store.lua`, `mod/scripts/spike/*`.
- Tests/docs: `tests/*_test.lua` + `tests/runner.lua` (`it()` runner), `docs/TESTING.md`, `docs/factorio_colony_mod_design_document.md`, `AGENTS.md`.
- GitHub: `gh issue list/view` (bodies, comments, milestones, `gh api .../milestones?state=all`), `git log/show -S`.

## Baseline facts verified

| Fact | Verified value | Evidence |
|---|---|---|
| Unit tests | **409** | `grep -c '\bit(' tests/*_test.lua` = 10+43+15+4+320+17 = 409; matches final AGENTS Status line and #54 comment |
| Schema | **37** | `mod/scripts/store.lua:4 local SCHEMA = 37` |
| Determinism checksum (current) | **2960604716** | AGENTS Status line 44/45; issue #54 final comment (`409 unit tests ... checksum 2960604716`); `git log -S '2960604716'` → added in `38fe643` |
| Older checksum | **10495216** | still present in AGENTS Cold Chain narrative (line 19); `git log -S '10495216'` → added `ef2c3e8`, status occurrence replaced by `2304208958` in `c758750`, then by `2960604716` in `38fe643`; the narrative copy was never updated |
| Spike check counts | AGENTS numbers match `docs/TESTING.md` (m1_colony 116, m1_haul_dist 21, s13_science 13, m1_desirability 19, m1_blueprint 26, s12_wildlife 14, m1_motor 26, m1_tavern 19, m1_rail 17, m1_death 16, m1_shelter 14, m1_commute 15, m1_illness 12, m1_garrison 18, m1_forest 38, s14_circuit 31, m2_ledger 46, m2_specialization 13, m2_cold 24, m2_tower 14) | `docs/TESTING.md:24-123`; `m1_colony` also 116 `ctx.check` call sites and #54 comment "116/116". `docs/TESTING.md:24` says 114 for m1_colony — **stale, see Risks** |
| Milestones | M0 open 4/closed 18; **M1 closed 27/27 (#2)**; M2 open 6/closed 18; M3 open 7/closed 1; M4 open 9/closed 0 | `gh api .../milestones?state=all` |
| Tool uses | `yields.TOOL_USES = 30`, steel 45; `labour.TOOL_USES = yields.TOOL_USES` | `mod/scripts/model/yields.lua:30-31`, `labour.lua:62` |
| Milestones in code | `M.LIST` contains **only** `colony-settlement` (halls = 1) | `mod/scripts/model/milestones.lua:8-10` |

---

## 1. Issue disposition

### 1a. CLOSE — exact comment text to post

**#46 — Geographic specialization scoring** (M2). Landed in `b01e4b0`, audit fixes in `a3bd5d1`. Issue has no comments and no outcome recorded — violates the AGENTS.md rule "Spike/decision outcomes: record on the GitHub issue (comment + close)".

> Closed: geographic specialization landed in `b01e4b0` (audit fixes in `a3bd5d1`). `model/specialization.lua` scores each town on the **dominant hut cluster** — coast (fishing dock + salt pan), fertile (farm hut), forest (chop/forest/hunt huts), industrial (three mine huts) — and pays **+1 per matching work trip** (fish, wood, ore, farm harvest); ties claim nothing. The scan runs on the scenic cadence (every four evaluations) and costs one `pairs(colony.huts)`, with no per-tick tile sampling. A straight tile-coverage scan was trialled first and reverted: every vanilla grass field is "fertile" by any covering metric, so it handed the bonus to every town and decided nothing; the huts a player already chose are the discriminating signal. Evidence: `m2_specialization` 13/13, `colony.spec`/`colony.spec_parts` live views, `work.lua` adds the bonus inline, design doc §2.2, AGENTS.md Decisions. Recording the outcome and closing as done.

**#21 — Decision: Tourism & commuting economy** (M0). Decision already recorded in an owner comment; AGENTS.md says "Open decisions: #21 tourism (commuting is decided)". Decision issues in the M0 "Feasibility Spikes & Decisions" milestone are closed once decided.

> Closing as decided. The commuting half was recorded on this issue and built in `#50` (`569a2e8`): idle-only boarders (a job lock keeps a colonist home), an outpost wants `ceil(hut capacity / (1 - 0.35))` commuters less those already there, departure by day only, shift until nightfall / at most 12000 ticks, no wages or satisfaction, feeding from the Canteen then the outpost hall larder, a 7200-tick stranded walk-home, deaths attributed to the home colony, and beds held in `colony.away`. Evidence: `model/commute.lua` + `scripts/commute.lua`, 15-check `m1_commute`, design doc §6.1, AGENTS.md Decisions ("Commuter outposts (#50, rules decided on #21)"). **Tourism (Resorts/Cultural Insights) is explicitly not decided here and remains open on #51.** Per AGENTS.md, decision outcomes are recorded on the issue and the issue closed.

**#60 — Motor Pool + colonist-driven vehicles OR replacement** (M3). Hauling half landed in `972edc3`; vehicle spike decision (unit-as-driver, no teleport) recorded in comments. Owner's comment says "Remaining for this ticket: mechanized patrols (driver + gunner), which depend on #55/#57" — those are tracked by #55 (Armory/Militia job), #57 (patrol posts/nest-clearing) and #62 (M3 playtest). **This is the one judgment call — see Risks.**

> Closing the Motor Pool half: landed in `972edc3`. The `colony-truck` is a `unit` wearing the vanilla car sprite (2.5x speed, 100-item load) pathed like a colonist; a hauler with a full hand-load checks out the nearest pool within 48 tiles that has a car and fuel, claims both at checkout, and waits at the pool under a stop order while the truck delivers. Trips per fuel: solid fuel 6 / coal 2 / wood 1; the car returns to the pool and unspent trips stay in its `tank`; a destroyed truck loses its car. The vehicle-spike decision (unit-as-driver instead of `set_driver`, teleport, or per-tick `unit.teleport`) is already recorded on this issue. Evidence: `model/motor.lua`, `m1_motor` 26/26, schema 21 (`storage.trucks`, `colony.pools`), design doc §7.3, AGENTS.md Status. The remaining **Mechanized Patrols (driver + gunner)** are M3 militia work, already covered by #55, #57 and #62 — closing here so that scope is not double-counted; if the owner wants a dedicated ticket, retitle/reopen as "Mechanized Patrols" rather than re-opening the landed Motor Pool.

### 1b. KEEP OPEN (with reason — do not close)

- **#48 — Scenic Appeal / Recreation / Theatres / Inspired** (M2): **partial**. Taverns landed in `b99b2c4` (`model/recreation.lua`, `m1_tavern` 19/19), and the scenic score (`model/scenic.lua`) is implemented, but the owner's own issue comment records: "Still open here: Theatres, the research-speed half of Inspired, and the Scenic Appeal / plaza work." Design doc §6.3 likewise says Theatres and the research-speed half are still planned. Closing would drop real scope.
- **#56 — Watchtowers/Bunkers** (M3): **first slice only**. Garrison landed in `d27da3c` (weapon choice in `9a00a6f`), but issue comments explicitly leave open "the Armory as a building, ammunition logistics (rifles are a wear-cost abstraction, no ammo item yet), armour, the patrol-waypoint militia, and the tower's defensive bonus/shared structural protection", plus Outposts/Waystations as separate territory nodes. Weapon choice/magazine requests have since landed, but the Armory entity, turret ammo (#59) and defensive bonus remain.
- **#85 — Onboarding & feedback** (M2): code pass landed, but the issue's in-game verification checklist is unchecked (custom status on containers, alerts focus/clear, carry sprite offsets, workshop scope), so it is not fully verified. **Its body is stale**: it still lists the 5-step 4/8/12/16 milestone ladder as "Done" although `57486fa` collapsed it to the single Settlement milestone (AGENTS.md and design doc §8 agree). Needs a body edit by the owner, not a close.
- **#54 — M2 UPS/MP regression + playtest + balance** (M2): bench/UPS half landed (`38fe643`, PASS 0.566/0.596 ms per issue comment), playtest and balance still open.
- **#52** (M2): only the `s16_links` engine probe (18 checks) landed; the linking/resource-transfer feature itself is not built.
- **#51** (M2): tourism/Resorts/Cultural Insights — explicitly the deferred half of #21, not built.
- **#13** (M0): art pass landed (`8b3d31c`), owner comment: "Still open: the owner choice between placeholder-only for MVP vs commissioned/AI-generated art." Needs an owner decision, not a close.
- **#11** (M0): `s11_biters` inconclusive; owner comment: "The flee test and the evolution gates are still open, and #61 and #57 depend on them."
- **#4** (M0): `s04_platform` passes, but owner comment: "the EVA hazards (unit deletion when commands fail to path, moving-platform pathing) are still unverified in game, and M4 (#63, #64, #68) depends on them."
- All remaining M3/M4 issues (#55–#59, #62–#71) are unlanded or explicitly future work.

No **other** open issue is demonstrably landed: #52/#4/#11 have spikes/probes only, #13/#85 have owner decisions or verification pending.

---

## 2. Exact documentation edits

Apply with `edit` (unique substrings quoted). "Evidence" gives the read-only proof for each number.

### AGENTS.md

**A1 — remove the stale "needs a re-baseline" claim in Status (line 26).**
- Old: `so the harness is unusable under load - the #22 gate needs a quiet re-baseline, and #90/#93 only add cached work (one demand table per 30 ticks per colony, one recipe graph per 1800 ticks per force).`
- New: `so that FAIL was load noise, not a regression; the gate was re-baselined quiet on 2026-11-16 (see below) and now measures a working town as well as an idle one. #90/#93 only add cached work (one demand table per 30 ticks per colony, one recipe graph per 1800 ticks per force).`
- Evidence: issue #54 comment "quiet run ... 0.657 / 0.676 ... PASS" and "fresh gate ... working town 0.566 ... PASS"; AGENTS.md 2026-11-16 paragraphs.

**A2 — mark the Cold Chain checksum as historical (line 19, Cold Chain narrative).**
- Old: `Numbers: 383 tests (one pins canned food eaten last in housing.FOOD), m1_colony 116/116, save/load PASS on schema 37, determinism PASS (checksum 10495216).`
- New: `At the Cold Chain commit: 383 tests (one pins canned food eaten last in housing.FOOD), m1_colony 116/116, save/load PASS on schema 37, determinism PASS (checksum 10495216). Current figures are in Status: 409 tests, schema 37, checksum 2960604716.`
- Evidence: `git log -S '10495216'` shows it added in `ef2c3e8` and replaced in the Status line by `c758750`/`38fe643`, while this narrative copy was untouched; current `SCHEMA = 37` in `store.lua:4`; 409 `it()` calls in `tests/`; `2960604716` in Status and #54 comment.

**A3 — record the #21 decision and the obsolete milestone ladder (line 19 end).**
- Old: `Open decisions: #21 tourism (commuting is decided). #18 (housing) and #22 (perf budget) are decided and closed; the onboarding pass is tracked in #85 with an in-game checklist that feeds the #54 playtest.`
- New: `#21 is decided and closed (commuting rules recorded on the issue; tourism stays open on #51). #18 (housing) and #22 (perf budget) are decided and closed; the onboarding pass is tracked in #85 with an in-game checklist that feeds the #54 playtest - its 4/8/12/16 milestone-threshold item is obsolete (Settlement is the only scripted milestone now).`
- Evidence: #21 comment + `#51` open; `milestones.lua:8-10` `M.LIST` only `colony-settlement`; AGENTS.md Onboarding sentence ("the five-step 4/8/12/16-colonist ladder was tried and collapsed in 57486fa").

**A4 — replace the stale "Next focus" (line 26 end).**
- Old: `Next focus: the open M2 issues (#45-#54), plus the in-game checklist in #85 (milestone thresholds, tooltips, alerts) which feeds the #54 playtest.`
- New: `Next focus: #54 playtest/balance and UPS/MP regression, the in-game checklist in #85 (tooltips, alerts, carry sprites, workshop - the 4/8/12/16 milestone-threshold item is obsolete), #48's Theatres / research-speed Inspired / Scenic Appeal work, #51 tourism, and #52 cross-colony linking; then M3 defence (#55/#56/#57/#59).`
- Evidence: open M2 issues from `gh api`/`gh issue list` are exactly #85, #54, #52, #51, #48, #46; #45 (Cold Chain), #46, #47, #49, #50 are landed; #48 owner comment lists the remaining pieces; #85 body checklist; #54 comment says playtest/balance still open.

**A5 (optional accuracy) — scope of #56's remainder (line 26).**
- Old: `the Armory, ammo logistics and defensive bonus stay open on #56.`
- New: `the Armory entity, turret ammo logistics (#59), armour and the defensive bonus stay open on #56 (weapon choice and magazine/arrow requests already landed).`
- Evidence: #56 last comment "Still open on this issue: Armory entity, turret ammo logistics (#59), defensive bonus"; `garrison.ammo_wanted` requests `firearm-magazine` (target 5) and arrows (target 20), design doc §7.2.

### docs/factorio_colony_mod_design_document.md

**D1 — stale "Mining Camp milestone" for Cabins (§2.2, line 29).**
- Old: `* **Tier 1: Tent (1 colonist) and Cabin (6 colonists)**, available from the start (Tent) and the Mining Camp milestone (Cabin).`
- New (rendered with literal backticks around the file name): ``* **Tier 1: Tent (1 colonist) and Cabin (6 colonists)** — Tent from the start; Cabin unlocked by the **Permanent Housing** research tech (10 Frontier Charters, after Frontier Charter). There is no Mining Camp milestone any more: Settlement (build a hall) is the only scripted milestone (`model/milestones.lua`); the old 4/8/12/16 population ladder was removed.``
- Evidence: `milestones.lua:8-10` only `colony-settlement`; `technology.lua:63-66` `colony-permanent-housing` unlocks `colony-housing-cabin`; no "mining camp"/"mining milestone" string anywhere else in `mod/` or `docs/`.

**D2 — stale "Mining milestone" for Cemetery (§2.4, line 63).**
- Old: `The dead are buried in the colony's first **Cemetery** (2x2, 12 graves, unlocked with the Mining milestone) with a free plot;`
- New: `The dead are buried in the colony's first **Cemetery** (2x2, 12 graves, unlocked by the **colony-cemetery** research tech: 10 Frontier Charters, after Frontier Charter) with a free plot;`
- Evidence: `technology.lua:111-114`; same milestone evidence as D1.

**D3 — wrong tool-wear number (§7.2, line 310).**
- Old: ``(`labour.TOOL_USES` = 12)``
- New: ``(`labour.TOOL_USES` = 30, from `yields.TOOL_USES`; the steel tier is 45)``
- Evidence: `yields.lua:30-31` (`M.TOOL_USES = 30`, `M.STEEL_TOOL_USES = 45`); `labour.lua:62` (`M.TOOL_USES = yields.TOOL_USES`). The same `= 12` mistake exists in the #56 issue comment — optional issue-body fix, not part of these doc edits.

**D4 — stale #98 tracking reference / Civic Treatise status (§8, line 334).**
- Old: `5. **Known gap:** every tech still costs only Frontier Charters, so the Civic Treatise recipe has no consumer yet; #98 tracks the pack-economy cleanup.`
- New (literal backticks around the item name): ``5. **Known gap:** every tech still costs only Frontier Charters, so the distinct `colony-civic-pack` (Civic Treatise) recipe has no consumer yet. #98 is closed: it only renamed the preserved Frontier Charter *recipe variants*; the Civic Treatise item/recipe still exists and a genuine second pack tier is deferred to the M4 tree (#69).``
- Evidence: #98 is CLOSED with comment "Decision: option 1 now, option 2 deferred to the M4 tree (#69)"; every `tech(...)` in `technology.lua` uses `{"colony-frontier-pack"}`; `colony-civic-pack` item `buildings.lua:393-397`, recipe `489-496`, unlocked by `technology.lua:151`; #69 is open; AGENTS.md "#98 ... preserved pack recipes are recipe *variants* ... A genuine second pack tier is deferred to the M4 tree (#69)."

### Related, out of scope but worth noting (docs/TESTING.md)

- Line 24 says `m1_colony` is "114 checks" — current is **116** (116 `ctx.check` sites, AGENTS Status, #54 comment "116/116"). Should read 116.
- Line 108 says the Cold Chain tech's prereqs are "Food Preservation only" — `technology.lua:82` lists `colony-food-preservation`, `colony-water-infrastructure`, `steel-processing`, `electronics`. Should be corrected.
- Lines 78 (`m1_haul_station`, "22 checks"; 23 `ctx.check` sites found) and 132 (`m1_persist`, 25 checks) were **not** resolved from a recorded report — verify before editing (see Risks).

---

## 3. Milestone update

Current (verified via `gh api .../milestones?state=all`): M0 #1 open 4 / closed 18; M1 #2 **closed 27/27**; M2 #3 open 6 / closed 18; M3 #4 open 7 / closed 1; M4 #5 open 9 / closed 0.

After the three proposed closures (no other milestone moves):
- **M0**: closing #21 → **open 3 / closed 19** (remaining: #4, #11, #13).
- **M2**: closing #46 → **open 5 / closed 19** (remaining: #85, #54, #52, #51, #48).
- **M3**: closing #60 → **open 6 / closed 2** (remaining: #62, #59, #58, #57, #56, #55).
- **M1**: no change — already closed 27/27, matching AGENTS.md.
- **M4**: no change (9 open).

No milestone is complete after these changes; do not close any. AGENTS.md's "M1 core loop ... milestone complete: 27/27" is already accurate and should stay.

---

## 4. Risks / what I could not verify

1. **Determinism checksum not independently re-run.** Read-only mandate; `scripts/determinism.sh` runs two 19500-tick Factorio benchmarks (heavy). `2960604716` is taken from AGENTS.md Status, the #54 issue comment and `git log -S`; `spike-results/` is empty in this worktree, so no first-hand report was available. Implementer should run `scripts/determinism.sh` once before finalising A2; if the number differs, update both the Cold Chain note and Status.
2. **Spike check counts are recorded, not re-run.** They come from `docs/TESTING.md` and issue comments. `docs/TESTING.md:24` disagrees with the code/AGENTS/#54 on `m1_colony` (114 vs 116) — treat 116 as current and fix TESTING.md; do not "correct" AGENTS to 114. `m1_haul_station` (22 vs 23 sites) and `m1_persist` (25) were not reconciled to a report.
3. **#60 close is a scope judgment.** The owner's comment said mechanized patrols remained "for this ticket" but depended on #55/#57; #55/#57/#62 do cover patrols, militia and M3 playtest. If the owner disagrees, keep #60 open and retitle it "Mechanized Patrols (Driver + Gunner)" instead — do **not** close the landed Motor Pool work twice.
4. **#48 is genuinely partial**; Theatres, the research-speed half of Inspired and the Scenic/plaza work are absent in code. Do not close it to "clean up" M2.
5. **#21 close assumes decision issues close on decision** (AGENTS.md rule). If the owner uses it as a running index, keep it open but still post the decision comment; the doc edits A3/A4 stand either way.
6. **#85 issue body is stale** (5-step milestone ladder listed as Done) but this plan is not allowed to post comments or edit issue bodies. Flag to the owner; otherwise the in-game checklist will keep referring to removed milestones.
7. **Historical numbers remain in AGENTS.md** (375 / 383 / 408 tests, checksums `10495216` and `2304208958`, schemas 21–36 in per-feature narratives). A2 fixes the one active confusion; a broader "numbers in feature narratives are as-of their commit; Status is current" note could be added to the Status header if the owner wants, but I did not rewrite historical records.
8. `docs/TESTING.md:108` also misstates the Cold Chain prereqs (above) — it is a real inconsistency with `technology.lua:82`, but outside the two requested docs.
9. No code, docs, issues, or milestones were modified by this plan; the worktree remains clean.
