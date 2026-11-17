# IMPLEMENTATION — Gleba food slice (issue #70, M4)

Branch `agent/gleba-food`, rebased onto merged master `30a7a8f`. PLAN §0 (derive `colony.M.FOOD_ITEMS`
from `housing.FOOD`) was already applied on master — verified at `colony.lua:101-106` — so it was NOT re-applied.
No schema change (`SCHEMA` stays 37), no `store.lua` migration, no new building/job/tool/registry, no per-tick
scan, no runtime `require`, no vanilla prototype edits.

## 1. Spike-first findings — `s17_gleba` (actual numbers from Factorio 2.1.24 build)

Report: `spike-results/20261117-110703/s17_gleba.txt` — **27 PASS, 0 FAIL, 0 errors**.

### Spoil data (PLAN's wiki table was in *seconds*, not ticks — all five values were 60× too small)

| Item | PLAN "ticks" | **Actual `spoil_ticks`** | `spoil_result` |
|---|---|---|---|
| yumako | 3600 | **216000** | spoilage |
| jellynut | 3600 | **216000** | spoilage |
| bioflux | 7200 | **432000** | spoilage |
| yumako-mash | 180 | **10800** | spoilage |
| jelly | 240 | **14400** | spoilage |
| spoilage | — | **0** (never spoils) | — |

These are data-stage, `MAP_SEED`-independent. All five spoil into `spoilage`.

### Recipes and freshness (the anti-faucet decision)

- A mod recipe CAN consume perishable vanilla items and produce our own perishable item: the dev probe
  `yumako + colony-salt -> colony-test-gleba-jam` loaded and crafted in a powered `assembling-machine-2`.
  All four shipped jam recipes load, are `enabled = false`, and produce `colony-gleba-jam` (spoil_ticks
  **162000**, spoil_result spoilage).
- **Freshness inheritance is real and strong.** Input yumako stack set to `spoil_tick = now + 600`
  (~83% spoiled at insertion) produced output with **`spoil_percent = 0.99895679012346`**. The same recipe with
  product `always_fresh = true` produced **`spoil_percent = 0.00085802469135798`** — i.e. `always_fresh` is
  exactly the laundering faucet we must avoid. None of our products use it.
- `recipe.result_is_always_fresh` (the old design-doc §9.2 / `s05_pod` name) **does not exist**:
  `LuaRecipePrototype doesn't contain key result_is_always_fresh`. At runtime the real fields
  `product.always_fresh` / `product.reset_freshness_on_craft` read back as `nil` on `LuaRecipePrototype.products`
  (the data stage honours `always_fresh` — proven by the fresh-output probe — but does not expose it at runtime).
- **Decision:** no freshness gate in `work.lua` is needed for engine-crafted jam. The colony's Smokehouse path
  is Lua bookkeeping (`remove_item` + `st.carry`), so it does not invoke the engine recipe; the jam it creates
  is a fresh stack. Because the input can only be a reasonably fresh fruit in practice (spoiled fruit becomes
  `spoilage` on its own, and raw fruit is not a standing haul request), this is acceptable and is called out
  for the adversarial reviewer below.

### Cold chain, compost, spores

- `cold.pause_all()` restamped **both** a near-spoiled raw `yumako` stack and a near-spoiled
  `colony-gleba-jam` stack in a `colony-refrigerated-warehouse` to `spoil_percent = 0` (2 stacks restamped);
  a control iron chest stack stayed at `0.99999537037037`. `cold.lua` needed no change.
- `LuaItemStack.spoil()` on both yumako and jam yields an inventory stack named `spoilage`;
  `compost.batches(10) == 1`. No compost change.
- `prototypes.airborne_pollutant` ids on this build: **`pollution, spores`**. Nauvis surface
  `pollutant_type` = `pollution`. `s.pollute(pos, 10, "spores")` under pcall →
  **`ok=false err=Unknown entity name: spores`** (no pollution change). Spore emission / Swamp Fever is
  follow-up work, explicitly out of scope here.

## 2. File-by-file changes

