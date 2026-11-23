---@diagnostic enable: undefined-field, missing-fields
-- PURE: Gleba fruit preserving (#70). A Smokehouse salts perishable Gleba fruit into a 45-minute jam.
--
-- Raw fruit is deliberately NOT in housing.FOOD (or colony.M.FOOD_ITEMS, which derives from it): the only
-- route from a Gleba harvest to a colonist's dinner is this lossy, salt-costing, worker-staffed conversion.
-- Two separate guards stop a near-spoiled fruit becoming fresh food:
--   * engine-crafted jam inherits its ingredients' spoil_percent (s17_gleba: 0.999 in -> 0.999 out), so no
--     product sets `always_fresh`; and
--   * the colony's Lua Smokehouse path (which never runs the engine recipe) REFUSES an input whose stack is
--     more than MAX_INPUT_SPOIL spoiled. The adapter supplies `freshness` from the real item stacks; this
--     module only applies the rule, so it stays free of Factorio globals.
local yields = require("scripts.model.yields")

local M = {}

M.PRODUCT = "colony-gleba-jam"
M.SALT = "colony-salt"
M.SALT_PER_BATCH = yields.CURE.salt        -- single source of truth with the meat/fish curing cost
M.TECH = "colony-gleba-cuisine"            -- the colony conversion is gated on this being researched
M.MAX_INPUT_SPOIL = 0.5                    -- refuse fruit at/above this spoil_percent; it will rot to spoilage

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

-- Spore exposure and Swamp Fever (#70). A scripted harvest on a spore surface emits SPORE_PER_HARVEST "spores"
-- into local pollution via surface.pollute(pos, count), and a Smokehouse preserving raw Gleba fruit emits the
-- same burst at the point the fruit enters the colony's food chain -- the adapter owns both surface checks.
-- A colonist on duty there catches swamp fever at illness.SWAMP_RATE * exposure per evaluation.
M.SPORE_PER_HARVEST = 15   -- wiki: one yumako harvest yields 15 spores (mirrors vanilla)
M.SPORE_SCALE = 300        -- local pollution that raises exposure by 1; the formula actually saturates at 150

-- Risk multiplier in [0.5, 1]. The 0.5 baseline is an intentional, constant risk even in perfectly clean air:
-- Gleba is a spore world, so merely working there carries half the fever chance; pollution only scales it up.
-- Plain floats, no rounding; nil/negative pollution is treated as none.
function M.exposure(local_pollution)
  return math.min(1, 0.5 + math.max(0, local_pollution or 0) / M.SPORE_SCALE)
end

-- Only real harvests kick up spores; hauling, building and processing do not. The Smokehouse burst is keyed on
-- the raw item instead (M.is_raw), because the colonist's job there is "preserve", not a harvest job.
function M.emits_spores(job) return job == "chop" or job == "forage" end

-- True for any raw Gleba fruit/pulp the Smokehouse can cure (the same list as M.RAW, single source of truth).
function M.is_raw(item)
  if item == nil then return false end
  for _, r in ipairs(M.RAW) do if r.item == item then return true end end
  return false
end

-- What can be cured from this stock? {raw=, product=, count=} or nil. Returning a `count` is what lets the
-- generic Smokehouse branch in work.lua remove 2 fruit for fruit recipes and 1 for pulp recipes.
-- `freshness` is an optional item -> spoil_percent map from the real stacks (nil/absent means fresh); a raw
-- whose worst stack is over MAX_INPUT_SPOIL is skipped in favour of the next usable one.
function M.recipe(stock, freshness)
  if (stock[M.SALT] or 0) < M.SALT_PER_BATCH then return nil end
  for _, r in ipairs(M.RAW) do
    if (stock[r.item] or 0) >= r.count then
      local spoiled = (freshness and freshness[r.item]) or 0
      if spoiled < M.MAX_INPUT_SPOIL then
        return {raw = r.item, product = M.PRODUCT, count = r.count}
      end
    end
  end
  return nil
end

return M
