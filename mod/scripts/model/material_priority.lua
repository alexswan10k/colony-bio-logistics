-- PURE: colony-wide material priorities (#91).
-- A rank says what the colony cares about *right now*, on a fixed 1..5 scale that reads like the job
-- matrix: rank 1 = most wanted, 3 = neutral, 5 = least (so a bigger number is never better). A rank
-- expresses **order, not stop**: it decides which material is gathered or hauled first; quotas and caps
-- (which live elsewhere) decide how much gathers at all.
--
-- Every material starts at rank 3, so a town that has never ranked anything behaves exactly as it did
-- before #91, and the tie-break when ranks are equal is demand: the demand behind the material (#90), not
-- a guess about proximity.
--
-- A *disabled* material never wins a tie-break: it sorts after every enabled one (score 6), but is still
-- gathered and hauled (its quotas still rule its volume, so disabling is not a stop).

local M = {}

M.DEFAULT = 3                    -- the neutral rank everything starts at
M.MAX_RANK = 5                   -- rank 5 = least wanted; nothing above it
M.DISABLED = M.MAX_RANK + 1      -- how a disabled material sorts

-- Rankable materials: the harvested goods (a colony-wide order can point a miner or woodcutter at them)
-- plus the produced intermediates the ledger already lets you cap. Tools, ammunition and medicine are
-- available but not ranked: their needs are per-hut, and a colony-wide rank for them would never bite.
M.RANKABLE = {
  "wood", "iron-ore", "copper-ore", "coal", "stone",
  "colony-forage", "colony-produce", "colony-meat", "colony-fish",
  "iron-plate", "copper-plate", "steel-plate", "iron-gear-wheel", "stone-brick",
  "concrete", "plastic-bar", "solid-fuel", "electronic-circuit", "advanced-circuit",
}

local RANKABLE_INDEX = {}
for i, item in ipairs(M.RANKABLE) do RANKABLE_INDEX[item] = i end

local function clamp_rank(r)
  r = math.floor(tonumber(r) or M.DEFAULT)
  if r < 1 then return 1 end
  if r > M.MAX_RANK then return M.MAX_RANK end
  return r
end

function M.is_rankable(item) return RANKABLE_INDEX[item] ~= nil end
function M.index(item) return RANKABLE_INDEX[item] end

-- Effective rank of `item`: 1 (most wanted)..5 (least), or DEFAULT when the colony has never rated it,
-- including when no ratings table exists at all (so towns saved before #91 read straight through).
function M.rank(ratings, item)
  if not M.is_rankable(item) then return M.DEFAULT end
  local rec = ratings and ratings[item]
  if rec == nil then return M.DEFAULT end
  if type(rec) == "number" then return clamp_rank(rec) end
  return clamp_rank(rec.rank)
end

-- Is this material enabled? An explicitly disabled material sorts after every enabled one.
function M.enabled(ratings, item)
  local rec = ratings and ratings[item]
  if rec == nil then return true end
  if type(rec) == "number" then return true end
  return rec.enabled ~= false
end

-- The single ordering number: 1 (most wanted) .. 5 (least), or DISABLED (6) for a material the player
-- turned off, so it loses every tie-break. Anything unrated reads DEFAULT, so an untouched town is neutral.
function M.score(ratings, item)
  if not M.is_rankable(item) then return M.DEFAULT end
  if not M.enabled(ratings, item) then return M.DISABLED end
  return M.rank(ratings, item)
end

-- The rank a miner uses for a material: the player's material rank inverted into mine order (rank 1 is
-- most wanted here too, so a higher-urgency material is worked first). Disabled reads DISABLED (6), which
-- must still order after every enabled 1..5, so `eff_ore_groups` (work.lua) groups by it directly rather
-- than going through `mine_plan.by_rank`, whose names stop at M.MAX_RANK = 4.
function M.mine_rank(ratings, item)
  if not M.is_rankable(item) then return M.DEFAULT end
  local rec = ratings and ratings[item]
  if rec == nil then return M.DEFAULT end
  if type(rec) == "number" then return clamp_rank(rec) end
  if rec.enabled == false then return M.DISABLED end
  return clamp_rank(rec.rank)   -- 1 = most wanted, so lower = worked first
end

-- Best (rank, demand) over a sequence of items, for the tie-breaks in work_plan and haul_plan: the
-- lowest score 1..5 (6 = disabled), then the demand standing behind an item at that score, so
-- "rank 3 that the colony wants more of wins" is a rule rather than a guess. Accepts items as plain
-- names or {item = name} records so it works on `M.load` output too.
function M.best(items, ratings, demand)
  local best_r, best_d = nil, 0
  for _, it in ipairs(items or {}) do
    local item = it.item or it
    local r = M.score(ratings, item)
    local d = (demand and demand[item]) or 0
    if not best_r or r < best_r or (r == best_r and d > best_d) then
      best_r, best_d = r, d
    end
  end
  return best_r or M.DEFAULT, best_d
end

-- Move one material up (-1) or down (+1) the scale and clamp it to 1..5; disabled materials only move
-- their stored rank unless they are enabled again.
function M.shift(ratings, item, delta)
  ratings[item] = ratings[item] or {rank = M.DEFAULT, enabled = true}
  ratings[item].rank = clamp_rank(M.rank(ratings, item) + (tonumber(delta) or 0))
  return ratings[item].rank
end

function M.set_enabled(ratings, item, on)
  ratings[item] = ratings[item] or {rank = M.DEFAULT, enabled = true}
  ratings[item].enabled = (on == true)
  return ratings[item].enabled
end

-- Ranked order of materials for the Town Hall panel: most wanted first, then the bigger demand behind
-- it, then the RANKABLE order (so the panel is stable no matter what the table looks like).
function M.order(ratings, demand)
  local rows = {}
  for _, item in ipairs(M.RANKABLE) do
    rows[#rows + 1] = {item = item, rank = M.score(ratings, item), demand = (demand and demand[item]) or 0}
  end
  table.sort(rows, function(a, b)
    if a.rank ~= b.rank then return a.rank < b.rank end
    if a.demand ~= b.demand then return a.demand > b.demand end
    return M.index(a.item) < M.index(b.item)
  end)
  return rows
end

return M
