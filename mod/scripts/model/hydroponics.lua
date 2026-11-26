---@diagnostic enable: undefined-field, missing-fields
-- PURE: Orbital Hydroponics (#69, design §9.3). A worker-free bay crushes asteroid chunks into water and
-- nutrients, grows fresh food in the closed loop, and recycles spoilage back into biomass. All numbers and
-- decisions live here; the adapter only reads/writes live inventories and registries.
local M = {}

M.BAY = "colony-hydroponics-bay"
M.TICKS = 600             -- one harvest cycle per 10 s
M.FOOD_PER_CYCLE = 4      -- colony-produce grown from one crushed chunk's nutrients
M.SPOILAGE_TO_NUTRIENT = 2 -- spoilage units recycled into one nutrient unit
M.MAX_STOCK = 40         -- the bay stops growing once its chest holds this much produce

-- Asteroid chunk -> what the bay gets from it. Deterministic order, never pairs(), and a fixed fallback so
-- an unknown chunk produces nothing (the platform loop must never invent resources).
M.CHUNKS = {
  {name = "metallic-asteroid-chunk", water = 20, nutrient = 0},
  {name = "carbonic-asteroid-chunk", water = 0, nutrient = 20},
  {name = "oxide-asteroid-chunk", water = 10, nutrient = 10},
}

---@param name string|nil
---@return table|nil {water=, nutrient=}
function M.crush(name)
  for _, c in ipairs(M.CHUNKS) do if c.name == name then return c end end
  return nil
end

-- What one cycle needs and makes, given the bay's stock. `stock` is an item->count map, `recycling` is the
-- number of spoilage units available to convert. Returns nil when there is nothing to do (no chunk, or full).
---@param stock ItemCount|nil
---@param recycling number|nil
---@return table|nil {chunk=, water=, nutrient=, produce=, recycle=}
function M.cycle(stock, recycling)
  if (stock and (stock["colony-produce"] or 0) >= M.MAX_STOCK) then return nil end
  for _, c in ipairs(M.CHUNKS) do
    if (stock and (stock[c.name] or 0) > 0) or (c.name == "carbonic-asteroid-chunk" and (recycling or 0) > 0) then
      local n = c.name == "carbonic-asteroid-chunk" and (recycling or 0) or 1
      local recycle = c.name == "carbonic-asteroid-chunk" and math.min(n, M.SPOILAGE_TO_NUTRIENT) or 0
      return {chunk = c.name, water = c.water, nutrient = c.nutrient,
        produce = M.FOOD_PER_CYCLE, recycle = recycle}
    end
  end
  return nil
end

return M
