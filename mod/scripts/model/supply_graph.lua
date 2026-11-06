-- PURE: transitive supply & demand (#90).
-- Demand is known at the top of a chain (a marked assembler wants circuits, an archive wants packs). This
-- walks *up* the recipe graph from that demand so the colony's quota targets, harvest priority and haul
-- bands respond on the lower floors too: packs -> plates -> ore, without the player setting a quota for
-- every intermediate by hand.
--
-- It is deliberately not a production planner. It answers "how much of this should the town want", which is
-- exactly what `quota_target` already asks; it never decides what to build or which colonist goes where.
local M = {}

M.DEPTH = 4         -- recipe steps upstream to follow (preserved food -> pack -> gear -> plate -> ore is 4)
-- Each step upstream counts three quarters of the one below it: the colony already holds part of an
-- intermediate (a plate sitting in the hall is ore it does not need again), and damping keeps a recipe that
-- cycles through itself bounded. 1.0 would be a pure production planner, which this is not (#90).
M.DAMPING = 0.75

-- recipe_list: array of {name=, products = {{item=, amount=}, ...}, ingredients = {{item=, amount=}, ...}}
-- Returns {product -> {ingredients = {{item, amount}, ...}, yield = n}}.
--
-- One recipe per product: the one with the *fewest ingredient types* (a tie is broken by recipe name). The
-- graph is a heuristic feedstock tree, not a solver - choosing the shortest path keeps the numbers honest for
-- the common case (ore -> plate -> gear) and stops an expensive alternate recipe from inflating a target.
function M.build(recipe_list)
  local best = {}
  for _, r in ipairs(recipe_list or {}) do
    local ingredients = r.ingredients or {}
    local n = #ingredients
    for _, p in ipairs(r.products or {}) do
      local item, amount = p[1], p[2] or 1
      if item and amount and amount > 0 then
        local cur = best[item]
        if not cur or n < cur.n or (n == cur.n and r.name < cur.name) then
          best[item] = {n = n, name = r.name, yield = amount, ingredients = ingredients}
        end
      end
    end
  end
  local out = {}
  for item, e in pairs(best) do
    out[item] = {ingredients = e.ingredients, yield = e.yield}
  end
  return out
end

-- seeds: {item -> count} demand already known at the top of the chain.
-- Returns {item -> additional upstream demand}: what the floors above the seeds ask for. An item that is both a
-- seed and an ingredient of something the colony wants (a demand crate of ore next to a plate assembler) is
-- reported for the ingredient side too; the caller adds the two, because both are real demand.
-- Bounded by `depth`, so a recipe that consumes its own output terminates; `damping` shrinks the further
-- floors so the sum is finite even on a long chain.
function M.propagate(recipes, seeds, depth, damping)
  depth = depth or M.DEPTH
  damping = damping or M.DAMPING
  local out = {}
  if not recipes or not seeds then return out end
  local level = {}
  for item, n in pairs(seeds) do
    if type(n) == "number" and n > 0 then level[item] = n end
  end
  local factor = 1
  for _ = 1, depth do
    factor = factor * damping
    local next_level, any = {}, false
    for product, demand in pairs(level) do
      local r = recipes[product]
      if r then
        local produced = r.yield
        if not produced or produced <= 0 then produced = 1 end
        for _, ing in ipairs(r.ingredients or {}) do
          local item, amount = ing[1], ing[2] or 0
          if item and amount > 0 then
            local add = demand * amount / produced * factor
            if add > 0 then
              next_level[item] = (next_level[item] or 0) + add
              out[item] = (out[item] or 0) + add
              any = true
            end
          end
        end
      end
    end
    if not any then break end
    level = next_level
  end
  return out
end

-- Merge the propagated floors into the direct demand table: both are real demand (a crate of ore beside a plate
-- assembler wants ore *and* the ore the assembler implies), so they add.
function M.merge(direct, upstream)
  local out = {}
  for item, n in pairs(direct or {}) do out[item] = n end
  for item, n in pairs(upstream or {}) do out[item] = (out[item] or 0) + n end
  return out
end

-- Round to a whole item and drop dust, so a chain of halves cannot make a quota target drift by 0.0001
-- between evaluations (and reads sensibly in the panel).
function M.whole(demand)
  local out = {}
  for item, n in pairs(demand or {}) do
    local v = math.floor(n + 0.5)
    if v > 0 then out[item] = v end
  end
  return out
end

return M
