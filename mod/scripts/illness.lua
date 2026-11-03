-- Illness adapter (#47). Rules are in model/illness.lua. storage.sick[unit_number] = {kind, age}. Everything runs
-- once per colony evaluation: exposure rolls, the Clinic's cures, and untreated illness running its course.
local illness = require("scripts.model.illness")
local mortality = require("scripts.mortality")
local M = {}

M.CLINIC = "colony-clinic"

local colony_mod   -- injected by scripts.colony via M.bind
function M.bind(c) colony_mod = c end

function M.is_sick(un) return storage.sick ~= nil and storage.sick[un] ~= nil end

-- Called by the house loop before a house's meal leaves its inventory: true when any food it is about to eat is
-- nearly spoiled (the first stack of each item is the one taken).
function M.rotten_meal(inv, consumed, food)
  for item, n in pairs(consumed) do
    if n > 0 and food[item] then
      local stack = inv.find_item_stack(item)
      if stack and stack.valid_for_read and (stack.spoil_percent or 0) >= illness.ROTTEN then return true end
    end
  end
  return false
end

-- Clinics in a stable order (they are labour huts: colony.huts entries whose job is "heal").
function M.clinics(colony)
  local out, ids = {}, {}
  for un, h in pairs(colony.huts or {}) do
    if h.job == "heal" and h.entity.valid then ids[#ids + 1] = un end
  end
  table.sort(ids)
  for _, un in ipairs(ids) do out[#out + 1] = colony.huts[un] end
  return out
end

local function medicine(colony)
  local n = 0
  for _, h in ipairs(M.clinics(colony)) do n = n + h.entity.get_item_count(illness.MEDICINE) end
  return n
end

local function use_medicine(colony, n)
  for _, h in ipairs(M.clinics(colony)) do
    if n <= 0 then return end
    n = n - h.entity.remove_item{name = illness.MEDICINE, count = n}
  end
end

-- Doctors on duty: colonists working a Clinic right now.
local function doctors(colony)
  local n = 0
  for un in pairs(colony.colonists) do
    local st = storage.unit_state[un]
    if st and st.job == "heal" and st.state == "working" then n = n + 1 end
  end
  return n
end

local function kill(colony, un, kind)
  local e = colony.colonists[un]
  storage.sick[un] = nil
  if not (e and e.valid) then return end
  local pos, surface = e.position, e.surface
  colony.colonists[un] = nil                      -- struck off first, so mortality's handler does not count it twice
  if colony.locks then colony.locks[un] = nil end
  colony.pop_cache, colony.pop_tick = nil, nil
  mortality.record(colony, pos, surface, "illness", true)
  e.die()
  colony.hall.force.print({"colony-message.died-illness", {"colony-illness." .. kind}, colony_mod.gps(pos, surface)})
end

-- One evaluation. `rotten` = set of house unit numbers that just ate nearly spoiled food.
function M.evaluate(colony, rotten)
  storage.sick = storage.sick or {}
  local tick = game.tick
  local ids = {}
  for un, c in pairs(colony.colonists) do if c.valid then ids[#ids + 1] = un end end
  table.sort(ids)

  -- Exposure. Everyone breathes the colony's air (commuters at an outpost breathe the outpost's); the occupants
  -- of a house that ate rotten food may get poisoned.
  local fell = {lung = 0, poison = 0}
  local pollution = colony.pollution or 0
  local home_of
  if next(rotten) then
    home_of = {}
    for house_un, members in pairs(colony_mod.households(colony)) do
      if rotten[house_un] then for _, un in ipairs(members) do home_of[un] = true end end
    end
  end
  for _, un in ipairs(ids) do
    if not storage.sick[un] then
      local kind
      if pollution > 0 and illness.catches("lung", pollution, illness.roll(un, tick, 1)) then kind = "lung"
      elseif home_of and home_of[un] and illness.catches("poison", 1, illness.roll(un, tick, 2)) then kind = "poison" end
      if kind then
        storage.sick[un] = {kind = kind, age = 0}
        fell[kind] = fell[kind] + 1
      end
    end
  end
  for _, kind in ipairs({"lung", "poison"}) do
    if fell[kind] > 0 then colony.hall.force.print({"colony-message.fell-ill", fell[kind], {"colony-illness." .. kind}}) end
  end

  -- Treatment: the doctors on duty cure the longest-sick first, one medicine each.
  local sick = {}
  for _, un in ipairs(ids) do
    local rec = storage.sick[un]
    if rec and rec.age > 0 then sick[#sick + 1] = un end   -- caught this evaluation: not yet a patient
  end
  table.sort(sick, function(a, b)
    local ra, rb = storage.sick[a], storage.sick[b]
    if ra.age ~= rb.age then return ra.age > rb.age end
    return a < b
  end)
  local cured = illness.treat(#sick, doctors(colony), medicine(colony))
  for i = 1, cured do storage.sick[sick[i]] = nil end
  if cured > 0 then
    use_medicine(colony, cured)
    colony.hall.force.print({"colony-message.cured", cured})
  end

  -- Untreated illness runs its course.
  local lung, poison = 0, 0
  for _, un in ipairs(ids) do
    local rec = storage.sick[un]
    if rec then
      local outcome = illness.step(rec)
      if outcome == "dies" then kill(colony, un, rec.kind)
      elseif outcome == "recovers" then storage.sick[un] = nil
      elseif rec.kind == "lung" then lung = lung + 1 else poison = poison + 1 end
    end
  end
  colony.sick_lung, colony.sick_poison, colony.sick_count = lung, poison, lung + poison
end

return M
