-- Refrigerated storage (#45) and cryo-preservation warehouses (#69). Both freeze the spoil countdown of their
-- contents while it is inside: the engine forbids growing `spoil_tick` past the item's base (the naive pause
-- is impossible), but `spoil_percent` is read/write and a downward write revives a near-spoiled stack, so
-- every pass stamps the whole inventory back to 0. Items never spoil while they stay inside; the countdown
-- resumes only when they leave. Verified end to end by the `s15_spoil` probe.
--
-- A Refrigerated Warehouse/Wagon is stamped every 600 ticks (one pass a minute). The Aquilo Cryo-Preservation
-- Warehouse (#69) is the 0% spoilage tier and is stamped every 60 ticks, so a stack can never accumulate a
-- visible fraction of its countdown. Both are finds over at most a handful of entities, so nothing here is
-- per-tick. Entities are rediscovered from the world (no registry, no migration), which makes the pass robust
-- to blueprint placement, paste copies and unit number churn.
local events = require("scripts.events")
local scheduler = require("scripts.scheduler")

local M = {}

M.PAUSE_TICKS = 600          -- one pass a minute: anything perishable stops spoiling promptly
M.CRYO_PAUSE_TICKS = 60      -- #69: the cryo tier's countdown never gets anywhere

local CHILLED = {"colony-refrigerated-warehouse", "colony-refrigerated-wagon"}
local CRYO = {"colony-cryo-warehouse"}

local function discover(names)
  local list = {}
  for _, s in pairs(game.surfaces) do
    if s.valid then
      for _, e in ipairs(s.find_entities_filtered{name = names}) do
        if e.valid then list[#list + 1] = e end
      end
    end
  end
  -- Deterministic order so two runs behave the same.
  table.sort(list, function(a, b) return a.unit_number < b.unit_number end)
  return list
end

---@param inv LuaInventory|nil
---@return integer # stacks restamped
local function freeze_inventory(inv)
  if not inv then return 0 end
  local n = 0
  for i = 1, #inv do
    local st = inv[i]
    if st.valid_for_read and st.spoil_tick > 0 then
      st.spoil_percent = 0
      n = n + 1
    end
  end
  return n
end

local function freeze(names)
  local n = 0
  for _, e in ipairs(discover(names)) do
    if e.valid then
      local inv = e.get_inventory(defines.inventory.chest) or e.get_inventory(defines.inventory.cargo_wagon)
      n = n + freeze_inventory(inv)
    end
  end
  return n
end

---@return integer # stacks restamped in this pass
function M.pause_all() return freeze(CHILLED) end

---@return integer # stacks restamped in this pass
function M.pause_cryo() return freeze(CRYO) end

scheduler.register("cold.tick", function()
  M.pause_all()
  scheduler.after(M.PAUSE_TICKS, "cold.tick")
end)
scheduler.register("cold.cryo.tick", function()
  M.pause_cryo()
  scheduler.after(M.CRYO_PAUSE_TICKS, "cold.cryo.tick")
end)

local function is_scheduled(handler)
  for _, bucket in pairs(storage.scheduled or {}) do
    for _, job in ipairs(bucket) do
      if job.handler == handler then return true end
    end
  end
  return false
end

local function arm(handler, ticks)
  if is_scheduled(handler) then return end
  scheduler.after(ticks, handler)
end

-- Arm each chain exactly once per world. Fresh worlds get it from on_init; existing saves pick it up via the
-- [37] migration (which marks `cold_armed`). The chains then self-perpetuate from storage like every other
-- colony timer, and a config change re-arm is a no-op once the handler is actually scheduled. Checking each
-- handler separately is what lets a save from before #69 gain the cryo chain without resetting the old one.
local function arm_once()
  if not storage then return end
  storage.scheduled = storage.scheduled or {}
  if storage.cold_armed and is_scheduled("cold.tick") and is_scheduled("cold.cryo.tick") then return end
  storage.cold_armed = true
  arm("cold.tick", M.PAUSE_TICKS)
  arm("cold.cryo.tick", M.CRYO_PAUSE_TICKS)
end

events.on_init(arm_once)
events.on_configuration_changed(arm_once)

return M