| File | Change |
|---|---|
| `mod/scripts/model/gleba.lua` | **NEW** pure model: `PRODUCT`, `SALT`, `SALT_PER_BATCH = 1`, ordered `RAW` (yumako 2, jellynut 2, mash 1, jelly 1), `SHELF_TICKS = 162000` (documentation only), `recipe(stock) -> {raw, product, count}`, `wants()` (salt only, currently advisory). No Factorio globals. |
| `mod/scripts/model/preserve.lua` | Requires `gleba`; `M.recipe` tries meat/fish first, then falls back to `gleba.recipe`. `M.wants` unchanged. |
| `mod/scripts/model/housing.lua` | `{item = "colony-gleba-jam", per = 1}` inserted in `M.FOOD` after preserved meat, before bread. |
| `mod/scripts/model/labour.lua` | Smokehouse `keep` gains the four raw Gleba names (inputs must not be hauled back out). |
| `mod/scripts/work.lua` | Generic Smokehouse branch honours `recipe.count or preserve.RAW_PER_BATCH` when removing/counting the raw input (2 fruit vs 1 pulp); meat/fish are byte-identical. |
| `mod/prototypes/buildings.lua` | New `colony-gleba-jam` item (45 min spoil, stack 100, spoilage) + four disabled energy-8 recipes (2 yumako / 2 jellynut / 1 mash / 1 jelly + 1 salt). No `always_fresh`. |
| `mod/prototypes/technology.lua` | New `colony-gleba-cuisine` tech (20 frontier packs, time 15), four `unlock-recipe` effects. |
| `mod/graphics/icon-gleba-jam.png` | **NEW** 64px tinted reuse of `icon-preserved-fish.png` (stopgap art, per PLAN §5). |
| `mod/locale/en/locale.cfg` | item name/description, four recipe names, one shared recipe description, tech name/description. Locale audit passes. |
| `mod/prototypes/spikes.lua` | Dev-only probe items/recipes for freshness inheritance (`colony-test-gleba-jam[-fresh]`); loaded only under the existing spike-protos startup setting. |
| `mod/scripts/spike/s17_gleba.lua` | **NEW** engine-fact spike (§1). |
| `mod/scripts/spike/m2_gleba.lua` | **NEW** feature spike: tech gate, four raws kept, Smokehouse produces jam, flow counted. |
| `mod/scripts/spike/loader.lua` | Registers both new spikes. |
| `tests/model_test.lua` | 9 new unit tests (recipe order/counts, determinism, inedible raws, salt-only wants, Smokehouse fallback, food ordering/step/demand). One existing expectation updated for the new position in `housing.FOOD`. |
| `tests/glue_test.lua` | New test: jam counted in `M.FOOD_ITEMS`, raw fruit not; a jam-only hall has food 7. |
| `docs/SPIKES.md`, `docs/factorio_colony_mod_design_document.md` | Spike runbook rows; M4 Gleba-food design paragraph (Swamp Fever still open). |

## 3. Gate outputs (exact)

```
scripts/test.sh                  -> 450 passed, 0 failed          (was 441)
scripts/lint-determinism.sh      -> determinism lint ok
scripts/typecheck.sh             -> Diagnosis completed, no problems found
luajit -bl <each of 13 changed/new .lua> -> all OK
scripts/determinism.sh           -> DETERMINISM: PASS; final checksum: 2125884680
scripts/save-load.sh             -> SAVE/LOAD: PASS (schema 37)
scripts/headless-spike.sh s17_gleba -> 27 PASS, 0 FAIL, 0 errors
TICKS=19500 scripts/headless-spike.sh m2_gleba -> 11 PASS; jam production flow=25
scripts/headless-spike.sh m1_colony -> 116 PASS, 0 FAIL
scripts/headless-spike.sh m1_tech  -> 13 PASS, 0 FAIL
```

### Determinism checksum: moved 2960604716 -> 2125884680, and why

The two-run gate still PASSES (identical reports and checksum), so this is a changed baseline, not a desync.
PLAN §5 predicted no movement, but that prediction was wrong: Factorio's benchmark checksum includes the
**prototype table** (the map-create log prints `Prototype list checksum: ...`). Controlled isolation on this
same machine, with identical `MAP_SEED` and 19500 ticks:

| Build | Checksum |
|---|---|
| master baseline (all scripts + prototypes from master) | 2960604716 |
| master + **only** the `colony-gleba-jam` item prototype added | **2992295773** |
| all model/adapter changes + only the jam item prototype (recipes/tech/probes removed) | **2992295773** |
| full change set (item + 4 recipes + tech + dev probe protos) | **2125884680** |

So (a) adding a single prototype moves the checksum on its own, and (b) the model/adapter changes are exactly
behaviour-neutral — the same checksum with and without them once the prototype set is fixed. No `m1_colony`
check changed; no Gleba item is created or consumed in that save. New baseline: **2125884680**.

## 4. Deviations from PLAN.md (and why)

