---@diagnostic enable: undefined-field, missing-fields
-- PURE: Space Training Center (#69, design §9.2). A worker-free depot that packs one colonist into a fresh
-- Cryo-Colonist Pod for launch. The launch consumes a volunteer and the centre's rations; the colony must keep
-- a minimum population so a small town cannot launch itself out of existence. All rules are plain numbers;
-- the adapter owns the live roster and inventories.
local M = {}

M.CENTER = "colony-space-training-center"
M.POD = "colony-cryo-pod"
M.MIN_POP = 4                 -- never launch below this many residents (the bootstrap settler count)
M.RATIONS = {["colony-canned-meat"] = 2, ["colony-water"] = 2}
M.LAUNCH_TICKS = 6000         -- one launch at most per ten minutes, per colony

---@param pop integer|nil
---@param tick number|nil
---@param ready_at number|nil
---@return boolean
function M.pop_ok(pop, tick, ready_at)
  return (pop or 0) > M.MIN_POP and (ready_at == nil or tick == nil or tick >= ready_at)
end

-- Missing rations for one launch, as {item -> n}. Empty when it can be packed.
---@param stock ItemCount|nil
---@return ItemCount
function M.missing(stock)
  local out = {}
  for item, n in pairs(M.RATIONS) do
    local have = (stock and stock[item] or 0)
    if have < n then out[item] = n - have end
  end
  return out
end

---@param pop integer|nil
---@param tick number|nil
---@param ready_at number|nil
---@param stock ItemCount|nil
---@return boolean
function M.can_launch(pop, tick, ready_at, stock)
  return M.pop_ok(pop, tick, ready_at) and next(M.missing(stock)) == nil
end

return M
