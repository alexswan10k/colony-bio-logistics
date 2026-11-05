-- PURE: choose a job for an idle colonist, driven by the colony's priority matrix (design §4.1, #27).
--   1. Logistics first: while hauling is enabled and below its share, keep the colony hauling or houses starve.
--   2. Otherwise take the best-ranked enabled harvest job that still has a free tooled slot. Jobs sharing a
--      rank are one group and split the workforce by the food ratio (so the default matrix behaves as before).
--   3. If no harvest slot is free, haul (rather than stand around); idle only if hauling is off too.
local M = {}
local jobs = require("scripts.model.jobs")
local construct = require("scripts.model.construct")
local headcount = require("scripts.model.headcount")

M.JOBS = jobs.JOBS          -- haul first: wins ties (keeps houses supplied)
M.HAUL_SHARE = 0.35
M.HAUL_MAX_SHARE = 0.5   -- a backlog of deliveries can pull up to this share of the town onto hauling
M.PRESERVE_SHARE = 0.15     -- of the town, at most: a smokehouse is fed, it does not need an army
M.RESEARCH_SHARE = 0.15     -- scholars investigating history and science
M.HARVEST = {"forage", "farm", "chop", "mine", "hunt", "fish"}
M.FOOD = {"forage", "farm", "hunt", "fish"}

function M.preserve_workers(pop) return math.max(1, math.floor((pop or 0) * M.PRESERVE_SHARE)) end
function M.research_workers(pop) return math.max(1, math.floor((pop or 0) * M.RESEARCH_SHARE)) end

-- food_ratio = stock/target; returns the share of non-hauling colonists each hut job should get.
function M.desired_shares(food_ratio)
  if food_ratio < 0.5 then return {forage = 0.3, hunt = 0.1, fish = 0.1, farm = 0.25, chop = 0.15, mine = 0.1}
  elseif food_ratio < 1 then return {forage = 0.2, hunt = 0.1, fish = 0.1, farm = 0.2, chop = 0.2, mine = 0.2}
  else return {forage = 0.1, hunt = 0.1, fish = 0.1, farm = 0.15, chop = 0.3, mine = 0.25} end
end

-- How many colonists should be hauling at this population (at least one, or nothing gets delivered). `backlog`
-- (destinations waiting on a real request, not a top-up) raises it: one hauler per waiting destination, up to
-- HAUL_MAX_SHARE of the town. Haulers walk to every pickup, so a fixed share either starves the low bands of a
-- busy town or wastes workers in a quiet one.
function M.haul_target(pop, backlog)
  if pop <= 0 then return 0 end
  local base = math.max(1, math.floor(M.HAUL_SHARE * pop + 0.5))
  if not backlog or backlog <= base then return base end
  local max_haul = math.max(base + 1, math.floor(M.HAUL_MAX_SHARE * pop + 0.5))
  return math.max(base, math.min(backlog, max_haul))
end

