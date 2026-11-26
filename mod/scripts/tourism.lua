-- Cultural Insights tourism adapter (#51). All rules are in model/tourism.lua (and model/transit.lua for the
-- coach trip); this file only reads trains, registries and unit_state. Everything runs once per colony
-- evaluation or on the existing on_train_changed_state handler - there is no on_tick scan.
--
-- storage.tourists[unit_number] = {home = colony id, host = colony id, ["until"] = tick}: a visitor at a host,
-- including one walking/waiting there for the train home. The held bed is colony.away back at home, exactly
-- as for commuters (#50), and is released on arrival home, on coach loss or on the stranded walk home.
local tourism = require("scripts.model.tourism")
local resorts = require("scripts.model.resorts")
local work = require("scripts.work")
local M = {}

local colony_mod, transit   -- injected by scripts.colony via M.bind
function M.bind(c, t) colony_mod, transit = c, t end

function M.is_visitor(un) return storage.tourists ~= nil and storage.tourists[un] ~= nil end

-- The pure self-link guard, re-exported so the transit boarding loop can refuse a same-town group without
-- requiring the model (adapters are wired with bind, never runtime require).
function M.host_ok(home_id, host_id) return tourism.host_ok(home_id, host_id) end

-- Visitors currently at `colony`, in unit-number order. They are in its colonist roster so work's platform
-- machinery can drive them, but they are not residents: see the exclusions in scripts/colony.lua.
function M.here(colony)
  local out = {}
  if not storage.tourists then return out end
  for un, c in pairs(colony.colonists) do
    if c.valid and storage.tourists[un] then out[#out + 1] = un end
  end
  table.sort(out)
  return out
end

-- A platform of `colony` that serves a train stop, or nil (the same test the commuter adapter uses).
local function platform(colony)
  for _, p in ipairs(colony_mod.platform_list(colony)) do
    if transit.stop_of(p) then return p end
  end
end

local function release_beds(home_id, n)
  local home = storage.colonies and storage.colonies[home_id]
  if home and (n or 0) > 0 then home.away = math.max((home.away or 0) - n, 0) end
end

-- A visitor whose way home is gone walks home on foot: its bed is released, but no insight is paid.
local function walk_home(colony, un)
  local rec = storage.tourists[un]
  storage.tourists[un] = nil
  local e = colony.colonists[un]
  colony.colonists[un] = nil
  if colony.locks then colony.locks[un] = nil end
  colony.pop_cache, colony.pop_tick = nil, nil
  if e and e.valid then e.destroy() end
  local home = rec and storage.colonies[rec.home]
  if home and home.hall.valid then
    release_beds(rec.home, 1)
    colony_mod.spawn_colonist(home)
    return true
  end
  return false
end

-- Boarding at home for the outbound trip: the home bed is held here, at the exact moment the rider leaves.
function M.left_home(colony, n) colony.away = (colony.away or 0) + n end

-- Called from the single transit boarding loop for each tourist rider just before its entity is destroyed.
function M.boarded(colony, un, kind)
  if kind == "tourist" then
    M.left_home(colony, 1)          -- `colony` here is the home (the boarding stop's colony)
  elseif kind == "tourist_return" then
    storage.tourists[un] = nil      -- the coach group now owns the visit; no second record can survive
  end
end

-- Tourists stepping off at the Spa colony: register the visit and stop them taking a host job. They are
-- spawned by colony.spawn_colonist, which assigns work immediately, so clear that claim here.
function M.arrive_at_host(colony, batch, spawned)
  storage.tourists = storage.tourists or {}
  local until_tick = game.tick + tourism.VISIT_TICKS
  -- A Resort host marks the visit: the returning coach group carries the flag and pays double insights at
  -- home (#69). A Spa host leaves it nil, so an untouched tourism town is bit-identical.
  local has_resort = #colony_mod.resort_list(colony) > 0
  for _, e in ipairs(spawned) do
    local un = e.unit_number
    local st = storage.unit_state[un]
    if st then
      if st.hut and st.hut.workers then st.hut.workers[un] = nil end
      work.release(st)
    end
    storage.unit_state[un] = {colony_id = colony.id, job = "travel", state = "visiting"}
    storage.unit_state[un].tourist_resort = has_resort or nil
    storage.tourists[un] = {home = batch.home, host = colony.id, ["until"] = until_tick, resort = has_resort or nil}
  end
end

-- Home alight: this is the ONLY payout site. Both a completed return group and a diverted outbound group
-- release the bed here; only the former can earn, and only through model/tourism.earns_insight.
function M.arrive_home(colony, batch)
  local n = batch.n or 0
  release_beds(batch.home or colony.id, n)
  local paid = tourism.credited(batch, colony.id)   -- one insight per rider, never a per-batch throttle
  if paid <= 0 then return 0 end
  colony.insights = (colony.insights or 0) + paid
  colony.insights_total = (colony.insights_total or 0) + paid
  colony.last_insight_tick = game.tick              -- informational only: no payout is gated by it
  if colony.hall.valid then colony.hall.force.print({"colony-message.insight-earned", paid}) end
  return paid
end

-- A coach destroyed/mined before the riders got home: beds come back, no insight, ever. Called by both
-- transit loss handlers, which also respawn the riders at their home hall.
function M.coach_lost(group)
  release_beds(group.home, group.n or 0)
end

-- A visitor killed by the engine dies as its home colony's colonist (the commute.died rule, #50/#53).
function M.died(un)
  local rec = storage.tourists and storage.tourists[un]
  if not rec then return nil end
  storage.tourists[un] = nil
  release_beds(rec.home, 1)
  return storage.colonies and storage.colonies[rec.home] or nil
end

-- Decay once per colony evaluation, not per tick. The stat itself decays (owner decision); the lifetime
-- total is kept separately for the panel and never feeds desirability.
function M.decay(colony)
  colony.insights = tourism.decay(colony.insights or 0)
  if colony.insights < 1e-9 then colony.insights = 0 end
end

local function visitors_at(host_id)
  local n = 0
  for _, rec in pairs(storage.tourists or {}) do if rec.host == host_id then n = n + 1 end end
  return n
end

local function inbound_to(host_id)
  local n = 0
  for _, rec in pairs(storage.coaches or {}) do
    for _, g in ipairs(rec.groups or {}) do
      if g.kind == "tourist" and g.host == host_id then n = n + g.n end
    end
  end
  return n
end

-- Tourists from ANY home walking to (or waiting at) a platform for this host but not yet aboard. They are
-- neither `visiting` nor `inbound` coach riders yet, so without this reservation several homes evaluating
-- in one tick would each see the full Spa capacity and over-send. One pass over unit_state per evaluation.
local function waiting_to(host_id)
  local n = 0
  for _, st in pairs(storage.unit_state or {}) do
    if st.tourist and st.tourist_host == host_id
        and (st.state == "to_platform" or st.state == "waiting_train") then n = n + 1 end
  end
  return n
end

-- Riders of this home away right now: visiting (including waiting at the host for the ride back), on a
-- coach in either direction, and waiting at a home platform to board.
local function away_from(colony)
  local visiting = 0
  for _, rec in pairs(storage.tourists or {}) do if rec.home == colony.id then visiting = visiting + 1 end end
  local riding = 0
  for _, rec in pairs(storage.coaches or {}) do
    for _, g in ipairs(rec.groups or {}) do
      if (g.kind == "tourist" and g.from == colony.id) or (g.kind == "tourist_return" and g.home == colony.id) then
        riding = riding + g.n
      end
    end
  end
  local waiting = 0
  for un, c in pairs(colony.colonists) do
    local st = storage.unit_state[un]
    if c.valid and st and st.tourist and (st.state == "to_platform" or st.state == "waiting_train") then
      waiting = waiting + 1
    end
  end
  return tourism.away_count(visiting, riding, waiting)
end

-- Host side: end visits, send returners to the platform, walk the stranded home on foot.
local function run_host(colony)
  local here = M.here(colony)
  if #here == 0 then return end
  local night = work.is_sleep_time(colony.hall.surface)
  local p = platform(colony)
  local walked = 0
  for _, un in ipairs(here) do
    local rec = storage.tourists[un]
    local st = storage.unit_state[un]
    if st and st.tourist_return then
      -- Already walking/waiting for the ride home: only a lost platform or a long wait sends them on foot.
      local stranded = (st.state == "to_platform" or st.state == "waiting_train")
        and game.tick - (st.wait_since or game.tick) >= tourism.STRANDED_TICKS
      if stranded or not (st.platform and st.platform.entity.valid) then
        if walk_home(colony, un) then walked = walked + 1 end
      end
    elseif tourism.visit_over(game.tick, rec["until"], night) then
      if not (p and work.send_to_platform(colony, un, p,
          {tourist_return = true, tourist_home = rec.home, tourist_visited = true,
           tourist_resort = rec.resort or nil, wait_since = game.tick},
          "heading home 🚉")) then
        if walk_home(colony, un) then walked = walked + 1 end
      end
    end
  end
  if walked > 0 then colony.hall.force.print({"colony-message.tourists-walked", walked}) end
end

-- Home side: pick one idle, adult, unlocked colonist for a different, rail-served Spa colony with space.
local function run_home(colony)
  if work.is_sleep_time(colony.hall.surface) then return end
  local p = platform(colony)
  if not p then return end
  local idle = {}
  local waiting = 0
  for un, c in pairs(colony.colonists) do
    local st = storage.unit_state[un]
    if c.valid and st and st.state == "idle" and not M.is_visitor(un) then
      local age = storage.age and storage.age[un]
      if not (age and age.stage == "child") and not (colony.locks and colony.locks[un]) then
        idle[#idle + 1] = un
      end
    end
    if c.valid and st and st.tourist and (st.state == "to_platform" or st.state == "waiting_train") then
      waiting = waiting + 1
    end
  end
  if #idle == 0 then return end
  table.sort(idle)
  local free = tourism.HOME_TOURIST_CAP - away_from(colony)
  if free <= 0 then return end

  -- Deterministic host order: ascending colony id. Only colonies on this surface, different from home,
  -- with a Spa and a platform serving a stop, count as destinations.
  local ids = {}
  for id in pairs(storage.colonies) do
    if id ~= colony.id then ids[#ids + 1] = id end
  end
  table.sort(ids)
  local want, target = 0, nil
  for _, id in ipairs(ids) do
    local host = storage.colonies[id]
    if host and host.hall.valid and host.hall.surface == colony.hall.surface and tourism.host_ok(colony.id, id)
        and #colony_mod.spa_list(host) > 0 and platform(host) then
      local cap = resorts.host_capacity(#colony_mod.spa_list(host), #colony_mod.resort_list(host),
        visitors_at(id), inbound_to(id), waiting_to(id))
      if cap > 0 then
        want = want + cap
        if not target then target = id end
      end
    end
  end
  if not target then return end
  local n = tourism.departures(#idle, math.min(free, want), waiting, tourism.MAX_SEND_PER_EVAL)
  if n <= 0 then return end
  local sent = 0
  for i = 1, n do
    if work.send_to_platform(colony, idle[i], p, {tourist = true, tourist_host = target}, "sightseeing 🚉") then
      sent = sent + 1
    end
  end
  if sent > 0 then colony.hall.force.print({"colony-message.tourists-bound", sent}) end
end

function M.evaluate(colony)
  run_host(colony)
  run_home(colony)
end

return M