1. **Vanilla tech prereq changed.** PLAN said `{"colony-food-preservation", "agriculture"}`; `m1_tech` failed
   with `unmakeable-ingredient` because vanilla `agriculture` only unlocks `agricultural-tower` and
   `nutrients-from-spoilage` — `yumako-mash` and `jelly` come from `yumako-processing` / `jellynut-processing`,
   unlocked by the vanilla `yumako` / `jellynut` techs. Prereqs are now
   `{"colony-food-preservation", "yumako", "jellynut"}` (both transitively require `agriculture`); `m1_tech`
   is green. This is a *stronger* "you have reached and processed Gleba" gate, in the spirit of the plan.
2. **Bioflux recipe deferred.** PLAN §2/§3 list a fifth `colony-gleba-jam-bioflux` recipe but §6's
   "Recommended minimal first slice" and Q1 recommend deferring it. Followed the recommendation: four
   recipes ship; bioflux stays an industrial intermediate. `gleba.RAW` has no bioflux entry, and a unit test
   pins that it cannot be cured.
3. **`work.lua` does change.** PLAN claimed "work.lua needs no new branch". The four recipes have two
   different raw counts, so the generic Smokehouse branch now uses `recipe.count or preserve.RAW_PER_BATCH`
   for the `remove_item`/`stats.consumed` pair. Meat/fish are unaffected (no `count` field), and determinism
   confirms behaviour is unchanged.
4. **No freshness gate added.** PLAN's fallback was a `spoil_percent` gate in `work.lua` if laundering is
   possible. The spike proved the engine inherits freshness (~0.999 in, ~0.999 out), and none of our products
   set `always_fresh`, so the fallback is unnecessary. The colony's manual conversion is reviewed below.
5. **Checksum moved** (see §3) — PLAN predicted unchanged.
6. **Spikes.lua probe protos** were added to pin item 4/3 of the spike; they are dev-only (startup setting
   gated), like the existing pod probes. They are part of the reason the new baseline checksum differs.

## 5. What the adversarial reviewer should scrutinise

- **Freshness laundering via the colony path.** The Smokehouse does NOT run the engine recipe: `work.lua`
  calls `remove_item` and sets `st.carry = {{item = "colony-gleba-jam", count = 1}}`, so the jam that appears
  in the hut/hall is a brand-new, 0%-spoiled stack. The s17 result proves *engine* crafts cannot launder, but
  it does not cover this Lua path. Our mitigations are: raw fruit is never a standing haul request (it must be
  belted/insertered in, opt-in), fruit that reaches 100% spoilage becomes `spoilage` on its own and is
  composted, and the 2:1 + salt + worker cost. A reviewer could argue for an explicit adapter gate that reads
  the hut stack's `spoil_percent` before consuming, or that carries the input freshness into the output
  stack. Consider whether "ship fresh fruit in a refrigerated wagon, cure it on Nauvis" is intended (we think
  yes: cold chain is the purchased upgrade) versus "let near-spoiled fruit be refreshed" (we think physics
  already prevents it).
- **Food-chain balance.** `colony-gleba-jam` is 45 min, i.e. *shorter* than a whole yumako (1 h) and much
  shorter than bioflux (2 h); curing fruit is a shelf-life **downgrade** but a pulp upgrader (mash 3 min /
  jelly 4 min -> 45 min). Nutrition is `per = 1`, identical to every other food. Is 2 fruit -> 1 jam too
  lossy/expensive for Gleba outposts, or is 1 mash -> 1 jam too generous given mash is a vanilla biochamber
  output? Is eating jam *before* 60-min bread and 4-h cans right (we followed "eat what spoils first")?
- **`keep` vs `wants` interaction.** Raw fruit is in the Smokehouse's `keep` list (so haulers never remove it)
  but is deliberately absent from `preserve.wants` / `gleba.wants` (so no automatic import). A reviewer should
  check that a fruit-choked Smokehouse cannot starve the town of haulers or block other inputs, and that the
  new `keep` names do not affect ore/material priority ordering.
- **Tech interlock strength.** `agriculture` alone was insufficient; we now require both `yumako` and
  `jellynut`. Check that this does not make the slice unreachable for a player who only has one fruit chain,
  and that `m1_tech` rule 6 stays green for future Gleba recipes.
- **Prototype-checksum baseline.** Any follow-up adding/removing a prototype will move the checksum again;
  reviewers should re-run `scripts/determinism.sh` and update the recorded baseline rather than assume the
  old value.
