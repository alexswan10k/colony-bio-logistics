-- Adapter: EVA tile-repair tasks (#69). A platform colony with an EVA Airlock, a jetpack in stock and repair
-- packs sends one idle colonist per evaluation to the most damaged foundation tile within airlock range.
-- No per-tick scan: dispatch rides the colony evaluation, the work spell is a scheduler timer, and the engine
-- owns the actual repair through `LuaSpacePlatform::repair_tile`. All rules live in model/eva_repair.lua.
local scheduler = require("scripts.scheduler")
local work = require("scripts.work")
local gear = require("scripts.model.gear")
local eva = require("scripts.model.eva")
local repair = require("scripts.model.eva_repair")
local planet = require("scripts.planet")
local M = {}

local colony_mod   -- injected by scripts.colony via M.bind
function M.bind(c) colony_mod = c end

local function take_pack(colony, hall)
  if hall.valid and hall.remove_item{name = repair.PACK, count = 1} > 0 then return true end
  for _, cr in ipairs(colony_mod.storage_crates(colony)) do
    local e = cr.entity
    if e and e.valid and e.remove_item{name = repair.PACK, count = 1} > 0 then return true end
  end
  return false
end

---@param colony table
---@return boolean whether a crew member was dispatched
local function dispatch(colony)
  local hall = colony and colony.hall
  if not (hall and hall.valid) then return false end
  local surface = hall.surface
  if not (planet.is_platform(surface) and surface.platform) then return false end
  local airlocks = colony_mod.airlock_list(colony)
  if #airlocks == 0 then return false end
  local stock = colony_mod.stock_table(colony)
  if not gear.present(stock, eva.JETPACK) then return false end
  if (colony_mod.stock_count(colony, repair.PACK) or 0) <= 0 then return false end
  local task = repair.task(surface.platform.damaged_tiles, airlocks[1].entity.position, 1)
  if not task then return false end

  local ids = {}
  for un, e in pairs(colony.colonists) do
    local st = storage.unit_state and storage.unit_state[un]
    if e.valid and st and st.state == "idle" and not (colony.locks and colony.locks[un]) then
      ids[#ids + 1] = un
    end
  end
  table.sort(ids)
  local un = ids[1]
  if not un then return false end
  if not take_pack(colony, hall) then return false end

  local e, st = colony.colonists[un], storage.unit_state[un]
  st.state, st.eva_repair = "eva-repair", {position = task.position, damage = task.damage, amount = repair.PACK_POINTS}
  work.go(e, task.position, 0.8)
  work.set_label(e, "EVA repair 🛠", true)
  colony.stock_cache, colony.storage_cache, colony.ledger_cache = nil, nil, nil
  scheduler.after(repair.WORK_TICKS, "eva_repair.finish", {un = un, colony_id = colony.id})
  return true
end
M.dispatch = dispatch

scheduler.register("eva_repair.finish", function(d)
  local st = storage.unit_state and storage.unit_state[d.un]
  if not (st and st.state == "eva-repair" and st.eva_repair) then return end
  local colony = storage.colonies[d.colony_id]
  if not colony then return end
  local hall = colony.hall
  local surface = hall and hall.valid and hall.surface
  local platform = surface and surface.platform
  if platform then
    local amount = repair.applied(st.eva_repair.damage, st.eva_repair.amount)
    pcall(function() platform.repair_tile(st.eva_repair.position, amount) end)
  end
  st.eva_repair = nil
  work.clear_label(d.un)
  work.assign(colony, d.un)
end)

return M
