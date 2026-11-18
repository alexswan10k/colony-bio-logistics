-- Adapter: Inspired scholars speed colony research (#48 slice A).
-- Research is engine-driven (work.lua only staffs the lab), so the lever is the force-wide
-- `force.laboratory_speed_modifier` (Factorio 2.1 runtime docs, LuaForce). That is a FORCE modifier:
-- vanilla labs on the same force also speed up. Research itself is force-wide in Factorio, so this is the
-- only coherent scope without physical speed modules, and the owner accepted the side effect.
--
-- All numbers come from the pure `model/inspiration.lua`. This file only reads/writes engine state. The
-- per-force bookkeeping is DURABLE in `storage.research_speed` (schema 44): the engine saves the modifier
-- itself, but we must also save the bonus we baked into it, or a cold load in which inspiration has changed
-- would subtract the wrong number (or never clear a stale bonus). No per-tick scan, one pass per evaluation.

local events = require("scripts.events")
local inspiration = require("scripts.model.inspiration")
local M = {}

local EPS = 1e-9

-- Highest bonus among the colonies whose hall belongs to `force`. Colonies combine by MAX, never by sum.
local function target_for(force)
  local target = 0
  for _, c in pairs(storage and storage.colonies or {}) do
    local hall = c.hall
    if hall and hall.valid and hall.force and hall.force.name == force.name then
      local insp = c.inspiration
      local bonus = inspiration.research_bonus(insp and insp.share or 0, insp and insp.quality or 0)
      if bonus > target then target = bonus end
    end
  end
  return target
end

local function record_for(force)
  storage.research_speed = storage.research_speed or {}
  local e = storage.research_speed[force.name]
  if not e then
    -- First write for this force (fresh map, or a save made before this feature): we have never touched the
    -- modifier, so every bit of the live value belongs to another mod / a technology. Keep it as the base.
    e = {base = force.laboratory_speed_modifier or 0, applied = 0}
    storage.research_speed[force.name] = e
  end
  return e
end

-- Write `record.base + target`. `base` is the foreign modifier with our bonus removed, so it is stable
-- across evaluations, across cold loads, and across changes in the target:
--   * cold load with a saved record -> base comes from storage, never from the live value;
--   * foreign write between evals   -> the live value no longer equals base + applied, so fold the delta
--                                     into base (never absorb our own bonus into it);
--   * on_technology_effects_reset   -> the engine discarded script modifiers, so the post-reset live value
--                                     is the new foreign base (handled by the event handler below).
local function write(force, target, after_reset)
  local live = force.laboratory_speed_modifier or 0
  -- A town that never had inspiration and whose modifier is untouched needs no record at all. Skipping it
  -- keeps Tavern-less towns byte-identical (the determinism checksum does not move for this slice).
  if target == 0 and live == 0 and not (storage.research_speed and storage.research_speed[force.name]) then
    return 0
  end
  local e = record_for(force)
  if after_reset then
    e.base = live
  elseif math.abs(live - (e.base + e.applied)) > EPS then
    e.base = live - e.applied
  end
  local value = math.max(-1, e.base + target)
  if value ~= live then force.laboratory_speed_modifier = value end
  e.applied = target
  return target
end

-- Called once at the end of each colony evaluation (idempotent across colonies on one force).
function M.apply(force)
  if not (force and force.valid) then return 0 end
  return write(force, target_for(force), false)
end

-- When a colony's last hall dies, evaluate() returns early before the per-colony apply call. Sweep every
-- force we have a saved record for with target 0 (target_for skips invalid halls), so no force keeps a
-- bonus that no colony can justify any more. Bounded by the number of forces we have touched, not by ticks.
function M.apply_all()
  storage.research_speed = storage.research_speed or {}
  for name in pairs(storage.research_speed) do
    local force = game.forces and game.forces[name]
    if force and force.valid then M.apply(force) end
  end
end

-- LuaForce::reset_technology_effects discards script-written modifiers and raises this event with `force`.
-- Re-apply immediately so a save in that window cannot lose the bonus and the player sees it restored
-- without waiting for the next colony evaluation.
events.on(defines.events.on_technology_effects_reset, function(ev)
  local force = ev and ev.force
  if force and force.valid then write(force, target_for(force), true) end
end)

return M
