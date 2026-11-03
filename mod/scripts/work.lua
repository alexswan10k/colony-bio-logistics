-- Colonist work loop (#30-#32 simplified): idle -> choose job -> walk to site -> work N ticks -> carry yield to hall.
-- Driven by on_ai_command_completed + scheduler; no per-tick polling per unit.
-- Jobs: haul (hall -> houses / tooled huts / opted-in machines, machine output -> hall),
--       forage (natural forage patches in territory), chop (tree destroyed -> wood), mine (ore depleted 1:1).
local events = require("scripts.events")
local scheduler = require("scripts.scheduler")
local territory = require("scripts.territory")
local work_plan = require("scripts.model.work_plan")
local housing = require("scripts.model.housing")
local labour = require("scripts.model.labour")
local haul_plan = require("scripts.model.haul_plan")
local farm = require("scripts.model.farm")
local mine_plan = require("scripts.model.mine_plan")
local crates = require("scripts.model.crates")
local compost = require("scripts.model.compost")
local hunting = require("scripts.model.hunting")
local wildlife = require("scripts.wildlife")
local fishing = require("scripts.model.fishing")
local preserve = require("scripts.model.preserve")
local kitchen = require("scripts.model.kitchen")
local yields = require("scripts.model.yields")
local salt = require("scripts.model.salt")
local well = require("scripts.model.well")
local construct = require("scripts.model.construct")
local science = require("scripts.model.science")
local motor = require("scripts.model.motor")
local M = {}
local colony_mod   -- injected by scripts.colony via M.bind
function M.bind(c) colony_mod = c end

M.WORK_TICKS = yields.WORK_TICKS
M.RETRY_TICKS = 300
M.RETRY_BACKOFF_MAX = 4     -- an idle colonist that keeps finding nothing waits up to this many retry periods (#22)
M.RETRY_BACKOFF_POP = 100   -- ...but only in big towns: one extra retry period per this many colonists
M.YIELD = {forage = yields.FORAGE, chop = yields.CHOP}
M.MINE_PER_TRIP = yields.MINE_PER_TRIP   -- each unit becomes exactly one item (design §4.2)
M.MINE_POLLUTION = 2        -- pollution per mining trip: colony industry still feeds the biters
M.CARRY_CAP = yields.CARRY_CAP
M.ORES = mine_plan.ORES   -- every ore a Miner's Hut can be pointed at
M.LABELS = {forage = "forager", chop = "woodcutter", mine = "miner", farm = "farmer", hunt = "hunter",
  fish = "fisher", preserve = "preserver", haul = "hauler", construct = "builder", research = "scholar"}

local function key(e) return e.surface.index .. ":" .. e.position.x .. "," .. e.position.y end

function M.job_counts(colony)
  local counts = {}
  for un, c in pairs(colony.colonists) do
    local st = storage.unit_state[un]
    if c.valid and st and st.job then counts[st.job] = (counts[st.job] or 0) + 1 end
  end
  return counts
end
local job_counts = M.job_counts

-- Floating job label above each colonist (makes the colony legible).
-- The entity behind a unit number: a colonist, or a truck a hauler is driving (#60).
local function unit_entity(colony, un)
  local e = colony.colonists[un]
  if e then return e end
  local t = storage.trucks and storage.trucks[un]
  return t and t.entity
end

local function set_label(e, text)
  local obj = storage.unit_labels[e.unit_number]
  if obj and obj.valid then obj.text = text; return end
  storage.unit_labels[e.unit_number] = rendering.draw_text{text = text, surface = e.surface, target = {entity = e, offset = {0, -1.4}},
    color = {1, 1, 1}, scale = 0.7, alignment = "center", only_in_alt_mode = true}
end

local function popup(surface, pos, text)
  rendering.draw_text{text = text, surface = surface, target = pos, color = {0.8, 1, 0.8},
    scale = 0.8, time_to_live = 90, alignment = "center"}
end

-- A ring that lives exactly as long as the work: you can see WHICH tree/patch/ore tile is being worked.
local function work_ring(e, pos)
  rendering.draw_circle{surface = e.surface, target = pos, radius = 0.9, color = {1, 0.85, 0.3, 0.8},
    width = 2, filled = false, time_to_live = M.WORK_TICKS}
end

local function item_name(item)
  if item and prototypes.item[item] then return {"item-name." .. item} end
  return item or "?"
end

-- Contents of a colony building's chest as item -> count (nil when it is empty or has no chest). Declared up
-- here because Lua locals only exist after their definition: `hut_offer` (below) needs it.
-- For lab entities (Town Archive, University), inspects defines.inventory.lab_input (#42).
local function chest_contents(entity)
  local inv = entity.type == "lab"
    and entity.get_inventory(defines.inventory.lab_input)
    or entity.get_inventory(defines.inventory.chest)
  if not (inv and not inv.is_empty()) then return nil end
  local out = {}
  for _, item in ipairs(inv.get_contents()) do out[item.name] = item.count end
  return out
end

local function update_lab_status(entity, workers, capacity)
  if not (entity and entity.valid and entity.type == "lab") then return end
  if workers > 0 then
    entity.custom_status = {
      diode = defines.entity_status_diode.green,
      label = {"colony-gui-hut.lab-staffed", workers, capacity}
    }
  else
    entity.custom_status = {
      diode = defines.entity_status_diode.red,
      label = {"colony-gui-hut.lab-unstaffed"}
    }
  end
end
M.update_lab_status = update_lab_status

-- One completed trip = one use of the hut's tool. Shared by `work.finish` (harvest) and the hunter, which
-- completes its trip the moment the animal dies rather than after a work animation.
local function use_tool(hut)
  local def = labour.HUTS[hut.entity.name]
  if not (def and def.tool) then return end
  local broke
  hut.wear, broke = labour.wear(hut.wear or 0)
  if broke and hut.entity.remove_item{name = def.tool, count = 1} > 0 then
    popup(hut.entity.surface, hut.entity.position, {"", "Tool broke: ", item_name(def.tool)})
  end
end

-- Labour buildings -------------------------------------------------------------------------------
local function hut_list(colony)
  local ids = {}
  for un, h in pairs(colony.huts) do if h.entity.valid then ids[#ids + 1] = un else colony.huts[un] = nil end end
  table.sort(ids)
  local out = {}
  for _, un in ipairs(ids) do out[#out + 1] = colony.huts[un] end
  return out
end

-- Machine index (#75) ------------------------------------------------------------------------------
-- find_haul_task used to walk every opted-in machine on every assignment and read its output inventory.
-- At 2000 machines that was ~3.9 of the ~5 ms/tick the #39 benchmark measured, and nearly all of it was
-- spent asking machines that had nothing to give. Machines are now swept in slices on a timer and the
-- sweep records `has_output`; assignment only visits machines with a request or with output.
M.MACHINE_SWEEP_TICKS = 30
M.MACHINE_SWEEP_SHARE = 10   -- 1/N of the registry per sweep, so each machine is checked every 300 ticks
M.MACHINE_OFFERS_PER_ASSIGN = 16   -- machines considered per trip; the cursor rotates through all of them

-- Sorted unit numbers plus the two working sets, rebuilt only when the registry changes (or a sweep
-- flips has_output). Everything downstream iterates the cached arrays, so the cost is per change rather
-- than per assignment. Returned tables are read-only for callers.
local function machine_ids(colony)
  if colony.machine_ids_cache and not colony.machine_dirty then return colony.machine_ids_cache end
  local ids = {}
  for un, m in pairs(colony.machines) do
    if m.entity.valid then ids[#ids + 1] = un else colony.machines[un] = nil end
  end
  table.sort(ids)
  local demand, output, damaged = {}, {}, {}
  for _, un in ipairs(ids) do
    local m = colony.machines[un]
    if m.enabled then
      if m.need and #m.need > 0 then demand[#demand + 1] = m end   -- refreshed by the sweep
      if m.has_output then output[#output + 1] = m end
      if m.damaged then damaged[#damaged + 1] = m end
    end
  end
  colony.machine_ids_cache, colony.machine_demand, colony.machine_output = ids, demand, output
  colony.machine_damaged = damaged
  colony.machine_dirty = false
  return ids
end

local function worker_count(h)
  local n = 0
  for _ in pairs(h.workers) do n = n + 1 end
  return n
end

function M.hut_info(h)
  local def = labour.HUTS[h.entity.name]
  -- A hut with no `tool` is gated by its inputs instead (#81): report its capacity as the allowance, and let
  -- the job itself refuse to start when there is nothing to work on.
  local tools = def.tool and h.entity.get_item_count(def.tool) or def.capacity
  return def, tools, labour.allowed(def.capacity, tools, h.limit), worker_count(h)
end

-- Construction (#37) ------------------------------------------------------------------------------
-- Ghosts and damage are not event-delivered (a player blueprint does not fire on_built_entity), so on a
-- timer each colony re-scans its own claimed area once and keeps a small registry. Assignment then reads
-- the registry instead of scanning the surface per trip.
local function sorted_keys(t)
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys)
  return keys
end

local function construct_open(colony)
  local ghosts, repairs = 0, 0
  for _, k in ipairs(sorted_keys(colony.ghosts or {})) do
    local g = colony.ghosts[k]
    if g.valid then
      if not colony.claimed[k] then ghosts = ghosts + 1 end
    else colony.ghosts[k] = nil end
  end
  for _, k in ipairs(sorted_keys(colony.repairs or {})) do
    local t = colony.repairs[k]
    if t.valid and construct.needs_repair(t.health, t.max_health) then
      if not colony.claimed[k] then repairs = repairs + 1 end
    else colony.repairs[k] = nil end
  end
  return ghosts + repairs
end

local function colony_area(colony)
  local hall = colony.hall
  if not (hall and hall.valid) then return nil end
  local minx, miny = hall.position.x - territory.HALL_RADIUS, hall.position.y - territory.HALL_RADIUS
  local maxx, maxy = hall.position.x + territory.HALL_RADIUS, hall.position.y + territory.HALL_RADIUS
  for _, t in pairs(colony.towers or {}) do
    if t.valid then
      minx = math.min(minx, t.position.x - territory.TOWER_RADIUS)
      miny = math.min(miny, t.position.y - territory.TOWER_RADIUS)
      maxx = math.max(maxx, t.position.x + territory.TOWER_RADIUS)
      maxy = math.max(maxy, t.position.y + territory.TOWER_RADIUS)
    end
  end
  return {{minx, miny}, {maxx, maxy}}
end

-- Damaged things the colony owns. Bounded: it reads its own registries, never the whole surface.
local function repair_candidates(colony)
  local out = {}
  local function add(e)
    if e and e.valid and construct.needs_repair(e.health, e.max_health) then out[#out + 1] = e end
  end
  add(colony.hall)
  for _, h in ipairs(colony_mod.house_list(colony)) do add(h.entity) end
  for _, h in ipairs(hut_list(colony)) do add(h.entity) end
  machine_ids(colony)   -- refreshes machine_damaged if the registry changed
  for _, m in ipairs(colony.machine_damaged or {}) do add(m.entity) end
  for _, c in ipairs(colony_mod.crate_list(colony)) do add(c.entity) end
  for _, t in pairs(colony.towers or {}) do add(t) end
  for _, p in pairs(colony.plots or {}) do add(p.entity) end
  return out
end

local function construct_scan(colony)
  colony.ghosts, colony.repairs = {}, {}
  local hall = colony.hall
  local area = colony_area(colony)
  if not (hall and hall.valid and area) then return 0, 0 end
  local ghosts = 0
  for _, g in ipairs(hall.surface.find_entities_filtered{type = "entity-ghost", area = area, force = hall.force}) do
    if g.valid and #construct.cost(g.ghost_prototype.items_to_place_this) > 0
      and territory.owner_at(colony.surface_index, g.position) == colony.id then
      colony.ghosts[key(g)] = g
      ghosts = ghosts + 1
    end
  end
  local repairs = 0
  for _, e in ipairs(repair_candidates(colony)) do
    colony.repairs[key(e)] = e
    repairs = repairs + 1
  end
  return ghosts, repairs
end

scheduler.register("construct.scan", function(d)
  local colony = storage.colonies[d.colony_id]
  if not (colony and colony.hall and colony.hall.valid) then return end
  construct_scan(colony)
  scheduler.after(construct.SCAN_TICKS, "construct.scan", {colony_id = colony.id})
end)

local function hut_resources(h)
  if h.job == "mine" then
    return mine_plan.order(h.ores)
  elseif h.job == "chop" then
    return {"wood"}
  elseif h.job == "forage" then
    return {"colony-forage"}
  elseif h.job == "hunt" then
    return {"colony-meat"}
  elseif h.job == "fish" then
    return {"colony-fish"}
  elseif h.job == "farm" then
    return {"colony-produce"}
  end
  return nil
end

local function hut_quota_met(colony, h)
  local res = hut_resources(h)
  if not res then return false, nil end
  local last_item = nil
  for _, item in ipairs(res) do
    if colony_mod.quota_met(colony, item) then
      last_item = item
    else
      return false, nil
    end
  end
  return true, last_item
end
M.hut_resources = hut_resources
M.hut_quota_met = hut_quota_met

local function job_slots(colony)
  local list = {}
  local active = {}
  for _, h in ipairs(hut_list(colony)) do
    local _, _, allowed, workers = M.hut_info(h)
    if hut_quota_met(colony, h) then allowed = 0 end
    if (colony.no_site[h.entity.unit_number] or 0) > game.tick or (colony.no_site[h.job] or 0) > game.tick then allowed = 0 end
    if allowed > 0 then active[h.job] = (active[h.job] or 0) + 1 end
    list[#list + 1] = {id = h.entity.unit_number, job = h.job, allowed = allowed, workers = workers, hut = h}
  end
  local slots = labour.free_slots(list)
  local capacity = labour.capacity_by_job(list)
  -- Construction has no hut: its slots are the open ghosts/repairs in the registry, minus current builders.
  capacity.construct = construct_open(colony)
  slots.construct = math.max(capacity.construct - (job_counts(colony).construct or 0), 0)
  return slots, capacity, list, active
end

-- Sites ------------------------------------------------------------------------------------------
local function dist2(a, b) local dx, dy = a.x - b.x, a.y - b.y; return dx * dx + dy * dy end

-- Nearest valid candidate, ties broken by unit_number so the choice is deterministic.
local function nearest(list, pos, accept)
  local best, best_d
  for _, e in ipairs(list) do
    if e.valid and (not accept or accept(e)) then
      local d = dist2(e.position, pos)
      if not best_d or d < best_d or (d == best_d and (e.unit_number or 0) < (best.unit_number or 0)) then best, best_d = e, d end
    end
  end
  return best
end

-- Rocks (rock-huge, rock-big, sand-rock-big...) are `simple-entity`s, not resource patches, but mining one gives
-- stone (and coal), so a Miner's Hut works them too. A rock is a one-off site: the colonist brings back its whole
-- average yield of the wanted ore and the rock is gone. Yields come from the prototype, which never changes at
-- runtime, so the cache is rebuilt identically on load.
local rock_yields = {}
local function rock_yield(e, ore)
  local y = rock_yields[e.name]
  if not y then
    y = {}
    local props = e.prototype.mineable_properties
    if props and props.minable then
      for _, p in ipairs(props.products or {}) do
        if p.type == "item" then
          local amt = p.amount or (((p.amount_min or 0) + (p.amount_max or 0)) / 2)
          y[p.name] = (y[p.name] or 0) + math.floor(amt * (p.probability or 1))
        end
      end
    end
    rock_yields[e.name] = y
  end
  return y[ore] or 0
end

local function find_rocks(s, base, radius, ore)
  local out = {}
  for _, r in ipairs(s.find_entities_filtered{position = base, radius = radius, type = "simple-entity"}) do
    if r.valid and r.name:find("rock", 1, true) and rock_yield(r, ore) > 0 then out[#out + 1] = r end
  end
  return out
end

-- A hut may work anything in its own radius that is not another colony's land. The radius is centred on a
-- hut that was itself built inside the colony, so a resource a few tiles past the drawn border is still
-- fair game: the old strict "owner == this colony" test made border huts look permanently empty.
local function harvestable(colony, t)
  local owner = territory.owner_at(colony.surface_index, t.position)
  return owner == nil or owner == colony.id
end

-- Harvest only in range and never on another colony's land (design §2.1), preferring the nearest site so
-- colonists visibly work the forest / berry patch / ore next to their hut instead of walking to a random
-- tree on the far edge of the radius.
local function find_site(colony, e, hut)
  local s, base, radius = e.surface, hut.entity.position, colony_mod.HUT_RADIUS
  local in_territory = function(t) return harvestable(colony, t) end
  local free = function(t) return in_territory(t) and not colony.claimed[key(t)] end
  if hut.job == "forage" then
    if colony_mod.quota_met(colony, "colony-forage") then return nil, "colony-forage" end
    return nearest(s.find_entities_filtered{name = "colony-forage-patch", position = base, radius = radius}, base, free)
  elseif hut.job == "chop" then
    if colony_mod.quota_met(colony, "wood") then return nil, "wood" end
    return nearest(s.find_entities_filtered{position = base, radius = radius, type = "tree"}, base, free)
  elseif hut.job == "mine" then
    -- Ore priority: work the best-ranked ore that is actually in range, so a hut does not walk past iron
    -- to grab the nearest stone. Ores sharing a rank fall back to distance (the old behaviour).
    -- Quota check (#84): skip any ore that has reached its quota; switch to the next open ore.
    local any_met, last_met = false, nil
    for _, ore in ipairs(mine_plan.order(hut.ores)) do
      if colony_mod.quota_met(colony, ore) then
        any_met = true
        last_met = ore
      else
        local site = nearest(s.find_entities_filtered{position = base, radius = radius, type = "resource", name = ore}, base, in_territory)
        local rock = nearest(find_rocks(s, base, radius, ore), base, in_territory)
        if site and rock then
          if dist2(rock.position, base) < dist2(site.position, base) then site = rock end
        else
          site = site or rock
        end
        if site then return site end
      end
    end
    if any_met and hut_quota_met(colony, hut) then
      return nil, last_met
    end
    return nil
  elseif hut.job == "preserve" then
    -- The smokehouse or kitchen is its own workplace, and it can only work when it holds its inputs.
    -- Returning nil leaves it unstaffed (and `no_site` stops the town from thrashing on it for a while).
    if hut.entity.name == "colony-kitchen" then
      return kitchen.recipe(chest_contents(hut.entity) or {}) and hut.entity
    end
    return preserve.recipe(chest_contents(hut.entity) or {}) and hut.entity
  elseif hut.job == "fish" then
    if colony_mod.quota_met(colony, "colony-fish") then return nil, "colony-fish" end
    -- The dock is the workplace: there is no world entity to harvest, the water is the resource, and whether
    -- there is enough of it was settled when the dock was built (model/fishing.lua). Everyone fishes the same
    -- dock, so it is never claimed.
    return hut.entity
  elseif hut.job == "hunt" then
    if colony_mod.quota_met(colony, "colony-meat") then return nil, "colony-meat" end
    -- Game roams, so it is picked by position *now*; the engine's attack command then does the chasing.
    -- One animal is claimed at a time so three hunters do not all shoot the same boar.
    local list = {}
    for un, rec in pairs(colony.animals or {}) do
      local a = rec.entity
      if a.valid and not colony.claimed["boar:" .. un] and dist2(a.position, base) <= radius * radius
          and in_territory(a) then
        list[#list + 1] = {unit_number = un, position = a.position, entity = a}
      end
    end
    local pick = hunting.nearest(list, base, radius)
    return pick and pick.entity
  elseif hut.job == "farm" then
    if colony_mod.quota_met(colony, "colony-produce") then return nil, "colony-produce" end
    -- Ripe plots first (food now), then fallow plots (plant for later); nearest wins, ties by unit_number.
    local best, best_ripe, best_d, r2 = nil, false, nil, radius * radius
    for un, plot in pairs(colony.plots or {}) do
      local pe = plot.entity
      if not pe.valid then
        colony.plots[un] = nil
      elseif (plot.stage == farm.FALLOW or plot.stage == farm.RIPE) and not colony.claimed[key(pe)]
          and in_territory(pe) and dist2(pe.position, base) <= r2 then
        local ripe, d = plot.stage == farm.RIPE, dist2(pe.position, base)
        if not best or (ripe and not best_ripe) or (ripe == best_ripe and
            (d < best_d or (d == best_d and un < best.unit_number))) then
          best, best_ripe, best_d = pe, ripe, d
        end
      end
    end
    return best
  elseif hut.job == "research" then
    -- The archive or university is its own workplace (#42). Scholars staff the facility when it holds science packs.
    local packs = science.PACKS_BY_LAB[hut.entity.name] or {}
    local contents = chest_contents(hut.entity)
    if not contents then return nil end
    local have = false
    for _, p in ipairs(packs) do
      if (contents[p] or 0) > 0 then have = true; break end
    end
    return have and hut.entity or nil
  end
end

-- How many harvestable sites the hut can currently see (GUI feedback for "nothing in range").
function M.site_count(h)
  local colony = storage.colonies[h.colony_id]
  if not (colony and h.entity.valid) then return 0 end
  if h.job == "research" or h.job == "preserve" or h.job == "fish" then return 1 end
  local s, base, radius = h.entity.surface, h.entity.position, colony_mod.HUT_RADIUS
  local in_territory = function(t) return harvestable(colony, t) end
  local free = function(t) return in_territory(t) and not colony.claimed[key(t)] end
  if h.job == "farm" then
    local n = 0
    for _, plot in pairs(colony.plots or {}) do
      if plot.entity.valid and (plot.stage == farm.FALLOW or plot.stage == farm.RIPE) and free(plot.entity) then n = n + 1 end
    end
    return n
  end
  if h.job == "mine" then
    local n = 0
    for _, ore in ipairs(mine_plan.order(h.ores)) do
      for _, e in ipairs(s.find_entities_filtered{position = base, radius = radius, type = "resource", name = ore}) do
        if e.valid and free(e) then n = n + 1 end
      end
      for _, e in ipairs(find_rocks(s, base, radius, ore)) do
        if free(e) then n = n + 1 end
      end
    end
    return n
  end
  local list
  if h.job == "forage" then list = s.find_entities_filtered{name = "colony-forage-patch", position = base, radius = radius}
  else list = s.find_entities_filtered{position = base, radius = radius, type = "tree"} end
  local n = 0
  for _, e in ipairs(list) do if e.valid and free(e) then n = n + 1 end end
  return n
end

-- What a colonist is carrying, drawn over its head (always, not only in alt-mode), so goods visibly travel
-- instead of vanishing from one chest and appearing in another. Refreshed whenever the colonist is sent
-- somewhere or goes idle, which is exactly when its load can have changed.
local function show_carry(e)
  local un = e.unit_number
  local st = storage.unit_state[un]
  local item = st and st.state ~= "to_pickup" and st.state ~= "to_pool" and st.carry and st.carry[1] and st.carry[1].item
  local sprites = storage.carry_sprites
  local cur = sprites[un]
  if cur and cur.item == item and cur.obj.valid then return end
  if cur and cur.obj.valid then cur.obj.destroy() end
  sprites[un] = nil
  if item and prototypes.item[item] then
    sprites[un] = {item = item, obj = rendering.draw_sprite{sprite = "item/" .. item, surface = e.surface,
      target = {entity = e, offset = {0, -1.1}}, x_scale = 0.4, y_scale = 0.4}}
  end
end
M.show_carry = show_carry

local function go(e, dest, radius)
  local cmd = {type = defines.command.go_to_location, radius = radius, distraction = defines.distraction.none}
  if type(dest) == "table" and dest.x then cmd.destination = dest else cmd.destination_entity = dest end
  e.commandable.set_command(cmd)
  show_carry(e)
end

-- Hunting (#79): the engine does the chasing and the shooting. The colonist prototype carries a ranged
-- hitscan attack and the animal is on a force nobody is at war with, so this is a real kill, with real
-- damage, and no aggro to the colony.
function M.command_attack(e, animal)
  if not (e and e.valid and animal and animal.valid) then return end
  e.commandable.set_command{type = defines.command.attack, target = animal,
    distraction = defines.distraction.none}
end

-- Haul planning ----------------------------------------------------------------------------------
-- House demand: critical (already unmet / never evaluated) beats buffering a well-stocked house.
local function house_offer(colony, h)
  local tier = housing.TIERS[h.kind]
  local occupants = h.occupants or 0
  local stock = colony_mod.house_stock_cached(h)
  local demands = housing.demand(tier, stock, h.inflight, colony_mod.is_powered(h), occupants)
  if #demands == 0 then return nil end
  local critical = false
  for _, need in ipairs(tier.needs) do
    if need.critical then
      local ok = h.sat and h.sat[need.id]
      if ok == false or (ok == nil and occupants > 0) then critical = true end
    end
  end
  return {kind = "supply", house = h, priority = critical and haul_plan.PRIORITY.critical or haul_plan.PRIORITY.buffer,
    key = h.entity.unit_number, demands = demands}
end

local function hut_offer(h)
  local def, tools = M.hut_info(h)
  if def.tool then
    local inflight = h.inflight[def.tool] or 0
    if tools == 0 then
      -- A hut with no tool cannot work at all, so it asks for exactly one before any hut tops up. Without
      -- this an older hut's full-capacity request ate a scarce supply and a newer hut (often the one built
      -- further out) never got its first tool. Once one is on the way, wait for it rather than pile up.
      if inflight > 0 then return nil end
      return {kind = "supply", hut = h, priority = haul_plan.PRIORITY.tools, key = h.entity.unit_number,
        deficit = def.capacity * 10 + 1, demands = {{item = def.tool, count = 1}}}
    end
    local want = math.min(def.capacity, h.limit or def.capacity) - tools - inflight
    if want >= 1 then
      return {kind = "supply", hut = h, priority = haul_plan.PRIORITY.tools, key = h.entity.unit_number,
        demands = {{item = def.tool, count = want}}}
    end
    if def.inputs then
      local demands = {}
      local contents = chest_contents(h.entity) or {}
      for _, inp in ipairs(def.inputs) do
        local deficit = inp.count - (contents[inp.item] or 0) - (h.inflight[inp.item] or 0)
        if deficit > 0 then demands[#demands + 1] = {item = inp.item, count = deficit} end
      end
      if #demands > 0 then
        return {kind = "supply", hut = h, priority = haul_plan.PRIORITY.request, key = h.entity.unit_number,
          demands = demands}
      end
    end
    return nil
  end
  -- No tool: the hut asks for its inputs instead (#81, #44, #42). A request, not a critical need, so houses are always
  -- served first and a smokehouse, kitchen or archive can never eat the town's dinner.
  local demands
  if h.job == "research" then
    demands = science.wants(h.entity.name, chest_contents(h.entity) or {}, h.inflight)
  elseif h.entity.name == "colony-kitchen" then
    demands = kitchen.wants(chest_contents(h.entity) or {}, h.inflight)
  else
    demands = preserve.wants(chest_contents(h.entity) or {}, h.inflight)
  end
  if #demands == 0 then return nil end
  return {kind = "supply", hut = h, priority = haul_plan.PRIORITY.request, key = h.entity.unit_number,
    demands = demands}
end

-- Finished goods sit in the hut until a hauler clears them, so the hut is the local stockpile and the
-- colonist never walks every load home. Everything except the hut's own tool is fair game.
-- For lab entities, collects from defines.inventory.lab_trash so spoilage is composted (#42).
local function hut_collect_offer(h)
  local def = labour.HUTS[h.entity.name]
  local inv = h.entity.type == "lab"
    and h.entity.get_inventory(defines.inventory.lab_trash)
    or h.entity.get_inventory(defines.inventory.chest)
  if not (def and inv and not inv.is_empty()) then return nil end
  local demands, available, keep = {}, {}, {}
  for _, item in ipairs(def.keep or {}) do keep[item] = true end
  for _, c in ipairs(inv.get_contents()) do
    -- Inputs stay put: a Smokehouse's salt and raw food are not output to be hauled away (#81).
    if c.name ~= def.tool and not keep[c.name] then
      demands[#demands + 1] = {item = c.name, count = c.count}
      available[c.name] = c.count
    end
  end
  if #demands == 0 then return nil end
  return {kind = "collect", hut = h, priority = haul_plan.PRIORITY.hut_output, key = h.entity.unit_number,
    demands = demands, available = available}
end

-- Crates (#33): a supply crate is a provider (empty it into stock), a demand crate is a requester (fill it
-- to the player's filters). A warehouse needs no offer of its own: colony.stock_count/take_stock/put_stock
-- already treat it as colony storage, both as a source and as overflow.
local function crate_contents(c) return chest_contents(c.entity) end

-- A bin's finished fertilizer, offered like a supply crate's contents.
local function bin_offer(b)
  local n = b.entity.get_item_count(compost.PRODUCT)
  if n < 1 then return nil end
  return {kind = "collect", bin = b, priority = haul_plan.PRIORITY.collect, key = b.entity.unit_number,
    demands = {{item = compost.PRODUCT, count = n}}, available = {[compost.PRODUCT] = n}}
end

-- A salt pan's contents, offered exactly like a supply crate's: evaporation is nobody's job, but hauling the
-- salt away is (#81).
local function salt_offer(pan)
  local n = pan.entity.get_item_count(salt.ITEM)
  if n < 1 then return nil end
  return {kind = "collect", pan = pan, priority = haul_plan.PRIORITY.collect, key = pan.entity.unit_number,
    demands = {{item = salt.ITEM, count = n}}, available = {[salt.ITEM] = n}}
end

-- A well's water, offered like a salt pan's: generation is nobody's job, but hauling the water
-- away is (#43).
local function well_offer(w)
  local n = w.entity.get_item_count(well.ITEM)
  if n < 1 then return nil end
  return {kind = "collect", well = w, priority = haul_plan.PRIORITY.collect, key = w.entity.unit_number,
    demands = {{item = well.ITEM, count = n}}, available = {[well.ITEM] = n}}
end

local function crate_supply_offer(c)
  local contents = crate_contents(c)
  if not contents then return nil end
  local demands = crates.supply(contents)
  if #demands == 0 then return nil end
  return {kind = "collect", crate = c, priority = haul_plan.PRIORITY.collect, key = c.entity.unit_number,
    demands = demands, available = contents}
end

local function crate_demand_offer(c)
  local contents = crate_contents(c) or {}
  local demands = crates.demands(c.filters, contents, c.inflight)
  if #demands == 0 then return nil end
  return {kind = "supply", crate = c, priority = haul_plan.PRIORITY.request, key = c.entity.unit_number,
    demands = demands}
end

local function machine_demands(m)
  local out = {}
  for _, req in pairs(m.requests or {}) do
    local want = req.count - m.entity.get_item_count(req.item) - (m.inflight[req.item] or 0)
    if want >= 1 then out[#out + 1] = {item = req.item, count = want} end
  end
  table.sort(out, function(a, b) return a.item < b.item end)
  return out
end

-- Offers use the need list the sweep cached, so an assignment never touches a machine inventory. In-flight
-- loads are subtracted here because they change between sweeps.
local function machine_offer(m)
  if not m.entity.valid or not m.enabled or (m.blocked_until or 0) > game.tick then return nil end
  local need = m.need
  if not need then return nil end
  local demands, any = {}, false
  for _, d in ipairs(need) do
    local n = d.count - (m.inflight[d.item] or 0)
    if n >= 1 then demands[#demands + 1] = {item = d.item, count = n}; any = true end
  end
  if not any then return nil end
  return {kind = "supply", machine = m, priority = haul_plan.PRIORITY.request, key = m.entity.unit_number, demands = demands}
end

-- Finished products leave the machine now; the load is filled from the machine, not the hall.
local function collect_offer(colony, m)
  if not m.entity.valid or not m.enabled or not m.collect then return nil end
  local inv = m.entity.get_output_inventory()
  if not inv or inv.is_empty() then
    if m.has_output then m.has_output, colony.machine_dirty = false, true end   -- emptied since the sweep
    return nil
  end
  local demands, available = {}, {}
  for _, c in ipairs(inv.get_contents()) do
    demands[#demands + 1] = {item = c.name, count = c.count}
    available[c.name] = (available[c.name] or 0) + c.count
  end
  return {kind = "collect", machine = m, priority = haul_plan.PRIORITY.collect, key = m.entity.unit_number,
    demands = demands, available = available}
end

-- Slice sweep (#75): the only place that touches machine inventories when nobody is asking for a haul.
-- Each machine is visited every MACHINE_SWEEP_TICKS * MACHINE_SWEEP_SHARE ticks; the sweep records what
-- it saw (has_output, need) and assignment reads those flags. A machine's own request therefore lags by
-- at most one sweep, which is invisible next to the time a colonist spends walking.
scheduler.register("work.machine_sweep", function(d)
  local colony = storage.colonies[d.colony_id]
  if not (colony and colony.hall and colony.hall.valid) then return end
  local ids = machine_ids(colony)
  local n = #ids
  if n > 0 then
    local step = math.max(1, math.ceil(n / M.MACHINE_SWEEP_SHARE))
    local cursor = colony.machine_cursor or 1
    local changed = false
    for i = 0, step - 1 do
      local m = colony.machines[ids[(cursor - 1 + i) % n + 1]]
      if m and m.entity.valid then
        local has, need = false, nil
        if m.enabled then
          if m.collect then
            local inv = m.entity.get_output_inventory()
            has = inv ~= nil and not inv.is_empty()
          end
          if next(m.requests or {}) then
            need = machine_demands(m)
            if #need == 0 then need = nil end
          end
        end
        if has ~= (m.has_output or false) then m.has_output, changed = has, true end
        -- Health is read here too: construct.scan used to read it for every machine every 300 ticks,
        -- which was a 13 ms tick at 2000 machines (#75).
        local hurt = m.entity.health < m.entity.max_health
        if hurt ~= (m.damaged or false) then m.damaged, changed = hurt, true end
        -- Badge tint (world view of the supply network): green stocked, orange waiting on a hauler, red
        -- starved because the colony has none. Only recoloured when the state flips.
        local state = "ok"
        if need then
          state = "wait"
          for _, d in ipairs(need) do
            if colony_mod.stock_count(colony, d.item) <= 0 and (m.inflight[d.item] or 0) <= 0 then state = "starved"; break end
          end
        end
        if state ~= m.badge_state and m.badge and m.badge.valid then
          m.badge_state = state
          m.badge.color = state == "ok" and {0.4, 1, 0.4} or (state == "wait" and {1, 0.75, 0.3} or {1, 0.3, 0.3})
        end
        if need and not m.need then m.need, changed = need, true
        elseif not need and m.need then m.need, changed = nil, true
        else m.need = need end
      end
    end
    colony.machine_cursor = (cursor - 1 + step) % n + 1
    if changed then colony.machine_dirty = true end
  end
  scheduler.after(M.MACHINE_SWEEP_TICKS, "work.machine_sweep", d)
end)

-- Cars a pool has out on the road right now (a handful at most, so counting beats keeping a counter in sync).
local function trucks_out(pool)
  local n = 0
  for _, t in pairs(storage.trucks or {}) do if t.pool == pool then n = n + 1 end end
  return n
end

-- A Motor Pool (#60) asks for fuel, and for cars while the colony has any in stock.
local function pool_offer(colony, p)
  local demands = motor.wants(chest_contents(p.entity) or {}, p.inflight,
    {[motor.CAR] = colony_mod.stock_count(colony, motor.CAR)}, trucks_out(p))
  if #demands == 0 then return nil end
  return {kind = "supply", pool = p, priority = haul_plan.PRIORITY.request, key = p.entity.unit_number,
    demands = demands}
end

-- One destination per trip, possibly several item types. Returns an offer with `.load` filled in.
-- `cap` is what the carrier holds: a colonist's hands by default, a truck's bed when one is driving.
local function find_haul_task(colony, cap)
  local offers = {}
  for _, h in ipairs(colony_mod.house_list(colony)) do
    local o = house_offer(colony, h); if o then offers[#offers + 1] = o end
  end
  for _, h in ipairs(hut_list(colony)) do
    local o = hut_offer(h); if o then offers[#offers + 1] = o end
    local c = hut_collect_offer(h); if c then offers[#offers + 1] = c end
  end
  for _, c in ipairs(colony_mod.crate_list(colony, crates.SUPPLY)) do
    local o = crate_supply_offer(c); if o then offers[#offers + 1] = o end
  end
  for _, c in ipairs(colony_mod.crate_list(colony, crates.DEMAND)) do
    local o = crate_demand_offer(c); if o then offers[#offers + 1] = o end
  end
  -- Compost (#78): carry the bin's fertilizer out to colony stock, and carry stock spoilage in to it.
  for _, p in ipairs(colony_mod.salt_pan_list(colony)) do
    local o = salt_offer(p); if o then offers[#offers + 1] = o end
  end
  for _, w in ipairs(colony_mod.well_list(colony)) do
    local o = well_offer(w); if o then offers[#offers + 1] = o end
  end
  for _, p in ipairs(colony_mod.pool_list(colony)) do
    local o = pool_offer(colony, p); if o then offers[#offers + 1] = o end
  end
  local bins = colony_mod.bin_list(colony)
  for _, b in ipairs(bins) do
    local o = bin_offer(b); if o then offers[#offers + 1] = o end
  end
  if #bins > 0 then
    local spoil = colony_mod.stock_count(colony, compost.SOURCE)
    if spoil > 0 then
      local bin = bins[1]
      -- A full batch is worth a trip like any collection: in a town whose haulers are always busy with hut output,
      -- the compost band alone never comes up and the hall's spoilage would sit there for good.
      local band = spoil >= compost.SPOILAGE_PER_FERTILIZER and haul_plan.PRIORITY.collect or haul_plan.PRIORITY.compost
      offers[#offers + 1] = {kind = "compost", bin = bin, priority = band,
        key = bin.entity.unit_number, demands = {{item = compost.SOURCE, count = spoil}},
        available = {[compost.SOURCE] = spoil}}
    end
  end
  machine_ids(colony)   -- refresh the working sets if the registry changed
  -- A big town has thousands of machines wanting the same ore; building an offer for every one of them on
  -- every trip is what made the demand case 17 ms/tick in the #39 benchmark. Take a bounded slice instead:
  -- any machine wanting an item we hold is a valid destination, and the cursor means every machine is still
  -- looked at regularly (2000 machines / 16 per trip is a full pass every ~120 assignments).
  local demand = colony.machine_demand or {}
  local n = #demand
  if n > 0 then
    local take = math.min(n, M.MACHINE_OFFERS_PER_ASSIGN)
    local cursor = colony.machine_offer_cursor or 1
    for i = 0, take - 1 do
      local o = machine_offer(demand[(cursor - 1 + i) % n + 1])
      if o then offers[#offers + 1] = o end
    end
    colony.machine_offer_cursor = (cursor - 1 + take) % n + 1
  end
  local output = colony.machine_output or {}
  local no, ocursor = #output, colony.collect_offer_cursor or 1
  if no > 0 then
    local take = math.min(no, M.MACHINE_OFFERS_PER_ASSIGN)
    for i = 0, take - 1 do
      local c = collect_offer(colony, output[(ocursor - 1 + i) % no + 1])
      if c then offers[#offers + 1] = c end
    end
    colony.collect_offer_cursor = (ocursor - 1 + take) % no + 1
  end
  if #offers == 0 then return nil, 0 end
  local backlog = 0
  for _, o in ipairs(offers) do
    if o.priority < haul_plan.PRIORITY.buffer then backlog = backlog + 1 end
  end
  haul_plan.order(offers)
  local hall = colony_mod.stock_table(colony)
  local offer, load = haul_plan.choose(offers, hall, cap or M.CARRY_CAP)
  if not offer then return nil, backlog end
  offer.load = load
  return offer, backlog
end

-- Take the load out of its source. The returned stacks hold the amounts that really left, so a
-- partially filled request can never duplicate items.
local function take_load(colony, offer)
  local taken = {}
  for _, s in ipairs(offer.load) do
    local n
    if offer.kind == "collect" then
      local src = offer.machine and offer.machine.entity or (offer.hut and offer.hut.entity)
        or (offer.crate and offer.crate.entity) or (offer.pan and offer.pan.entity)
        or (offer.well and offer.well.entity) or offer.bin.entity
      n = src.remove_item{name = s.item, count = s.count}
    else
      n = colony_mod.take_stock(colony, s.item, s.count)
    end
    if n and n > 0 then taken[#taken + 1] = {item = s.item, count = n} end
  end
  if #taken == 0 then return nil end
  if offer.kind == "supply" then
    local target = offer.house or offer.machine or offer.hut or offer.crate or offer.pan or offer.pool
    for _, s in ipairs(taken) do target.inflight[s.item] = (target.inflight[s.item] or 0) + s.count end
    return taken, target
  end
  return taken, nil
end

local function return_to_hall(colony, stacks)
  local hall = colony.hall
  if not (hall and hall.valid) then return end
  for _, s in ipairs(stacks) do
    local n = colony_mod.put_stock(colony, s.item, s.count)   -- hall first, then warehouses
    if n < s.count then
      hall.surface.spill_item_stack{position = hall.position, stack = {name = s.item, count = s.count - n}, allow_belts = false}
    end
  end
end

-- Trip start / finish ----------------------------------------------------------------------------
local function stock_map(colony, cost)
  local m = {}
  for _, s in ipairs(cost) do m[s.item] = colony_mod.stock_count(colony, s.item) end
  return m
end

-- Nearest open construction job: repairs first (keep what is already built), then ghosts the colony can pay for.
local function find_construct_site(colony, pos)
  local best, best_d, best_kind, best_cost
  for _, k in ipairs(sorted_keys(colony.repairs or {})) do
    local t = colony.repairs[k]
    if t.valid then
      if not colony.claimed[k] and construct.needs_repair(t.health, t.max_health)
        and colony_mod.stock_count(colony, construct.REPAIR_PACK) > 0 then
        local d = dist2(t.position, pos)
        if not best_d or d < best_d then best, best_d, best_kind = t, d, "repair" end
      end
    else colony.repairs[k] = nil end
  end
  if best then return {kind = best_kind, target = best, key = key(best)} end
  for _, k in ipairs(sorted_keys(colony.ghosts or {})) do
    local g = colony.ghosts[k]
    if g.valid then
      if not colony.claimed[k] and (colony.ghost_blocked[k] or 0) <= game.tick then
        local cost = construct.cost(g.ghost_prototype.items_to_place_this)
        if #cost > 0 and construct.affordable(cost, stock_map(colony, cost)) then
          local d = dist2(g.position, pos)
          if not best_d or d < best_d then best, best_d, best_kind, best_cost = g, d, "build", cost end
        end
      end
    else colony.ghosts[k] = nil end
  end
  if not best then return nil end
  return {kind = "build", target = best, key = key(best), cost = best_cost}
end

-- Pay for the job up front (like a hauler taking a load), then walk there and work. Paying first means a
-- ghost is never half-built by two colonists who both counted the same stock.
local function start_construct(colony, un, e)
  local site = find_construct_site(colony, e.position)
  if not site then return false end
  local carry, got = {}, 0
  if site.kind == "build" then
    for _, s in ipairs(site.cost) do
      local n = colony_mod.take_stock(colony, s.item, s.count)
      if n < s.count then                      -- someone else bought it first: put ours back and wait
        if n > 0 then colony_mod.put_stock(colony, s.item, n) end
        if #carry > 0 and colony.hall.valid then return_to_hall(colony, carry) end
        return false
      end
      carry[#carry + 1] = {item = s.item, count = n}
      got = got + n
    end
  else
    local n = colony_mod.take_stock(colony, construct.REPAIR_PACK, 1)
    if n < 1 then return false end
    carry[1] = {item = construct.REPAIR_PACK, count = n}
    got = n
  end
  if got <= 0 then return false end
  colony.claimed[site.key] = true
  storage.unit_state[un] = {colony_id = colony.id, job = "construct", state = "to_construct",
    kind = site.kind, site = site.target, site_key = site.key, carry = carry}
  set_label(e, M.LABELS.construct)
  go(e, site.target.position, 2)
  return true
end

local function start_trip(colony, un, hut)
  local e = colony.colonists[un]
  local site, quota_item = find_site(colony, e, hut)
  if not site then
    hut.workers[un] = nil
    if quota_item then
      if e and e.valid then popup(e.surface, e.position, {"colony-message.quota-reached", item_name(quota_item)}) end
    else
      colony.no_site[hut.entity.unit_number] = game.tick + 600
    end
    return false
  end
  -- Resources are shared; trees/patches/plots are not; an animal is claimed by unit_number because its
  -- position moves under our feet.
  if hut.job == "hunt" then
    colony.claimed["boar:" .. site.unit_number] = true
  elseif hut.job ~= "mine" and hut.job ~= "fish" and hut.job ~= "preserve" and hut.job ~= "research" then
    colony.claimed[key(site)] = true
  end
  if hut.job == "hunt" then
    storage.unit_state[un] = {colony_id = colony.id, job = "hunt", hut = hut, state = "hunting", site = site,
      site_key = "boar:" .. site.unit_number, attempts = 0}
    set_label(e, M.LABELS.hunt)
    M.command_attack(e, site)
    return true
  end
  storage.unit_state[un] = {colony_id = colony.id, job = hut.job, hut = hut, state = "to_site", site = site,
    site_key = key(site)}
  set_label(e, M.LABELS[hut.job])
  go(e, site, 1.5)
  return true
end

local function idle(colony, un, e)
  -- A surplus colonist re-runs the whole job matrix on every retry and almost always finds nothing, which
  -- was most of the colony's Lua time in the #22 benchmark. Each fruitless retry waits a little longer; any
  -- real assignment replaces this state and starts over, and a hut, priority or target change wakes the town
  -- through reassign_workforce regardless of the timer.
  local prev = storage.unit_state[un]
  -- A young colony stays snappy (its few idle colonists must notice new work quickly); only a big town backs off.
  local cap = math.min(1 + math.floor(colony_mod.live_colonists(colony) / M.RETRY_BACKOFF_POP), M.RETRY_BACKOFF_MAX)
  local misses = math.min((prev and prev.state == "idle" and prev.misses or 0) + 1, cap)
  storage.unit_state[un] = {colony_id = colony.id, state = "idle", misses = misses}
  set_label(e, "idle")
  show_carry(e)
  -- Deterministic jitter by unit number: a town spawned in one tick would otherwise retry in lockstep.
  scheduler.after(M.RETRY_TICKS * misses + (un * 37) % 240, "work.retry", {un = un})
end

-- Start a haul trip if there is one; returns true when the colonist is on its way.
-- Take a task's load and build the hauler state that delivers it: (state table, destination), or nil.
local function haul_trip(colony, task)
  local taken, inflight_target = take_load(colony, task)
  if not taken then return nil end
  -- Where the load physically is: a collect is picked up at its source, anything from colony stock at the hall.
  local pickup = colony.hall.position
  if task.kind == "collect" then
    local src = task.machine or task.hut or task.crate or task.pan or task.well or task.bin
    pickup = src.entity.position
  end
  local dest, state = nil, "to_house"
  if task.kind == "collect" then dest, state = colony.hall.position, "to_hall"
  elseif task.kind == "compost" then dest, state = task.bin.entity.position, "to_bin"
  elseif task.house then dest = task.house.entity.position
  elseif task.machine then dest = task.machine.entity.position
  elseif task.crate then dest = task.crate.entity.position
  elseif task.pool then dest = task.pool.entity.position
  else dest = task.hut.entity.position end
  return {colony_id = colony.id, job = "haul", state = state, bin = task.bin,
    target = inflight_target or (task.kind == "collect" and task.machine or nil), inflight_target = inflight_target,
    carry = taken, pickup = {x = pickup.x, y = pickup.y}, dest = dest}, dest
end

M.PICKUP_SKIP = 4   -- tiles: a hauler already this close to the load does not make a separate pickup walk

-- Send a hauler (or truck) on its trip: to the pickup first, then the destination. The load is claimed when the
-- trip starts (so two haulers never count the same items), but it only shows on the carrier once it is
-- collected, and the carrier really walks there: distance to the source costs time, which is what trucks and
-- forward stockpiles are for.
local function set_off(e, st)
  local p = st.pickup
  if p and dist2(e.position, p) > M.PICKUP_SKIP * M.PICKUP_SKIP then
    st.next_state, st.state = st.state, "to_pickup"
    go(e, p, 2.5)
  else
    st.pickup = nil
    go(e, st.dest, 3)
  end
end

local function start_haul(colony, un, e, task, label)
  if not task then return false end
  local st = haul_trip(colony, task)
  if not st then return false end
  storage.unit_state[un] = st
  set_label(e, label or "hauler")
  set_off(e, st)
  return true
end

-- Motor Pool trucks (#60) --------------------------------------------------------------------------
-- A car cannot be driven by a unit, so the hauler does not sit in a `car`: it walks to the pool, waits inside it
-- (teleported onto the pool under a stop order, labelled "driving"), and a `colony-truck` unit does the trip in its
-- place. The truck is a hauler with a bigger load and a faster walk. It keeps taking big loads until its fuel is
-- spent or there is nothing big left to move, then drives back, the car goes back on the pool's floor, and the
-- hauler steps out where the truck stopped.
M.POOL_REACH = 48    -- a hauler only detours to a pool this close (tiles)

-- The nearest pool within reach that has a car and fuel, or nil.
local function dispatch_pool(colony, pos)
  local best, best_d
  for _, p in ipairs(colony_mod.pool_list(colony)) do
    local d = dist2(p.entity.position, pos)
    local contents = chest_contents(p.entity) or {}
    if d <= M.POOL_REACH * M.POOL_REACH and (not best_d or d < best_d)
        and (motor.can_dispatch(contents) or ((contents[motor.CAR] or 0) > 0 and (p.tank or 0) > 0)) then
      best, best_d = p, d
    end
  end
  return best
end

-- Put a checked-out car back: on the pool's floor, or in colony stock when the pool is gone or full.
local function return_car(colony, pool)
  if pool and pool.entity.valid and pool.entity.insert{name = motor.CAR, count = 1} > 0 then return end
  return_to_hall(colony, {{item = motor.CAR, count = 1}})
end

-- Is the haul this colonist was about to make big enough for a truck? `task.load` is already capped at one
-- colonist's hands, so a full hand-load with more still wanted is the signal.
local function wants_truck(task)
  return task and haul_plan.total(task.load) >= M.CARRY_CAP and motor.worth_truck(haul_plan.deficit(task))
end

-- Send a hauler to the pool to check a car out. The car and the truck-sized load are both claimed now, exactly
-- as a hauler on foot claims its load when it sets off: otherwise the walkers empty the source 20 at a time
-- while the driver is still on the way to the pool, and the truck comes out to nothing (the m1_motor spike).
local function start_drive(colony, un, e, task)
  if not (next(colony.pools or {}) and wants_truck(task)) then return false end
  local pool = dispatch_pool(colony, e.position)
  if not pool then return false end
  local big = find_haul_task(colony, motor.CAPACITY)
  if not (big and motor.worth_truck(haul_plan.total(big.load))) then return false end
  if pool.entity.remove_item{name = motor.CAR, count = 1} < 1 then return false end
  local trip, dest = haul_trip(colony, big)
  if not trip then return_car(colony, pool); return false end
  storage.unit_state[un] = {colony_id = colony.id, job = "haul", state = "to_pool", pool = pool, car = true,
    carry = trip.carry, inflight_target = trip.inflight_target, trip = trip, dest = dest}
  set_label(e, "hauler → motor pool")
  go(e, pool.entity.position, 3)
  return true
end

-- Burn one fuel item from the pool. Returns the trips it bought, or nil when the pool is dry. Trips a parked
-- truck had left (`pool.tank`) are used first, so fuel already burnt is never thrown away.
local function burn_fuel(pool)
  if not (pool and pool.entity.valid) then return nil end
  if (pool.tank or 0) > 0 then
    local trips = pool.tank
    pool.tank = nil
    return trips
  end
  local fuel, trips = motor.refuel(chest_contents(pool.entity) or {})
  if not fuel or pool.entity.remove_item{name = fuel, count = 1} < 1 then return nil end
  return trips
end

-- The hauler arrived at the pool: fuel up, bring the truck out, and wait inside.
local function board(colony, un, e, st)
  local pool = st.pool
  local trips = burn_fuel(pool)
  local pos = trips and e.surface.find_non_colliding_position("colony-truck", pool.entity.position, 8, 0.5)
  local truck = pos and e.surface.create_entity{name = "colony-truck", position = pos, force = e.force}
  if not truck then
    if trips then pool.tank = (pool.tank or 0) + trips end   -- nowhere to put the truck: keep the fuel
    return false                                        -- the caller releases the car and the load
  end
  script.register_on_object_destroyed(truck)
  storage.trucks[truck.unit_number] = {entity = truck, colony_id = colony.id, driver = un, pool = pool, trips = trips - 1}
  storage.unit_state[truck.unit_number] = st.trip      -- the load the driver claimed at checkout rides in the truck
  storage.unit_state[un] = {colony_id = colony.id, job = "haul", state = "driving", truck = truck.unit_number}
  -- `LuaEntity.active` is read-only in 2.0, so the driver is parked with a stop order instead: it waits on the
  -- pool, and the next command (release_driver -> assign) replaces it.
  e.teleport(pool.entity.position)
  e.commandable.set_command{type = defines.command.stop, ticks_to_wait = 4294967295, distraction = defines.distraction.none}
  set_label(e, "driving 🚚")
  show_carry(e)
  popup(e.surface, pos, "🚚")
  set_label(truck, "truck 🚚")
  set_off(truck, st.trip)
  return true
end

-- The driver climbs out next to wherever the truck stopped and goes back to the job matrix.
local function release_driver(colony, t, pos)
  local d = colony.colonists[t.driver]
  if not (d and d.valid) then return end
  local spot = d.surface.find_non_colliding_position("colony-colonist", pos, 8, 0.5)
  if spot then d.teleport(spot) end
  storage.unit_state[t.driver] = {colony_id = colony.id, state = "idle"}
  M.assign(colony, t.driver)
end

local function park(colony, tun)
  local t = storage.trucks[tun]
  if not t then return end
  storage.trucks[tun], storage.unit_state[tun] = nil, nil
  local e = t.entity
  local pos = e.valid and e.position or (t.pool.entity.valid and t.pool.entity.position) or colony.hall.position
  return_car(colony, t.pool)
  if t.pool.entity.valid and (t.trips or 0) > 0 then t.pool.tank = (t.pool.tank or 0) + t.trips end
  if e.valid then e.destroy() end
  release_driver(colony, t, pos)
end
M.park = park

local function send_home(colony, tun, e)
  local t = storage.trucks[tun]
  local dest = (t.pool.entity.valid and t.pool.entity) or colony.hall
  storage.unit_state[tun] = {colony_id = colony.id, job = "haul", state = "to_park"}
  set_label(e, "truck → motor pool")
  go(e, dest.position, 4)
end

-- A truck's own assignment: another big load while it has fuel, a driver and daylight; otherwise home.
local function assign_truck(colony, tun)
  local t = storage.trucks[tun]
  local e = t.entity
  if not e.valid then storage.trucks[tun] = nil; return end
  local driver = colony.colonists[t.driver]
  if not (driver and driver.valid) or M.is_sleep_time(e.surface) or t.trips <= 0 then
    return send_home(colony, tun, e)
  end
  local task = find_haul_task(colony, motor.CAPACITY)
  if task and motor.worth_truck(haul_plan.total(task.load)) and start_haul(colony, tun, e, task, "truck 🚚") then
    t.trips = t.trips - 1
    return
  end
  send_home(colony, tun, e)
end

-- Back at the pool: refuel and go again if the tank is what stopped it, otherwise park.
local function truck_home(colony, tun)
  local t = storage.trucks[tun]
  if not t then return end
  local driver = colony.colonists[t.driver]
  if t.trips <= 0 and driver and driver.valid and t.entity.valid and not M.is_sleep_time(t.entity.surface) then
    local task = find_haul_task(colony, motor.CAPACITY)
    local trips = task and motor.worth_truck(haul_plan.total(task.load)) and burn_fuel(t.pool)
    if trips then
      t.trips = trips
      return assign_truck(colony, tun)
    end
  end
  park(colony, tun)
end

function M.is_sleep_time(surface)
  if not surface or surface.freeze_daytime then return false end
  local d = surface.daytime
  return d >= 0.40 and d <= 0.60
end

-- Huts of one role that still have a free slot, least-staffed first (see labour.spread).
local function candidates_for(slot_list, job)
  local out = {}
  for _, sl in ipairs(slot_list) do
    if sl.job == job then out[#out + 1] = sl end
  end
  return labour.spread(out)
end

function M.assign(colony, un)
  if storage.trucks and storage.trucks[un] then return assign_truck(colony, un) end
  local e = colony.colonists[un]
  if not (e and e.valid and colony.hall.valid) then return end
  local st = storage.unit_state[un]
  -- Waiting inside a Motor Pool while its truck works: the truck decides when the shift ends.
  if st and st.state == "driving" and storage.trucks and storage.trucks[st.truck] then return end
  local lock = colony.locks and colony.locks[un]

  -- Night time: colonists return to their house to sleep
  if M.is_sleep_time(e.surface) then
    if st and st.hut then
      if st.hut.workers then st.hut.workers[un] = nil end
      st.hut = nil
    end
    local house = colony_mod.house_of_colonist(colony, un)
    if house and house.valid then
      storage.unit_state[un] = {colony_id = colony.id, job = (st and st.job) or lock or "idle", state = "to_bed", house = house}
      set_label(e, "sleeping 💤")
      go(e, house.position, 1.5)
      return
    end
  end

  -- Keep the current post while its hut stands, still holds a slot for us and matches the player's lock.
  -- This is the common case by far, and it is the difference between an O(1) assignment and rebuilding the
  -- whole job matrix for every colonist that finishes a trip (#22 re-measured it).
  local prev_hut = st and st.hut
  if prev_hut then
    local capped = not lock and colony_mod.headcount_capped(colony, prev_hut.job)
    if not capped and prev_hut.entity and prev_hut.entity.valid and prev_hut.workers and prev_hut.workers[un]
        and (not lock or lock == prev_hut.job) then
      local _, _, allowed, workers = M.hut_info(prev_hut)
      if workers <= allowed and start_trip(colony, un, prev_hut) then return end
    end
    if prev_hut.workers then prev_hut.workers[un] = nil end
  end

  local counts = job_counts(colony)
  if st and st.job then counts[st.job] = math.max((counts[st.job] or 1) - 1, 0) end
  local slots, capacity, slot_list, hut_count = job_slots(colony)
  local task, backlog = find_haul_task(colony)
  -- Player lock (#38): this colonist works only the chosen role, even when the matrix would send it elsewhere.
  local job
  if lock then
    job = lock
  else
    local target = math.max(colony_mod.live_colonists(colony) * colony_mod.FOOD_PER_COLONIST * colony_mod.TARGET_STOCK_INTERVALS, 1)
    job = work_plan.choose{food_ratio = colony_mod.total_food(colony) / target, counts = counts,
      slots = slots, capacity = capacity, hut_count = hut_count, pop = math.max(colony_mod.live_colonists(colony) - 1, 0),
      haul = task ~= nil, backlog = backlog, priority = colony.priority, targets = colony.job_targets}
  end

  if not job then idle(colony, un, e); return end
  if job == "haul" then
    if start_drive(colony, un, e, task) then return end
    if start_haul(colony, un, e, task) then return end
    idle(colony, un, e); return
  end
  if job == "construct" then
    if start_construct(colony, un, e) then return end
    idle(colony, un, e); return
  end
  for _, sl in ipairs(candidates_for(slot_list, job)) do
    sl.hut.workers[un] = true
    if start_trip(colony, un, sl.hut) then return end
  end
  idle(colony, un, e)
end

-- Aborted trip: release reservations, claims and carried goods.
function M.release(st)
  if not st then return end
  local colony = storage.colonies[st.colony_id]
  if colony and st.car then return_car(colony, st.pool); st.car = nil end
  if colony and st.site_key and (st.job == "chop" or st.job == "forage" or st.job == "farm"
      or st.job == "construct" or st.job == "hunt") then
    colony.claimed[st.site_key] = nil
  end
  if st.carry and colony then
    if st.inflight_target and st.inflight_target.inflight then
      for _, s in ipairs(st.carry) do
        st.inflight_target.inflight[s.item] = math.max((st.inflight_target.inflight[s.item] or 0) - s.count, 0)
      end
    end
    return_to_hall(colony, st.carry)
    st.carry = nil
  end
  if st.job == "research" and st.hut and st.hut.entity and st.hut.entity.valid then
    local def = labour.HUTS[st.hut.entity.name]
    update_lab_status(st.hut.entity, worker_count(st.hut), def and def.capacity or 2)
  end
end

scheduler.register("work.retry", function(d)
  local st = storage.unit_state[d.un]
  if not st then return end
  local colony = storage.colonies[st.colony_id]
  if colony then M.assign(colony, d.un) end
end)

-- Crops ripen on a scheduled event per planted plot (no per-tick scanning).
scheduler.register("farm.ripen", function(d)
  local colony = storage.colonies[d.colony_id]
  local plot = colony and colony.plots and colony.plots[d.un]
  if not (plot and plot.entity.valid) then return end
  if plot.stage ~= farm.GROWING then return end
  plot.stage, plot.ripe_at = farm.RIPE, nil
  plot.entity.graphics_variation = farm.RIPE
  for _, h in pairs(colony.huts or {}) do
    if h.job == "farm" and h.entity.valid then
      colony.no_site[h.entity.unit_number] = nil
    end
  end
  -- A whole field ripens in one tick, and each reassignment walks the town; once per tick is plenty, since
  -- idle colonists also re-check on their own `work.retry` timer.
  if colony.reassign_tick ~= game.tick then
    colony.reassign_tick = game.tick
    colony_mod.reassign_workforce(colony)
  end
end)

scheduler.register("work.finish", function(d)
  local st = storage.unit_state[d.un]
  if not (st and st.state == "working") then return end
  local colony = storage.colonies[st.colony_id]
  local e = colony and colony.colonists[d.un]
  if not (e and e.valid and colony.hall.valid) then return end
  local hut, site = st.hut, st.site
  if not (hut and hut.entity.valid and site and site.valid) then
    -- tree cut by the player, ore exhausted or hut removed while we were working: no yield, retry
    if hut and hut.workers then hut.workers[d.un] = nil end
    M.release(st)
    M.assign(colony, d.un)
    return
  end
  use_tool(hut)   -- one completed trip = one use of the hut's tool
  local pos, k, item, n = site.position, key(site), site.name, 0
  if st.job == "chop" then
    colony.claimed[k] = nil; site.destroy()
    item, n = M.YIELD.chop.item, M.YIELD.chop.count
  elseif st.job == "forage" then
    colony.claimed[k] = nil; site.destroy()
    item, n = M.YIELD.forage.item, M.YIELD.forage.count
    colony_mod.on_forage_harvested(colony, pos)     -- the patch grows back in place, later
  elseif st.job == "farm" then
    colony.claimed[k] = nil
    local plot = colony.plots and colony.plots[site.unit_number]
    if plot and plot.entity.valid then
      if plot.stage == farm.RIPE then
        n = farm.harvest_yield(farm.fertility(site.surface.get_tile(site.position).name), plot.fertilized)
        item = "colony-produce"
        plot.stage, plot.ripe_at, plot.fertilized = farm.FALLOW, nil, nil
        site.graphics_variation = farm.FALLOW
      elseif plot.stage == farm.FALLOW then
        plot.stage, plot.ripe_at = farm.GROWING, game.tick + farm.GROW_TICKS
        site.graphics_variation = farm.GROWING
        if hut and hut.entity and hut.entity.valid and hut.entity.get_item_count("colony-fertilizer") >= 1 then
          hut.entity.remove_item{name = "colony-fertilizer", count = 1}
          plot.fertilized = true
        end
        scheduler.after(farm.GROW_TICKS, "farm.ripen", {colony_id = colony.id, un = site.unit_number})
      end
    end
  elseif st.job == "preserve" then
    -- Curing or cooking happens here, in the hut, out of the hut's own inventory: the input offer keeps it stocked.
    -- The output is carried home like any other hut yield, so the processed food rides existing hauling.
    if hut.entity.name == "colony-kitchen" then
      local recipe = kitchen.recipe(chest_contents(hut.entity) or {})
      if recipe then
        hut.entity.remove_item{name = kitchen.PRODUCE, count = kitchen.PRODUCE_PER_BATCH}
        hut.entity.remove_item{name = kitchen.WATER, count = kitchen.WATER_PER_BATCH}
        item, n = recipe.product, kitchen.PRODUCT_PER_BATCH
      end
    else
      local recipe = preserve.recipe(chest_contents(hut.entity) or {})
      if recipe then
        hut.entity.remove_item{name = preserve.SALT, count = preserve.SALT_PER_BATCH}
        hut.entity.remove_item{name = recipe.raw, count = preserve.RAW_PER_BATCH}
        item, n = recipe.product, preserve.PRODUCT_PER_BATCH
      end
    end
  elseif st.job == "fish" then
    item, n = "colony-fish", fishing.FISH_PER_TRIP
  elseif st.job == "mine" and site.type == "simple-entity" then
    -- A rock: take its whole yield of the best-ranked ore it holds that the colony still wants, and it is gone.
    for _, ore in ipairs(mine_plan.order(hut.ores)) do
      local y = rock_yield(site, ore)
      if y > 0 and not colony_mod.quota_met(colony, ore) then item, n = ore, y; break end
    end
    if n > 0 then
      site.destroy()
      e.surface.pollute(pos, M.MINE_POLLUTION)
    end
  elseif st.job == "mine" then
    n = math.min(M.MINE_PER_TRIP, site.amount or 0)
    if n > 0 then
      if site.amount > n then site.amount = site.amount - n else site.destroy() end   -- 0 is not a legal amount
      e.surface.pollute(pos, M.MINE_POLLUTION)       -- 1:1 depletion, zero electricity, but not zero pollution
    end
  elseif st.job == "research" then
    -- Lab research is performed natively by the engine while powered and stocked (#42).
    -- Scholars maintain and staff the facility.
    local contents = chest_contents(hut.entity)
    local packs = science.PACKS_BY_LAB[hut.entity.name] or {}
    local have = false
    if contents then
      for _, p in ipairs(packs) do
        if (contents[p] or 0) > 0 then have = true; break end
      end
    end
    local lock = colony.locks and colony.locks[d.un]
    if have and (not lock or lock == "research") then
      local e = colony.colonists[d.un]
      if e and e.valid and hut.entity.valid then
        work_ring(e, hut.entity.position)
      end
      scheduler.after(M.WORK_TICKS + (d.un * 23) % 240, "work.finish", {un = d.un})
      return
    else
      if hut.workers then hut.workers[d.un] = nil end
      local def = labour.HUTS[hut.entity.name]
      update_lab_status(hut.entity, worker_count(hut), def and def.capacity or 2)
      M.release(st)
      M.assign(colony, d.un)
      return
    end
  end
  if n <= 0 then
    if hut.workers then hut.workers[d.un] = nil end
    M.release(st)
    M.assign(colony, d.un)
    return
  end
  popup(e.surface, pos, {"", "+" .. n .. " ", item_name(item)})
  -- Yield goes into the hut that employed the colonist: the hut is the forward stockpile, and a hauler
  -- carries it inward (hut_collect_offer) instead of every worker walking each load to the Town Hall.
  st.carry = {{item = item, count = n}}
  colony.ledger_cache = nil
  st.state = "to_hut"
  go(e, hut.entity.position, 3)
end)

-- A `unit` standing inside a ghost blocks `revive` outright (the engine will not place an entity where a
-- character stands). `go(..., 2)` can leave the builder on its own site, and an idle colonist never steps off
-- by itself, so a blocked site used to be retried forever with the builder standing on it.
local function unit_blocking(site)
  local box = site.bounding_box
  local r = math.max(box.right_bottom.x - box.left_top.x, box.right_bottom.y - box.left_top.y) / 2 + 1
  for _, o in ipairs(site.surface.find_entities_filtered{position = site.position, radius = r, type = "unit"}) do
    if o.valid then return o end
  end
end

-- A walkable point just outside the ghost's footprint, on the side the colonist already stands, so it steps
-- off rather than across the site.
local function aside_from(site, from)
  local box = site.bounding_box
  local r = math.max(box.right_bottom.x - box.left_top.x, box.right_bottom.y - box.left_top.y) / 2 + 2.5
  local dx, dy = from.x - site.position.x, from.y - site.position.y
  local len = math.sqrt(dx * dx + dy * dy)
  if len < 0.1 then dx, dy, len = 1, 0, 1 end
  return {x = site.position.x + dx / len * r, y = site.position.y + dy / len * r}
end

scheduler.register("construct.finish", function(d)
  local st = storage.unit_state[d.un]
  if not (st and st.job == "construct") then return end
  local colony = storage.colonies[st.colony_id]
  local e = colony and colony.colonists[d.un]
  if not (colony and e and e.valid) then return end
  if st.site_key then colony.claimed[st.site_key] = nil end
  local site = st.site
  if st.kind == "build" then
    -- `revive` consumes the ghost, so capture what we need for the message first.
    local pos = site and site.valid and {x = site.position.x, y = site.position.y}
    local ghost_name = site and site.valid and site.ghost_name
    -- `revive` returns (items it collided with, the new entity, the item request proxy): the entity is the
    -- second value, so take it explicitly rather than testing the item list for truthiness. `raise_revive`
    -- also re-delivers the ghost's blueprint tags to `on_built`, which is how a revived opt-in machine is
    -- registered again (#36).
    local built = site and site.valid and site.type == "entity-ghost" and select(2, site.revive{raise_revive = true})
    if built then
      st.carry = nil                            -- the ghost consumed the materials
      if colony.ghosts then colony.ghosts[st.site_key] = nil end
      popup(e.surface, pos or e.position, {"", "Built ", item_name(ghost_name)})
    else
      -- The builder is the blocker: step it off the footprint and come back, instead of backing off for an
      -- hour and leaving the ghost standing. Any other blocker (tree, biter, someone else's building) earns
      -- the long back-off, because nothing about it changes just by waiting a few ticks.
      local blocker = site and site.valid and unit_blocking(site)
      if blocker and blocker.unit_number == d.un then
        colony.claimed[st.site_key] = true       -- the site is still ours, just not reachable yet
        st.state = "to_construct"                -- arriving again re-arms the work timer and retries
        go(e, aside_from(site, e.position), 0.5)
        return
      end
      if st.carry then return_to_hall(colony, st.carry) end
      st.carry = nil
      colony.ghost_blocked = colony.ghost_blocked or {}
      colony.ghost_blocked[st.site_key] = game.tick + construct.RETRY_TICKS   -- blocked site: back off
    end
  else
    local packs = 0
    for _, s in ipairs(st.carry or {}) do if s.item == construct.REPAIR_PACK then packs = packs + s.count end end
    st.carry = nil
    if site and site.valid and packs > 0 then
      local health, used = construct.repaired(site.health, site.max_health)
      site.health = health
      if used then
        packs = packs - 1
        popup(e.surface, site.position, {"", "Repaired ", item_name(site.name)})
      end
    end
    if packs > 0 then return_to_hall(colony, {{item = construct.REPAIR_PACK, count = packs}}) end
  end
  M.assign(colony, d.un)
end)

scheduler.register("work.sleep_check", function(d)
  local st = storage.unit_state and storage.unit_state[d.un]
  if not (st and (st.state == "sleeping" or st.state == "to_bed")) then return end
  local colony = storage.colonies[st.colony_id]
  local e = colony and colony.colonists and colony.colonists[d.un]
  if not (colony and e and e.valid) then return end
  if M.is_sleep_time(e.surface) then
    popup(e.surface, e.position, "💤")
    scheduler.after(180 + (d.un * 13) % 120, "work.sleep_check", d)
  else
    popup(e.surface, e.position, "☀️")
    st.state = "idle"
    M.assign(colony, d.un)
  end
end)

events.on(defines.events.on_ai_command_completed, function(ev)
  local st = storage.unit_state[ev.unit_number]
  if not st then return end
  local colony = storage.colonies[st.colony_id]
  if not colony then return end
  -- A truck heading home parks wherever it gave up, rather than looping on an unreachable pool.
  if st.state == "to_park" then truck_home(colony, ev.unit_number); return end
  if ev.result ~= defines.behavior_result.success and st.job ~= "hunt" and st.state ~= "to_bed" then
    M.release(st)
    M.assign(colony, ev.unit_number)
    return
  end
  if st.state == "to_pickup" then
    local e = unit_entity(colony, ev.unit_number)
    st.state, st.next_state, st.pickup = st.next_state, nil, nil
    if e and e.valid then go(e, st.dest, 3) end
    return
  end
  if st.state == "to_pool" then
    local e = unit_entity(colony, ev.unit_number)
    if not (e and e.valid and st.pool.entity.valid and board(colony, ev.unit_number, e, st)) then
      M.release(st)                                -- car back to the pool (or hall), the claimed load to the hall
      M.assign(colony, ev.unit_number)
    end
    return
  end
  if st.state == "to_bed" then
    st.state = "sleeping"
    local e = unit_entity(colony, ev.unit_number)
    if e and e.valid then
      set_label(e, "sleeping 💤")
      popup(e.surface, e.position, "💤")
      scheduler.after(180 + (ev.unit_number * 13) % 120, "work.sleep_check", {un = ev.unit_number})
    end
    return
  end
  if st.state == "hunting" then
    -- The engine reports the attack command finished when the animal dies - or when it cannot be reached.
    local animal = st.site
    if st.site_key then colony.claimed[st.site_key] = nil; st.site_key = nil end
    if animal and animal.valid and (st.attempts or 0) < hunting.MAX_ATTEMPTS then
      st.attempts = (st.attempts or 0) + 1
      st.site_key = "boar:" .. animal.unit_number
      colony.claimed[st.site_key] = true
      M.command_attack(unit_entity(colony, ev.unit_number), animal)
      return
    end
    st.site = nil
    local e = unit_entity(colony, ev.unit_number)
    if st.carry and st.hut and st.hut.entity.valid and e and e.valid then
      use_tool(st.hut)                          -- a kill is a completed trip: the rifle wears once
      st.state = "to_hut"
      go(e, st.hut.entity.position, 3)
      return
    end
    if st.hut and st.hut.workers then st.hut.workers[ev.unit_number] = nil end
    M.assign(colony, ev.unit_number)
    return
  end
  if st.state == "to_construct" then
    st.state = st.kind == "build" and "building" or "repairing"
    local e = unit_entity(colony, ev.unit_number)
    if e and e.valid and st.site and st.site.valid then work_ring(e, st.site.position) end
    scheduler.after(construct.WORK_TICKS, "construct.finish", {un = ev.unit_number})
    return
  end
  if st.state == "to_house" then
    local target = st.target
    if target and target.entity.valid and st.carry then
      local inserted, refused = 0, {}
      for _, s in ipairs(st.carry) do
        local n = target.entity.insert{name = s.item, count = s.count}
        inserted = inserted + n
        if n < s.count then refused[#refused + 1] = {item = s.item, count = s.count - n} end
      end
      -- The house's cached stock (colony.house_stock_cached) predates this drop. Expire it so the next haul
      -- plan sees the delivery instead of sending another hauler to top up a house that is already full.
      target.stock_tick = nil
      if st.inflight_target and st.inflight_target.inflight then
        for _, s in ipairs(st.carry) do
          st.inflight_target.inflight[s.item] = math.max((st.inflight_target.inflight[s.item] or 0) - s.count, 0)
        end
        -- A machine just got items: its cached need list is stale, so drop it until the next sweep re-reads
        -- the inventory. Without this the colony would re-request the same load every trip.
        if st.inflight_target.requests then
          st.inflight_target.need, colony.machine_dirty = nil, true
        end
      end
      if #refused > 0 then return_to_hall(colony, refused) end
      if inserted == 0 then target.blocked_until = game.tick + 600 end   -- machine refuses these items: stop retrying for a while
      st.carry = nil
      -- Spoilage (#78): a house that fills up with garbage cannot take food, and this colonist is already
      -- standing here, so clearing it costs a trip nobody had to plan.
      local e = unit_entity(colony, ev.unit_number)
      local bin = e and e.valid and colony_mod.nearest_bin(colony, target.entity.position)
      local spoil = bin and target.entity.remove_item{name = compost.SOURCE, count = M.CARRY_CAP}
      if spoil and spoil > 0 then
        st.carry, st.state, st.bin = {{item = compost.SOURCE, count = spoil}}, "to_bin", bin
        go(e, bin.entity.position, 3)
        return
      end
    else M.release(st) end
    M.assign(colony, ev.unit_number)
  elseif st.state == "to_bin" then
    local e = unit_entity(colony, ev.unit_number)
    local bin, carry = st.bin, st.carry
    st.bin, st.carry = nil, nil
    local leftover, dropped = {}, 0
    if bin and bin.entity.valid then
      for _, s in ipairs(carry or {}) do
        local n = bin.entity.insert{name = s.item, count = s.count}
        dropped = dropped + n
        if n < s.count then leftover[#leftover + 1] = {item = s.item, count = s.count - n} end
      end
    else leftover = carry or {} end
    -- A bin full or gone is not a reason to lose the load; the hall is a poor home for spoilage but the bin
    -- can be rebuilt, and the next delivery clears it out again.
    if #leftover > 0 then return_to_hall(colony, leftover) end
    if dropped > 0 and e and e.valid then popup(e.surface, e.position, {"", "Composted ", tostring(dropped)}) end
    M.assign(colony, ev.unit_number)
  elseif st.state == "to_site" then
    st.state = "working"
    local e = unit_entity(colony, ev.unit_number)
    if e and e.valid and st.site.valid then work_ring(e, st.site.position) end
    if st.hut and st.hut.job == "research" and st.hut.entity.valid then
      local def = labour.HUTS[st.hut.entity.name]
      update_lab_status(st.hut.entity, worker_count(st.hut), def and def.capacity or 2)
    end
    scheduler.after(M.WORK_TICKS + (ev.unit_number * 23) % 240, "work.finish", {un = ev.unit_number})
  elseif st.state == "to_hut" then
    local e = unit_entity(colony, ev.unit_number)
    local hut_entity = st.hut and st.hut.entity
    local refused = {}
    if hut_entity and hut_entity.valid then
      colony.no_site[hut_entity.unit_number] = nil
      if st.carry then
        for _, s in ipairs(st.carry) do
          local n = hut_entity.insert{name = s.item, count = s.count}
          if n < s.count then refused[#refused + 1] = {item = s.item, count = s.count - n} end
        end
      end
    else
      refused = st.carry or {}
    end
    st.carry = nil
    colony.ledger_cache = nil
    if #refused > 0 then
      if e and e.valid and colony.hall.valid then
        st.carry, st.state = refused, "to_hall"     -- hut full or gone: fall back to the Town Hall
        go(e, colony.hall.position, 3)
        return
      end
      if e and e.valid then
        for _, s in ipairs(refused) do
          e.surface.spill_item_stack{position = e.position, stack = {name = s.item, count = s.count}, allow_belts = false}
        end
      end
    end
    M.assign(colony, ev.unit_number)
  elseif st.state == "to_hall" then
    if st.carry then return_to_hall(colony, st.carry) end
    st.carry = nil
    colony.ledger_cache = nil
    M.assign(colony, ev.unit_number)
  end
end)

-- A hunter's kill is credited here, not in the work loop: the engine kills the animal, and `ev.cause` is the
-- only link between the dying animal and the hut the meat belongs in.
events.on(defines.events.on_entity_died, function(ev)
  if ev.entity.name ~= wildlife.ANIMAL then return end
  local cause = ev.cause
  local un = cause and cause.valid and cause.unit_number
  local st = un and storage.unit_state[un]
  if not (st and st.job == "hunt") then return end
  local n = hunting.MEAT_PER_KILL
  st.carry = st.carry or {}
  st.carry[#st.carry + 1] = {item = "colony-meat", count = n}
  local colony = storage.colonies[st.colony_id]
  if colony then colony.ledger_cache = nil end
  if ev.entity.surface and ev.entity.position then
    popup(ev.entity.surface, ev.entity.position, {"", "+" .. n .. " ", item_name("colony-meat")})
  end
end)

events.on(defines.events.on_object_destroyed, function(ev)
  local un = ev.useful_id
  local st = un and storage.unit_state[un]
  if st then
    if st.hut and st.hut.workers then st.hut.workers[un] = nil end
    M.release(st)
    storage.unit_state[un] = nil
  end
  -- A truck destroyed on the road (a parked one is already gone from storage.trucks): the car is lost, the
  -- driver climbs out at the pool.
  local t = un and storage.trucks and storage.trucks[un]
  if t then
    storage.trucks[un] = nil
    local colony = storage.colonies[t.colony_id]
    if colony and colony.hall.valid then
      colony.hall.force.print({"colony-message.truck-lost"})
      release_driver(colony, t, (t.pool.entity.valid and t.pool.entity.position) or colony.hall.position)
    end
  end
  if un and storage.unit_labels and storage.unit_labels[un] then
    local lbl = storage.unit_labels[un]
    if lbl and lbl.valid then lbl.destroy() end
    storage.unit_labels[un] = nil
  end
  local carried = un and storage.carry_sprites and storage.carry_sprites[un]
  if carried then
    if carried.obj.valid then carried.obj.destroy() end
    storage.carry_sprites[un] = nil
  end
end)

return M