-- s = {food_ratio=, backlog= (haul destinations waiting), counts={job->n}, slots={job->free tooled slots}, capacity={job->tooled slots},
--      hut_count={job->staffable huts}, pop=, haul=bool, priority={job->rank}, targets={job->headcount|nil}}.
-- `pop` excludes the colonist being assigned.
-- Returns a job name or nil.
function M.choose(s)
  local counts, slots, capacity = s.counts or {}, s.slots or {}, s.capacity or {}
  local hut_count = s.hut_count or {}
  local pop = s.pop or 0
  local priority = s.priority
  local targets = s.targets
  local haul_on = jobs.enabled(priority, "haul")
  local haul_rank = jobs.rank(priority, "haul")

  local haul_capped = headcount.is_capped(targets, "haul", counts.haul)
  local haul_wanted = headcount.target(targets, "haul") or M.haul_target(math.max(pop, 1), s.backlog)
  local can_haul = haul_on and s.haul and not haul_capped and (counts.haul or 0) < haul_wanted

  local c_rank = jobs.rank(priority, "construct")
  local c_cap = headcount.target(targets, "construct") or construct.builders(pop)
  local c_capped = headcount.is_capped(targets, "construct", counts.construct)
  local can_construct = c_rank > 0 and (slots.construct or 0) > 0 and not c_capped and (counts.construct or 0) < c_cap

  local p_rank = jobs.rank(priority, "preserve")
  local p_cap = headcount.target(targets, "preserve") or M.preserve_workers(pop)
  local p_capped = headcount.is_capped(targets, "preserve", counts.preserve)
  local can_preserve = p_rank > 0 and (slots.preserve or 0) > 0 and not p_capped and (counts.preserve or 0) < p_cap

  -- Doctors (#47): a Clinic only has an open slot while it holds medicine and someone is sick (the adapter closes
  -- it otherwise), and it holds two, so the clinic's own capacity is the cap.
  local h_rank = jobs.rank(priority, "heal")
  local h_capped = headcount.is_capped(targets, "heal", counts.heal)
  local can_heal = h_rank > 0 and (slots.heal or 0) > 0 and not h_capped

  local r_rank = jobs.rank(priority, "research")
  local r_cap = headcount.target(targets, "research") or M.research_workers(pop)
  local r_capped = headcount.is_capped(targets, "research", counts.research)
  local can_research = r_rank > 0 and (slots.research or 0) > 0 and not r_capped and (counts.research or 0) < r_cap

  -- Guards (#56): no share of the town - the tower's tooled slots are the whole cap, like the heal role.
  local g_rank = jobs.rank(priority, "guard")
  local g_capped = headcount.is_capped(targets, "guard", counts.guard)
  local can_guard = g_rank > 0 and (slots.guard or 0) > 0 and not g_capped

  -- Best eligible harvest rank among slots that are not headcount-capped
  local eligible_harvest_slots = {}
  for _, job in ipairs(M.HARVEST) do
    if (slots[job] or 0) > 0 and not headcount.is_capped(targets, job, counts[job]) then
      eligible_harvest_slots[job] = slots[job]
    end
  end
  local harvest_rank = jobs.best_rank(priority, M.HARVEST, eligible_harvest_slots)

  -- Hunger priority (#expectation): if there is no food in the colony, food roles come first
  local food_rank = jobs.best_rank(priority, M.FOOD, eligible_harvest_slots)
  if s.food_ratio and s.food_ratio <= 0 and food_rank then
    for _, job in ipairs(M.FOOD) do
      if (eligible_harvest_slots[job] or 0) > 0 and jobs.rank(priority, job) == food_rank and (counts[job] or 0) == 0 then
        return job
      end
    end
    local best_food, best_gap
    for _, job in ipairs(M.FOOD) do
      if (eligible_harvest_slots[job] or 0) > 0 and jobs.rank(priority, job) == food_rank then
        local gap = (targets and targets[job] or 1) - (counts[job] or 0)
        if not best_gap or gap > best_gap then best_food, best_gap = job, gap end
      end
    end
    if best_food then return best_food end
  end

  local better_than_haul = (can_heal and h_rank < haul_rank)
      or (can_construct and c_rank < haul_rank)
      or (can_preserve and p_rank < haul_rank)
      or (can_research and r_rank < haul_rank)
      or (can_guard and g_rank < haul_rank)
      or (harvest_rank and harvest_rank < haul_rank)

  if can_haul and not better_than_haul then
    return "haul"
  end

  -- Guard duty first among the dedicated posts: a manned tower is a standing order, not a surplus share.
  if can_guard and (not harvest_rank or g_rank <= harvest_rank) and (not can_construct or g_rank <= c_rank)
      and (not can_preserve or g_rank <= p_rank) and (not can_research or g_rank <= r_rank)
      and (not can_heal or g_rank <= h_rank) then
    return "guard"
  end

  if can_heal and (not harvest_rank or h_rank <= harvest_rank) and (not can_construct or h_rank <= c_rank)
      and (not can_preserve or h_rank <= p_rank) and (not can_research or h_rank <= r_rank) then
    return "heal"
  end

  -- Check construction if prioritized
  if can_construct and (not harvest_rank or c_rank <= harvest_rank) and (not can_preserve or c_rank <= p_rank)
      and (not can_research or c_rank <= r_rank) then
    return "construct"
  end

  -- Check preserve if prioritized
  if can_preserve and (not harvest_rank or p_rank <= harvest_rank) and (not can_research or p_rank <= r_rank) then
    return "preserve"
  end

  -- Check research if prioritized
  if can_research and (not harvest_rank or r_rank <= harvest_rank) then
    return "research"
  end

  -- Check harvest rank
  if harvest_rank then
    -- Missing resources first (empty stock, or below a player quota), round-robin between them.
    if s.missing then
      local missing_candidates = {}
      for _, job in ipairs(M.HARVEST) do
        if (eligible_harvest_slots[job] or 0) > 0 and jobs.rank(priority, job) == harvest_rank then
          local wanted_by_target = targets and targets[job] and (counts[job] or 0) < targets[job]
          if s.missing[job] or wanted_by_target then
            missing_candidates[#missing_candidates + 1] = job
          end
        end
      end
      -- Every staffable role gets its first worker before a missing one doubles up: otherwise one ore the
      -- huts can never reach (no copper in range) pulls the whole town into the mines.
      local unstaffed_missing, unstaffed = {}, {}
      for _, job in ipairs(missing_candidates) do
        if (counts[job] or 0) == 0 then unstaffed_missing[#unstaffed_missing + 1] = job end
      end
      for _, job in ipairs(M.HARVEST) do
        if (eligible_harvest_slots[job] or 0) > 0 and jobs.rank(priority, job) == harvest_rank and (counts[job] or 0) == 0 then
          unstaffed[#unstaffed + 1] = job
        end
      end
      for _, list in ipairs{unstaffed_missing, unstaffed, missing_candidates} do
        if #list > 0 then return list[((s.cursor or 0) % #list) + 1] end
      end
    end
    -- Otherwise the usual shares. A hut whose quota is met already has no slots (work.job_slots), so this
    -- stops at the quota; with no quota (0 = unlimited) gathering simply carries on.
    local shares = M.desired_shares(s.food_ratio)
    local best, best_gap
    for _, job in ipairs(M.HARVEST) do
      if (eligible_harvest_slots[job] or 0) > 0 and jobs.rank(priority, job) == harvest_rank then
        local tgt = headcount.target(targets, job)
        -- Every staffable hut gets one worker before the food share can double up on another hut. Without
        -- this, a role's whole share fills the oldest hut and a hut built further out never gets anyone.
        local floor = math.min(math.max(1, hut_count[job] or 0), capacity[job] or 0)
        local wanted = tgt or math.max(shares[job] * (1 - M.HAUL_SHARE) * pop, floor)
        local gap = wanted - (counts[job] or 0)
        if not best_gap or gap > best_gap then best, best_gap = job, gap end
      end
    end
    if best then return best end
  end

  -- Fallbacks if earlier prioritized roles were skipped
  if can_guard then return "guard" end
  if can_heal then return "heal" end
  if can_construct then return "construct" end
  if can_preserve then return "preserve" end
  if can_research then return "research" end

  if haul_on and s.haul and not haul_capped then return "haul" end
  return nil
end

return M
