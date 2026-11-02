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
* **Tier 1: Shacks / Tents**
  * **Capacity:** $2\text{--}4$ Colonists.
  * **Upkeep:** Raw Food (Foraged Berries, Raw Meat, Fish) + Wood.
* **Tier 2: Homesteads / Cottages**
  * **Capacity:** $6\text{--}8$ Colonists.
  * **Upkeep:** Preserved/Cooked Food (Bread, Salted Meat, Smoked Fish) + Water + Coal/Wood.
* **Tier 3: Apartment Blocks**
  * **Capacity:** $16+$ Colonists.
  * **Upkeep:** Gourmet/Canned Food + Electricity + Consumer Goods (Clothing, Furniture, Medical Supplies) + Access to Recreation.
* **Tier 4: Interplanetary Arcologies / Habitat Domes**
  * **Capacity:** $32+$ Colonists (Required on hostile planets & orbital platforms; acts as both Housing and Territory Emitter).
  * **Upkeep:** Pressurized Air/Water + Multi-Planet Luxury Goods + Bioflux/Advanced Medicine.

### 2.3 Desirability, Migration & Natural Reproduction
Population grows through two mechanisms depending on the environment:

$$D = (W_{\text{food}} \cdot S_{\text{food}}) + (W_{\text{housing}} \cdot S_{\text{housing}}) + (W_{\text{scenic}} \cdot S_{\text{scenic}}) + (W_{\text{leisure}} \cdot S_{\text{leisure}}) - P_{\text{pollution}} - P_{\text{deaths}}$$

