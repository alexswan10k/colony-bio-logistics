-- Passenger rail adapter (#49). Rules are in model/transit.lua; this file reads trains and platforms.
-- A Passenger Platform is a colony building near a vanilla train stop. Colonists who would leave town (or have no
-- bed) walk to it and wait. When a train holding Passenger Coaches stops at that stop, riders for this colony get
-- off first and become its colonists, then the waiting colonists board: they leave their colony and ride as a
-- count on the coach (storage.coaches), drawn over the wagon. No per-tick work: everything happens on
-- on_train_changed_state.
local events = require("scripts.events")
local transit = require("scripts.model.transit")
local work = require("scripts.work")
local M = {}

M.COACH = "colony-passenger-coach"

local colony_mod   -- injected by scripts.colony via M.bind
function M.bind(c) colony_mod = c end

local function dist2(a, b) local dx, dy = a.x - b.x, a.y - b.y; return dx * dx + dy * dy end

-- The train stop a platform serves (nearest within STOP_RADIUS), cached on the record while it stays valid.
function M.stop_of(p)
  if p.stop and p.stop.valid then return p.stop end
  local e = p.entity
  local best, best_d
  for _, s in ipairs(e.surface.find_entities_filtered{type = "train-stop", position = e.position, radius = transit.STOP_RADIUS}) do
    local d = dist2(s.position, e.position)
    if not best_d or d < best_d or (d == best_d and s.unit_number < best.unit_number) then best, best_d = s, d end
  end
  p.stop = best
  return best
end

-- The platform (and its colony) serving a stop, or nil.
local function platform_at(stop)
  for _, colony in pairs(storage.colonies) do
    if colony.hall.valid and colony.hall.surface == stop.surface then
      for _, p in ipairs(colony_mod.platform_list(colony)) do
        if M.stop_of(p) == stop then return p, colony end
      end
    end
  end
end

-- Colonists of `colony` waiting at platform `p`, in unit-number order (deterministic boarding).
local function waiting_at(colony, p)
  local out = {}
  for un, c in pairs(colony.colonists) do
    local st = storage.unit_state[un]
    if c.valid and st and st.state == "waiting_train" and st.platform == p then out[#out + 1] = un end
  end
  table.sort(out)
  return out
end

-- Colonists already bound for or waiting at any of this colony's platforms.
function M.waiting_count(colony, p)
  local n = 0
  for un in pairs(colony.colonists) do
    local st = storage.unit_state[un]
    if st and (st.state == "waiting_train" or st.state == "to_platform") and (not p or st.platform == p) then n = n + 1 end
  end
  return n
end

-- Free beds in every other colony on the same surface that has a platform with a stop: where riders could go.
local function room_elsewhere(colony)
  local room = 0
  for _, other in pairs(storage.colonies) do
    if other ~= colony and other.hall.valid and other.hall.surface == colony.hall.surface then
      local served = false
      for _, p in ipairs(colony_mod.platform_list(other)) do
        if M.stop_of(p) then served = true; break end
      end
      if served then room = room + math.max(colony_mod.capacity(other) - colony_mod.live_colonists(other), 0) end
    end
  end
  return room
end

-- Send up to `leaving` would-be leavers plus the homeless to the platform. Returns how many of `leaving` were
-- sent (the caller lets the rest walk off as before).
function M.depart(colony, leaving, homeless)
  local platforms = colony_mod.platform_list(colony)
  local p
  for _, cand in ipairs(platforms) do if M.stop_of(cand) then p = cand; break end end
  if not p then return 0 end
  local waiting = M.waiting_count(colony)
  local n = transit.departures(leaving, homeless, waiting, room_elsewhere(colony))
  if n <= 0 then return 0 end
  -- Newest arrivals go first, as when colonists leave on foot (colony.leave_one).
  local ids = {}
  for un, c in pairs(colony.colonists) do
    local st = storage.unit_state[un]
    if c.valid and not (st and (st.state == "waiting_train" or st.state == "to_platform" or st.state == "driving")) then
      ids[#ids + 1] = un
    end
  end
  table.sort(ids, function(a, b) return a > b end)
  local sent = 0
  for i = 1, math.min(n, #ids) do
    if work.send_to_platform(colony, ids[i], p) then sent = sent + 1 end
  end
  if sent > 0 then colony.hall.force.print({"colony-message.platform-bound", sent}) end
  return math.min(sent, leaving or 0)
end

local function draw_riders(coach, rec)
  local n = transit.riders(rec.groups)
  if rec.text and rec.text.valid then
    if n > 0 then rec.text.text = "👥 " .. n else rec.text.destroy(); rec.text = nil end
  elseif n > 0 then
    rec.text = rendering.draw_text{text = "👥 " .. n, surface = coach.surface, target = {entity = coach, offset = {0, -1.5}},
      color = {1, 1, 1}, scale = 1.2, alignment = "center"}
  end
end

events.on(defines.events.on_train_changed_state, function(ev)
  local train = ev.train
  if not (train and train.valid and train.state == defines.train_state.wait_station) then return end
  local stop = train.station
  if not (stop and stop.valid) then return end
  local coaches = {}
  for _, w in ipairs(train.cargo_wagons) do if w.name == M.COACH then coaches[#coaches + 1] = w end end
  if #coaches == 0 then return end
  local p, colony = platform_at(stop)
  if not p then return end
  storage.coaches = storage.coaches or {}
  local arrived = 0
  -- Riders off first: they free seats for the people waiting, and they need beds that boarders are leaving.
  for _, coach in ipairs(coaches) do
    local rec = storage.coaches[coach.unit_number]
    if rec then
      local free = colony_mod.capacity(colony) - colony_mod.live_colonists(colony)
      local off, left = transit.alight(rec.groups, colony.id, free)
      rec.groups = left
      for _ = 1, off do
        if colony_mod.spawn_colonist(colony, p.entity.position) then arrived = arrived + 1 end
      end
      draw_riders(coach, rec)
    end
  end
  if arrived > 0 then
    colony.hall.force.print({"colony-message.train-arrived", arrived,
      string.format("[gps=%d,%d,%s]", math.floor(p.entity.position.x), math.floor(p.entity.position.y), p.entity.surface.name)})
  end
  -- Then board, coach by coach, until the seats or the queue run out.
  local queue, qi = waiting_at(colony, p), 1
  for _, coach in ipairs(coaches) do
    if qi > #queue then break end
    local rec = storage.coaches[coach.unit_number]
    if not rec then
      rec = {groups = {}}
      storage.coaches[coach.unit_number] = rec
      script.register_on_object_destroyed(coach)
    end
    local seats, boarded = transit.seats(rec.groups), 0
    while seats > 0 and qi <= #queue do
      local un = queue[qi]
      qi = qi + 1
      local c = colony.colonists[un]
      if c and c.valid then
        colony.colonists[un] = nil
        if colony.locks then colony.locks[un] = nil end
        c.destroy()     -- work's on_object_destroyed clears its state, label and anything it carried
        boarded, seats = boarded + 1, seats - 1
      end
    end
    if boarded > 0 then
      rec.groups[#rec.groups + 1] = {from = colony.id, n = boarded, stops = 0}
      colony.pop_cache, colony.pop_tick = nil, nil
      draw_riders(coach, rec)
    end
  end
end)

events.on(defines.events.on_object_destroyed, function(ev)
  local rec = ev.useful_id and storage.coaches and storage.coaches[ev.useful_id]
  if not rec then return end
  storage.coaches[ev.useful_id] = nil
  local n = transit.riders(rec.groups)
  if n > 0 then
    for _, colony in pairs(storage.colonies) do
      if colony.hall.valid then colony.hall.force.print({"colony-message.coach-lost", n}); break end
    end
  end
end)

return M
