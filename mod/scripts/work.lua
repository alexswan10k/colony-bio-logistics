-- Colonist work loop (#30-#32 simplified): idle -> choose job -> walk to site -> work N ticks -> carry yield to hall.
-- Driven by on_ai_command_completed + scheduler; no per-tick polling per unit.
-- Jobs: haul (hall -> houses / tooled huts / opted-in machines, machine output -> hall),
--       forage (natural forage patches in territory), chop (tree destroyed -> wood), mine (ore depleted 1:1).
local events = require("scripts.events")
local scheduler = require("scripts.scheduler")
local territory = require("scripts.territory")
local stats = require("scripts.stats")
local work_plan = require("scripts.model.work_plan")
local housing = require("scripts.model.housing")
local labour = require("scripts.model.labour")
local alarm = require("scripts.model.alarm")
local commute = require("scripts.model.commute")
local haul_plan = require("scripts.model.haul_plan")
local farm = require("scripts.model.farm")
local mine_plan = require("scripts.model.mine_plan")
local crates = require("scripts.model.crates")
local compost = require("scripts.model.compost")
local garrison = require("scripts.model.garrison")
local hunting = require("scripts.model.hunting")
local wildlife = require("scripts.wildlife")
local fishing = require("scripts.model.fishing")
local preserve = require("scripts.model.preserve")
local kitchen = require("scripts.model.kitchen")
local toolsmith = require("scripts.model.toolsmith")
local workshop = require("scripts.model.workshop")
local yields = require("scripts.model.yields")
local salt = require("scripts.model.salt")
local well = require("scripts.model.well")
local construct = require("scripts.model.construct")
local science = require("scripts.model.science")
local illness = require("scripts.model.illness")
local headcount = require("scripts.model.headcount")
local motor = require("scripts.model.motor")
local recreation = require("scripts.model.recreation")
local jobs = require("scripts.model.jobs")
local M = {}
local colony_mod   -- injected by scripts.colony via M.bind
function M.bind(c) colony_mod = c end

M.WORK_TICKS = yields.WORK_TICKS
-- Tools the Toolsmith has made since the game started. A diagnostic for the spikes, not game state: it is not saved.
M.tools_made = 0
M.RETRY_TICKS = 300
M.SMALL_TOWN = 8           -- below this many colonists a harvester also checks for waiting deliveries
M.RETRY_BACKOFF_MAX = 4     -- an idle colonist that keeps finding nothing waits up to this many retry periods (#22)
M.RETRY_BACKOFF_POP = 100   -- ...but only in big towns: one extra retry period per this many colonists
M.YIELD = {forage = yields.FORAGE, chop = yields.CHOP}
M.MINE_PER_TRIP = yields.MINE_PER_TRIP   -- each unit becomes exactly one item (design §4.2)
M.MINE_POLLUTION = 2        -- pollution per mining trip: colony industry still feeds the biters
M.CARRY_CAP = yields.CARRY_CAP
M.ORES = mine_plan.ORES   -- every ore a Miner's Hut can be pointed at
M.LABELS = {forage = "forager", chop = "woodcutter", mine = "miner", farm = "farmer", hunt = "hunter",
  fish = "fisher", preserve = "preserver", haul = "hauler", construct = "builder", research = "scholar", heal = "doctor", guard = "guard"}

local function key(e) return e.surface.index .. ":" .. e.position.x .. "," .. e.position.y end

-- How close a harvester stands to its site: right at the edge of the thing being worked, not somewhere near it.
-- The radius is measured from the entity's centre, so it must clear the collision box or the command never
-- completes (and the colonist gets stuck). A 2x2 rock needs ~1.5, a tree ~1.
local function site_radius(site)
  local proto = (site.type == "entity-ghost" and site.ghost_prototype)
    or (prototypes and prototypes.entity and prototypes.entity[site.name])
  local box = proto and (proto.collision_box or proto.selection_box)
  local half = 0.5
  if box then
    half = math.max(math.abs(box.left_top.x), math.abs(box.right_bottom.x),
      math.abs(box.left_top.y), math.abs(box.right_bottom.y))
  end
  return half + 0.45
end

function M.job_counts(colony)
  local counts = {}
  for un, c in pairs(colony.colonists) do
    local st = storage.unit_state[un]
    if c.valid and st and st.job and st.job ~= "child" then counts[st.job] = (counts[st.job] or 0) + 1 end
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

local function set_label(e, text, always)
  local want = always and "always" or "alt"
  local rec = storage.unit_labels[e.unit_number]
  if rec then
    local obj = type(rec) == "table" and rec.obj or rec   -- tolerate pre-schema-28 bare render objects
    if obj and obj.valid and (type(rec) == "table" and rec.mode == want or type(rec) ~= "table") then
      obj.text = text
      return
    end
    if obj and obj.valid then obj.destroy() end
    storage.unit_labels[e.unit_number] = nil
  end
  storage.unit_labels[e.unit_number] = {mode = want, obj = rendering.draw_text{text = text, surface = e.surface, target = {entity = e, offset = {0, -1.4}},
    color = {1, 1, 1}, scale = 0.7, alignment = "center", only_in_alt_mode = not always}}
end
M.set_label = set_label

local function clear_label(un)
  local rec = storage.unit_labels and storage.unit_labels[un]
  if rec then
    local obj = type(rec) == "table" and rec.obj or rec
    if obj and obj.valid then obj.destroy() end
    storage.unit_labels[un] = nil
  end
end
M.clear_label = clear_label

local function popup(surface, pos, text)
  rendering.draw_text{text = text, surface = surface, target = pos, color = {0.8, 1, 0.8},
    scale = 0.8, time_to_live = 90, alignment = "center"}
end

-- A standable spot right next to a building: units cannot stand inside them. The old sleep command aimed at
-- the house's centre from 3.5 tiles away, so it completed instantly and colonists bedded down in a field.
local function door_point(surface, house)
  if not (house and house.valid) then return nil end
  local p = surface.find_non_colliding_position("colony-colonist", house.position, 4, 0.3)
  return p or house.position
end
M.door_point = door_point

local function clear_carry_sprite(un)
  local sprites = storage.carry_sprites
  local cur = sprites and sprites[un]
  if cur then
    if cur.obj and cur.obj.valid then cur.obj.destroy() end
    sprites[un] = nil
  end
end

-- Is this colonist a child? Children (#88) are never assigned jobs; they stay at the house and grow up.
local function is_child(un)
  local rec = storage.age and storage.age[un]
  return rec ~= nil and rec.stage == "child"
end

-- A ring that lives exactly as long as the work: you can see WHICH tree/patch/ore tile is being worked.
local function work_ring(e, pos, radius)
  rendering.draw_circle{surface = e.surface, target = pos, radius = radius or 0.9, color = {1, 0.85, 0.3, 0.8},
    width = 3, filled = false, time_to_live = M.WORK_TICKS}
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
  local def = hut and hut.entity and hut.entity.valid and labour.HUTS[hut.entity.name]
  if not (def and (def.tools or def.tool)) then return end
  local broke
  hut.wear, broke = labour.wear(hut.wear or 0)
  if broke then
    local tool_item = def.tool
    if def.tools then
      for _, t in ipairs(def.tools) do
        if hut.entity.get_item_count(t) > 0 then tool_item = t; break end
      end
    end
    if tool_item and hut.entity.remove_item{name = tool_item, count = 1} > 0 then
      local colony = hut.colony_id and storage.colonies and storage.colonies[hut.colony_id]
      if colony then stats.consumed(colony, tool_item, 1) end
      popup(hut.entity.surface, hut.entity.position, {"", "Tool broke: ", item_name(tool_item)})
    end
  end
end

local function hut_weapon(hut)
  local inv = hut and hut.entity and hut.entity.valid and (
    hut.entity.type == "lab" and hut.entity.get_inventory(defines.inventory.lab_input)
    or hut.entity.get_inventory(defines.inventory.chest)
  )
  if not inv then return "bow" end
  local has_gun = inv.get_item_count("submachine-gun") > 0 or inv.get_item_count("pistol") > 0 or inv.get_item_count("colony-rifle") > 0
  local has_ammo = inv.get_item_count("firearm-magazine") > 0 or inv.get_item_count("piercing-rounds-magazine") > 0
  if has_gun and (has_ammo or inv.get_item_count("colony-rifle") > 0) then
    return "gun"
  end
  return "bow"
end

local function use_weapon(hut)
  local inv = hut and hut.entity and hut.entity.valid and hut.entity.get_inventory(defines.inventory.chest)
  if not inv then return use_tool(hut) end
  local w = hut_weapon(hut)
  if w == "gun" then
    hut.ammo_count = (hut.ammo_count or 0) + 1
    if hut.ammo_count >= 10 then
      hut.ammo_count = 0
      if inv.get_item_count("piercing-rounds-magazine") > 0 then
        inv.remove_item{name = "piercing-rounds-magazine", count = 1}
      elseif inv.get_item_count("firearm-magazine") > 0 then
        inv.remove_item{name = "firearm-magazine", count = 1}
      end
    end
    if inv.get_item_count("colony-rifle") > 0 then
      use_tool(hut)
    end
  else
    if inv.get_item_count("colony-arrow") > 0 then
      inv.remove_item{name = "colony-arrow", count = 1}
    end
    use_tool(hut)
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
    if m.entity.valid and m.entity.type ~= "entity-ghost" then ids[#ids + 1] = un else colony.machines[un] = nil end
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
  local tools
  if def.tools then
    tools = 0
    for _, t in ipairs(def.tools) do
      tools = tools + (h.entity.valid and h.entity.get_item_count(t) or 0)
    end
  elseif def.tool then
    tools = h.entity.valid and h.entity.get_item_count(def.tool) or 0
  else
    tools = def.capacity
  end
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

local function wake_idle_colonists(colony)
  if not colony then return end
  for un, c in pairs(colony.colonists or {}) do
    local st = storage.unit_state and storage.unit_state[un]
    if c.valid and st and st.state == "idle" then
      st.misses = 0
      M.assign(colony, un)
    end
  end
end
M.wake_idle_colonists = wake_idle_colonists

scheduler.register("construct.scan", function(d)
  local colony = storage.colonies[d.colony_id]
  if not (colony and colony.hall and colony.hall.valid) then return end
  local ghosts, repairs = construct_scan(colony)
  if ghosts > 0 or repairs > 0 then wake_idle_colonists(colony) end
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
  if h.quota_item then
    if colony_mod.quota_met(colony, h.quota_item) then
      return true, h.quota_item
    else
      h.quota_item = nil
      h.quota_met = nil
    end
  end
  local res = hut_resources(h)
  if not res then return false, nil end
  if h.job == "mine" then
    local ranks = mine_plan.effective(h.ores)
    local any_active = false
    local all_met = true
    local last_item = nil
    for ore, rank in pairs(ranks) do
      if rank > 0 then
        any_active = true
        if colony_mod.quota_met(colony, ore) then
          last_item = ore
        else
          all_met = false
        end
      end
    end
    if any_active and all_met and last_item then return true, last_item end
    return false, nil
  end
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

-- Toolsmith (model/toolsmith.lua) -----------------------------------------------------------------------
-- Any built Toolsmith of the colony, or nil. Only its presence matters to the rest of the town.
function M.toolsmith_of(colony)
  for _, h in pairs(colony.huts) do
    if h.entity.valid and h.entity.name == toolsmith.NAME then return h end
  end
  return nil
end

-- The tools the colony wants made right now, in order: what huts are short of, then one spare of each tool a built
-- hut uses. Built from the same gap list the GUI shows (colony_mod.tool_gaps).
local function toolsmith_wanted(colony)
  local gap_tools, built, seen = {}, {}, {}
  for _, g in ipairs(colony_mod.tool_gaps(colony)) do gap_tools[#gap_tools + 1] = g.tool end
  for _, h in pairs(colony.huts) do
    local def = h.entity.valid and labour.HUTS[h.entity.name]
    -- A hut the player has deliberately unmanned (limit 0) does not want a spare tool: without this a
    -- limit-0 Watchtower would have the Toolsmith crafting rifles out of the town's iron (#56).
    if def and def.tool and not seen[def.tool] and (h.limit or def.capacity) > 0 then
      seen[def.tool] = true
      built[#built + 1] = def.tool
    end
  end
  table.sort(built)   -- pairs order is not stable
  -- Ingredients already hauled into a Toolsmith (and tools made but not yet carried home) count as stock:
  -- otherwise the hall runs dry of iron the moment it is delivered and the Toolsmith idles on a full chest.
  local stock = {}
  for item, n in pairs(colony_mod.stock_table(colony)) do stock[item] = n end   -- a copy: stock_table is cached
  for _, h in pairs(colony.huts) do
    if h.entity.valid and h.entity.name == toolsmith.NAME then
      for item, n in pairs(chest_contents(h.entity) or {}) do stock[item] = (stock[item] or 0) + n end
    end
  end
  return toolsmith.wanted(gap_tools, built, stock)
end

M.toolsmith_wanted = toolsmith_wanted

-- Which tool this Toolsmith makes next, and its recipe, or nil. Only recipes the force has researched count.
local function toolsmith_pick(colony, hut)
  local wanted = toolsmith_wanted(colony)
  if #wanted == 0 then return nil end
  local recipes, unlocked = hut.entity.force.recipes, {}
  for _, tool in ipairs(wanted) do
    if recipes[tool] and recipes[tool].enabled then unlocked[tool] = true end
  end
  return toolsmith.pick(wanted, chest_contents(hut.entity) or {}, unlocked)
end

-- A hut short of `tool` with none in colony stock: what the colony's Toolsmith means for it, as
-- toolsmith.gap returns it ("craft", "making", or "short", item, n).
function M.tool_gap(colony, tool)
  local force = colony and colony.hall and colony.hall.valid and colony.hall.force
  local recipes = force and force.recipes
  local recipe = recipes and recipes[tool]
  return toolsmith.gap{toolsmith = M.toolsmith_of(colony) ~= nil, unlocked = recipe ~= nil and recipe.enabled == true,
    missing = workshop.missing(tool, colony_mod.stock_table(colony))}
end

-- A supply-gated preserve hut (Smokehouse, Kitchen, Toolsmith) can work only while it holds what it works on. Used
-- by the job slots (so the chooser never sends a colonist to a hut with nothing to do) and by the site check.
-- Returns the tool to make for a Toolsmith, or a truthy value for the others.
local function preserve_ready(colony, hut)
  if hut.entity.name == toolsmith.NAME then return toolsmith_pick(colony, hut) end
  if hut.entity.name == "colony-kitchen" then return kitchen.recipe(chest_contents(hut.entity) or {}) end
  return preserve.recipe(chest_contents(hut.entity) or {})
end

local function job_slots(colony)
  local list = {}
  local active = {}
  for _, h in ipairs(hut_list(colony)) do
    local _, _, allowed, workers = M.hut_info(h)
    if hut_quota_met(colony, h) then allowed = 0 end
    if (colony.no_site[h.entity.unit_number] or 0) > game.tick or (colony.no_site[h.job] or 0) > game.tick then allowed = 0 end
    -- A supply-gated hut is a slot only while it can work: otherwise a colonist is sent to it, finds no site and idles.
    if h.job == "preserve" and not preserve_ready(colony, h) then allowed = 0 end
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
M.job_slots = job_slots

-- Identify harvest jobs whose resources are missing in the colony (#84, priority tuning).
-- Completely empty resources (stock == 0) take strict precedence; otherwise jobs below target quota.
local HARVEST_JOB = {}
for _, j in ipairs(work_plan.HARVEST) do HARVEST_JOB[j] = true end
local FOOD_JOB = {}
for _, j in ipairs(work_plan.FOOD) do FOOD_JOB[j] = true end

local function colony_missing_jobs(colony)
  local led = colony_mod.ledger_snapshot(colony)
  local totals = led and led.totals or {}
  local empty = {}
  local below_target = {}

  -- 1. Chop: wood
  if not colony_mod.quota_met(colony, "wood") then
    local cnt = totals["wood"] or 0
    local tgt = colony_mod.quota_target(colony, "wood")
    if cnt == 0 then empty.chop = true end
    if tgt > 0 and cnt < tgt then below_target.chop = true end
  end

  -- 2. Mine: ores
  local mine_ores = {"iron-ore", "copper-ore", "coal", "stone"}
  for _, ore in ipairs(mine_ores) do
    if not colony_mod.quota_met(colony, ore) then
      local cnt = totals[ore] or 0
      local tgt = colony_mod.quota_target(colony, ore)
      if cnt == 0 then empty.mine = true end
      if tgt > 0 and cnt < tgt then below_target.mine = true end
    end
  end

  -- 3. Food: forage, farm, hunt, fish
  local target_food = math.max(colony_mod.live_colonists(colony) * colony_mod.FOOD_PER_COLONIST * colony_mod.TARGET_STOCK_INTERVALS, 1)
  local total_food = colony_mod.total_food(colony)
  local food_ratio = total_food / target_food
  if total_food == 0 then
    if not colony_mod.quota_met(colony, "colony-forage") then empty.forage = true end
    if not colony_mod.quota_met(colony, "colony-produce") then empty.farm = true end
    if not colony_mod.quota_met(colony, "colony-meat") then empty.hunt = true end
    if not colony_mod.quota_met(colony, "colony-fish") then empty.fish = true end
  elseif food_ratio < 1.0 then
    if not colony_mod.quota_met(colony, "colony-forage") then below_target.forage = true end
    if not colony_mod.quota_met(colony, "colony-produce") then below_target.farm = true end
    if not colony_mod.quota_met(colony, "colony-meat") then below_target.hunt = true end
    if not colony_mod.quota_met(colony, "colony-fish") then below_target.fish = true end
  end

  local has_empty = false
  for _, v in pairs(empty) do if v then has_empty = true; break end end
  if has_empty then
    -- Empty stock comes first, but hungry towns still feed themselves.
    for _, job in ipairs{"forage", "farm", "hunt", "fish"} do
      if below_target[job] then empty[job] = true end
    end
    return empty
  end
  return below_target
end
M.colony_missing_jobs = colony_missing_jobs

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

-- Downstream demand for ore from marked machines (e.g. smelters) and demand crates, less colony stock.
local function colony_ore_demand(colony, ore)
  local want = 0
  for _, m in pairs(colony.machines or {}) do
    if m.entity and m.entity.valid and m.enabled and m.need then
      for _, d in ipairs(m.need) do
        if d.item == ore then want = want + d.count end
      end
    end
  end
  for _, c in ipairs(colony_mod.crate_list(colony, crates.DEMAND)) do
    if c.filters then
      for i = 1, crates.FILTER_ROWS do
        local f = c.filters[i]
        if f and f.item == ore then
          local needed = (f.count or crates.DEFAULT_COUNT) - c.entity.get_item_count(ore) - (c.inflight[ore] or 0)
          if needed > 0 then want = want + needed end
        end
      end
    end
  end
  local stock = colony_mod.stock_count(colony, ore)
  return math.max(0, want - stock)
end

-- Harvest only in range and never on another colony's land (design §2.1), preferring the nearest site so
-- colonists visibly work the forest / berry patch / ore next to their hut instead of walking to a random
-- tree on the far edge of the radius.
local function find_site(colony, e, hut)
  local s, base = e.surface, hut.entity.position
  local radius = hut.job == "forage" and colony_mod.FORAGE_RADIUS or colony_mod.HUT_RADIUS
  local in_territory = function(t) return harvestable(colony, t) end
  local free = function(t) return in_territory(t) and not colony.claimed[key(t)] end
  if hut.job == "forage" then
    if colony_mod.quota_met(colony, "colony-forage") then return nil, "colony-forage" end
    return nearest(s.find_entities_filtered{name = "colony-forage-patch", position = base, radius = radius}, base, free)
  elseif hut.job == "chop" then
    if colony_mod.quota_met(colony, "wood") then return nil, "wood" end
    return nearest(s.find_entities_filtered{position = base, radius = radius, type = "tree"}, base, free)
  elseif hut.job == "mine" then
    -- Ore priority: work the best-ranked ore that is actually in range.
    -- Ores sharing a rank round robin or follow downstream demand.
    -- Quota check (#84): skip any ore that has reached its quota; switch to the next open ore.
    local any_met, last_met = false, nil
    for _, group in ipairs(mine_plan.by_rank(hut.ores)) do
      local available = {}
      for _, ore in ipairs(group.ores) do
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
          if site then
            available[#available + 1] = {ore = ore, site = site, demand = colony_ore_demand(colony, ore)}
          end
        end
      end

      if #available > 0 then
        -- Prefer ores that have active downstream demand in the colony
        local demanded = {}
        for _, entry in ipairs(available) do
          if entry.demand > 0 then demanded[#demanded + 1] = entry end
        end
        local candidates
        if #demanded > 0 then
          candidates = demanded
        else
          local led = colony_mod.ledger_snapshot(colony)
          local totals = led and led.totals or {}
          local missing_ores = {}
          for _, entry in ipairs(available) do
            if (totals[entry.ore] or 0) == 0 then
              missing_ores[#missing_ores + 1] = entry
            end
          end
          if #missing_ores > 0 then
            candidates = missing_ores
          else
            candidates = available
          end
        end

        -- Round robin among candidates sharing this rank
        local cursor = ((hut.ore_cursor or 0) % #candidates) + 1
        hut.ore_cursor = cursor
        local chosen = candidates[cursor]
        return chosen.site, nil, chosen.ore
      end
    end
    if any_met then
      hut.quota_met = true
      hut.quota_item = last_met
      return nil, last_met
    end
    return nil
  elseif hut.job == "preserve" then
    -- The smokehouse, kitchen or toolsmith is its own workplace, and it can only work when it holds its inputs.
    -- Returning nil leaves it unstaffed (and `no_site` stops the town from thrashing on it for a while).
    return preserve_ready(colony, hut) and hut.entity
  elseif hut.job == "fish" then
    if colony_mod.quota_met(colony, "colony-fish") then return nil, "colony-fish" end
    -- The dock is the workplace: there is no world entity to harvest, the water is the resource, and whether
    -- there is enough of it was settled when the dock was built (model/fishing.lua). Everyone fishes the same
    -- dock, so it is never claimed.
    return hut.entity
  elseif hut.job == "guard" then
    -- The tower is the workplace: unmanned posts close automatically when its rifles are gone (labour slots).
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
  elseif hut.job == "heal" then
    -- A Clinic (#47) is its own workplace: doctors go on duty while it holds medicine and someone is sick.
    if (colony.sick_count or 0) > 0 and hut.entity.get_item_count(illness.MEDICINE) > 0 then return hut.entity end
    return nil
  end
end

-- How many harvestable sites the hut can currently see (GUI feedback for "nothing in range").
function M.site_count(h)
  local colony = storage.colonies[h.colony_id]
  if not (colony and h.entity.valid) then return 0 end
  if h.job == "guard" then return nil end   -- not a resource job; no quota to miss and the tower always stands
  if h.job == "research" or h.job == "preserve" or h.job == "fish" or h.job == "heal" then return 1 end
  local s, base = h.entity.surface, h.entity.position
  local radius = h.job == "forage" and colony_mod.FORAGE_RADIUS or colony_mod.HUT_RADIUS
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
  if h.job == "hunt" then
    local n = 0
    local r2 = radius * radius
    for un, rec in pairs(colony.animals or {}) do
      local a = rec.entity
      if a and a.valid and not colony.claimed["boar:" .. un] and dist2(a.position, base) <= r2 and in_territory(a) then
        n = n + 1
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
M.go = go

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
  if h.logistics_enabled == false then return nil end
  local tier = housing.TIERS[h.kind]
  local occupants = h.mouths or h.occupants or 0   -- children eat half (#88)
  local stock = colony_mod.house_stock_cached(h)
  local demands = housing.demand(tier, stock, h.inflight, colony_mod.is_powered(h), occupants)
  if #demands == 0 then return nil end
  local critical = false
  local unmet = false
  for _, need in ipairs(tier.needs) do
    local ok = h.sat and h.sat[need.id]
    if ok == false or (ok == nil and occupants > 0) then
      if need.critical then
        critical = true
      else
        unmet = true
      end
    end
  end
  local band = critical and haul_plan.PRIORITY.critical
    or (unmet and haul_plan.PRIORITY.request)
    or haul_plan.PRIORITY.buffer
  return {kind = "supply", house = h, entity = h.entity, pos = h.entity.position,
    priority = band,
    building_priority = h.priority or 3,
    key = h.entity.unit_number, demands = demands}
end

local function hut_offer(h)
  if h.logistics_enabled == false then return nil end
  local def, tools = M.hut_info(h)
  if def.tools or def.tool then
    -- A hut the player has closed (limit 0) asks for nothing: an unmanned Watchtower must not pull rifles/weapons out
    -- of the hall (#56). Weapons already in the tower stay there, ready for the player to man it.
    if (h.limit or def.capacity) <= 0 then return nil end
    local primary_tool = def.tool
    local colony = storage.colonies[h.colony_id]
    if def.tools and colony then
      if colony_mod.stock_count(colony, primary_tool) == 0 then
        for _, t in ipairs(def.tools) do
          if colony_mod.stock_count(colony, t) > 0 then
            primary_tool = t
            break
          end
        end
      end
      local force = h.entity.valid and h.entity.force
      local has_guns = force and force.technologies["colony-firearms"] and force.technologies["colony-firearms"].researched
      if has_guns then
        if colony_mod.stock_count(colony, "colony-rifle") > 0 then primary_tool = "colony-rifle"
        elseif colony_mod.stock_count(colony, "submachine-gun") > 0 then primary_tool = "submachine-gun"
        elseif colony_mod.stock_count(colony, "pistol") > 0 then primary_tool = "pistol"
        end
      end
    end
    local inflight = 0
    if def.tools then
      for _, t in ipairs(def.tools) do inflight = inflight + (h.inflight[t] or 0) end
    elseif primary_tool then
      inflight = h.inflight[primary_tool] or 0
    end
    if tools == 0 then
      -- A hut with no tool cannot work at all, so it asks for exactly one before any hut tops up. Without
      -- this an older hut's full-capacity request ate a scarce supply and a newer hut (often the one built
      -- further out) never got its first tool. Once one is on the way, wait for it rather than pile up.
      if inflight > 0 then return nil end
      return {kind = "supply", hut = h, entity = h.entity, pos = h.entity.position,
        priority = haul_plan.PRIORITY.tools, building_priority = h.priority or 3, key = h.entity.unit_number,
        deficit = def.capacity * 10 + 1, demands = {{item = primary_tool, count = 1}}}
    end
    local want = math.min(def.capacity, h.limit or def.capacity) - tools - inflight
    if want >= 1 then
      return {kind = "supply", hut = h, entity = h.entity, pos = h.entity.position,
        priority = haul_plan.PRIORITY.tools, building_priority = h.priority or 3, key = h.entity.unit_number,
        demands = {{item = primary_tool, count = want}}}
    end
    if def.tools then
      local inv = h.entity.valid and (h.entity.type == "lab" and h.entity.get_inventory(defines.inventory.lab_input) or h.entity.get_inventory(defines.inventory.chest))
      local is_gun = hut_weapon(h) == "gun"
      local ammo_item = is_gun and "firearm-magazine" or "colony-arrow"
      local ammo_target = is_gun and 5 or 20
      local have_ammo = inv and inv.get_item_count(ammo_item) or 0
      local inflight_ammo = h.inflight[ammo_item] or 0
      local ammo_deficit = ammo_target - have_ammo - inflight_ammo
      if ammo_deficit > 0 and colony and colony_mod.stock_count(colony, ammo_item) > 0 then
        return {kind = "supply", hut = h, entity = h.entity, pos = h.entity.position,
          priority = haul_plan.PRIORITY.request, building_priority = h.priority or 3, key = h.entity.unit_number,
          demands = {{item = ammo_item, count = ammo_deficit}}}
      end
    end
    if def.inputs then
      local demands = {}
      local contents = chest_contents(h.entity) or {}
      for _, inp in ipairs(def.inputs) do
        local deficit = inp.count - (contents[inp.item] or 0) - (h.inflight[inp.item] or 0)
        if deficit > 0 then demands[#demands + 1] = {item = inp.item, count = deficit} end
      end
      if #demands > 0 then
        return {kind = "supply", hut = h, entity = h.entity, pos = h.entity.position,
          priority = haul_plan.PRIORITY.request, building_priority = h.priority or 3, key = h.entity.unit_number,
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
  elseif h.job == "heal" then
    demands = illness.wants(h.entity.get_item_count(illness.MEDICINE), h.inflight[illness.MEDICINE])
  elseif h.entity.name == toolsmith.NAME then
    -- Materials only while there is a tool to make: an idle Toolsmith does not hoard wood and iron.
    local colony = storage.colonies[h.colony_id]
    demands = (colony and #toolsmith_wanted(colony) > 0) and toolsmith.wants(chest_contents(h.entity) or {}, h.inflight) or {}
  elseif h.entity.name == "colony-kitchen" then
    demands = kitchen.wants(chest_contents(h.entity) or {}, h.inflight)
  else
    demands = preserve.wants(chest_contents(h.entity) or {}, h.inflight)
  end
  if #demands == 0 then return nil end
  return {kind = "supply", hut = h, entity = h.entity, pos = h.entity.position,
    priority = haul_plan.PRIORITY.request, building_priority = h.priority or 3, key = h.entity.unit_number,
    demands = demands}
end

-- Finished goods sit in the hut until a hauler clears them, so the hut is the local stockpile and the
-- colonist never walks every load home. Everything except the hut's own tool is fair game.
-- For lab entities, collects from defines.inventory.lab_trash so spoilage is composted (#42).
local function hut_collect_offer(h)
  if h.logistics_enabled == false then return nil end
  local def = labour.HUTS[h.entity.name]
  if h.job == "guard" then return nil end   -- a garrison produces nothing; its rifles are not output
  local inv = h.entity.type == "lab"
    and h.entity.get_inventory(defines.inventory.lab_trash)
    or h.entity.get_inventory(defines.inventory.chest)
  if not (def and inv and not inv.is_empty()) then return nil end
  local demands, available, keep = {}, {}, {}
  for _, item in ipairs(def.keep or {}) do keep[item] = true end
  for _, c in ipairs(inv.get_contents()) do
    -- Inputs stay put: a Smokehouse's salt and raw food are not output to be hauled away (#81).
    local is_tool = (c.name == def.tool)
    if def.tools then
      for _, t in ipairs(def.tools) do if c.name == t then is_tool = true; break end end
    end
    if not is_tool and not keep[c.name] then
      demands[#demands + 1] = {item = c.name, count = c.count}
      available[c.name] = c.count
    end
  end
  if #demands == 0 then return nil end
  return {kind = "collect", hut = h, entity = h.entity, pos = h.entity.position,
    priority = haul_plan.PRIORITY.hut_output, building_priority = h.priority or 3, key = h.entity.unit_number,
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
  return {kind = "collect", bin = b, entity = b.entity, pos = b.entity.position,
    priority = haul_plan.PRIORITY.collect, building_priority = 3, key = b.entity.unit_number,
    demands = {{item = compost.PRODUCT, count = n}}, available = {[compost.PRODUCT] = n}}
end

-- A salt pan's contents, offered exactly like a supply crate's: evaporation is nobody's job, but hauling the
-- salt away is (#81).
local function salt_offer(pan)
  local n = pan.entity.get_item_count(salt.ITEM)
  if n < 1 then return nil end
  return {kind = "collect", pan = pan, entity = pan.entity, pos = pan.entity.position,
    priority = haul_plan.PRIORITY.collect, building_priority = 3, key = pan.entity.unit_number,
    demands = {{item = salt.ITEM, count = n}}, available = {[salt.ITEM] = n}}
end

-- A well's water, offered like a salt pan's: generation is nobody's job, but hauling the water
-- away is (#43).
local function well_offer(w)
  local n = w.entity.get_item_count(well.ITEM)
  if n < 1 then return nil end
  return {kind = "collect", well = w, entity = w.entity, pos = w.entity.position,
    priority = haul_plan.PRIORITY.collect, building_priority = 3, key = w.entity.unit_number,
    demands = {{item = well.ITEM, count = n}}, available = {[well.ITEM] = n}}
end

local function crate_supply_offer(c)
  if c.logistics_enabled == false then return nil end
  local contents = crate_contents(c)
  if not contents then return nil end
  local demands = crates.supply(contents)
  if #demands == 0 then return nil end
  return {kind = "collect", crate = c, entity = c.entity, pos = c.entity.position,
    priority = haul_plan.PRIORITY.collect, building_priority = c.priority or 3, key = c.entity.unit_number,
    demands = demands, available = contents}
end

local function crate_demand_offer(c)
  if c.logistics_enabled == false then return nil end
  local contents = crate_contents(c) or {}
  local demands = crates.demands(c.filters, contents, c.inflight)
  if #demands == 0 then return nil end
  return {kind = "supply", crate = c, entity = c.entity, pos = c.entity.position,
    priority = haul_plan.PRIORITY.request, building_priority = c.priority or 3, key = c.entity.unit_number,
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
  if not m.entity.valid or not m.enabled or m.entity.type == "entity-ghost" or (m.blocked_until or 0) > game.tick then return nil end
  local need = m.need
  if not need then return nil end
  local demands, any = {}, false
  for _, d in ipairs(need) do
    local n = d.count - (m.inflight[d.item] or 0)
    if n >= 1 then demands[#demands + 1] = {item = d.item, count = n}; any = true end
  end
  if not any then return nil end
  return {kind = "supply", machine = m, entity = m.entity, pos = m.entity.position,
    priority = haul_plan.PRIORITY.request, building_priority = m.priority or 4, key = m.entity.unit_number, demands = demands}
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
  return {kind = "collect", machine = m, entity = m.entity, pos = m.entity.position,
    priority = haul_plan.PRIORITY.collect, building_priority = m.priority or 4, key = m.entity.unit_number,
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
        local hurt = construct.needs_repair(m.entity.health, m.entity.max_health)
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
  return {kind = "supply", pool = p, entity = p.entity, pos = p.entity.position,
    priority = haul_plan.PRIORITY.request, building_priority = 3, key = p.entity.unit_number,
    demands = demands}
end

-- A Tavern (#48) asks for ale up to its stock line.
local function tavern_offer(t)
  local demands = recreation.wants(t.entity.get_item_count(recreation.ITEM), t.inflight[recreation.ITEM])
  if #demands == 0 then return nil end
  return {kind = "supply", tavern = t, entity = t.entity, pos = t.entity.position,
    priority = haul_plan.PRIORITY.request, building_priority = 3, key = t.entity.unit_number,
    demands = demands}
end

-- A Canteen (#50) asks for food, any kind, up to its stock line.
local function canteen_offer(colony, c)
  local have = 0
  for _, item in ipairs(colony_mod.MEAL_ITEMS) do have = have + c.entity.get_item_count(item) end
  local inflight = 0
  for _, n in pairs(c.inflight) do inflight = inflight + n end
  local demands = commute.wants(colony_mod.MEAL_ITEMS, have, inflight)
  if #demands == 0 then return nil end
  return {kind = "supply", canteen = c, entity = c.entity, pos = c.entity.position,
    priority = haul_plan.PRIORITY.request, building_priority = 3, key = c.entity.unit_number,
    demands = demands}
end

-- One destination per trip, possibly several item types. Returns an offer with `.load` filled in.
-- `cap` is what the carrier holds: a colonist's hands by default, a truck's bed when one is driving.
local function find_haul_task(colony, cap, hauler_pos)
  local requesters, providers = {}, {}
  for _, h in ipairs(colony_mod.house_list(colony)) do
    local o = house_offer(colony, h); if o then requesters[#requesters + 1] = o end
  end
  for _, h in ipairs(hut_list(colony)) do
    local o = hut_offer(h); if o then requesters[#requesters + 1] = o end
    local c = hut_collect_offer(h); if c then providers[#providers + 1] = c end
  end
  for _, c in ipairs(colony_mod.crate_list(colony, crates.SUPPLY)) do
    local o = crate_supply_offer(c); if o then providers[#providers + 1] = o end
  end
  for _, c in ipairs(colony_mod.crate_list(colony, crates.DEMAND)) do
    local o = crate_demand_offer(c); if o then requesters[#requesters + 1] = o end
  end
  for _, p in ipairs(colony_mod.salt_pan_list(colony)) do
    local o = salt_offer(p); if o then providers[#providers + 1] = o end
  end
  for _, w in ipairs(colony_mod.well_list(colony)) do
    local o = well_offer(w); if o then providers[#providers + 1] = o end
  end
  for _, p in ipairs(colony_mod.pool_list(colony)) do
    local o = pool_offer(colony, p); if o then requesters[#requesters + 1] = o end
  end
  for _, t in ipairs(colony_mod.tavern_list(colony)) do
    local o = tavern_offer(t); if o then requesters[#requesters + 1] = o end
  end
  for _, c in ipairs(colony_mod.canteen_list(colony)) do
    local o = canteen_offer(colony, c); if o then requesters[#requesters + 1] = o end
  end
  local bins = colony_mod.bin_list(colony)
  for _, b in ipairs(bins) do
    local o = bin_offer(b); if o then providers[#providers + 1] = o end
  end

  machine_ids(colony)
  local demand = colony.machine_demand or {}
  local n = #demand
  if n > 0 then
    local take = math.min(n, M.MACHINE_OFFERS_PER_ASSIGN)
    local cursor = colony.machine_offer_cursor or 1
    for i = 0, take - 1 do
      local o = machine_offer(demand[(cursor - 1 + i) % n + 1])
      if o then requesters[#requesters + 1] = o end
    end
    colony.machine_offer_cursor = (cursor - 1 + take) % n + 1
  end
  local output = colony.machine_output or {}
  local no, ocursor = #output, colony.collect_offer_cursor or 1
  if no > 0 then
    local take = math.min(no, M.MACHINE_OFFERS_PER_ASSIGN)
    for i = 0, take - 1 do
      local c = collect_offer(colony, output[(ocursor - 1 + i) % no + 1])
      if c then providers[#providers + 1] = c end
    end
    colony.collect_offer_cursor = (ocursor - 1 + take) % no + 1
  end

  local storages = colony_mod.storage_list(colony)

  local compost_offers = {}
  if #bins > 0 then
    local spoil = colony_mod.stock_count(colony, compost.SOURCE)
    if spoil > 0 then
      local bin = bins[1]
      local band = spoil >= compost.SPOILAGE_PER_FERTILIZER and haul_plan.PRIORITY.collect or haul_plan.PRIORITY.compost
      local src_storage = nil
      for _, s in ipairs(storages) do
        if (s.available[compost.SOURCE] or 0) > 0 then src_storage = s; break end
      end
      compost_offers[1] = {
        priority = band,
        source = src_storage or storages[1],
        bin = bin,
        spoil = spoil,
        item = compost.SOURCE,
        key = bin.entity.unit_number,
      }
    end
  end

  return haul_plan.match(requesters, providers, storages, compost_offers, cap or M.CARRY_CAP, hauler_pos)
end
M.find_haul_task = find_haul_task

-- Take the load out of its source. The returned stacks hold the amounts that really left, so a
-- partially filled request can never duplicate items.
local function take_load(colony, offer)
  local taken = {}
  for _, s in ipairs(offer.load or {}) do
    local n = 0
    if offer.kind == "collect" or offer.kind == "direct" then
      local src = offer.source and offer.source.entity
        or (offer.machine and offer.machine.entity)
        or (offer.hut and offer.hut.entity)
        or (offer.crate and offer.crate.entity)
        or (offer.pan and offer.pan.entity)
        or (offer.well and offer.well.entity)
        or (offer.bin and offer.bin.entity)
      if src and src.valid then
        n = src.remove_item{name = s.item, count = s.count}
      end
    else
      local src = offer.source and offer.source.entity
      if src and src.valid then
        n = src.remove_item{name = s.item, count = s.count}
      end
      if n < s.count then
        local extra = colony_mod.take_stock(colony, s.item, s.count - n)
        n = n + extra
      end
    end
    if n and n > 0 then taken[#taken + 1] = {item = s.item, count = n} end
  end
  if #taken == 0 then return nil end
  if offer.kind == "supply" or offer.kind == "direct" then
    local tgt = offer.target or offer.house or offer.machine or offer.hut or offer.crate or offer.pan or offer.pool or offer.tavern or offer.canteen
    local inflight_obj = tgt and (tgt.house or tgt.machine or tgt.hut or tgt.crate or tgt.pan or tgt.pool or tgt.tavern or tgt.canteen or tgt)
    if inflight_obj and inflight_obj.inflight then
      for _, s in ipairs(taken) do
        inflight_obj.inflight[s.item] = (inflight_obj.inflight[s.item] or 0) + s.count
      end
    end
    return taken, inflight_obj
  end
  return taken, nil
end

local function return_to_hall(colony, stacks)
  local hall = colony.hall
  if not (hall and hall.valid) then return end
  for _, s in ipairs(stacks) do
    if s.item == compost.SOURCE then
      local bin = colony_mod.nearest_bin(colony, hall.position)
      local n = bin and bin.entity.valid and bin.entity.insert{name = s.item, count = s.count} or 0
      local left = s.count - n
      if left > 0 then
        local put = colony_mod.put_stock(colony, s.item, left)
        if put < left then
          hall.surface.spill_item_stack{position = hall.position, stack = {name = s.item, count = left - put}, allow_belts = false}
        end
      end
    else
      local n = colony_mod.put_stock(colony, s.item, s.count)   -- hall first, then warehouses
      if n < s.count then
        hall.surface.spill_item_stack{position = hall.position, stack = {name = s.item, count = s.count - n}, allow_belts = false}
      end
    end
  end
end
M.return_to_hall = return_to_hall

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
  go(e, site.target, 2)
  return true
end
M.start_construct = start_construct

local function start_trip(colony, un, hut)
  local e = colony.colonists[un]
  local site, quota_item, target_ore = find_site(colony, e, hut)
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
  elseif hut.job ~= "mine" and hut.job ~= "fish" and hut.job ~= "preserve" and hut.job ~= "research"
      and hut.job ~= "heal" and hut.job ~= "guard" then
    colony.claimed[key(site)] = true
  end
  if hut.job == "guard" then
    -- Anchored at the tower: no site to reach, no claim needed, the post is the building.
    storage.unit_state[un] = {colony_id = colony.id, job = "guard", hut = hut, state = "to_tower"}
    set_label(e, M.LABELS.guard, true)
    go(e, door_point(e.surface, hut.entity) or hut.entity.position, 0.5)
    return true
  end
  if hut.job == "hunt" then
    storage.unit_state[un] = {colony_id = colony.id, job = "hunt", hut = hut, state = "hunting", site = site,
      site_key = "boar:" .. site.unit_number, attempts = 0}
    set_label(e, M.LABELS.hunt)
    M.command_attack(e, site)
    return true
  end
  storage.unit_state[un] = {colony_id = colony.id, job = hut.job, hut = hut, state = "to_site", site = site,
    site_key = key(site), ore = target_ore}
  set_label(e, M.LABELS[hut.job] .. (colony_mod.is_inspired(colony, un) and " ★" or "")
    .. (colony_mod.is_sick(un) and " 🤒" or ""))
  go(e, site, site_radius(site))
  return true
end
M.start_trip = start_trip

local function idle(colony, un, e)
  -- A surplus colonist re-runs the whole job matrix on every retry and almost always finds nothing, which
  -- was most of the colony's Lua time in the #22 benchmark. Each fruitless retry waits a little longer; any
  -- real assignment replaces this state and starts over, and a hut, priority or target change wakes the town
  -- through reassign_workforce regardless of the timer.
  local prev = storage.unit_state[un]
  -- A young colony stays snappy (its few idle colonists must notice new work quickly); only a big town backs off.
  local pop = colony_mod.live_colonists(colony)
  local cap = math.min(1 + math.floor(pop / M.RETRY_BACKOFF_POP), M.RETRY_BACKOFF_MAX)
  local misses = math.min((prev and prev.state == "idle" and prev.misses or 0) + 1, cap)
  storage.unit_state[un] = {colony_id = colony.id, state = "idle", misses = misses}
  set_label(e, "idle")
  show_carry(e)
  local retry_period = (pop <= 5) and 60 or M.RETRY_TICKS
  local jitter = (pop <= 5) and ((un * 11) % 60) or ((un * 37) % 240)
  scheduler.after(retry_period * misses + jitter, "work.retry", {un = un})
end
M.idle = idle

-- Start a haul trip if there is one; returns true when the colonist is on its way.
-- Take a task's load and build the hauler state that delivers it: (state table, destination), or nil.
local function haul_trip(colony, task)
  local taken, inflight_target = take_load(colony, task)
  if not taken then return nil end
  -- Where the load physically is: picked up at source, or fallback to colony hall.
  local pickup = colony.hall.position
  if task.source and task.source.entity and task.source.entity.valid then
    pickup = task.source.entity.position
  elseif task.kind == "collect" then
    local src = task.machine or task.hut or task.crate or task.pan or task.well or task.bin
    if src and src.entity and src.entity.valid then pickup = src.entity.position end
  end

  local dest, state = nil, "to_house"
  local dest_entity = nil
  if task.kind == "collect" then
    dest_entity = task.target and task.target.entity
    dest = (dest_entity and dest_entity.valid and dest_entity.position) or colony.hall.position
    state = "to_hall"
  elseif task.kind == "compost" then
    local bin_obj = task.bin or (task.target and (task.target.bin or task.target))
    dest_entity = bin_obj and bin_obj.entity
    dest = (dest_entity and dest_entity.valid and dest_entity.position) or colony.hall.position
    state = "to_bin"
  else -- direct or supply
    local tgt_obj = task.target or task.house or task.machine or task.crate or task.pool or task.tavern or task.canteen or task.hut
    dest_entity = tgt_obj and tgt_obj.entity
    dest = (dest_entity and dest_entity.valid and dest_entity.position) or colony.hall.position
    state = "to_house"
  end

  local bin_obj = task.bin or (task.kind == "compost" and (task.target and (task.target.bin or task.target))) or nil
  local target_obj = inflight_target or (task.target and (task.target.house or task.target.machine or task.target.crate or task.target.pool or task.target.tavern or task.target.canteen or task.target.hut or task.target)) or (task.kind == "collect" and task.machine or nil)

  return {colony_id = colony.id, job = "haul", state = state, bin = bin_obj,
    target = target_obj, inflight_target = inflight_target, dest_entity = dest_entity,
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
M.start_haul = start_haul

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
  local big = find_haul_task(colony, motor.CAPACITY, e.position)
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
M.start_drive = start_drive

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
  local task = find_haul_task(colony, motor.CAPACITY, e.position)
  if task and motor.worth_truck(haul_plan.total(task.load)) and start_haul(colony, tun, e, task, "truck 🚚") then
    t.trips = t.trips - 1
    return
  end
  send_home(colony, tun, e)
end
M.assign_truck = assign_truck

-- Back at the pool: refuel and go again if the tank is what stopped it, otherwise park.
local function truck_home(colony, tun)
  local t = storage.trucks[tun]
  if not t then return end
  local driver = colony.colonists[t.driver]
  if t.trips <= 0 and driver and driver.valid and t.entity.valid and not M.is_sleep_time(t.entity.surface) then
    local task = find_haul_task(colony, motor.CAPACITY, t.entity.position)
    local trips = task and motor.worth_truck(haul_plan.total(task.load)) and burn_fuel(t.pool)
    if trips then
      t.trips = trips
      return assign_truck(colony, tun)
    end
  end
  park(colony, tun)
end

-- Passenger rail (#49): send a colonist to a platform to wait for a train out. Its current trip is abandoned
-- (carried goods go home, its hut seat frees up); the train itself is handled in scripts/transit.lua.
-- `extra` = more fields for the rider's state (commuters, #50: `commute`, or `home` + `wait_since`), `label` its tag.
function M.send_to_platform(colony, un, platform, extra, label)
  local e = colony.colonists[un]
  if not (e and e.valid and platform.entity.valid) then return false end
  local st = storage.unit_state[un]
  if st then
    if st.hut and st.hut.workers then st.hut.workers[un] = nil end
    M.release(st)
  end
  local nst = {colony_id = colony.id, job = "travel", state = "to_platform", platform = platform}
  for k, v in pairs(extra or {}) do nst[k] = v end
  storage.unit_state[un] = nst
  set_label(e, label or "leaving by train 🚉")
  go(e, platform.entity.position, 2.5)
  return true
end

-- Civil defence (#61, scripts/shelter.lua): run for `shelter` (a house or the Town Hall) and wait there.
function M.send_to_shelter(colony, un, shelter)
  local e = colony.colonists[un]
  if not (e and e.valid and shelter and shelter.valid) then return false end
  local st = storage.unit_state[un]
  local job = st and st.job
  if st then
    if st.hut and st.hut.workers then st.hut.workers[un] = nil end
    M.release(st)
  end
  local from = st and st.fled_from or {x = e.position.x, y = e.position.y}
  storage.unit_state[un] = {colony_id = colony.id, job = job or "idle", state = "to_shelter", shelter = shelter, fled_from = from}
  set_label(e, "taking shelter 🛡")
  go(e, shelter, 2)
  return true
end

-- The alarm is over: come out (vulnerable again) and go back to work.
function M.leave_shelter(colony, un)
  local e = colony.colonists[un]
  local st = storage.unit_state[un]
  if e and e.valid then e.destructible = true end
  if st then st.state, st.shelter, st.fled_from = "idle", nil, nil end
  M.assign(colony, un)
end

-- Set by scripts/shelter.lua: sends a colonist standing inside an alarm to shelter, true if it did.
M.take_cover = nil

function M.is_sleep_time(surface)
  if not surface or surface.freeze_daytime or not surface.daytime then return false end
  local d = surface.daytime
  return d >= 0.40 and d <= 0.60
end

-- Huts of one role that still have a free slot, least-staffed first (see labour.spread).
-- Breaks ties by proximity to colonist's house (#expectation: work close to home).
local function candidates_for(slot_list, job, home_pos)
  local out = {}
  for _, sl in ipairs(slot_list) do
    if sl.job == job then out[#out + 1] = sl end
  end
  local sorted = labour.spread(out)
  if home_pos and #sorted > 1 then
    table.sort(sorted, function(a, b)
      if a.workers ~= b.workers then return a.workers < b.workers end
      return dist2(a.hut.entity.position, home_pos) < dist2(b.hut.entity.position, home_pos)
    end)
  end
  return sorted
end
M.candidates_for = candidates_for

function M.assign(colony, un)
  if storage.trucks and storage.trucks[un] then return M.assign_truck(colony, un) end
  local e = colony.colonists[un]
  if not (e and e.valid and colony.hall.valid) then return end
  local st = storage.unit_state[un]
  -- Waiting inside a Motor Pool while its truck works: the truck decides when the shift ends.
  if st and st.state == "driving" and storage.trucks and storage.trucks[st.truck] then return end
  -- Bound for (or waiting at) a Passenger Platform: the next train decides (scripts/transit.lua).
  if st and (st.state == "to_platform" or st.state == "waiting_train") and st.platform and st.platform.entity.valid then
    return
  end
  -- Sheltering from enemies: the alarm decides when it is over (scripts/shelter.lua).
  if st and (st.state == "to_shelter" or st.state == "sheltered") and st.fled_from
      and alarm.covers(colony.alarms, st.fled_from) then return end
  if M.take_cover and colony.alarms and #colony.alarms > 0 and M.take_cover(colony, un, e) then return end
  if st and st.state == "sheltered" then e.destructible = true end   -- its alarm is gone: out and back to work
  local lock = colony.locks and colony.locks[un]

  -- Night time: colonists return to their house to sleep. Children (#88) sleep with the household too.
  if M.is_sleep_time(e.surface) then
    if st and st.hut then
      if st.hut.workers then st.hut.workers[un] = nil end
      st.hut = nil
    end
    -- Going to bed never evaporates the load being hauled: it lands in the hall like any completed trip home.
    if st and st.carry and #st.carry > 0 then M.return_to_hall(colony, st.carry) end
    local house = colony_mod.house_of_colonist(colony, un)
    if house and house.valid then
      storage.unit_state[un] = {colony_id = colony.id, job = is_child(un) and "child" or (st and st.job) or lock or "idle", state = "to_bed", house = house}
      M.set_label(e, "going to bed 🏠", true)
      M.go(e, M.door_point(e.surface, house) or house.position, 0.5)
      return
    end
  elseif is_child(un) then
    -- A child is not part of the workforce: it stays by the house until grown, so no job, no retry timer.
    storage.unit_state[un] = {colony_id = colony.id, job = "child", state = "child"}
    M.set_label(e, "child", true)
    return
  end

  local pop = math.max(colony_mod.live_colonists(colony) - 1, 0)
  local missing

  -- Keep the current post while its hut stands, still holds a slot for us and matches the player's lock.
  -- This is the common case by far, and it is the difference between an O(1) assignment and rebuilding the
  -- whole job matrix for every colonist that finishes a trip (#22 re-measured it).
  local prev_hut = st and st.hut
  if prev_hut then
    local capped = not lock and (colony_mod.headcount_capped(colony, prev_hut.job) or not jobs.enabled(colony.priority, prev_hut.job) or M.hut_quota_met(colony, prev_hut))
    -- A harvester leaves its post when another resource is missing, or (small towns only: it rebuilds the haul
    -- list) when deliveries are waiting and the town is short of haulers. Kept off the common path otherwise:
    -- keeping the post must stay O(1) (#22).
    local should_switch = false
    if not lock and HARVEST_JOB[prev_hut.job] then
      missing = M.colony_missing_jobs(colony)
      local mates = 0
      for _ in pairs(prev_hut.workers or {}) do mates = mates + 1 end
      -- Never strip a hut of its last worker for another resource (see work_plan.choose).
      -- Hunger priority (#expectation): if there is no food in the colony, food roles come first.
      -- A harvester on a non-food job (wood/ore) switches to food if the town is starving.
      local starving = colony_mod.total_food(colony) == 0
      if starving and not FOOD_JOB[prev_hut.job] then
        should_switch = true
      elseif next(missing) and not missing[prev_hut.job] and mates >= 2 then
        should_switch = true
      elseif pop < M.SMALL_TOWN then
        local task, backlog = M.find_haul_task(colony, nil, e.position)
        local counts = task and M.job_counts(colony)
        local haul_wanted = task and (headcount.target(colony.job_targets, "haul") or work_plan.haul_target(math.max(pop, 1), backlog))
        if task and (counts.haul or 0) < haul_wanted then should_switch = true end
      end
    end
    if not capped and not should_switch and prev_hut.entity and prev_hut.entity.valid and prev_hut.workers and prev_hut.workers[un]
        and (not lock or lock == prev_hut.job) then
      local _, _, allowed, workers = M.hut_info(prev_hut)
      if workers <= allowed and M.start_trip(colony, un, prev_hut) then return end
    end
    if prev_hut.workers then prev_hut.workers[un] = nil end
  end

  local counts = M.job_counts(colony)
  if st and st.job then counts[st.job] = math.max((counts[st.job] or 1) - 1, 0) end
  local slots, capacity, slot_list, hut_count = M.job_slots(colony)
  local task, backlog = M.find_haul_task(colony, nil, e.position)
  missing = missing or M.colony_missing_jobs(colony)

  local target = math.max(colony_mod.live_colonists(colony) * colony_mod.FOOD_PER_COLONIST * colony_mod.TARGET_STOCK_INTERVALS, 1)
  local choose_state = {
    food_ratio = colony_mod.total_food(colony) / target,
    counts = counts,
    slots = slots,
    capacity = capacity,
    hut_count = hut_count,
    pop = pop,
    haul = task ~= nil,
    backlog = backlog,
    priority = colony.priority,
    targets = colony.job_targets,
    missing = missing,
    cursor = colony.harvest_cursor or 0,
  }

  for attempt = 1, 2 do
    local job
    if lock then
      job = lock
    else
      job = work_plan.choose(choose_state)
      if job and (job == "chop" or job == "mine" or job == "forage" or job == "farm" or job == "hunt" or job == "fish") then
        colony.harvest_cursor = ((colony.harvest_cursor or 0) + 1) % 1000000
      end
    end

    if not job then M.idle(colony, un, e); return end
    if job == "haul" then
      if M.start_drive(colony, un, e, task) then return end
      if M.start_haul(colony, un, e, task) then return end
      if attempt == 1 and not lock then
        choose_state.haul = false
      else
        M.idle(colony, un, e); return
      end
    elseif job == "construct" then
      if M.start_construct(colony, un, e) then return end
      if attempt == 1 and not lock then
        slots.construct = 0
        choose_state.slots = slots
      else
        M.idle(colony, un, e); return
      end
    else
      local house = colony_mod.house_of_colonist(colony, un)
      local home_pos = house and house.valid and house.position or e.position
      local candidate_huts = M.candidates_for(slot_list, job, home_pos)
      local started = false
      for _, sl in ipairs(candidate_huts) do
        sl.hut.workers[un] = true
        if M.start_trip(colony, un, sl.hut) then
          started = true
          return
        end
      end
      -- If all candidates for this job failed (e.g. no site / missing inputs, comms #4), retry once with other roles
      if not started and attempt == 1 and not lock then
        slots[job] = 0
        choose_state.slots = slots
      else
        M.idle(colony, un, e)
        return
      end
    end
  end
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

scheduler.register("garrison.scan", function(d)
  local st = storage.unit_state[d.un]
  if not (st and st.job == "guard" and st.state == "guarding") then return end
  local colony = storage.colonies[st.colony_id]
  if not colony then return end
  local tower = st.hut and st.hut.entity
  if not (tower and tower.valid) then M.assign(colony, d.un); return end   -- tower mined: back to work
  -- The post must still be legitimate: crewed up to the rifles actually in the tower (limit lowered or a rifle
  -- broke). Releasing here is what keeps a garrison from outliving its weapons.
  local _, _, allowed, workers = M.hut_info(st.hut)
  if allowed <= 0 or workers > allowed or not (st.hut.workers and st.hut.workers[d.un]) then
    M.assign(colony, d.un)
    return
  end
  -- Off duty at night like everyone else (#86); the morning assignment re-posts them.
  if M.is_sleep_time(tower.surface) then M.assign(colony, d.un); return end
  local surface, tp, r = tower.surface, tower.position, garrison.RANGE
  local list = {}
  for _, en in ipairs(surface.find_entities_filtered{type = "unit", force = "enemy",
      area = {{tp.x - r, tp.y - r}, {tp.x + r, tp.y + r}}}) do
    if en.valid then list[#list + 1] = {unit_number = en.unit_number, position = en.position, entity = en} end
  end
  local pick = garrison.nearest(list, tp, r)
  local e2 = unit_entity(colony, d.un)
  if pick and e2 and e2.valid then
    st.site, st.state, st.engaged, st.attempts = pick.entity, "guarding-fight", {un = pick.unit_number}, 1
    M.command_attack(e2, pick.entity)
    return
  end
  scheduler.after(garrison.CHECK_TICKS + (d.un * 29) % 120, "garrison.scan", {un = d.un})
end)

scheduler.register("work.retry", function(d)
  local st = storage.unit_state[d.un]
  -- Retries are only ever scheduled for an idle colonist. A second retry landing in the same tick as a first
  -- must not reassign a colonist that just set off on a trip: that drops the load it already picked up (#56).
  if not (st and st.state == "idle") then return end
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
    if hut.entity.name == toolsmith.NAME then
      -- A tool is made from the wood, iron and copper in the Toolsmith's own chest, then carried home like any yield.
      local tool, recipe = toolsmith_pick(colony, hut)
      if tool then
        for ingredient, n in pairs(recipe) do hut.entity.remove_item{name = ingredient, count = n} end
        for ingredient, n in pairs(recipe) do stats.consumed(colony, ingredient, n) end
        item, n = tool, 1
        M.tools_made = M.tools_made + 1
        rendering.draw_text{text = {"colony-message.workshop-made", "[item=" .. tool .. "]"}, surface = hut.entity.surface,
          target = {entity = hut.entity, offset = {0, -2.5}}, color = {0.8, 1, 0.8}, scale = 1, alignment = "center",
          time_to_live = 120}
      end
    elseif hut.entity.name == "colony-kitchen" then
      local recipe = kitchen.recipe(chest_contents(hut.entity) or {})
      if recipe then
        hut.entity.remove_item{name = kitchen.PRODUCE, count = kitchen.PRODUCE_PER_BATCH}
        hut.entity.remove_item{name = kitchen.WATER, count = kitchen.WATER_PER_BATCH}
        stats.consumed(colony, kitchen.PRODUCE, kitchen.PRODUCE_PER_BATCH)
        stats.consumed(colony, kitchen.WATER, kitchen.WATER_PER_BATCH)
        item, n = recipe.product, kitchen.PRODUCT_PER_BATCH
      end
    else
      local recipe = preserve.recipe(chest_contents(hut.entity) or {})
      if recipe then
        hut.entity.remove_item{name = preserve.SALT, count = preserve.SALT_PER_BATCH}
        hut.entity.remove_item{name = recipe.raw, count = preserve.RAW_PER_BATCH}
        stats.consumed(colony, preserve.SALT, preserve.SALT_PER_BATCH)
        stats.consumed(colony, recipe.raw, preserve.RAW_PER_BATCH)
        item, n = recipe.product, preserve.PRODUCT_PER_BATCH
      end
    end
  elseif st.job == "fish" then
    item, n = "colony-fish", fishing.FISH_PER_TRIP
  elseif st.job == "mine" and site.type == "simple-entity" then
    -- A rock: take its whole yield of the targeted ore (or best-ranked ore) that the colony still wants, and it is gone.
    if st.ore and rock_yield(site, st.ore) > 0 and not colony_mod.quota_met(colony, st.ore) then
      item, n = st.ore, rock_yield(site, st.ore)
    else
      for _, ore in ipairs(mine_plan.order(hut.ores)) do
        local y = rock_yield(site, ore)
        if y > 0 and not colony_mod.quota_met(colony, ore) then item, n = ore, y; break end
      end
    end
    if n > 0 then
      site.destroy()
      e.surface.pollute(pos, M.MINE_POLLUTION)
    end
  elseif st.job == "mine" then
    n = math.min(M.MINE_PER_TRIP, site.amount or 0)
    if n > 0 then
      if site.amount > n then
        site.amount = site.amount - n
      elseif site.deplete then
        site.deplete()
      else
        site.destroy()
      end   -- 0 is not a legal amount (#10, #54)
      e.surface.pollute(pos, M.MINE_POLLUTION)       -- 1:1 depletion, zero electricity, but not zero pollution
    end
  elseif st.job == "heal" then
    -- Doctors (#47) stay on duty while there is medicine and someone to treat; the cures themselves happen in
    -- the colony evaluation (scripts/illness.lua), which counts the doctors working here.
    local lock = colony.locks and colony.locks[d.un]
    if not M.is_sleep_time(e.surface) and (colony.sick_count or 0) > 0 and hut.entity.get_item_count(illness.MEDICINE) > 0 and (not lock or lock == "heal") then
      e.commandable.set_command{type = defines.command.stop, ticks_to_wait = 4294967295, distraction = defines.distraction.none}
      scheduler.after(M.WORK_TICKS + (d.un * 23) % 240, "work.finish", {un = d.un})
      return
    end
    if hut.workers then hut.workers[d.un] = nil end
    M.release(st)
    M.assign(colony, d.un)
    return
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
    if not M.is_sleep_time(e.surface) and have and (not lock or lock == "research") then
      local e = colony.colonists[d.un]
      if e and e.valid and hut.entity.valid then
        e.commandable.set_command{type = defines.command.stop, ticks_to_wait = 4294967295, distraction = defines.distraction.none}
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
  stats.produced(colony, item, n)
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
    -- Clear colliding trees and rocks on the ghost footprint before reviving!
    if site and site.valid and site.type == "entity-ghost" then
      for _, blocker in ipairs(site.surface.find_entities_filtered{area = site.bounding_box, type = {"tree", "simple-entity"}}) do
        if blocker.valid then blocker.destroy() end
      end
    end
    -- `revive` consumes the ghost, so capture what we need for the message first.
    local pos = site and site.valid and {x = site.position.x, y = site.position.y}
    local ghost_name = site and site.valid and site.ghost_name
    local ghost_tags = site and site.valid and site.tags
    -- `revive` returns (items it collided with, the new entity, the item request proxy): the entity is the
    -- second value, so take it explicitly rather than testing the item list for truthiness. `raise_revive`
    -- also re-delivers the ghost's blueprint tags to `on_built`, which is how a revived opt-in machine is
    -- registered again (#36).
    local built = site and site.valid and site.type == "entity-ghost" and select(2, site.revive{raise_revive = true})
    if built then
      if ghost_tags then colony_mod.apply_tags(colony, built, ghost_tags) end
      for _, s in ipairs(st.carry or {}) do stats.consumed(colony, s.item, s.count) end
      st.carry = nil                            -- the ghost consumed the materials
      if colony.ghosts then colony.ghosts[st.site_key] = nil end
      popup(e.surface, pos or e.position, {"", "Built ", item_name(ghost_name)})
    else
      local attempts = st.attempts or 0
      local blocker = site and site.valid and unit_blocking(site)
      if attempts < 2 and (blocker or (site and site.valid)) then
        st.attempts = attempts + 1
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
        stats.consumed(colony, construct.REPAIR_PACK, 1)
        popup(e.surface, site.position, {"", "Repaired ", item_name(site.name)})
      end
    end
    if packs > 0 then return_to_hall(colony, {{item = construct.REPAIR_PACK, count = packs}}) end
  end
  wake_idle_colonists(colony)
  M.assign(colony, d.un)
end)

scheduler.register("work.sleep_check", function(d)
  local st = storage.unit_state and storage.unit_state[d.un]
  if not (st and (st.state == "sleeping" or st.state == "to_bed")) then return end
  local colony = storage.colonies[st.colony_id]
  local e = colony and colony.colonists and colony.colonists[d.un]
  if not (colony and e and e.valid) then return end
  local house = st.house or colony_mod.house_of_colonist(colony, d.un)
  if M.is_sleep_time(e.surface) then
    if house and house.valid then
      e.teleport(house.position)
      e.destructible = false
      popup(house.surface, house.position, "💤")
    end
    e.commandable.set_command{type = defines.command.stop, ticks_to_wait = 4294967295, distraction = defines.distraction.none}
    scheduler.after(180 + (d.un * 13) % 120, "work.sleep_check", d)
  else
    e.destructible = true
    if house and house.valid then
      local out_pos = door_point(e.surface, house) or house.position
      e.teleport(out_pos)
      popup(e.surface, out_pos, "☀️")
    else
      popup(e.surface, e.position, "☀️")
    end
    st.state = "idle"
    M.assign(colony, d.un)
  end
end)

events.on(defines.events.on_ai_command_completed, function(ev)
  local st = storage.unit_state[ev.unit_number]
  if not st then return end
  local colony = storage.colonies[st.colony_id]
  if not colony then return end
  if st.state == "to_platform" then
    local e = unit_entity(colony, ev.unit_number)
    if ev.result == defines.behavior_result.success and e and e.valid then
      st.state = "waiting_train"
      set_label(e, "waiting for a train 🚉")
    else
      storage.unit_state[ev.unit_number] = {colony_id = colony.id, state = "idle"}   -- cannot reach it: stay
      M.assign(colony, ev.unit_number)
    end
    return
  end
  if st.state == "to_shelter" then
    -- Inside: out of reach of the enemy until the all-clear. A shelter it cannot reach leaves it exposed, and
    -- the next alarm check sends it to another one.
    local e = unit_entity(colony, ev.unit_number)
    if not (e and e.valid) then return end
    if ev.result == defines.behavior_result.success and st.shelter and st.shelter.valid then
      st.state = "sheltered"
      e.destructible = false
      e.commandable.set_command{type = defines.command.stop, ticks_to_wait = 4294967295, distraction = defines.distraction.none}
      set_label(e, "sheltering 🛡")
    else
      st.state, st.shelter = "exposed", nil
    end
    return
  end
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
  if st.state == "to_tower" then
    -- Posted: hold at the door with a stop order; the scan decides who to engage.
    st.state = "guarding"
    local e2 = unit_entity(colony, ev.unit_number)
    if e2 and e2.valid then
      e2.commandable.set_command{type = defines.command.stop, ticks_to_wait = 4294967295, distraction = defines.distraction.none}
      set_label(e2, M.LABELS.guard, true)
    end
    scheduler.after(garrison.CHECK_TICKS + (ev.unit_number * 29) % 120, "garrison.scan", {un = ev.unit_number})
    return
  end
  if st.job == "guard" and st.state == "guarding-fight" then
    -- One engagement just finished (kill or done trying): weapon wear or ammo pays.
    use_weapon(st.hut)
    local e2 = unit_entity(colony, ev.unit_number)
    if ev.result ~= defines.behavior_result.success and st.site and st.site.valid
        and (st.attempts or 1) < garrison.MAX_ATTEMPTS then
      st.attempts = (st.attempts or 0) + 1
      if e2 and e2.valid then M.command_attack(e2, st.site); return end
    end
    st.site, st.state, st.engaged, st.attempts = nil, "guarding", nil, nil
    if e2 and e2.valid then
      e2.commandable.set_command{type = defines.command.stop, ticks_to_wait = 4294967295, distraction = defines.distraction.none}
    end
    scheduler.after(garrison.CHECK_TICKS + (ev.unit_number * 29) % 120, "garrison.scan", {un = ev.unit_number})
    return
  end
  if st.state == "to_bed" then
    st.state = "sleeping"
    local e = unit_entity(colony, ev.unit_number)
    local house = st.house or (colony and colony_mod.house_of_colonist(colony, ev.unit_number))
    if e and e.valid and house and house.valid then
      e.teleport(house.position)
      e.destructible = false
      e.commandable.set_command{type = defines.command.stop, ticks_to_wait = 4294967295, distraction = defines.distraction.none}
      clear_label(ev.unit_number)
      clear_carry_sprite(ev.unit_number)
      popup(house.surface, house.position, "💤")
      scheduler.after(180 + (ev.unit_number * 13) % 120, "work.sleep_check", {un = ev.unit_number})
    elseif e and e.valid then
      e.commandable.set_command{type = defines.command.stop, ticks_to_wait = 4294967295, distraction = defines.distraction.none}
      clear_label(ev.unit_number)
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
      use_weapon(st.hut)                          -- a kill is a completed trip: weapon wear or ammo pays
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
    if e and e.valid then
      e.commandable.set_command{type = defines.command.stop, ticks_to_wait = 4294967295, distraction = defines.distraction.none}
      if st.site and st.site.valid then work_ring(e, st.site.position) end
    end
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
    wake_idle_colonists(colony)
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
    wake_idle_colonists(colony)
    M.assign(colony, ev.unit_number)
  elseif st.state == "to_site" then
    st.state = "working"
    local e = unit_entity(colony, ev.unit_number)
    if e and e.valid then
      e.commandable.set_command{type = defines.command.stop, ticks_to_wait = 4294967295, distraction = defines.distraction.none}
      if st.site and st.site.valid then work_ring(e, st.site.position, site_radius(st.site) * 0.75) end
    end
    if st.hut and st.hut.job == "research" and st.hut.entity.valid then
      local def = labour.HUTS[st.hut.entity.name]
      update_lab_status(st.hut.entity, worker_count(st.hut), def and def.capacity or 2)
    end
    -- Inspired colonists (served by a Tavern, #48) finish each job sooner.
    local base = M.WORK_TICKS
    if st.hut and st.hut.entity.valid and st.hut.entity.name == toolsmith.NAME then base = toolsmith.work_ticks(base) end
    local ticks = recreation.work_ticks(base, colony_mod.is_inspired(colony, ev.unit_number))
    ticks = illness.work_ticks(ticks, colony_mod.is_sick(ev.unit_number))   -- the sick work at half speed (#47)
    scheduler.after(ticks + (ev.unit_number * 23) % 240, "work.finish", {un = ev.unit_number})
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
    wake_idle_colonists(colony)
    M.assign(colony, ev.unit_number)
  elseif st.state == "to_hall" then
    if st.carry then
      local dest_e = st.dest_entity
      if dest_e and dest_e.valid then
        local leftover = {}
        for _, s in ipairs(st.carry) do
          local n = dest_e.insert{name = s.item, count = s.count}
          if n < s.count then leftover[#leftover + 1] = {item = s.item, count = s.count - n} end
        end
        if #leftover > 0 then return_to_hall(colony, leftover) end
      else
        return_to_hall(colony, st.carry)
      end
    end
    st.carry = nil
    colony.ledger_cache = nil
    wake_idle_colonists(colony)
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
  if un and storage.unit_state and storage.unit_state[un]
      and settings and settings.global and settings.global["colony-debug-log"] and settings.global["colony-debug-log"].value then
    local st = storage.unit_state[un]
    log(string.format("[colony-destroyed] tick=%d colonist %s destroyed (job=%s state=%s colony=%s)",
      game.tick, tostring(un), tostring(st.job), tostring(st.state), tostring(st.colony_id)))
  end
  local st = un and storage.unit_state[un]
  if st then
    if st.hut and st.hut.workers then st.hut.workers[un] = nil end
    M.release(st)
    storage.unit_state[un] = nil
  end
  if un and storage.sick then storage.sick[un] = nil end
  if un and storage.age then storage.age[un] = nil end
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
    local obj = type(lbl) == "table" and lbl.obj or lbl   -- labels are {mode, obj} since schema 28
    if obj and obj.valid then obj.destroy() end
    storage.unit_labels[un] = nil
  end
  local carried = un and storage.carry_sprites and storage.carry_sprites[un]
  if carried then
    if carried.obj.valid then carried.obj.destroy() end
    storage.carry_sprites[un] = nil
  end
end)

local in_damage_bonus = false
events.on(defines.events.on_entity_damaged, function(ev)
  if in_damage_bonus then return end
  local attacker = ev.cause
  if not (attacker and attacker.valid and attacker.name == "colony-colonist") then return end
  local st = storage.unit_state and storage.unit_state[attacker.unit_number]
  local hut = st and st.hut
  if hut and hut_weapon(hut) == "gun" then
    if ev.entity and ev.entity.valid and ev.entity.health > 0 then
      in_damage_bonus = true
      ev.entity.damage(15, attacker.force, "physical", attacker)
      in_damage_bonus = false
    end
  end
end)

return M
