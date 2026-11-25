-- Adapter: the exoskeleton harness (#69). While a colony holds one in stock, its colonists walk at
-- `gear.EXO_HAUL_MULT` speed. Units cannot wear real equipment (s19_defence), so this is a durable per-unit
-- overlay on LuaEntity.speed, exactly like research_speed's force modifier: a plain {base, applied} record in
-- `storage.gear_speed` (nil-safe, no schema) survives save/load and lets a cold load clear a stale buff.
--
-- Composition with the wooden trailer (#94) matters: a trailer stores its own pre-penalty speed in the unit's
-- state and restores it at the end of the trip. We therefore keep `st.trailer_speed` in step with the overlay,
-- so a harness issued mid-trip is not lost when the trailer is returned. The pure multiplier is gear.haul_speed;
-- this file only reads and writes engine state, once per colony evaluation.
local gear = require("scripts.model.gear")
local trailer = require("scripts.model.trailer")
local M = {}

local colony_mod   -- injected by scripts.colony via M.bind
function M.bind(c) colony_mod = c end

local EPS = 1e-6

local function live_speed(e)
  local ok, v = pcall(function() return e.speed end)
  if ok and type(v) == "number" and v > 0 then return v end
  return nil
end

local function write_speed(e, v)
  pcall(function() e.speed = v end)
end

-- One pass over the colony's colonists. Returns how many live speeds changed (useful to a spike).
---@param colony table
---@return integer
function M.apply(colony)
  if not (colony and colony.hall and colony.hall.valid) then return 0 end
  local exo = gear.present(colony_mod.stock_table(colony), gear.ITEM.exoskeleton)
  local mult = exo and gear.EXO_HAUL_MULT or 1
  storage.gear_speed = storage.gear_speed or {}
  local changed = 0

  for un, e in pairs(colony.colonists) do
    if e and e.valid and e.name == "colony-colonist" then
      local st = storage.unit_state and storage.unit_state[un]
      local factor = (st and st.trailer) and trailer.SPEED or 1
      local live = live_speed(e)
      local rec = storage.gear_speed[un]
      if not rec then
        -- Only create a record when we actually apply a buff, so a town that never sees a harness stays
        -- byte-identical (the determinism checksum moves only on the prototype hash).
        if mult ~= 1 and live then
          write_speed(e, gear.haul_speed(live, true))
          storage.gear_speed[un] = {base = live, applied = mult}
          changed = changed + 1
        end
      else
        -- A foreign writer (the trailer code, a mod, the engine) changed the live speed. Fold the difference
        -- into the untampered base rather than absorbing our own bonus into it.
        local expected = rec.base * rec.applied * factor
        if live and math.abs(live - expected) > EPS then rec.base = live / (rec.applied * factor) end
        local target = rec.base * mult * factor
        if (not live or math.abs(live - target) > EPS) and target > 0 then
          write_speed(e, target)
          changed = changed + 1
        end
        -- A checked-out trailer restores this value when the trip ends; keep it buffed too.
        if factor ~= 1 and st and st.trailer_speed then st.trailer_speed = rec.base * mult end
        rec.applied = mult
        if mult == 1 and math.abs(target - rec.base) <= EPS then storage.gear_speed[un] = nil end
      end
    else
      storage.gear_speed[un] = nil
    end
  end

  -- Deaths and militia conversions change unit numbers. Prune stale overlays lazily, once per evaluation,
  -- so a long-lived world cannot accumulate them (bounded by the number of townsfolk who ever wore a harness).
  for un in pairs(storage.gear_speed) do
    local alive = false
    for _, c in pairs(storage.colonies or {}) do
      if c.colonists and c.colonists[un] then alive = true; break end
    end
    if not alive then storage.gear_speed[un] = nil end
  end
  return changed
end

return M
