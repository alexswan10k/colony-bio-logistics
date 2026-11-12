# Factorio Mod Design Document: Project "Bio-Logistics" (Working Title)

## 1. Vision & Core Pillars
A complementary overhaul/expansion mod for **Factorio 2.0 / Space Age** that introduces a RimWorld, *The Settlers*, and City-Builder inspired colony simulation layer.

* **Total Optionality:** Players can play 100% vanilla, 100% colony-driven (bypassing belts, inserters, and bots), or a hybrid of both.
* **Macro-First, Micro-Optional Control:** The default experience is semi-passive and high-level (expanding territory via Town Halls and Watchtowers, opting buildings into colony hauling, setting priority lists, and running commuter trains), with an optional RTS selection tool for direct control.
* **Parallel Resource Economy & Science:** Colonists run on biological/consumer needs (Food, Wood, Water, Medicine, Tools, Recreation) and drive their own dedicated **Colony Science** technology subtree.
* **Geographic Specialization & Commuting:** Pollution, terrain fertility, water access, and scenic beauty incentivize building specialized towns (Fishing Villages, Farming Valleys, Resort Towns) connected to polluted Industrial Outposts via **Passenger Commuter Trains**.
* **Interplanetary & Orbital Progression:** Expand from open-air frontier towns on Nauvis to sealed Habitat Domes on Vulcanus, Fulgora, and Aquilo, and ultimately build **self-sustaining Orbital Space Colonies** on Space Platforms.
* **UPS-First Architecture:** Non-destructive metadata tagging and C++ pathfinding/event hooks ensure hundreds of colonists run smoothly with zero regression to vanilla gameplay.

---

## 2. Colony Lifecycle: Housing, Territory & Population Growth

### 2.1 Territory & Boundaries (*The Settlers* / Roboport Model)
Colony boundaries work like a mix of **Factorio Roboports** and **The Settlers**:
* **The Town Hall (Colony Core):** Projects a large territory radius (e.g., $64 \times 64$ tiles) with a visible overlay when placing colony buildings.
* **Expanding Territory (Outposts & Watchtowers):** Building **Waystations / Outposts** or **Watchtowers** within or adjacent to your existing boundary extends the contiguous territory of that colony.
  * **M1 implementation:** the Town Hall claims a 3x3 chunk block. A **Watchtower** must be built on an already-claimed chunk and claims the 3x3 chunks around itself, so territory creeps outward one chunk ring at a time. Removing a watchtower re-derives the claim from the hall and the remaining towers, so no orphaned chunks are left behind. Watchtowers show their coverage as an alt-mode rectangle, and the Town Hall panel reports the chunk and watchtower counts.
* **How Territory Governs AI:**
  * Colonists automatically harvest resources (trees, ore), construct blueprints (`entity-ghost`), repair buildings, and haul items **only within their current territory**.
  * Distant industrial complexes, mines, or specialized towns have their own territory networks linked by **Colonist Car Routes** or **Passenger/Cargo Trains**.

### 2.2 Housing Tiers (Age of Empires Meets City Builder)
Houses must be placed within a colony's territory radius. They act as both the population cap increaser and the hub where colonists rest and consume goods.
Implemented tiers (`model/housing.lua`; each need is met by its first workable option, and haulers bring what the hall has):
* **Tier 1: Tent (1 colonist) and Cabin (6 colonists)**, available from the start (Tent) and the Mining Camp milestone (Cabin).
  * **Upkeep:** Food (forage, fish, meat, produce, then bread, with preserved food eaten last) + heat (wood; a Cabin also takes power).
  * **Tents are the bootstrap home, not a settlement type:** each tent drags desirability down (`w_tents`, stops growing at `tent_cap` = 8 tents), so a tent town plateaus and the player is pushed towards Cabins, then Homesteads.
* **Tier 2: Homestead (8 colonists, 3x3)**, unlocked by Water Infrastructure. Cabins upgrade into it.
  * **Upkeep:** Food + Water (`colony-water`, 0.5 per colonist per interval, from a Colony Well or bottling) + heat (power, coal or wood).
* **Tier 3: Apartment (16 colonists, 4x4)**, unlocked by Civic Governance.
  * **Upkeep:** Food + Water + mandatory electricity + Comfort (`colony-furniture`, 0.1 per colonist per interval).
