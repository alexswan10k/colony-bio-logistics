# IMPLEMENTATION — Docs & Issue Hygiene

Executed from worktree `docs-hygiene` (branch `agent/docs-hygiene`) against `PLAN.md`. No Lua or test code was touched. Every old string below was checked with `grep -F -c` and found **unique** in its file before editing.

## 1. Documentation edits (11 total)

### AGENTS.md (5)

**A1 — stale "needs a re-baseline" claim (Status).**
- old: `so the harness is unusable under load - the #22 gate needs a quiet re-baseline, and #90/#93 only add cached work (one demand table per 30 ticks per colony, one recipe graph per 1800 ticks per force).`
- new: `so that FAIL was load noise, not a regression; the gate was re-baselined quiet on 2026-11-16 (see below) and now measures a working town as well as an idle one. #90/#93 only add cached work (one demand table per 30 ticks per colony, one recipe graph per 1800 ticks per force).`

**A2 — mark the Cold Chain checksum as historical (Decisions narrative).**
- old: `Numbers: 383 tests (one pins canned food eaten last in housing.FOOD), m1_colony 116/116, save/load PASS on schema 37, determinism PASS (checksum 10495216).`
- new: `At the Cold Chain commit: 383 tests (one pins canned food eaten last in housing.FOOD), m1_colony 116/116, save/load PASS on schema 37, determinism PASS (checksum 10495216 - historical). Current figures are in Status: 409 tests, schema 37, checksum 2960604716 (current at the time of writing; re-run \`scripts/determinism.sh\` to confirm).`
- Per the implementer instruction, `10495216` is explicitly labelled **historical** and `2960604716` is kept but qualified as "current at the time of writing" with a re-run note — no new value was hard-coded. **A parallel agent is changing behaviour, so the live checksum may move; flag to owner.**

**A3 — #21 decision and obsolete milestone ladder (Decisions narrative).**
- old: `Open decisions: #21 tourism (commuting is decided). #18 (housing) and #22 (perf budget) are decided and closed; the onboarding pass is tracked in #85 with an in-game checklist that feeds the #54 playtest.`
- new: `#21 is decided and closed (commuting rules recorded on the issue; tourism stays open on #51). #18 (housing) and #22 (perf budget) are decided and closed; the onboarding pass is tracked in #85 with an in-game checklist that feeds the #54 playtest - its 4/8/12/16 milestone-threshold item is obsolete (Settlement is the only scripted milestone now).`

**A4 — replace stale "Next focus" (Status).**
- old: `Next focus: the open M2 issues (#45-#54), plus the in-game checklist in #85 (milestone thresholds, tooltips, alerts) which feeds the #54 playtest.`
- new: `Next focus: #54 playtest/balance and UPS/MP regression, the in-game checklist in #85 (tooltips, alerts, carry sprites, workshop - the 4/8/12/16 milestone-threshold item is obsolete), #48's Theatres / research-speed Inspired / Scenic Appeal work, #51 tourism, and #52 cross-colony linking; then M3 defence (#55/#56/#57/#59).`

**A5 — scope of #56's remainder (Status).**
- old: `the Armory, ammo logistics and defensive bonus stay open on #56.`
- new: `the Armory entity, turret ammo logistics (#59), armour and the defensive bonus stay open on #56 (weapon choice and magazine/arrow requests already landed).`

### docs/factorio_colony_mod_design_document.md (4)

**D1 — bogus Mining Camp milestone for Cabin (§2.2).**
- old: `* **Tier 1: Tent (1 colonist) and Cabin (6 colonists)**, available from the start (Tent) and the Mining Camp milestone (Cabin).`
- new: `* **Tier 1: Tent (1 colonist) and Cabin (6 colonists)** — Tent from the start; Cabin unlocked by the **Permanent Housing** research tech (10 Frontier Charters, after Frontier Charter). There is no Mining Camp milestone any more: Settlement (build a hall) is the only scripted milestone (\`model/milestones.lua\`); the old 4/8/12/16 population ladder was removed.`

**D2 — bogus Mining milestone for Cemetery (§2.4).**
- old: `The dead are buried in the colony's first **Cemetery** (2x2, 12 graves, unlocked with the Mining milestone) with a free plot;`
- new: `The dead are buried in the colony's first **Cemetery** (2x2, 12 graves, unlocked by the **colony-cemetery** research tech: 10 Frontier Charters, after Frontier Charter) with a free plot;`

**D3 — wrong tool-wear number (§7.2).**
- old: `(\`labour.TOOL_USES\` = 12)`
- new: `(\`labour.TOOL_USES\` = 30, from \`yields.TOOL_USES\`; the steel tier is 45)`

**D4 — stale #98 tracking reference (§8).**
- old: `5. **Known gap:** every tech still costs only Frontier Charters, so the Civic Treatise recipe has no consumer yet; #98 tracks the pack-economy cleanup.`
- new: `5. **Known gap:** every tech still costs only Frontier Charters, so the distinct \`colony-civic-pack\` (Civic Treatise) recipe has no consumer yet. #98 is closed: it only renamed the preserved Frontier Charter *recipe variants*; the Civic Treatise item/recipe still exists and a genuine second pack tier is deferred to the M4 tree (#69).`

### docs/TESTING.md (2)

**T1 — stale `m1_colony` check count (line 24).**
- old: `- \`TICKS=19500 scripts/headless-spike.sh m1_colony\` - the playable end-to-end scenario (114 checks, final checks at`
- new: `- \`TICKS=19500 scripts/headless-spike.sh m1_colony\` - the playable end-to-end scenario (116 checks, final checks at`

