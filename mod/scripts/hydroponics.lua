-- Adapter: Orbital Hydroponics Bays (#69). A worker-free chest is discovered from each colony's lazy registry
-- (no schema) and processed on a slow scheduler chain, never per tick. All the numbers are in the pure model;
-- this file only moves items in and out of real inventories. A bay with nothing to crush costs one lookup.
local events = require("scripts.events")
local scheduler = require("scripts.scheduler")
local hydro = require("scripts.model.hydroponics")
local M = {}

M.TICKS = hydro.TICKS

---@param colony table
---@return table[] live bays in a stable order
function M.list(colony)
  local ids = {}
  for un, b in pairs(colony.hydroponics or {}) do
    if b.entity.valid then ids[#ids + 1] = un else colony.hydroponics[un] = nil end
  end
  table.sort(ids)
  local out = {}
  for _, un in ipairs(ids) do out[#out + 1] = colony.hydroponics[un] end
  return out
end

---@param colony table
---@return integer number of bays that completed a cycle
function M.run_colony(colony)
  local done = 0
  for _, b in ipairs(M.list(colony)) do
    local e = b.entity
    local inv = e.get_inventory(defines.inventory.chest)
    if inv then
      local stock = {}
      for _, s in ipairs(inv.get_contents()) do stock[s.name] = (stock[s.name] or 0) + s.count end
      local r = hydro.cycle(stock, stock.spoilage or 0)
      if r and e.can_insert{name = "colony-produce", count = r.produce} then
        if e.remove_item{name = r.chunk, count = 1} > 0 then
          if r.recycle > 0 then e.remove_item{name = "spoilage", count = r.recycle} end
          if r.water > 0 then e.insert{name = "colony-water", count = r.water} end
          e.insert{name = "colony-produce", count = r.produce}
          colony.ledger_cache, colony.stock_cache, colony.storage_cache = nil, nil, nil
          done = done + 1
        end
      end
    end
  end
  return done
end

scheduler.register("hydro.tick", function()
  for _, colony in pairs(storage.colonies or {}) do M.run_colony(colony) end
  scheduler.after(M.TICKS, "hydro.tick")
end)

local function armed()
  for _, bucket in pairs(storage.scheduled or {}) do
    for _, job in ipairs(bucket) do if job.handler == "hydro.tick" then return true end end
  end
  return false
end

local function arm_once()
  if not storage then return end
  storage.scheduled = storage.scheduled or {}
  if not armed() then scheduler.after(M.TICKS, "hydro.tick") end
end

events.on_init(arm_once)
events.on_configuration_changed(arm_once)

return M