1. **Organic Migration (Life-Friendly Worlds - Nauvis & Gleba):**
   * When your colony's **Desirability Rating ($D$)** is positive and housing is available, wild migrants periodically arrive at your Town Hall.
   * If $D$ drops into the negative (starvation, heavy factory pollution, frequent deaths), migration stops and existing colonists eventually pack up and leave.
   * **Leaving (implemented, #29):** below `leave_below` ($-0.10$) the newest arrivals start walking out, one per evaluation interval at minimum, rising with how far below the line $D$ has fallen and capped at `leave_rate` (10%) of the town per interval. A colonist that leaves returns whatever it was carrying to the Town Hall, frees its hut seat and its job lock, and is gone - it is not a death, so it does not feed the death penalty. The rule lives in `model/colony_model.leave_count` so the sim harness and the game agree.
   * **The five inputs are real, not placeholders (implemented, #29):**
     * *Food / housing / leisure* come from the evaluation loop (stock ratio, free beds, powered-house score).
     * *Scenic* (`model/scenic.lua`) is read from the world in a fixed 40-tile box around the Town Hall, once every 4 evaluations: tree cover (from one filtered find), water tiles and paving on a 1-in-16 tile sample. A forest scores full marks at 35% tree cover, a lake at 15% water, and paving subtracts up to 0.6 - so the player's own concrete works against them, which is the point.
     * *Pollution* is `surface.get_pollution` at the Town Hall, normalised against 300 units (`MINE_POLLUTION` is 2 per mining trip, so a concentrated mining outpost is felt while a clean town is not).
     * The hall panel shows $D$, its six components, and the two raw inputs (scenic, pollution) so the number is explainable without a debug build.
2. **Natural Reproduction / Breeding (Advanced, Off-World & Orbital Colonies):**
   * On barren worlds (Vulcanus, Fulgora, Aquilo) and Space Platforms, wild migrants cannot spawn.
   * Once a colony reaches a **Critical Mass** (e.g., $\ge 10$ colonists) inside Tier 2+ Housing or Habitat Domes with high Desirability and a **Maternity Clinic / Nursery**, the colony generates new colonists organically via natural reproduction.

### 2.4 Permanent Death, Illness & Hospitals
* **Permanent Death:** Combat and starvation are lethal ($0\text{ HP} = \text{permanent death}$). Every death applies a temporary stacking penalty ($P_{\text{deaths}}$) to Desirability.
* **Illness & Disease:**
  * Living or working in high-pollution chunks causes **Smoker's Lung**; eating near-spoiled food causes **Food Poisoning**; working on Gleba causes **Swamp Fever**.
  * Sick colonists work at $50\%$ speed and eventually die unless treated by a Doctor colonist at a **Clinic / Hospital** stocked with Herbal Medicine or Pharmaceuticals.

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
ammo on dinner. The **Hunting Lodge** (3 hunters, one **rifle** each, 30-tile radius, must be built inside
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
2. **Mid Game (Agriculture & Salt/Smoke Preservation - Medium Shelf Life):**
   * **Farms / Greenhouses:** Require water, seeds, and fertilizer (yielding $2\times$ crops when built on lush/fertile soil tiles).
   * **Kitchens & Smokehouses:** Combine raw meat/fish with **Salt** (from coastal Salt Pans) or Wood Smoke, or bake grain into Bread, increasing nutrition $4\times$ and extending shelf life to $30\text{--}60\text{ minutes}$.
3. **Late Game (Industrial Canning & Cold Chain - Long Shelf Life):**
   * **Canneries:** Seal food with Steel/Iron Plates into **Canned Rations** ($3+\text{ hours}$ shelf life).
   * **Refrigerated Warehouses & Wagons:** Powered storage that drastically slows spoilage.

**M1 farming slice (implemented, first pass of #44):** the player places **Farm plots** (1x1, 4 per wood recipe) on farmland inside colony territory; a **Farm Hut** (3 farmers, one **hoe** each, 30-tile radius) plants fallow plots, the crop ripens in 60 s, and a farmer harvests it into **Colony produce** (spoils in 30 min) and carries it to the Town Hall. Plots are free to plant and yield 8 produce at fertility 1.0. Vanilla 2.0 exposes no per-tile fertility (spike s06), so `model/farm.lua` maps tile names to fertility: grass 1.0, dirt 0.85, dry dirt 0.5, red desert 0.45, sand 0.25, landfill 0.6. Below 0.35 a plot cannot be placed, and water/paving cannot be farmed, so poor soil visibly yields less - the first hook for geographic specialization. Seeds, fertilizer, kitchens, smokehouses and compost stay in #44.

### 3.2 Dealing with Spoilage (The Closed Loop)
* Expired food turns into native `spoilage`, which colonists automatically clear out of houses and haul to **Compost Bins** to turn into **Fertilizer** for planetary or orbital farms.

**M1 implementation (#78):** spoilage is not just cosmetic - it is the failure mode of the whole food chain. A house whose inventory fills with garbage cannot accept food, so it starves its occupants while the Town Hall is stocked. Colonists therefore clear it out on two paths: **for free on a delivery** (a hauler standing in a house takes the spoilage away with it instead of walking home empty) and as the **lowest-priority haul band** (`compost`, below buffering, because nothing is waiting on it but the food slots it blocks) for spoilage sitting in colony stock. Both end at a **Compost Bin** (1x1, 12 slots, must be inside territory like every colony building), which converts whole batches of ten into **Colony Fertilizer** on a 10 s pass - batches, not a per-tick reaction, and the remainder waits in the bin. Fertilizer is carried back into colony stock like any other output; spending it (seeds, water, the 2x yield rule) belongs to the farming slice (#44), so today it is an input waiting for its consumer.

---

## 4. Agent Behavior, Explicit Tools & Priority System

### 4.1 Job Types
Players configure a per-colony **Priority Matrix** (ranked $1$ to $4$, or disabled) for colonist roles:
1. **Guard / Militia:** Patrol designated areas, man Watchtowers, and respond to enemy threats.
2. **Doctor:** Tend to sick colonists in Clinics/Hospitals.
3. **Construct & Repair:** Deliver materials to `entity-ghost` blueprints within territory, construct them, and repair damaged buildings/walls.
4. **Haul (Logistics):** Move items between Colony Crates and opted-in machines, including **hand-feeding ammo into Gun Turrets** and fuel into burner machines.
5. **Harvest / Mine / Chop:** Mine ore patches, chop trees, fish, or tend farms within territory.

**M1 behaviour (implemented):** the Town Hall panel exposes the matrix for the live roles (haul, forage, chop, mine, farm, hunt, fish; rank 1\u20134, 0 = off). Jobs sharing a rank form one priority group and split the workforce by the food ratio, so the default (`haul 1`, harvest roles `2`) behaves like the old rule set. The planner (1) keeps roughly 30% of the colony hauling while hauling is enabled and there is haul work (at least one colonist), (2) takes the best-ranked enabled harvest role with a free tooled slot, and (3) splits a group by the food ratio, shifting toward foraging when stocks are below target. Harvest sites are chosen nearest-first inside territory, so colonists visibly work the forest or patch beside their hut. A Miner's Hut additionally carries a per-ore priority (iron/copper/coal/stone, rank 1–4, 0 = off): the hut works the best-ranked ore that is in range and only falls back to distance between ores sharing a rank, so it no longer walks past iron to grab the closest stone.

**Construction & repair (implemented, #37):** builders honour the matrix like any other role but are capped at 25% of the population (`model/construct.lua`), so a blueprint never costs the town its dinner. Every 5 s each colony re-scans its claimed area once (a player blueprint fires no build event) and keeps a small registry of `entity-ghost`s and of damaged colony buildings; assignment reads that registry, never the surface. A ghost's price is its `ghost_prototype.items_to_place_this`, paid out of colony stock up front and carried by the builder, who then revives it; if the site refuses to revive the materials come back and the ghost is skipped for a minute - unless the only thing in the way is the builder itself standing on the footprint, in which case it steps aside and tries again (a unit blocks `revive`, #76). Repairs run before builds and consume one `repair-pack` per 200 health, so repair packs are a logistics input like tools. Ghosts outside territory are ignored.

**Player control over allocation (implemented):** the Town Hall panel carries an **accept-migrants** toggle and a **population target** (migration stops at that population even when desirability is high), plus aggregate job counts. Individual assignment lives on **each house**: the house panel lists that house's occupants (filled in house order, so the counts always agree) and each colonist can be locked to one role (`A` = follow the matrix). A locked colonist ignores the matrix and idles when its role has no free tooled slot. This keeps the panel usable when a town has hundreds of colonists; a town-wide quota/squad view is the planned long-term replacement for per-colonist lists (#73). Each labour hut has its own **worker limit** (0 pauses the hut), so a hut only takes as many colonists as the player wants, up to its tools and capacity. Opening a hut panel draws its working radius in the world, matching the Town Hall's territory rectangle.

**Haul priority (implemented in `model/haul_plan.lua`):** unmet critical need (food/heat) $\rightarrow$ tools for huts $\rightarrow$ collecting a hut's finished goods $\rightarrow$ explicit machine and demand-crate requests $\rightarrow$ collecting machine output and supply crates $\rightarrow$ buffering a well-stocked house. One trip serves one destination but may carry several item types at once (e.g. iron ore **and** fuel for a furnace), with the carry cap split across the destination's demands, so a multi-input machine is never starved one ingredient at a time. House buffers are sized by occupants, so empty houses do not hoard supplies. Harvest yield is deposited in the **worker's hut** rather than the Town Hall, so a worker never walks every load home; a hauler clears the hut's output inward.

**Machine opt-in (implemented):** ticking the supply box on a machine's panel, or dragging the **Colony logistics marker** selection tool over machines (alt-drag to opt out), registers the machine for colony hauling. Opted-in machines show a Town Hall badge in alt mode, so coverage is visible without opening each panel.

### 4.2 Explicit Tooling, 1:1 Mining & Pollution
* **The Bootstrap Loop:** The player starts by hand-crafting **Iron Axes** and **Iron Pickaxes** and placing them in the Town Hall or straight into the labour hut that needs them. There is no separate Tool Rack entity: **each labour hut is its own tool store** (implemented, #31 closed as superseded).
* **Job Gating & Durability:** Colonists must work at a hut that holds the right tool: an **Axe** to chop trees, a **Pickaxe** to mine ore, a **Hoe** to farm, a **Basket** to forage, or carry **Repair Packs** to repair. A hut holds up to `capacity` tools, only employs as many colonists as it holds tools for (further capped by its panel's worker limit), and wears one tool per `TOOL_USES` completed trips of its own work, with a popup when a tool breaks. A hut short of tools raises a **tools-priority** haul request, so the player never hand-delivers replacements; this is why wear lives on the hut, not on the colonist - the tool is the employment slot. Tiers (Iron $\rightarrow$ Steel $\rightarrow$ Tungsten/Plasma) switch the tool item when the tech tree lands (#69), which is also when per-colonist gear becomes worth revisiting.
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

---

## 6. Commuter Trains, Town Specialization & Tourism

Because heavy industry and mining generate pollution—which tanks **Desirability ($D$)** and causes **Smoker's Lung**—players have a natural reason to separate **clean Residential/Specialized Towns** from **polluted Industrial Outposts**, connecting them with **Passenger Trains**.

### 6.1 Residential Towns vs. Industrial Outposts (The Commuter Loop)
* **Industrial Outpost Territory:** Built around ore patches, smelter arrays, or oil refineries. Instead of building Houses in the smog, the player builds an **Outpost Station**, a **Canteen / Breakroom** (stocked with basic food/water), and the **tooled labour huts** for that site - each hut carries its own tools and output buffer, so an outpost needs no Town Hall to keep working.
* **Passenger Coach & Station Platform:**
  * A new train wagon (`Passenger Coach`) that holds up to $20\text{--}40$ colonists, paired with a `Passenger Platform` placed adjacent to a vanilla Train Stop.
* **How Commuting Works:**
  1. An Industrial Outpost calculates its **Worker Deficit** (e.g., "Needs 16 Miners/Haulers").
  2. When a train with a `Passenger Coach` stops at a Residential Town, idle colonists board the coach.
  3. When the train arrives at the Industrial Outpost, those colonists disembark and temporarily register to the Outpost's work queue for a **Work Shift** (e.g., $1\text{ in-game day}$).
  4. During their shift, commuters grab a quick meal at the Outpost's **Canteen** rather than needing local housing.
  5. When their shift timer finishes, they wait at the Outpost Passenger Platform to ride the next commuter train back home to their clean Residential Town to rest in high-tier housing!

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
4. **Industrial & Mining Towns (Ore Patches & Geothermal/Oil):**
   * High pollution, zero scenic value—staffed by **Commuters** riding in from Residential Towns.

### 6.3 Scenic Appeal, Entertainment & Tourism
As colonies advance to Tier 2 and Tier 3 Housing, colonists desire **Recreation & Leisure**. Fulfilling it grants a massive boost to Desirability, prevents morale decay, and applies an **"Inspired" buff** ($+25\%$ work and research speed):
* **Scenic Appeal Score ($S_{\text{scenic}}$):** Every territory calculates a Scenic Appeal rating based on clean air (zero pollution), natural water tiles, living trees, and decorative plazas/parks.
* **Local Entertainment:** Players can build **Taverns** (consuming Ale/Wine and Cooked Food) and **Theatres** in their residential towns.
* **Resort Towns & Tourist Trains:**
  * If you build a town on a pristine coastline or lush forest with **Resorts / Spas / Grand Hotels**, off-duty colonists from other towns will board **Passenger Trains as Tourists**, travel to the Resort Town, consume luxury food/drinks, and return home with maximum Leisure satisfaction—while generating **Cultural Insights** (used in high-tier Colony Science!).

---

## 7. Colony Defense, Militia & Vehicles

### 7.1 The Armory & Weapon Integration
* **Armory Building:** Stocked with vanilla weapons (SMGs, Shotguns, Rocket Launchers, Tesla/Railguns), Armor, and Ammo.
* **Equipping:** Civilians assigned to **Militia/Guard** consume 1 Weapon and 1 Armor at the Armory to become a Militia unit, automatically restocking ammo between fights.

### 7.2 Semi-Passive Defense (Watchtowers & Patrols)
* **Watchtowers / Bunkers:** Expand colony territory and hold a garrison of Militia (e.g., $4$ Guards) with bonus range and shared structural protection.
* **Patrol Waypoints:** Place `Patrol Post` markers along borders or rail lines; Militia squads autonomously patrol between them and clear biter expansions.
* **Command Whistle (`selection-tool`):** Optional RTS drag-select tool to issue temporary AoE-style **Move / Attack-Move** orders when clearing nests.

### 7.3 Colonist-Driven Vehicles (Cars & Trucks)
* **Motor Pool / Garage:** Stocked with vanilla **Cars** and fuel. Colonists drive Cars to haul $20\text{--}40$ stacks of supplies between territories before trains are built, or form 2-person **Mechanized Patrols** (Driver + Gunner).

---

## 8. Dedicated Colony Tech Subtree & Custom Science

Colonies have their own **Tech Subtree** researched in a **Town Archive** (Early) or **University** (Late) staffed by educated colonists:
1. **Frontier Charter (Tier 1):** *Lumber + Salted/Smoked Food + Stone Bricks* $\rightarrow$ Unlocks Homesteads, Farms, Fishing Docks, Salt Pans, Watchtowers, Steel Tools.
2. **Civic Treatise (Tier 2):** *Paper + Textiles/Clothing + Herbal Medicine + Iron Gear* $\rightarrow$ Unlocks Apartment Blocks, Clinics, Passenger Trains & Commuting, Motor Pools, Taverns.
3. **Bio-Ecological Data (Tier 3):** *Canned Rations + Pharmaceuticals + Cultural Insights (Tourism) + Advanced Circuits* $\rightarrow$ Unlocks Resorts, Habitat Domes, Enviro-Suits, Cryo-Colonist Pods, Nurseries.
4. **Interplanetary Sovereignty Codex (Tier 4):** *Multi-Planet Inputs (Bioflux, Tungsten, Holmium, Cryo-tech)* $\rightarrow$ Unlocks Arcologies, Orbital Hydroponics, Space Platform EVA Crew, Cybernetic Upgrades.

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