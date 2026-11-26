-- Armory adapter (M3 defence stack, #56 remainder). A worker-free depot (like a Well or Salt Pan) with two
-- jobs: it is the militia's gear source, and a *manned* Armory (or a posted Watchtower) grants a structural
-- damage aura. All rules live in pure models (model/defence.lua, model/armour.lua); this file only resolves
-- live entities, reads chest inventories and applies one heal-back on the existing #61 damage handler.
-- Bound via M.bind (no runtime require of scripts.colony). No per-tick scans: posts are derived on damage only.
local territory = require("scripts.territory")
local defence = require("scripts.model.defence")
local armour = require("scripts.model.armour")
local haul_plan = require("scripts.model.haul_plan")
local M = {}

-- M.bind stays part of the bind protocol; this adapter needs no colony reference.
function M.bind() end

M.EQUIP_RANGE = defence.RADIUS   -- militia draws from an Armory within the same radius the aura covers
M.MAX_LIMIT = 4                  -- at most four militia can be equipped from one Armory

local function invalidate(colony)
  if not colony then return end
  colony.ledger_cache, colony.stock_cache, colony.storage_cache = nil, nil, nil
end

--- Sorted, valid armories of a colony; dead entries are pruned in place (plain data only).
---@param colony table
---@return table[] records
function M.list(colony)
  if not colony then return {} end
  colony.armories = colony.armories or {}
  local ids, out = {}, {}
  for un, a in pairs(colony.armories) do
    if a and a.entity and a.entity.valid then ids[#ids + 1] = un else colony.armories[un] = nil end
  end
  table.sort(ids)
  for _, un in ipairs(ids) do out[#out + 1] = colony.armories[un] end
  return out
end

--- Called from colony.lua when a player builds (or a blueprint revives) a colony-armory.
--- The default limit is 0: an unmanned Armory asks for nothing, grants nothing and never nags.
---@param colony table
---@param e LuaEntity
---@param dict table|nil blueprint tags (reserved; the manning limit is plain registry state)
function M.register(colony, e, dict)
  colony.armories = colony.armories or {}
  colony.armories[e.unit_number] = {entity = e, colony_id = colony.id, inflight = {}, equipped = {},
    limit = 0, logistics_enabled = true, priority = 3}
  invalidate(colony)
  return colony.armories[e.unit_number]
end

--- Chest contents with qualities, as plain values (a unit cannot carry a real gear grid - s19_defence).
---@param a table armory record
---@return table<string, integer>, table<string, string>
function M.contents(a)
  local counts, quals = {}, {}
  if not (a and a.entity and a.entity.valid) then return counts, quals end
  local inv = a.entity.get_inventory(defines.inventory.chest)
  if not inv then return counts, quals end
  for _, stack in ipairs(inv.get_contents()) do
    if stack and stack.name then
      counts[stack.name] = (counts[stack.name] or 0) + (stack.count or 1)
      local q = stack.quality
      quals[stack.name] = type(q) == "string" and q or (q and q.name) or "normal"
    end
  end
  return counts, quals
end

--- Remove gear from an Armory's own chest. Returns the number actually removed.
---@param a table
---@param item string
---@param count integer
---@return integer
function M.take(a, item, count)
  if not (a and a.entity and a.entity.valid and item) then return 0 end
  local n = a.entity.remove_item{name = item, count = count or 1}
  if n > 0 then invalidate(storage.colonies[a.colony_id]) end
  return n
end

--- Return gear to its source Armory (or the Town Hall if the Armory was mined/full).
---@param colony table
---@param a table|nil
---@param item string
---@param count integer
---@return integer
function M.put(colony, a, item, count)
  if not item then return 0 end
  local n = 0
  if a and a.entity and a.entity.valid then n = a.entity.insert{name = item, count = count or 1} end
  local left = (count or 1) - n
  if left > 0 and colony.hall and colony.hall.valid then
    n = n + colony.hall.insert{name = item, count = left}
  end
  if n > 0 then invalidate(colony) end
  return n
end

--- Nearest Armory within EQUIP_RANGE that can actually grant part of `wanted_fn(contents)`.
--- `wanted_fn` is supplied by the militia adapter (it knows which gear the unit is missing), so the source
--- choice stays here and the gear choice stays in the pure model. Ties break by unit number via M.list.
---@param colony table
---@param pos table
---@param wanted_fn fun(counts: table, quals: table): table[]
---@return table|nil, table[] grants
function M.gear_source(colony, pos, wanted_fn)
  local best, best_d2, best_grants
  for _, a in ipairs(M.list(colony)) do
    local p = a.entity.position
    local dx, dy = p.x - pos.x, p.y - pos.y
    local d2 = dx * dx + dy * dy
    if d2 <= M.EQUIP_RANGE * M.EQUIP_RANGE and (not best_d2 or d2 <= best_d2) then
      local counts, quals = M.contents(a)
      local grants = armour.draw_gear(counts, wanted_fn(counts, quals))
      if #grants > 0 then best, best_d2, best_grants = a, d2, grants end
    end
  end
  return best, best_grants or {}
end

--- A militia drew (some of) its gear from this Armory: record the claim as plain unit numbers.
---@param colony table
---@param un integer
---@param a table|nil
function M.mark_equipped(colony, un, a)
  if not (a and un) then return end
  a.equipped = a.equipped or {}
  a.equipped[un] = true
  invalidate(colony)
end

--- A militia died or demobilised: drop every claim it held (idempotent).
---@param colony table
---@param un integer|nil
function M.clear_equipped(colony, un)
  if not un then return end
  for _, a in ipairs(M.list(colony)) do
    if a.equipped and a.equipped[un] then a.equipped[un] = nil; invalidate(colony) end
  end
end

--- Equipped militia currently answered by this Armory. Stale claims are pruned lazily (no per-tick sweep):
--- a claim lives only while the unit is an on-duty militia whose gear still names this Armory as its source.
---@param colony table
---@param a table
---@return integer
function M.equipped_count(colony, a)
  if not a.equipped then return 0 end
  local n = 0
  for un in pairs(a.equipped) do
    local st = storage.unit_state and storage.unit_state[un]
    local e = colony.colonists and colony.colonists[un]
    local gear = st and st.gear
    if st and st.job == "militia" and gear and gear.source_armory == a.entity.unit_number
        and e and e.valid and (st.state == "militia-hold" or st.state == "militia-fight") then
      n = n + 1
    else
      a.equipped[un] = nil
    end
  end
  return math.min(n, a.limit or 0)
end

--- Every manned post in one colony, as plain records for model/defence.coverage. Watchtowers use the same
--- rule as Armories: a tower with posted guards grants the aura too, so the two structures share one path.
---@param colony table
---@return table[] posts
function M.posts(colony)
  local out = {}
  for _, a in ipairs(M.list(colony)) do
    local limit = a.limit or 0
    if limit > 0 then
      local n = M.equipped_count(colony, a)
      if n > 0 then
        out[#out + 1] = {position = a.entity.position, key = a.entity.unit_number, strength = defence.aura(n)}
      end
    end
  end
  for un, tower in pairs(colony.towers or {}) do
    if tower and tower.valid then
      local hut = colony.huts and colony.huts[un]
      if hut and hut.workers and next(hut.workers) ~= nil then
        local guards = 0
        for _ in pairs(hut.workers) do guards = guards + 1 end
        out[#out + 1] = {position = tower.position, key = un, strength = defence.aura(math.min(guards, 4))}
      end
    end
  end
  return out
end

--- Apply the aura on an enemy damage event. Called from shelter.lua's ONE on_entity_damaged handler, so a
--- town with no manned posts pays one empty-table check and there is never a second per-tick pass.
--- Units are excluded: militia armour owns their mitigation (different model, different heal-back path), and
--- healing an enemy is impossible because we require a colony-owned target inside that colony's territory.
---@param ev table on_entity_damaged event
function M.mitigate(ev)
  local e = ev.entity
  if not (e and e.valid) then return end
  local etype = e.type
  if etype == "unit" or etype == "character" then return end
  local f = ev.force
  if not (f and f.name == "enemy") or e.force.name == "enemy" then return end
  local owner = territory.owner_at(e.surface.index, e.position)
  local colony = owner and storage.colonies[owner]
  if not colony or not colony.hall or not colony.hall.valid then return end
  local posts = M.posts(colony)
  if #posts == 0 then return end
  local applied = ev.final_damage_amount or ev.original_damage_amount or 0
  if applied <= 0 then return end
  local reduction = defence.coverage(e.position, posts, defence.RADIUS)
  if reduction <= 0 then return end
  local healed = applied - defence.apply_incoming(applied, reduction)
  if healed <= 0 then return end
  local hp = e.health
  -- Setting health does not raise on_entity_damaged (Stage 1), so this cannot recurse. Never revive and never
  -- heal past full: repeated hits can only subtract from the same finite health pool.
  if not hp or hp <= 0 then return end
  local cap = (e.max_health or hp) - hp
  if cap <= 0 then return end
  e.health = hp + math.min(healed, cap)
end

--- Requester offer for the gear haul band. A limit of 0 emits nothing at all (no nagging, no hauler trips).
---@param a table armory record
---@param colony table
---@return table|nil HaulOffer
function M.offer(a, colony)
  if a.logistics_enabled == false then return nil end
  local limit = a.limit or 0
  if limit <= 0 then return nil end
  local contents = M.contents(a)
  -- Endgame armour is only requested once Bio-Ecological Data is researched; before that the haul rows are
  -- exactly what they always were (#69).
  local unlocked = nil
  local force = colony.hall and colony.hall.valid and colony.hall.force
  local data = force and force.technologies and force.technologies["colony-bio-ecological-data"]
  if data and data.researched then
    unlocked = {}
    for _, item in ipairs(armour.ENDGAME) do unlocked[item] = true end
  end
  local demands = armour.restock_deficit(contents, armour.armory_targets(limit, unlocked), a.inflight)
  if #demands == 0 then return nil end
  return {kind = "supply", armory = a, entity = a.entity, pos = a.entity.position,
    priority = haul_plan.PRIORITY.tools, building_priority = a.priority or 3,
    key = a.entity.unit_number, demands = demands}
end

--- Change a player's manning limit. Lowering it closes posts; gear stays in the chest (as with a tower).
---@param a table
---@param delta integer
function M.shift_limit(a, delta)
  a.limit = math.max(0, math.min(M.MAX_LIMIT, (a.limit or 0) + delta))
end

return M
