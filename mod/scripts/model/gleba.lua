---@diagnostic enable: undefined-field, missing-fields
-- PURE: Gleba fruit preserving (#70). A Smokehouse salts perishable Gleba fruit into a 45-minute jam.
--
-- Raw fruit is deliberately NOT in housing.FOOD (or colony.M.FOOD_ITEMS, which derives from it): the only
-- route from a Gleba harvest to a colonist's dinner is this lossy, salt-costing, worker-staffed conversion.
-- s17_gleba pinned the engine facts: a craft inherits ~100% of a spoiled ingredient's spoil_percent, so a
-- spoiled input can never be laundered into a fresh output (no `always_fresh` on our product).
local M = {}

M.PRODUCT = "colony-gleba-jam"
M.SALT = "colony-salt"
M.SALT_PER_BATCH = 1

-- Ordered and deterministic: salt first, then these raws in the declared order. The counts mirror the
-- recipes in prototypes/buildings.lua (2 fruit, or 1 short-lived pulp, + 1 salt -> 1 jam). Bioflux is
-- deliberately deferred (Q1 on #70): it is a high-value industrial intermediate, not a food feedstock.
M.RAW = {
  {item = "yumako", count = 2},
  {item = "jellynut", count = 2},
  {item = "yumako-mash", count = 1},
  {item = "jelly", count = 1},
}

-- Documentation only. The real shelf life is the prototype's spoil_ticks (45 * 60 * 60 ticks at 60 UPS),
-- asserted by s17_gleba; do not use this constant to drive engine timers.
M.SHELF_TICKS = 45 * 60 * 60

-- What can be cured from this stock? {raw=, product=, count=} or nil. Returning a `count` is what lets the
-- generic Smokehouse branch in work.lua remove 2 fruit for fruit recipes and 1 for pulp recipes.
function M.recipe(stock)
  if (stock[M.SALT] or 0) < M.SALT_PER_BATCH then return nil end
  for _, r in ipairs(M.RAW) do
    if (stock[r.item] or 0) >= r.count then
      return {raw = r.item, product = M.PRODUCT, count = r.count}
    end
  end
  return nil
end

-- Kept as the contract for a future standing request. The adapter deliberately does NOT call this yet:
-- a Smokehouse is a plain container, so a player belts/inserters fruit into it (opt-in pillar), and preserve.wants
-- already asks for the salt. A standing "2 of every perishable on each Smokehouse" would be a permanent
-- import faucet from Gleba and would spoil in transit.
function M.wants(counts, inflight)
  local out = {}
  local want = M.SALT_PER_BATCH * 4   -- same buffer a Smokehouse keeps for curing meat/fish
  local n = want - (counts[M.SALT] or 0) - ((inflight and inflight[M.SALT]) or 0)
  if n > 0 then out[#out + 1] = {item = M.SALT, count = n} end
  return out
end

return M
