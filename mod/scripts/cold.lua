-- Refrigerated storage (#45). A cargo wagon or refrigerated warehouse freezes the spoil countdown of its
-- contents while it is inside: the engine forbids growing `spoil_tick` past the item's base (the naive pause
-- is impossible), but `spoil_percent` is read/write and a downward write revives a near-spoiled stack, so
-- every pass stamps the whole inventory back to 0. Items never spoil while they stay inside; the countdown
-- resumes only when they leave. Verified end to end by the `s15_spoil` probe.
--
-- Cost is a find over at most a handful of entities every minute, so nothing here is per-tick. Entities are
-- rediscovered from the world (cached for CACHE_TICKS), which makes the pass robust to blueprint placement,
-- paste copies and unit number churn - no registry, no migration.
local events = require("scripts.events")
local scheduler = require("scripts.scheduler")

local M = {}

M.PAUSE_TICKS = 600          -- one pass a minute: anything perishable stops spoiling promptly

local function discover()
  local list = {}
  for _, s in pairs(game.surfaces) do
    if s.valid then
      for _, e in ipairs(s.find_entities_filtered{name = {"colony-refrigerated-warehouse", "colony-refrigerated-wagon"}}) do
        if e.valid then list[#list + 1] = e end
      end
    end
  end
  -- Deterministic order so two runs behave the same.
  table.sort(list, function(a, b) return a.unit_number < b.unit_number end)
  return list
end

local function targets() return discover() end

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

---@return integer # stacks restamped in this pass
function M.pause_all()
  local n = 0
  for _, e in ipairs(targets()) do
    if e.valid then
      local inv = e.get_inventory(defines.inventory.chest) or e.get_inventory(defines.inventory.cargo_wagon)
      n = n + freeze_inventory(inv)
    end
  end
  return n
end

scheduler.register("cold.tick", function()
  M.pause_all()
  scheduler.after(M.PAUSE_TICKS, "cold.tick")
end)

local function is_scheduled()
  for _, bucket in pairs(storage.scheduled or {}) do
    for _, job in ipairs(bucket) do
      if job.handler == "cold.tick" then return true end
    end
  end
  return false
end

-- Arm the chain exactly once per world. Fresh worlds get it from on_init; existing saves pick it up via the
-- [37] migration (which sets the same marker). The chain then self-perpetuates from storage like every
-- other colony timer, and a config change re-arm is a no-op once cold.tick is actually scheduled.
local function arm_once()
  if not storage then return end
  storage.scheduled = storage.scheduled or {}
  if storage.cold_armed and is_scheduled() then return end
  storage.cold_armed = true
  scheduler.after(M.PAUSE_TICKS, "cold.tick")
end

events.on_init(arm_once)
events.on_configuration_changed(arm_once)

return M