**T2 — wrong Cold Chain prereqs (line 108).**
- old: `Also checks the Cold Chain technology's prereqs (Food Preservation only), costs Frontier Charters and unlocks everything on research.`
- new: `Also checks the Cold Chain technology's prereqs (Food Preservation, Water Infrastructure, Steel Processing and Electronics), costs Frontier Charters and unlocks everything on research.`

## 2. Evidence actually checked (not just copied from PLAN.md)

- `grep -h -o '\bit(' tests/*_test.lua | wc -l` = **409**; `ctx.check(` sites in `m1_colony.lua` = **116** (supports Status and T1).
- `mod/scripts/model/yields.lua:30-31`: `M.TOOL_USES = 30`, `M.STEEL_TOOL_USES = 45`; `labour.lua:62-63` aliases them (supports D3).
- `mod/scripts/store.lua:4`: `local SCHEMA = 37` (supports A2).
- `mod/scripts/model/milestones.lua:8-10`: `M.LIST` contains only `colony-settlement` (supports A3/D1).
- `mod/prototypes/technology.lua`: `colony-permanent-housing` = 10 Frontier Charters after `colony-frontier-charter`, unlocks `colony-housing-cabin` (D1); `colony-cemetery` same cost/prereq (D2); `colony-cold-chain` prereqs `colony-food-preservation`, `colony-water-infrastructure`, `steel-processing`, `electronics` (T2); `colony-civic-pack` unlocked at line 151 (D4).
- GitHub: #98 CLOSED (comment: "Decision: option 1 now, option 2 deferred to the M4 tree (#69)") and #69 OPEN (D4); #21 owner comment records commuting rules and points tourism to #51 (A3); #56 last comment still lists "Armory entity, turret ammo logistics (#59), defensive bonus", and `garrison.ammo_wanted` requests firearm magazines (target 5) and arrows (target 20) (A5).
- Determinism checksum `2960604716` was **not** re-run: heavy harness and a parallel behaviour change. It remains the recorded value in Status and is qualified in the doc; see scrutiny note below.

## 3. Issue actions taken (exact comment text from PLAN.md)

- **#46** — posted the drafted "Closed: geographic specialization landed in `b01e4b0` …" evidence comment (comment `6927241531`) and **CLOSED** the issue. Verified state now `CLOSED`.
- **#21** — posted the drafted "Closing as decided. The commuting half … Tourism … remains open on #51" comment (comment `6927243698`) and **CLOSED** the issue. Verified state now `CLOSED`.
- **#60** — posted the drafted "Closing the Motor Pool half: landed in `972edc3` …" evidence comment (comment `6927245927`) but **deliberately did NOT close** it, per the implementer instruction (scope is a judgment call). Verified state still `OPEN`.

No comments or closes on any other issue. Verified #48 and #56 are still `OPEN`.

## 4. Deliberately left open / not done

- **#60 stays OPEN** for the owner: the drafted comment opens with "Closing the Motor Pool half … closing here so that scope is not double-counted", but the issue was intentionally left open. Owner should decide whether to retitle it "Mechanized Patrols (Driver + Gunner)", close it, or leave the wording as-is. (This mismatch is a direct consequence of the instruction to quote the plan's comment verbatim while not closing.)
- **#48, #56, #54, #52, #51, #85, #13, #11, #4 and all other issues** untouched — partial scope or owner decisions pending.
- **#85 issue body is stale** (still lists the removed 5-step 4/8/12/16 milestone ladder as "Done"). PLAN.md records this; it needs an owner body edit, not a close. Flagged here for the owner.
- No milestone was closed or otherwise changed.
- No Lua/test code changed; no harnesses (`test.sh`, `determinism.sh`, etc.) run — static evidence only.
- Historical numbers elsewhere in AGENTS.md feature narratives (375/383/408 tests, `2304208958`, schemas 21–36) were deliberately left as as-of-commit records, per PLAN.md Risk 7.

## 5. What the reviewer should scrutinise

1. **Checksum caveat (highest priority).** `2960604716` is kept as "current at the time of writing"; a parallel agent may change the deterministic behaviour and therefore the checksum. Owner must re-run `scripts/determinism.sh` and, if it moved, update both the Status line and the new Cold Chain note. Do not treat my edited value as freshly verified.
2. **A1 bench claims** ("load noise, not a regression", "re-baselined quiet on 2026-11-16", "measures a working town") rest on the AGENTS.md 2026-11-16 paragraphs and the #54 issue comment, not a re-run. Re-check against recorded spike reports if available.
3. **#60 comment/state mismatch** described in §4 — confirm the owner is happy with an evidence comment that says "Closing" on an open issue.
4. **A4 "Next focus" list** assumes the open M2 set is exactly #85, #54, #52, #51, #48 (after closing #46). Confirm against a fresh `gh issue list` at review time.
5. **A5 armour scope**: I added "armour" to the open #56 scope from the PLAN.md wording; the #56 owner comment says only "Armory entity, turret ammo logistics (#59), defensive bonus". Confirm whether "armour" is a real tracked item or should be dropped from that sentence.
6. **TESTING.md line 78 (`m1_haul_station`, 22 checks) and line 132 (`m1_persist`, 25 checks)** were NOT reconciled to a report (PLAN.md Risk 2). Left untouched deliberately.
7. `git diff --check` was run and passed; all edits are documentation-only.
