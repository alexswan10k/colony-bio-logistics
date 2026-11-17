---@diagnostic enable: undefined-field, missing-fields
-- PURE: curing rules (#81, #70). A Smokehouse turns raw meat, fish or (since #70) Gleba fruit plus salt into
-- a preserved variant.
--
-- Nutrition per item is unchanged and the payoff is *shelf life* (~3x), which is what #81 asked for: the
-- preserved tier exists so a colony can stockpile food instead of eating what it brought home this minute.
-- Keeping every food option at `per = 1` also keeps housing's demand sizing honest (it sizes a need from the
-- first option's `per`, so mixing values inside one list would silently over- or under-request food).
local yields = require("scripts.model.yields")
local gleba = require("scripts.model.gleba")

local M = {}

M.SALT = "colony-salt"
M.SALT_PER_BATCH = yields.CURE.salt
M.RAW_PER_BATCH = yields.CURE.raw
M.PRODUCT_PER_BATCH = yields.CURE.out
M.SALT_STOCK = 4            -- what a Smokehouse wants on hand
M.RAW_STOCK = 2             -- per raw item, so a smokehouse never strips the houses' dinner
M.RAW = {"colony-meat", "colony-fish"}
M.PRODUCT = {["colony-meat"] = "colony-preserved-meat", ["colony-fish"] = "colony-preserved-fish"}

-- What can be cured from this stock? {raw=, product=, count?} or nil. Meat and fish are tried first, so the
-- choice is stable when a hut holds several inputs at once; Gleba fruit is the fallback (model/gleba.lua, #70).
-- Gleba recipes carry an explicit `count` (2 fruit / 1 pulp); meat and fish leave it nil so work.lua still
-- uses preserve.RAW_PER_BATCH for them.
-- `freshness` (item -> spoil_percent) and `gleba_unlocked` (the researched-tech flag) apply ONLY to the Gleba
-- fallback: meat/fish curing predates #70 and must be unchanged by them. `gleba_unlocked == false` closes the
-- Smokehouse's Gleba work entirely, which is what makes the colony tech gate real rather than cosmetic.
function M.recipe(stock, freshness, gleba_unlocked)
  if (stock[M.SALT] or 0) < M.SALT_PER_BATCH then return nil end
  for _, raw in ipairs(M.RAW) do
    if (stock[raw] or 0) >= M.RAW_PER_BATCH then return {raw = raw, product = M.PRODUCT[raw]} end
  end
  if gleba_unlocked == false then return nil end
  return gleba.recipe(stock, freshness)
end

-- What a Smokehouse wants delivered: salt, plus a little of each raw item. `counts`/`inflight` are item -> n.
function M.wants(counts, inflight)
  local out = {}
  local function add(item, want)
    local n = want - (counts[item] or 0) - ((inflight and inflight[item]) or 0)
    if n > 0 then out[#out + 1] = {item = item, count = n} end
  end
  add(M.SALT, M.SALT_STOCK)
  for _, raw in ipairs(M.RAW) do add(raw, M.RAW_STOCK) end
  return out
end

return M