* **Tier 4: Interplanetary Arcologies / Habitat Domes** (planned, #63): **capacity 32+**, required on hostile planets and orbital platforms; acts as both Housing and Territory Emitter.
  * **Upkeep:** Pressurized Air/Water + Multi-Planet Luxury Goods + Bioflux/Advanced Medicine.

### 2.3 Desirability, Migration & Natural Reproduction
Population grows through two mechanisms depending on the environment:

$$D = (W_{\text{food}} \cdot S_{\text{food}}) + (W_{\text{housing}} \cdot S_{\text{housing}}) + (W_{\text{scenic}} \cdot S_{\text{scenic}}) + (W_{\text{leisure}} \cdot S_{\text{leisure}}) + W_{\text{recreation}} \cdot S_{\text{recreation}} + W_{\text{jobs}} \cdot S_{\text{jobs}} + W_{\text{privacy}} \cdot S_{\text{privacy}} - W_{\text{tents}} \cdot \min(T, T_{\max}) - P_{\text{pollution}} - P_{\text{deaths}} - P_{\text{sickness}}$$

1. **Migration (the bootstrap mechanism, §2.3.1):** When your colony's **Desirability Rating ($D$)** is positive and housing is available, wild migrants periodically arrive at your Town Hall.
   * **Bootstrap pacing:** arrivals are brisk while the colony is small (below `BOOTSTRAP_SETTLERS` = 4 colonists, one per evaluation so a fresh hall fills), then five times slower (`next_migrant`, 5 evaluations between arrivals). The first settler at an empty hall arrives regardless of $D$. Migration is intentionally good at *starting out* and poor at growth beyond it; breeding is the long-term rate.
   * If $D$ drops into the negative (starvation, heavy factory pollution, frequent deaths), migration stops and existing colonists eventually pack up and leave.
   * **Leaving (implemented, #29):** below `leave_below` ($-0.10$) the newest arrivals start walking out, one per evaluation interval at minimum, rising with how far below the line $D$ has fallen and capped at `leave_rate` (10%) of the town per interval. A colonist that leaves returns whatever it was carrying to the Town Hall, frees its hut seat and its job lock, and is gone - it is not a death, so it does not feed the death penalty. The rule lives in `model/colony_model.leave_count` so the sim harness and the game agree.
   * **The inputs are real, not placeholders (implemented, #29/#47/#48/#88):**
     * *Food / housing / leisure* come from the evaluation loop (stock ratio, free beds, powered-house score).
     * *Scenic* (`model/scenic.lua`) is read from the world in a fixed 40-tile box around the Town Hall, once every 4 evaluations: tree cover (from one filtered find), water tiles and paving on a 1-in-16 tile sample. A forest scores full marks at 35% tree cover, a lake at 15% water, and paving subtracts up to 0.6 - so the player's own concrete works against them, which is the point.
     * *Pollution* is `surface.get_pollution` at the Town Hall, normalised against 300 units (`MINE_POLLUTION` is 2 per mining trip, so a concentrated mining outpost is felt while a clean town is not).
     * *Recreation* is the share of the town served by a stocked Tavern (#48); *Sickness* is the share that is ill (#47); *Jobs* is the number of unfilled hut slots (a big pull factor, so a town with work to offer grows); *Privacy* is the share of houses that are empty or single-occupancy (houses are most desirable empty or with one resident); *Tents* penalises tent count (see §2.2).
2. **Natural Reproduction / Breeding (implemented, #88):** An opposite-sex pair of adults in one house, with that house's critical provisions met and a free bed, can have a child. Children count toward occupancy, eat half portions, never receive jobs, and grow into adults after `CHILD_TICKS` (one in-game day). This is the long-term growth path that takes over once the colony is fed and housed properly; migration only bootstraps the colony.
   * **M/F colonists:** sex is assigned deterministically from the unit number, so no storage is required; the house panel marks each colonist with ♂/♀ or 🧒.
   * **Future (planned, #65):** a Nursery/Maternity building to raise fertility, and off-world colonies that cannot receive migrants at all.

### 2.4 Permanent Death, Illness & Hospitals
* **Permanent Death:** Combat and starvation are lethal ($0\text{ HP} = \text{permanent death}$). Every death applies a temporary stacking penalty ($P_{\text{deaths}}$) to Desirability.
  * **Implemented (#53):** every colonist death counts, whatever the cause: starvation, a train, a vehicle, enemies, fire, poison, acid, explosions (`model/mortality.cause` names the killer from `on_entity_died`). It is final, adds one entry to the death penalty (0.15, halving every 6 evaluations) and to the hall's "Dead" count, and is announced with a map link. The dead are buried in the colony's first **Cemetery** (2x2, 12 graves, unlocked with the Mining milestone) with a free plot; otherwise a **Grave** marker is left where they fell (walk-through, mine it to clear). A colony with a Cemetery mourns for half as long (half-life 3 evaluations). Riders aboard a Passenger Coach that is destroyed die with it and count against the colony they boarded from; a coach that is mined or deconstructed sets its riders back down at their own Town Hall.
* **Illness & Disease:**
  * Living or working in high-pollution chunks causes **Smoker's Lung**; eating near-spoiled food causes **Food Poisoning**; working on Gleba causes **Swamp Fever**.
  * Sick colonists work at $50\%$ speed and eventually die unless treated by a Doctor colonist at a **Clinic / Hospital** stocked with Herbal Medicine or Pharmaceuticals.
  * **Implemented (#47, decided on #20):**
    * **Diseases.** Smoker's Lung is caught from the colony's pollution (2% per colonist per evaluation at full pollution, linear below that). It never passes on its own and kills after 40 untreated evaluations. Food Poisoning is caught when a house eats food at least 75% spoiled (30% per occupant). It passes by itself after 4 evaluations. Swamp Fever waits for Gleba (#70).
    * **No contagion.** Rolls are a hash of unit number, tick and purpose, once per colony evaluation, so runs are deterministic with no stored generator.
    * **Effects.** A sick colonist works at half speed. The sick share of the town is a desirability penalty (`w_sickness` 0.3).
    * **Treatment.** A **Clinic** (2x2, Medicine tech) is a labour hut with the new **heal** job. Doctors go on duty while it holds Herbal Medicine (2 forage + 1 wood) and someone is sick. Each doctor on duty cures 2 patients per evaluation, longest-sick first, at 1 medicine each. Patients do not walk to the Clinic yet. Haulers keep 10 medicine there.
    * **Deaths.** Someone who dies of illness is struck off first and recorded through `mortality.record`, as a death from "illness".
    * **Known gap.** A train ride clears sickness, because the entity is destroyed on boarding.

---

## 3. Food Production & Space Age Spoilage

Targeting **Factorio: Space Age** allows us to use native `spoil_ticks` and `spoil_result` properties on all food items.

### 3.1 Production Tiers & Shelf Life
1. **Early Game (Foraging, Hunting & Fishing - Short Shelf Life):**
   * **Foraging Post, Hunting Lodge & Fishing Dock:** Harvest wild berries, game meat, and coastal fish.
   * **Natural forage patches:** Berries grow as world entities autoplaced on grass (they ride the vanilla vegetation/`trees` map-gen control, so density follows that slider). A Forager's Hut never spawns bushes: it harvests patches that already exist inside colony territory, and a picked patch grows back in place after $40\text{--}70$ seconds. Chunks generated before the patches existed are seeded once on load, so old saves behave like new ones ($\approx 3$ patches per $32 \times 32$ chunk).
   * **Spoilage:** Raw foods spoil quickly ($5\text{--}10\text{ minutes}$).

**M1 hunting slice (implemented, #79):** hunting is **real engine combat** - a hunter is given an `attack`
command and the engine does the chasing, the shooting and the kill - but the colony stays a non-combat faction
by putting the game on its **own force**. `colony-wildlife` is at cease-fire with `player`, `enemy` and
`neutral`, so nothing shoots a boar except a hunter, biters ignore it, and turrets have no reason to spend
ammo on dinner. The **Hunting Lodge** (3 hunters, one **bow** by default and any better gun the stock room
holds, 30-tile radius, must be built inside
territory) sends a hunter at the nearest live **Wild boar** inside the territory, claims it (by unit number,
because it moves), and commands an attack. The colonist prototype carries a ranged *hitscan* attack (14 tiles,
no projectile entity to spawn, no shot that can miss a moving animal) - `vision_distance` stays at 1, so a
colonist still never picks a fight on its own; the gun only matters when a hunter is told to use it. A kill
drops 6 **Wild game meat** (spoils in 20 min) which the hunter carries back to the lodge; the meat is credited
from `on_entity_died`'s `ev.cause`, so the hut that employed the hunter is the hut that gets fed. Game is
**docile by design**: it wanders (`defines.command.wander`), never retaliates, and is deliberately not
dangerous - the interesting ramification (aggro, defence, hunters as soldiers) is left for the combat slice,
which can flip the force relationship without touching the lodge. The herd is capped (`wildlife.CAP` = 12 per
colony, `PER_CHUNK` = 0.5, one spawn per evaluation), so hunting never becomes a source of unbounded entities.
**M1 fishing slice (implemented, #80):** the **Fishing Dock** is the first building whose *placement* is a real
decision. It must be built inside territory and beside water: the rule is **six water tiles within a 15-tile
box**, sampled once at build time (`model/fishing.lua` drives the scan, the adapter supplies the tile probe),
and a dock that fails is **refused and refunded with a flying text** saying so - it is never a silently dead
building. Any tile that collides with the `water_tile` layer counts, so ponds and lakes on any planet work and
lava does not. The scan visits tiles outward from the dock and stops as soon as the answer is known, so a dock
in the right place costs a handful of tile reads and only a doomed placement pays for the whole box. Fishers
(3 per dock, one **rod** each, delivered from the Hall, wearing per trip) walk to the dock and fish for the
standard work period, landing **5 raw fish** per trip - deliberately better than the 4 forage gives, because
water access is earned. Fish is food with the shortest shelf life in the tier (15 minutes, spoiling into
spoilage, which the Compost Bin already handles), and it lands in the dock and is hauled inward like every
other hut output (#72).
**M1 salt + preserved tier (implemented, #81):** salt is a *geography* problem, not a mining one. The **Salt
Pan** uses the Fishing Dock's shore rule (six water tiles in a 15-tile box, checked once at build time,
refused-and-refunded otherwise) and **nobody works it**: it evaporates one salt per 30 s up to a pan of 8, and
a hauler empties it into colony stock like any other provider. The **Smokehouse** is the first hut with **no
tool**: its gate is *supply*, because curing needs salt and something to cure, not equipment. `labour.HUTS`
leaves `tool` out, `hut_info` reports capacity as the allowance, the job refuses to start (and reports
`no_site`) when the hut holds no salt or no raw food, and the hut asks for its inputs through a normal haul
request at `request` priority - below the houses' `critical` food need, so a smokehouse can never eat the
town's dinner. Its `keep` list marks salt and raw meat/fish as *inputs*, so haulers do not treat them as hut
output and cart them straight back. One raw + one salt cures into one preserved item with **~3x the shelf life
(45 min vs 15-20)** and the same nutrition: the payoff of this tier is shelf life, not throughput (#81), and
keeping every food option at `per = 1` also keeps housing's demand sizing honest. Preserved food is **eaten
last** in `housing.FOOD`, because it is the food that keeps.

2. **Mid Game (Agriculture & Salt/Smoke Preservation - Medium Shelf Life):**
   * **Farms / Greenhouses:** Require water, seeds, and fertilizer (yielding $2\times$ crops when built on lush/fertile soil tiles).
   * **Kitchens & Smokehouses:** Combine raw meat/fish with **Salt** (from coastal Salt Pans) or Wood Smoke, or bake grain into Bread, increasing nutrition $4\times$ and extending shelf life to $30\text{--}60\text{ minutes}$.
3. **Late Game (Industrial Canning & Cold Chain - Long Shelf Life):**
   * **Canneries:** Seal food with Steel/Iron Plates into **Canned Rations** ($3+\text{ hours}$ shelf life).
   * **Refrigerated Warehouses & Wagons:** Powered storage that drastically slows spoilage.

**M1 farming slice (implemented, first pass of #44):** the player places **Farm plots** (1x1, 4 per wood recipe) on farmland inside colony territory; a **Farm Hut** (3 farmers, one **hoe** each, 30-tile radius) plants fallow plots, the crop ripens in 60 s, and a farmer harvests it into **Colony produce** (spoils in 30 min) and carries it to the Town Hall. Plots are free to plant and yield 8 produce at fertility 1.0; a plot planted with one **fertilizer** (from the Compost Bin, #78, hauled to the Farm Hut on request) yields double, 16. Fertilizer is spent when the plot is planted, not when it is harvested (`model/farm.lua`, #44). Vanilla 2.0 exposes no per-tile fertility (spike s06), so `model/farm.lua` maps tile names to fertility: grass 1.0, dirt 0.85, dry dirt 0.5, red desert 0.45, sand 0.25, landfill 0.6. Below 0.35 a plot cannot be placed, and water/paving cannot be farmed, so poor soil visibly yields less - the first hook for geographic specialization.

**M2 farming slice (implemented, #44):** Fertilizer consumer + Colony Kitchens + Bread. Haulers deliver fertilizer from Compost Bins/stock to the Farm Hut on request-priority haul offers; farmers spend 1 fertilizer per fallow plot planted, boosting harvest yield $2\times$ (16 produce at 1.0 fertility). Colony Kitchens (2 cooks, supply-gated, no tool) combine 1 colony produce + 1 colony water (from well/bottling) into 1 Colony Bread (60 min shelf life), eaten last alongside preserved fish/meat. Farm Hut GUI displays plot breakdown (fallow, growing, ripe, fertilized) and local fertilizer stock.

### 3.2 Dealing with Spoilage (The Closed Loop)
* Expired food turns into native `spoilage`, which colonists automatically clear out of houses and haul to **Compost Bins** to turn into **Fertilizer** for planetary or orbital farms.

**M1 implementation (#78) & M2 closure (#44):** spoilage is not just cosmetic - it is the failure mode of the whole food chain. A house whose inventory fills with garbage cannot accept food, so it starves its occupants while the Town Hall is stocked. Colonists therefore clear it out on two paths: **for free on a delivery** (a hauler standing in a house takes the spoilage away with it instead of walking home empty) and as the **lowest-priority haul band** (`compost`, below buffering, because nothing is waiting on it but the food slots it blocks) for spoilage sitting in colony stock. Both end at a **Compost Bin** (1x1, 12 slots, must be inside territory like every colony building), which converts whole batches of ten into **Colony Fertilizer** on a 10 s pass - batches, not a per-tick reaction, and the remainder waits in the bin. Fertilizer is carried back into colony stock like any other output; in #44, haulers bring it to Farm Huts to be spent on fallow plots for the $2\times$ yield boost, completing the agricultural loop.

---

## 4. Agent Behavior, Explicit Tools & Priority System

### 4.1 Job Types
Players configure a per-colony **Priority Matrix** (ranked $1$ to $4$, or disabled) for colonist roles:
1. **Guard / Militia:** Patrol designated areas, man Watchtowers, and respond to enemy threats.
2. **Doctor:** Tend to sick colonists in Clinics/Hospitals.
3. **Construct & Repair:** Deliver materials to `entity-ghost` blueprints within territory, construct them, and repair damaged buildings/walls.
4. **Haul (Logistics):** Move items between Colony Crates and opted-in machines, including **hand-feeding ammo into Gun Turrets** and fuel into burner machines.
5. **Harvest / Mine / Chop:** Mine ore patches, chop trees, fish, or tend farms within territory.

**M1 behaviour (implemented):** the Town Hall panel exposes the matrix for the live roles (haul, forage, chop, mine, farm, hunt, fish, preserve; rank 1\u20134, 0 = off). Jobs sharing a rank form one priority group and split the workforce by the food ratio, so the default (`haul 1`, harvest roles `2`) behaves like the old rule set. The planner (1) keeps roughly 30% of the colony hauling while hauling is enabled and there is haul work (at least one colonist), (2) takes the best-ranked enabled harvest role with a free tooled slot, and (3) splits a group by the food ratio, shifting toward foraging when stocks are below target. Harvest sites are chosen nearest-first inside territory, so colonists visibly work the forest or patch beside their hut. A Miner's Hut additionally carries a per-ore priority (iron/copper/coal/stone, rank 1–4, 0 = off): the hut works the best-ranked ore that is in range and only falls back to distance between ores sharing a rank, so it no longer walks past iron to grab the closest stone.

**Construction & repair (implemented, #37):** builders honour the matrix like any other role but are capped at 25% of the population (`model/construct.lua`), so a blueprint never costs the town its dinner. Every 5 s each colony re-scans its claimed area once (a player blueprint fires no build event) and keeps a small registry of `entity-ghost`s and of damaged colony buildings; assignment reads that registry, never the surface. A ghost's price is its `ghost_prototype.items_to_place_this`, paid out of colony stock up front and carried by the builder, who then revives it; if the site refuses to revive the materials come back and the ghost is skipped for a minute - unless the only thing in the way is the builder itself standing on the footprint, in which case it steps aside and tries again (a unit blocks `revive`, #76). Repairs run before builds and consume one `repair-pack` per 200 health, so repair packs are a logistics input like tools. Ghosts outside territory are ignored.

**Player control over allocation (implemented):** the Town Hall panel carries an **accept-migrants** toggle and a **population target** (migration stops at that population even when desirability is high), plus aggregate job counts. Individual assignment lives on **each house**: the house panel lists that house's occupants (filled in house order, so the counts always agree) and each colonist can be locked to one role (`A` = follow the matrix). A locked colonist ignores the matrix and idles when its role has no free tooled slot. This keeps the panel usable when a town has hundreds of colonists; a town-wide quota/squad view is the planned long-term replacement for per-colonist lists (#73). Each labour hut has its own **worker limit** (0 pauses the hut), so a hut only takes as many colonists as the player wants, up to its tools and capacity. Opening a hut panel draws its working radius in the world, matching the Town Hall's territory rectangle.

**Haul priority (implemented in `model/haul_plan.lua`):** unmet critical need (food/heat) $\rightarrow$ tools for huts $\rightarrow$ collecting a hut's finished goods $\rightarrow$ explicit machine and demand-crate requests $\rightarrow$ collecting machine output and supply crates $\rightarrow$ buffering a well-stocked house. One trip serves one destination but may carry several item types at once (e.g. iron ore **and** fuel for a furnace), with the carry cap split across the destination's demands, so a multi-input machine is never starved one ingredient at a time. House buffers are sized by occupants, so empty houses do not hoard supplies. Harvest yield is deposited in the **worker's hut** rather than the Town Hall, so a worker never walks every load home; a hauler clears the hut's output inward.

**Material caps (implemented, #84; default 20 + sink exception, #54):** the Town Hall ledger lists the produced intermediates the colony moves (iron/copper/steel plate, gears, stone brick, concrete, circuits, plastic, solid fuel) next to the harvested resources, with the same `-`/`+` quota buttons. Their default is **20**, the sensible default matching harvested quotas, so a furnace town never produces plates to infinity with no sink. A cap is a *ceiling on collection*, not a target: `work.supply_capped` compares stock against `base + resource_demand`, so saturation stops haulers emptying opted-in machine output (backing up and stalling the machine via `m.capped`) unless downstream demand is the obvious sink that exits the system — an opted-in machine eating the item raises the ceiling and haulers keep feeding it 1:1 while stock stays bounded. Setting the cap to **0 = unlimited** opts out explicitly.

**Transitive supply & demand (implemented, #90):** demand is a graph, not a flat count. `model/supply_graph.lua` walks the force's *unlocked* recipes upward from the seeds the colony already had — opted-in machine requests, demand-crate filters and hut inputs (e.g. the Town Archive's `colony-frontier-pack` x10) — keeping one recipe per product (the fewest ingredient types, ties by name), for `DEPTH = 4` floors at `DAMPING = 0.75` per floor. A pack request therefore raises plates, gears, cable and, two floors down, the ore itself, without the player setting a quota for every intermediate. Damping is deliberate: the colony already holds part of an intermediate (a plate in the hall is ore it does not need again), and it keeps a recipe that cycles through its own output bounded. `quota_target = base + demand` is otherwise unchanged, the result is rounded to whole items, and the demand table is merged with the directly requested amount rather than replacing it. The recipe map is derived data: it is rebuilt lazily per force (`GRAPH_TTL` 1800 ticks) and cached outside `storage`, so it needs no schema bump; the demand table is cached per colony for `DEMAND_TTL` 30 ticks and dropped by `set_quota`/`set_machine`, so the hot path is a table lookup. It answers "how much of this should the town want", never "what should be built" — this is a feedstock heuristic, not a production planner.

**Distance-aware picking (implemented, #93):** the band order above stays the first key; everything below is a tie-break inside a band. A hut is chosen least-staffed first, then nearest the colonist's house. Inside the hut, a harvest site is chosen by distance **band** (8 tiles) first, and the colonist's house only breaks ties inside the band (`model/sites.lua`) — the walk hut $\rightarrow$ site $\rightarrow$ hut dominates, so home proximity is a nudge towards compact towns, never a reason to cross the radius. A haul source is chosen by the route the hauler actually walks, `dist(hauler, src) + dist(src, dst)`, not by proximity to the destination, so a hauler does not walk past a full hut on its way to a marginally closer one. A hut's food already goes straight to a house that wants it (a direct hut $\rightarrow$ house transfer beats storage inside the same band), and the mean house-to-work walk feeds `w_commute = 0.05` into desirability (saturating at 48 tiles, workers only, so having no job is never a penalty).

**Machine opt-in (implemented):** ticking the supply box on a machine's panel, or dragging the **Colony logistics marker** selection tool over machines (alt-drag to opt out), registers the machine for colony hauling. Opted-in machines show a Town Hall badge in alt mode, so coverage is visible without opening each panel.

### 4.2 Explicit Tooling, 1:1 Mining & Pollution
* **The Bootstrap Loop:** The player starts by hand-crafting **Iron Axes** and **Iron Pickaxes** and placing them in the Town Hall or straight into the labour hut that needs them. There is no separate Tool Rack entity: **each labour hut is its own tool store** (implemented, #31 closed as superseded).
* **Job Gating & Durability:** Colonists must work at a hut that holds the right tool: an **Axe** to chop trees, a **Pickaxe** to mine ore, a **Hoe** to farm, a **Basket** to forage, or carry **Repair Packs** to repair. A hut holds up to `capacity` tools, only employs as many colonists as it holds tools for (further capped by its panel's worker limit), and wears one tool per `TOOL_USES` completed trips of its own work, with a popup when a tool breaks. A hut short of tools raises a **tools-priority** haul request, so the player never hand-delivers replacements; this is why wear lives on the hut, not on the colonist - the tool is the employment slot. Steel tier (implemented, #95): Woodcutter/Miner/Farm have a steel ladder (`colony-steel-axe/pickaxe/hoe`, 2 iron + 1 steel, 0 wood), unlocked by Steel Tools (30 frontier packs, after Logistics). Steel lasts 45 trips at 0.8x work ticks vs tier-1 30/1.0x, so upgraded huts use 0 wood per tool (wood/col-h 12.0 -> 0.0 in `sim/balance.lua` Q12) and shift demand to iron/steel. Hut wear follows the best tool present and consumes tier-1 first; the Toolsmith covers tier-1 before steel. Basket/rod stay single-tier; Tungsten/plasma tiers stay for #69.
* **1:1 Depletion & Pollution (Zero Electricity):** Mining depletes ore entities 1:1 (respecting Mining Productivity) and uses zero electricity, but emits localized **Pollution** via `surface.pollute()` so biters still evolve and react to colony industry.

---

## 5. Hybrid Logistics Architecture: Colony Crates & Non-Destructive Opt-In Machines

To let players seamlessly mix-and-match colonists with belts, inserters, and bots—without causing game-breaking regressions or scanning thousands of irrelevant entities—the logistics system uses a **two-pronged Hybrid Opt-In model**:

### 5.1 Colony Logistics Crates (First-Class Logistics Nodes)
Players can build dedicated colony containers that work just like early-game, biological versions of Logistic Bot chests:
* **Colony Supply Crate (Passive/Active Provider):** Colonists empty mined ore, lumber, or belt outputs from here.
* **Colony Demand Crate (Requester):** Players set item filters (using Factorio 2.0's native `logistic-container` filter UI or combinator signals); colonists haul matching items here so inserters can pull them into machines.
* **Colony Warehouse (Filtered Bulk Storage):** High-capacity buffer storage for town centers and train stations.

**M1 implementation (#33):** all three are plain containers, not logistic chests, so belts and inserters keep working on them and colony hauling stays deterministic (bots and colonists never race for the same slot). A **Supply Crate** is a provider: colonists empty it into colony stock at haul priority "collect", the same band as machine output. A **Demand Crate** is a requester: its panel takes up to four item filters with target counts and shows filled/target, and colonists fill it at machine-request priority. The **Warehouse** counts as colony stock: supply trips draw from the Town Hall first and fall back to warehouses, while deposits fill the Town Hall first and overflow into the warehouse. Warehouse-side filters are still open. Crate filters persist through blueprints and copy-paste (#36): see §5.2.

**Haul Station + Wooden Trailer (built, #94):** a 2x2 distributed-storage depot (20 wood + 10 stone, no power, Colony Logistics) that counts as colony storage like a Warehouse, with a Wooden Trailer rack (10 wood + 2 iron, Colony Logistics). A hauler within 48 tiles whose load is worth more than a hand-load (deficit > 20) checks a trailer out of the nearest station holding one, claims the trailer-sized load (60) at checkout, pulls it on foot at 0.6x walking speed, and returns the trailer at delivery. Trailers wear like tools and break after 30 trips. When a Motor Pool truck can dispatch, the truck still wins; the trailer is the cheap bulk option before the Motor Pool (#60). First slice: no explicit A->B pair routing, just distributed stock rooms plus the trailer depot.

### 5.2 Non-Destructive "Opt-In" Direct Machine Hauling
Colonists can also directly load ingredients/fuel into—and empty products from—any vanilla `assembling-machine`, `furnace`, `lab`, `boiler`, or `ammo-turret`, **strictly on an opt-in basis**:
* **How Opt-In Works (Zero Prototype Modification):**
  * We **never** overwrite or replace vanilla machine prototypes. Every vanilla entity remain $100\%$ untouched at the prototype level, guaranteeing zero regressions with vanilla mechanics or other mods.
  * **Method 1 (Machine GUI Toggle):** Using Factorio's `gui.relative` API, whenever a player opens any assembling machine, furnace, or turret, a small, non-intrusive docked checkbox appears beside the vanilla UI: **`[x] Colony Direct Service (Supply / Empty)`**.
  * **Method 2 (Drag-Select Logistics Tool):** Players have a shortcut tool (`Colony Logistics Marker`). Dragging it over a line of 20 furnaces toggles them into Colony Direct Service all at once (`Shift+Drag` to opt out).
* **Visual Clarity & Blueprint Support:**
  * Opted-in machines display a tiny, subtle badge icon in their top corner via `LuaRendering.draw_sprite` (visible in `Alt-Mode`).
  * When opted in, the machine's `unit_number` is added to `storage.colony_logistics_machines[colony_id]`.
  * **Persistence across Copy-Paste and Blueprints (implemented, #36).** The opt-in flag, the `collect`
    setting, the machine's supply rows and a crate's filters live in `storage`, which a blueprint cannot see,
    so the colony mirrors them into the blueprint entity's own `tags` (`BlueprintEntity.tags`, one namespaced
    key, dense row lists - `model/tags.lua`). Writing happens on `on_player_setup_blueprint` (walking
    `ev.mapping`, so a blueprint index is never guessed, and merging over other mods' tags); reading happens
    on `on_built_entity`, `on_robot_built_entity`, `script_raised_revive` (which is what a colony builder's
    `revive` raises, carrying the ghost's tags) and `on_blueprint_settings_pasted`. `on_entity_settings_pasted`
    and `on_entity_cloned` copy the registry record directly, and a *plain* machine or crate used as the
    copy source **clears** the destination rather than leaving it silently served. Tag payloads are treated
    as untrusted input: rows are validated, deduplicated and clamped to the panel's row count and
    `crates.MAX_COUNT`. Verified by `m1_blueprint` (26 checks) and by a save/load round-trip of a tagged
    ghost.
* **Massive UPS Benefit:** Because colonists *only* iterate over the opted-in `colony_logistics_machines` table and Colony Crates (rather than scanning every entity in the territory), CPU cost scales strictly with the machines you actively want colonists to serve.

### 5.3 Publishing the Colony onto the Circuit Network (#92)
The colony is the only part of the base that is not a machine, so the factory around it has always been blind: a belt feeding the Town Hall could not know whether the town needed 200 more iron plates or was drowning in them. The **Colony Ledger** closes that loop from the colony side, without asking the player to build logic.

* **The entity is a constant combinator.** A 1x1, worker-free, fuel-free building (`colony-ledger`) that any circuit wire can read. Cloning `constant-combinator` means the vanilla section editor, wire connectors and signal names all work for free - the player's existing belt condition (`iron-plate < 500`) needs no new vocabulary, and nothing in the *vanilla* prototypes is modified.
* **The colony writes it, every second.** One publish pass per colony every 60 ticks (`ledger_signal.PUBLISH_TICKS`) rewrites the combinator's logistic sections from `colony.ledger_snapshot` - the same number the Town Hall ledger shows, already including warehouses, hut chests and goods a hauler is carrying. The pass replaces the whole filter array, so an item that leaves the colony stops being published instead of leaving a stale signal on the wire, and it re-enables the combinator, so a player edit or a disabled combinator is corrected on the next pass (the entity is a read-out, not a setting).
* **Two questions, one toggle.** *Stock* publishes what the town holds (a belt condition: `iron-plate < 500`). *Shortfall* publishes `quota target - stock` for items under their target and nothing otherwise, so a wire reads `> 0` to mean "the town still wants this" without the player copying thresholds into a decider. Items with no quota are not published in shortfall mode - the town is not asking for them.
* **Order is by magnitude.** Signals are sorted biggest first, with the Town Hall ledger's own category order as the tie-break, so the list is deterministic and the numbers a factory is most likely to act on survive the cap. The cap is `20 signals per section x 2 sections`; a town tracking more than 40 distinct items only publishes the largest 40 (a section holds more, but the vanilla UI stops being readable, and 40 covers a mature town).
* **Only the interesting numbers.** Zero counts are never published - a missing signal already reads as 0 on the network, so an empty slot is worth more spent on something the factory can act on.
* **Blueprint/copy-paste parity.** The publish mode is the ledger's only setting, so it rides in the same `BlueprintEntity.tags` channel as the opt-in flag and crate filters (`model/tags.lua`); a pasted ledger comes back on the mode the player chose, and copy-paste carries it too.
* **Nothing when there is nothing to do.** The publish chain is one timer per *colony*, started by the first ledger and stopped by the last one going away; a town with no ledger pays no cost at all, and a pass with 40 signals measures ~0.19 ms.
* **Engine notes** (`s14_circuit`): in 2.1 a constant combinator's signals are its logistic sections (`parameters` is gone), the value on the wire comes from a filter's `min`, replacing the array clears stale rows, sections sum onto one network, and `LuaWireConnector` methods are bound (call with `.`).

---

## 6. Commuter Trains, Town Specialization & Tourism

Because heavy industry and mining generate pollution—which tanks **Desirability ($D$)** and causes **Smoker's Lung**—players have a natural reason to separate **clean Residential/Specialized Towns** from **polluted Industrial Outposts**, connecting them with **Passenger Trains**.

### 6.1 Residential Towns vs. Industrial Outposts (The Commuter Loop)
* **Industrial Outpost Territory:** Built around ore patches, smelter arrays, or oil refineries. Instead of building Houses in the smog, the player builds an **Outpost Station**, a **Canteen / Breakroom** (stocked with basic food/water), and the **tooled labour huts** for that site - each hut carries its own tools and output buffer, so an outpost needs no Town Hall to keep working.
* **Passenger Coach & Station Platform:**
  * A new train wagon (`Passenger Coach`) that holds up to $20\text{--}40$ colonists, paired with a `Passenger Platform` placed adjacent to a vanilla Train Stop.
  * *Built (#49, Rail Transit tech after Civic Governance + Railway):* the Platform serves the nearest train stop within 10 tiles, and a Coach seats 20. Units cannot sit in trains (spike #2), so a ride is bookkeeping: boarders leave their colony, ride as a count drawn on the coach, and step off as colonists of the first *other* colony whose platform the train stops at and which has free beds (or back home after 4 stops). For now migration is the only reason to ride: colonists who would leave town (desirability below the leave line), or have no bed, wait at the platform instead whenever another rail-served colony has room. Commuter shifts are built (#50, below).
* **How Commuting Works:**
  1. An Industrial Outpost calculates its **Worker Deficit** (e.g., "Needs 16 Miners/Haulers").
  2. When a train with a `Passenger Coach` stops at a Residential Town, idle colonists board the coach.
  3. When the train arrives at the Industrial Outpost, those colonists disembark and temporarily register to the Outpost's work queue for a **Work Shift** (e.g., $1\text{ in-game day}$).
  4. During their shift, commuters grab a quick meal at the Outpost's **Canteen** rather than needing local housing.
  5. When their shift timer finishes, they wait at the Outpost Passenger Platform to ride the next commuter train back home to their clean Residential Town to rest in high-tier housing!

* **Built (#50, decisions recorded on #21):**
  * **An outpost is a colony with a Canteen** (2x2, Rail Transit tech). It keeps its own Town Hall for stock, tools and territory, and needs no houses. It wants commuters for its hut capacity scaled up by the hauling share, less the commuters already there. It only asks while the Canteen or its hall has food, while it is daytime, and while one of its platforms serves a train stop.
  * **Only idle colonists commute.** A town with a platform sends idle colonists (no job anywhere at home) to wait for the train while outposts on the same surface want hands, less those already riding or waiting. Departures happen by day only.
  * **A ride has three kinds of passenger.** Commuters ride as a `commute` group and step off at the first other colony with open slots (up to that number). Commuters going home ride as a `return` group and step off only at home. A commute group that finds no outpost comes home after 4 stops. Migrants ride as before.
  * **At the outpost** commuters are its colonists, so its huts and haulers use them as normal. The home town counts them in `away`, which holds their beds: no migrant takes them, and the housing ratio counts them. They are never homeless, never leave, and are never sent off as migrants from the outpost.
  * **The Canteen feeds commuters.** It feeds them at the house rate from its own stock first, then from the outpost hall's larder (without the larder an empty outpost could never reopen, since only commuters can haul food in). Haulers keep it stocked up to 30 meals of any food.
  * **A shift ends** at nightfall, after 12000 ticks, or as soon as the Canteen and larder cannot feed everyone. The commuter then waits at the platform with `home` set.
  * **Stranded commuters walk home.** If no train comes within 7200 ticks, or the platform is gone, the commuter leaves the outpost and turns up at its own Town Hall.
  * **Deaths and lost coaches.** A commuter who dies is the home town's death (penalty, grave, bed freed). Riders on a destroyed or removed coach are attributed to their home, and its held beds are released.
  * **Not built:** wages and satisfaction, player-chosen commuters (job locks still keep a colonist at home), and tourism (#51).

### 6.2 Geographic Town Specialization
To make building multiple specialized towns across the map deeply rewarding, colony production buildings interact with the **underlying terrain tiles and natural features** within their territory:
1. **Coastal Fishing & Salt Towns (Requires Water Coastline):**
   * **Buildings:** *Fishing Docks, Aquaculture Pens, Coastal Salt Pans*.
   * **Outputs:** Fresh Fish, Shellfish, **Salt** (essential early/mid-game preservative for Salted Meat/Fish before refrigeration!), and **Pearls/Shells** (Luxury Goods).
2. **Lush Agricultural Valleys (Requires Fertile Grass/Loam Tiles):**
   * **Mechanic:** Farms and Orchards inspect the tile fertility beneath them. Building farms in lush grassland valleys yields $200\%$ crop speed compared to arid desert or rocky terrain.
   * **Outputs:** Grain, Vegetables, Fruit, Cotton/Flax (for Textiles/Clothing), and Hops/Grapes (for Brewing/Wine).
3. **Woodland / Highland Timber Towns (Requires Dense Forest Coverage):**
   * **Buildings:** *Forester's Lodge (plants & harvests trees sustainably), Herbalist Hut, Trapper's Cabin*.
   * **Outputs:** Sustainable Lumber/Wood, **Medicinal Herbs** (for Clinics), Game Meat, and **Pelts/Leather** (for Clothing & Armor).
   * **Forester's Hut (built, #97):** chopping destroys the tree the trip picked, and wood is a permanent sink (heat for tents/cabins/homesteads, every tier-1 tool), so a mature colony stripped its own territory and walked further every trip. The nursery is a 2x2 labour hut (`colony-forester-hut`, 20 wood + 5 iron, `job = "forest"`, two foresters, one **spade** each - 2 wood + 2 iron, unlocked with Advanced Agriculture) that costs **one wood out of its own chest** per tree and plants a full-grown tree the woodcutter gets 4 wood back out of, so it is a backstop rather than a wood source (net +3 per tree, and ~2 foresters replant ~1.5x slower than one 3-worker woodcutter cuts: `sim/balance.lua` Q14). `model/forest.lua` keeps the rules offline-testable: spots sit on a **global 4-tile lattice** shared between huts (so two nurseries never crowd each other), only soil tiles take a sapling (never sand, water, paving or landfill), and nothing is planted within `SPACING` = 4 tiles of a standing tree, so the hut fills the gaps a woodcutter opened instead of carpeting the map. The forester really walks to the hole (`work.PLANT_REACH` = 1.6 tiles out, claimed as `"plant:x,y"`), everything is re-checked on arrival, an empty chest closes the hut's slots and reports "waiting for supplies", and the hut panel draws its true 20-tile radius.
4. **Industrial & Mining Towns (Ore Patches & Geothermal/Oil):**
   * High pollution, zero scenic value—staffed by **Commuters** riding in from Residential Towns.

### 6.3 Scenic Appeal, Entertainment & Tourism
As colonies advance to Tier 2 and Tier 3 Housing, colonists desire **Recreation & Leisure**. Fulfilling it grants a massive boost to Desirability, prevents morale decay, and applies an **"Inspired" buff** ($+25\%$ work and research speed):
* **Scenic Appeal Score ($S_{\text{scenic}}$):** Every territory calculates a Scenic Appeal rating based on clean air (zero pollution), natural water tiles, living trees, and decorative plazas/parks.
* **Local Entertainment:** Players can build **Taverns** and **Theatres** in their residential towns. *Built (#48):* the **Tavern** (2x2, Recreation tech: 40 Frontier packs after Advanced Agriculture) pours **Ale** (2 produce + 2 water -> 2 ale, hand-craftable or in any assembler) for every occupied house within 24 tiles, 0.25 ale per resident per colony evaluation. Served residents are **Inspired** (+25% work speed, a star on their label), and the share of the town served adds up to +0.15 desirability as `recreation` (a bonus only: no penalty before you have a Tavern). Haulers keep each Tavern stocked to 20 ale. Theatres and the research-speed half of the buff are still planned.
* **Resort Towns & Tourist Trains:**
  * If you build a town on a pristine coastline or lush forest with **Resorts / Spas / Grand Hotels**, off-duty colonists from other towns will board **Passenger Trains as Tourists**, travel to the Resort Town, consume luxury food/drinks, and return home with maximum Leisure satisfaction—while generating **Cultural Insights** (used in high-tier Colony Science!).

---

## 7. Colony Defense, Militia & Vehicles

### 7.0 Civilians Take Shelter (built, #61)
* **Alarm:** anything of the colony's damaged by the enemy force inside its territory raises an alarm at that spot (nearby hits within 24 tiles refresh the same alarm). There is no peacetime scanning: the trigger is `on_entity_damaged`, and the upkeep (one `find_units` per alarm plus a pass over the colonists) only runs once a second while an alarm is up. The first alarm is announced with a map link, and the Town Hall goes red with a native alert ("Under attack! N colonists sheltering") until it clears.
* **Shelter:** colonists within 40 tiles of an alarm drop their work (claims and carried goods are released as for any aborted trip) and run to the nearest house or Town Hall at least 24 tiles from every threat (failing that, the one farthest from it). Inside a shelter a colonist cannot be hurt (`destructible = false`, standing in for "indoors"); if the shelter falls it runs again. Drivers waiting in a Motor Pool and passengers bound for a platform are left alone.
* **All-clear:** an alarm stays up while enemy units are within 40 tiles of it, but never more than a minute past the last hit, so biters idling at a nest near town cannot keep everyone indoors; it clears 10 s after the enemy is gone. A colonist comes out once no alarm covers the place it fled from, becomes vulnerable again and goes back to work. Turrets and, later, the Militia (M3) do the fighting.

### 7.1 The Armory & Weapon Integration
* **Armory Building:** Stocked with vanilla weapons (SMGs, Shotguns, Rocket Launchers, Tesla/Railguns), Armor, and Ammo.
* **Equipping:** Civilians assigned to **Militia/Guard** consume 1 Weapon and 1 Armor at the Armory to become a Militia unit, automatically restocking ammo between fights.

### 7.2 Semi-Passive Defense (Watchtowers & Patrols)
* **Watchtowers / Bunkers:** Expand colony territory and hold a garrison of Militia (e.g., $4$ Guards) with bonus range and shared structural protection.
* **Garrison, first slice (built, #56):** the Watchtower is registered as a labour hut with `job = "guard"`, so it reuses the existing machinery instead of a new building: `labour.HUTS["colony-watchtower"] = {job = "guard", tool = "colony-rifle", capacity = 4}`. The tower's stock room *is* the armory — every rifle inside opens one post (hauler-delivered at `tools` priority) and caps the garrison, and the hut's limit buttons (default **0**) decide how many of those posts the player mans. An unmanned tower posts nobody, asks for no rifles and never nags.
  * **Duty:** a posted guard walks to the tower's door and holds it under a stop order (an always-visible "guard" label). Every ~1 s (`garrison.CHECK_TICKS`, jittered per colonist) the post scans `garrison.RANGE` (16 tiles) for the nearest enemy **unit** — biters and spitters, not worms or nests — and attacks it with the colonist's hitscan rifle, re-trying up to `garrison.MAX_ATTEMPTS` times. Engagement is unconditional: it does not need the #61 alarm, and guards are exempt from sheltering (`alarm.EXEMPT`) so a manned tower keeps shooting while the town hides.
  * **Cost:** one completed engagement wears the tower's rifle one step, exactly like a hunter's trip (`labour.TOOL_USES` = 12). A rifle that wears out is consumed from the tower, its post closes, and the guard who lost it walks off — the garrison can never outlive its weapons. Rifles are ordinary craftable tools (wood 4, iron 6, copper 2), and a Toolsmith will make one when a *manned* tower is short.
  * **Weapon choice (implemented):** a post uses the best weapon its stock room holds, `colony-rifle` > `submachine-gun` > `pistol` > `colony-bow` (`garrison.PREFERENCE`). **Vanilla firearms need no colony research**: there is no `colony-firearms` tech any more — if the player hauls a gun in, the guards use it. A rifle is hitscan and carries its own ammunition, so it wears like a tool; a pistol or submachine gun spends one magazine (piercing first) every ten completed engagements; a bow spends one arrow per kill. A gun with no magazine is *not* fitted, so the post falls back to the bow rather than standing unarmed — but the tower still asks for `firearm-magazine` (target 5, batch 3) because the request is keyed off the weapons present, not off what can fire right now. Arrows target 20 (batch 10). Ammunition and the next weapon travel in the same trip when both are wanted.
  * **Roster:** `guard` joins `jobs.JOBS`/`jobs.DEFAULT` (rank 2) so the priority matrix, headcount targets, per-hut locks and the desirability open-jobs pull all work unchanged. Guards go to bed at night like everyone else and are re-posted in the morning; lowering the limit disbands the garrison and the rifles stay in the tower for later.
* **Patrol Waypoints:** Place `Patrol Post` markers along borders or rail lines; Militia squads autonomously patrol between them and clear biter expansions.
* **Command Whistle (`selection-tool`):** Optional RTS drag-select tool to issue temporary AoE-style **Move / Attack-Move** orders when clearing nests.

### 7.3 Colonist-Driven Vehicles (Cars & Trucks)
* **Motor Pool (built, #60):** A pool holds vanilla **Cars** and fuel and requests both by haul. A car cannot be driven by a unit and has no autopilot, so the truck is a `colony-truck` unit that wears the car sprite and is pathed by the engine like a colonist (2.5x speed, 100-item load). A hauler whose load is a full hand-load with more still wanted checks out the nearest pool within 48 tiles that has a car and fuel, claims the car and the big load at checkout, and waits on the pool under a stop order while the truck delivers. Fuel buys trips (solid fuel 6, coal 2, wood 1). The truck takes further big loads while it has trips, a driver and daylight, then parks: the car returns to the pool, unspent trips stay in the pool, and a truck destroyed on the road loses its car. **Mechanized Patrols** (Driver + Gunner) are still planned under M3 (#57, #60).

* **Haul Station + Wooden Trailer (built, #94):** cheap bulk hauling before the Motor Pool. A station is distributed colony storage (hall + warehouses + watchtowers + stations source and deposit alike); its Wooden Trailers give one hauler a 60-item load at 0.6x speed for 30 trips each (trailer.USES), claimed at checkout from the nearest station in reach.

---

## 8. Dedicated Colony Tech Subtree & Custom Science

**Onboarding milestone (current):** a new game shows only the Town Hall. **Settlement** is the one scripted-trigger technology (`model/milestones.lua`): build a Town Hall. It unlocks the starter kit (Tent, Forager's/Woodcutter's/Miner's Huts, basket/axe/pickaxe, Toolsmith, Compost Bin, Supply Crate), the **Town Archive**, and the **Frontier Charter** recipes (forage, meat, produce, Gleba). Pack research therefore starts at Settlement. The earlier five-step 4/8/12/16-colonist ladder was tried and collapsed in 57486fa: it gated the Archive behind the population the Archive was meant to support, so `colony-hunting-fishing` and `colony-food-preservation` are research technologies now, not milestones. The native tree still states the trigger ("Build a Town Hall"), so the first hour needs no research.

A **Toolsmith** (`model/toolsmith.lua`, a staffed hut on the preserve job) makes the tools huts are waiting on from the wood, iron and copper haulers bring it (about 30 s per tool, unlocked recipes only, one spare of each kept), so woodcutters keep foragers in baskets without the player crafting them. The Town Hall makes nothing for free. Problems are reported where the player looks (`scripts/feedback.lua`, every 5 s): a status line on every house, hut and hall tooltip, and native custom alerts for red problems (a house about to starve, a hut that cannot get its tool, no sites in range, no food at all), toggled by the per-player `colony-alerts` setting. Carried goods are drawn over the colonist carrying them.

Colonies have their own **Tech Subtree** researched in a **Town Archive** (early) or **University** (late) staffed by educated colonists. Every technology is paid for with colony packs, never vanilla science, but the **two trees interlock through prerequisites** so a colony tier never gets ahead of the factory that must build it. The tree as built (`prototypes/technology.lua`):
1. **Frontier Charter** (10 packs; Settlement): unlocks the fish Frontier Charter recipe and gates everything below.
2. **Tier 1** (10-25 packs): Permanent Housing (Cabin), Hunting & Fishing (Lodge, bow, arrows, Dock, rod), Food Preservation (Salt Pan, Smokehouse, preserved packs), Cemetery, Advanced Agriculture (Farm Hut, Plot, Hoe), and Logistics (Watchtower, Demand Crate, marker, rifle, Haul Station, trailer; **needs vanilla Logistics**).
3. **Tier 2** (15-40 packs): Warehousing, Steel Tools (**needs Steel Processing**), Water Infrastructure (Well, bottling, Homestead, Furniture; **needs Automation 2** for the fluid-capable assembler), Recreation (Tavern, ale), Medicine (Clinic, Herbal Medicine), and Motor Pool (**needs Automobilism**).
4. **Tier 3** (40-50 packs): Civic Governance (University, Apartment, Kitchen, Civic Treatise recipe; **needs Concrete** and the circuits it implies) and Rail Transit (Passenger Platform, Coach, Canteen; **needs Railway**).
5. **Known gap:** every tech still costs only Frontier Charters, so the Civic Treatise recipe has no consumer yet; #98 tracks the pack-economy cleanup.

Later tiers are planned, not built: **Bio-Ecological Data** (Resorts, Habitat Domes, Enviro-Suits, Cryo-Colonist Pods, Nurseries) and **Interplanetary Sovereignty Codex** (Arcologies, Orbital Hydroponics, Space Platform EVA Crew) are tracked in #69.

* **Implementation details (#42, #19):**
  * **Lab Whitelist Isolation:** Vanilla labs reject custom colony packs (`can_insert == false`, `insert() == 0`), and colony labs reject vanilla packs. Isolation is enforced at the C++ engine level.
  * **Perishable Spoilage in Labs:** Perishable science packs (Frontier Charters, Civic Treatises) that spoil inside a lab automatically move into `defines.inventory.lab_trash`. The lab does not jam and continues researching fresh packs. Haulers collect spoilage from `lab_trash` and route it to Compost Bins.
  * **Staffed Mechanics:** Town Archives (3x3, cap 2) and Universities (4x4, cap 4) register as labour huts with `job = "research"` (`scholar` role, default rank 2, 15% workforce target). Scholars maintain and staff the facility while science packs are present, updating the native `custom_status` diode (`green` staffed / `red` unstaffed).
  * **Unified Research Queue:** Colony technologies reside in standard `data.raw["technology"]`, appearing in the native "T" tech tree and FIFO research queue (`force.research_queue`). Technology progress advances natively when powered and staffed.
  * **Vanilla Interlock:** colony technologies never cost vanilla science, but advanced tiers carry vanilla prerequisites (Logistics, Steel Processing, Automation 2, Concrete, Automobilism, Railway). This keeps the tree from offering a Homestead before the player can assemble water bottles, or an Apartment before concrete exists, without merging the two science economies.
  * **Update Safety:** `scripts/tech.lua` re-applies `unlock-recipe` effects for every researched technology on `on_configuration_changed`. A technology that gains an effect in a mod update therefore enables the new recipe in an existing save instead of leaving the force with the tech and no item.
  * **Tree Integrity Gate:** `model/tech_audit.lua` + `m1_tech` check that every colony technology is reachable, every unlocked recipe exists exactly once, every pack is accepted by a lab available at that point, and every vanilla ingredient's recipe is unlocked by a technology in the colony tech's prerequisite closure.

---

## 9. Space Age: Interplanetary & Self-Sustaining Orbital Colonies

### 9.1 Planet Classifications
* **Life-Friendly Worlds (Nauvis & Gleba):** Open-air housing and organic migration. Gleba offers abundant foraging and wood, balanced by Swamp Fever and Pentapods.
* **Hostile / Barren Worlds (Vulcanus, Fulgora, Aquilo):** Unbreathable environments. Colonists must live inside pressurized **Habitat Domes** (which emit territory), equip **Enviro-Suits** to work outside, and grow their population via **natural reproduction** in Nurseries.

### 9.2 Cryo-Colonist Pods & Refillable Life Support
* **Launching Pioneers:** Train a colonist at a Space Training Center into a launchable `Cryo-Colonist Pod` item.
* **Spoilage Timer as Life Support:** The pod has a $20\text{-minute}$ spoilage timer representing finite internal battery, oxygen, and rations.
* **Refueling / Resetting Pod Life Support (Solving the Locked-Pod Problem):**
  * What if a pod is waiting on a Space Platform or Landing Pad and its life-support timer is running low, while you have plenty of food and oxygen on hand?
  * Using Factorio 2.0's native `result_is_always_fresh = true` recipe property, any Assembler or **Life-Support Bay** can run a fast **"Replenish Pod Life Support"** recipe:
    $$\text{Cryo-Colonist Pod (Any Freshness)} + \text{Canned Rations} + \text{Water/Oxygen Barrel} \longrightarrow \text{Cryo-Colonist Pod (100\% Fresh)}$$
  * This means players can build a life-support maintenance loop on their Space Platforms or staging areas to keep pods alive indefinitely as long as they supply food and water/oxygen!

### 9.3 Self-Sustaining Orbital Space Colonies (Space Platforms)
Rather than treating Space Platforms as purely unmanned robot ships, late-game players can turn massive Space Platforms into **Self-Sustaining Orbital Colonies**:
* **Orbital Habitat Domes & Hydroponics:**
  * Unpack `Cryo-Colonist Pods` into an **Orbital Habitat Dome** built on the Space Platform deck.
  * Build **Orbital Hydroponics Bays** that crush metallic/carbonic/oxide asteroid chunks for **Ice (Water)** and **Carbon (Nutrients/Fertilizer)**, growing fresh food in orbit and recycling organic `spoilage` back into biomass in a closed loop!
  * Once a critical mass of colonists is unpacked in an Orbital Dome with a Nursery, the orbital colony becomes **100% self-sustaining and self-reproducing** in deep space.
* **Zero-G Spacewalkers (EVA Crew):**
  * Colonists exit the Orbital Dome through an **EVA Airlock** wearing Zero-G Jetpacks (`unit` prototype constrained to `space-platform-foundation` tiles).
  * They manually haul ammo to edge turrets, clear asteroid collectors, tend Orbital Hydroponics, and repair platform tiles damaged by impacts during flight.

### 9.4 Cross-Planetary Endgame Gear
* **Vulcanus (Tungsten):** Tungsten Pickaxes & Heavy Siege Armor for Militia.
* **Fulgora (Holmium):** Exoskeleton Harnesses (car-speed hauling) & Personal Shield Packs.
* **Gleba (Bioflux):** Panacea Serums (disease immunity + $+50\%$ work speed).
* **Aquilo (Cryogenics):** Cryo-Preservation Warehouses ($0\%$ spoilage rate) & Fusion Arcologies.

---

## 10. Technical Architecture & UPS Optimization (Factorio 2.0 API)

1. **$O(1)$ Territory Grid Indexing:** Town Halls, Outposts, Watchtowers, and Habitat Domes register covered $32 \times 32$ Map Chunks into `storage.colony_chunks[surface_index][chunk_x][chunk_y] = colony_id`.
2. **Non-Destructive Opt-In Machine Registry:** Opting in a vanilla machine via `gui.relative` or the `selection-tool` registers `entity.unit_number` into `storage.colony_logistics_machines[colony_id]` and attaches a `LuaRendering` badge. The colony job dispatcher only scans registered machines and Colony Crates (processed in a staggered queue of $5\text{--}10$ buildings per tick).
3. **Event-Driven Agents (`on_ai_command_completed`):** Colonists use C++ `unit` pathfinding and tick-bucketed task completion (`storage.scheduled_tasks[target_tick]`) for 1:1 mining depletion, pollution emission, and tool durability—avoiding per-tick Lua polling.
4. **Commuter & Tourist Train Hook (`on_train_changed_state`):** Colonists only evaluate boarding or disembarking when a train containing a `Passenger Coach` fires `defines.train_state.wait_station` adjacent to a `Passenger Platform`, transferring colonist data cleanly in $O(1)$ time.

---

## 11. Proposed Phased Development Roadmap (MVP $\rightarrow$ Full Release)

To make building this mod manageable and testable at every step, here is a suggested 4-phase implementation plan:

* **Phase 1: Core Colony Loop (The Frontier MVP)**
  * Town Hall territory chunks, Tier 1 Housing, Desirability & Migration.
  * Foraging/Hunting, Spoilage, tooled labour huts (Iron Axes & Pickaxes, hut-owned wear), 1:1 Mining & Tree Chopping.
  * Colony Crates + Non-destructive Opt-in Machine Hauling (`gui.relative` & Selection Tool) + Blueprint construction.
* **Phase 2: Civilization, Industry & Commuter Trains**
  * Frontier Charter & Civic Treatise Science Packs + Town Archive.
  * Geographic Town Specializations (Fishing Docks, Salt Pans, Fertile Farming, Smokehouses, Clinics & Illness).
  * Passenger Coaches, Commuter Work Shifts (Canteens), and Tourism/Resorts.
* **Phase 3: Militia, Watchtowers & Mechanized Defense**
  * Armory (Vanilla Weapons/Armor/Ammo integration), Watchtowers, Automated Patrols, RTS Command Whistle, and Colonist-Driven Cars.
* **Phase 4: Space Age Interplanetary & Orbital Colonies**
  * Habitat Domes, Enviro-Suits, Refillable `Cryo-Colonist Pods`, Natural Reproduction (Nurseries), Off-World Gear, and Orbital Space Platform EVA Colonies.