---@diagnostic enable: undefined-field, missing-fields
-- PURE: which harvest roles the colony is short of (#84, #91).
-- Two questions, no engine: "is any resource missing, and is that an empty store or just a top-up?" and
-- "given the player's material ranks, which of those roles should a free colonist take first?".
-- `work.lua` supplies the colony stock and quota accessors and passes the answers to `work_plan.choose`.
local M = {}
local material_priority = require("scripts.model.material_priority")

-- Each harvest job's products, so a colony-wide material rank can be resolved to the role that makes it.
M.JOB_ITEMS = {
  forage = {"colony-forage"}, farm = {"colony-produce"}, chop = {"wood"},
  mine = {"iron-ore", "copper-ore", "coal", "stone"}, hunt = {"colony-meat"}, fish = {"colony-fish"},
}

-- The roles that feed the colony, in the order a hungry town tries them.
M.FOOD_ORDER = {"forage", "farm", "hunt", "fish"}
M.FOOD_ITEMS = {
  {job = "forage", item = "colony-forage"},
  {job = "farm", item = "colony-produce"},
  {job = "hunt", item = "colony-meat"},
  {job = "fish", item = "colony-fish"},
}

-- Roles whose stock alone says "empty": a hut with a full chest does not need a colonist walking to it.
M.EMPTY_JOBS = {"chop", "mine"}

-- The colony's missing harvest roles as a set {job -> true}: `empty` when a resource is at zero (or the town
-- has no food at all), otherwise the below-target top-ups.
-- `api` is the colony adapter: quota_met(colony, item), stock_count(colony, item), quota_target(colony, item),
-- food_in(colony).
function M.missing(colony, api)
  local empty, below_target = {}, {}
  -- Wood and ore: an empty store is an empty resource, a store under its target is only a top-up.
  for _, job in ipairs(M.EMPTY_JOBS) do
    for _, item in ipairs(M.JOB_ITEMS[job]) do
      if not api.quota_met(colony, item) then
        local count = api.stock_count(colony, item)
        local target = api.quota_target(colony, item)
        if count == 0 then empty[job] = true end
        if target > 0 and count < target then below_target[job] = true end
      end
    end
  end
  -- Food is different: a single food item running out is not an empty resource (another kind feeds them), so it
  -- is only a top-up. The whole larder being empty promotes every food role at once, below.
  for _, food in ipairs(M.FOOD_ITEMS) do
    if not api.quota_met(colony, food.item) then
      local count = api.stock_count(colony, food.item)
      local target = api.quota_target(colony, food.item)
      if target > 0 and count < target then below_target[food.job] = true end
    end
  end
  if api.food_in(colony) == 0 then
    for _, food in ipairs(M.FOOD_ITEMS) do
      if not api.quota_met(colony, food.item) then empty[food.job] = true end
    end
  end
  if next(empty) then
    -- Empty stock comes first, but hungry towns still feed themselves.
    for _, job in ipairs(M.FOOD_ORDER) do
      if below_target[job] then empty[job] = true end
    end
    return empty
  end
  return below_target
end

local order_index = setmetatable({}, {__mode = "k"})

-- Harvest order ({work_plan.HARVEST}) -> {job -> position}, cached per order table so the ranked list below
-- allocates nothing for a table it has already seen.
local function index_of(order)
  local idx = order_index[order]
  if idx then return idx end
  idx = {}
  for i, job in ipairs(order) do idx[job] = i end
  order_index[order] = idx
  return idx
end

-- The ranked missing-jobs list (#91): the missing set above decorated with each job's best material rank and the
-- demand standing behind that material, best first (rank 1 = most wanted, then bigger demand, then harvest
-- order). Deterministic: the sort key is unique per job.
function M.ranked(set, order, ratings, demand)
  local order_pos = index_of(order)
  local rows = {}
  for _, job in ipairs(order) do
    if set[job] then
      local rank, want = material_priority.best(M.JOB_ITEMS[job] or {}, ratings, demand)
      rows[#rows + 1] = {job = job, rank = rank, demand = want}
    end
  end
  table.sort(rows, function(a, b)
    if a.rank ~= b.rank then return a.rank < b.rank end
    if a.demand ~= b.demand then return a.demand > b.demand end
    return (order_pos[a.job] or 0) < (order_pos[b.job] or 0)
  end)
  return rows
end

return M
