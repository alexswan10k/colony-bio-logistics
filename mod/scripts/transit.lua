-- Passenger rail adapter (#49). Rules are in model/transit.lua; this file reads trains and platforms.
-- A Passenger Platform is a colony building near a vanilla train stop. Colonists who would leave town (or have no
-- bed) walk to it and wait. When a train holding Passenger Coaches stops at that stop, riders for this colony get
-- off first and become its colonists, then the waiting colonists board: they leave their colony and ride as a
-- count on the coach (storage.coaches), drawn over the wagon. No per-tick work: everything happens on
-- on_train_changed_state.
local events = require("scripts.events")
local transit = require("scripts.model.transit")
local work = require("scripts.work")
local mortality = require("scripts.mortality")
local commute = require("scripts.commute")
local M = {}

M.COACH = "colony-passenger-coach"

local colony_mod, tourism   -- injected by scripts.colony via M.bind / M.bind_tourism
function M.bind(c) colony_mod = c end
function M.bind_tourism(t) tourism = t end

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
      if served then room = room + math.max(colony_mod.capacity(other) - colony_mod.live_colonists(other) - (other.away or 0), 0) end
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
    local rec = storage.age and storage.age[un]   -- never send a child to its death on a bench seat
    local st = storage.unit_state[un]
    if c.valid and not (st and (st.state == "waiting_train" or st.state == "to_platform" or st.state == "driving"))
        and not (rec and rec.stage == "child")
        and not commute.is_commuter(un)
        and not (tourism and tourism.is_visitor(un)) then   -- #51: host visitors are not the home's to lose
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
  -- Migrants need a free bed, commuters bound for work an open job slot (#50), commuters bound home nothing.
  local arrived, commuters_in, home_again, tourists_in, tourists_home = 0, 0, 0, 0, 0
  for _, coach in ipairs(coaches) do
    local rec = storage.coaches[coach.unit_number]
    if rec then
      local free = colony_mod.capacity(colony) - colony_mod.live_colonists(colony) - (colony.away or 0)
      local _, left, offs = transit.alight(rec.groups, colony.id, free, colony.deficit or 0)
      rec.groups = left
      for _, b in ipairs(offs) do
        local spawned = {}
        for _ = 1, b.n do
          local e = colony_mod.spawn_colonist(colony, p.entity.position)
          if e then spawned[#spawned + 1] = e end
        end
        if b.kind == "tourist" and b.host == colony.id then
          -- Arrival at the Spa: register the visit, but pay nothing. The held bed stays held at home.
          if tourism then tourism.arrive_at_host(colony, b, spawned) end
          tourists_in = tourists_in + #spawned
        elseif b.kind == "tourist" or b.kind == "tourist_return" then
          -- Home alight (or a diverted outbound group). tourism.arrive_home is the one and only payout
          -- site; model/transit.alight has already consumed the group, so a second stop pays nothing.
          if tourism then tourism.arrive_home(colony, b) end
          tourists_home = tourists_home + #spawned
        elseif b.kind == "commute" and b.from ~= colony.id then
          commute.arrived(colony, b.from, spawned)
          commuters_in = commuters_in + #spawned
          local lost = b.n - #spawned
          local home = storage.colonies and storage.colonies[b.from]
          if lost > 0 and home then commute.back_home(home, lost) end
        elseif b.kind == "commute" or b.kind == "return" then
          commute.back_home(colony, b.n)
          home_again = home_again + #spawned
        else
          arrived = arrived + #spawned
        end
      end
      draw_riders(coach, rec)
    end
  end
  local at = string.format("[gps=%d,%d,%s]", math.floor(p.entity.position.x), math.floor(p.entity.position.y), p.entity.surface.name)
  if arrived > 0 then colony.hall.force.print({"colony-message.train-arrived", arrived, at}) end
  if commuters_in > 0 then colony.hall.force.print({"colony-message.commuters-arrived", commuters_in, at}) end
  if home_again > 0 then colony.hall.force.print({"colony-message.commuters-home", home_again}) end
  if tourists_in > 0 then colony.hall.force.print({"colony-message.tourists-arrived", tourists_in, at}) end
  if tourists_home > 0 then colony.hall.force.print({"colony-message.tourists-home", tourists_home}) end
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
    -- Each boarder joins a group by why it rides: a migrant, a commuter off to work, a commuter going home.
    local seats, boarded, batches = transit.seats(rec.groups), 0, {}
    while seats > 0 and qi <= #queue do
      local un = queue[qi]
      qi = qi + 1
      local c = colony.colonists[un]
      if c and c.valid then
        local st = storage.unit_state[un]
        local kind, home, host, visited, resort, grand = nil, nil, nil, nil, nil, nil
        if st and st.tourist and tourism and tourism.host_ok(colony.id, st.tourist_host) then
          -- Outbound tourist: home is where we boarded; host is the Spa town. The bed is held at boarding.
          kind, home, host = "tourist", colony.id, st.tourist_host
        elseif st and st.tourist_return then
          -- Returning visitor: the host is where we board, the bed is still held at `tourist_home`.
          kind, home, host, visited, resort = "tourist_return", st.tourist_home, colony.id,
            st.tourist_visited == true, st.tourist_resort == true, st.tourist_grand == true
        elseif st and st.commute then kind = "commute"
        elseif st and st.home then kind, home = "return", st.home end
        local k = (kind or "") .. ":" .. tostring(home) .. ":" .. tostring(host) .. ":"
          .. tostring(resort) .. ":" .. tostring(grand)
        local b = batches[k]
        if not b then
          b = {from = colony.id, n = 0, kind = kind, home = home, host = host,
            visited = visited, resort = resort, grand = grand}
          batches[k] = b
          batches[#batches + 1] = b
        end
        b.n = b.n + 1
        colony.colonists[un] = nil
        if colony.locks then colony.locks[un] = nil end
        if storage.commuters then storage.commuters[un] = nil end
        if kind == "tourist" or kind == "tourist_return" then
          if tourism then tourism.boarded(colony, un, kind) end
        end
        c.destroy()     -- work's on_object_destroyed clears its state, label and anything it carried
        boarded, seats = boarded + 1, seats - 1
      end
    end
    for _, b in ipairs(batches) do
      rec.groups[#rec.groups + 1] = {from = b.from, n = b.n, stops = 0, kind = b.kind, home = b.home,
        host = b.host, visited = b.visited, resort = b.resort, grand = b.grand}
      if b.kind == "commute" then commute.left_home(colony, b.n) end
    end
    if boarded > 0 then
      colony.pop_cache, colony.pop_tick = nil, nil
      draw_riders(coach, rec)
    end
  end
end)

-- A coach destroyed in combat or a crash (on_entity_died, which fires before on_object_destroyed) kills its
-- riders: each is a death in the colony it boarded from (#53). Any other removal (mined, deconstructed, a
-- script) lets them climb down and walk back to that colony's Town Hall.
-- Riders by the colony they belong to: a commuter's is its home (`from` on the way out, `home` on the way
-- back), whose bed it holds; that hold is released here, since the rider is not coming back from this coach.
local function each_origin(rec, fn)
  local by = {}
  for _, g in ipairs(rec.groups or {}) do
    local tourist_group = g.kind == "tourist" or g.kind == "tourist_return"
    local id = (g.kind == "return" or g.kind == "tourist_return") and g.home or g.from
    by[id] = (by[id] or 0) + g.n
    if tourist_group then
      -- #51: a lost coach returns the held bed but pays no insight. This is the only bed release for
      -- tourist groups here, so a returning commuter's `back_home` below cannot double-release theirs.
      if tourism then tourism.coach_lost(g) end
    else
      local home = g.kind and storage.colonies[id]
      if home then commute.back_home(home, g.n) end
    end
  end
  local ids = {}
  for id in pairs(by) do ids[#ids + 1] = id end
  table.sort(ids)
  for _, id in ipairs(ids) do
    local colony = storage.colonies[id]
    if colony and colony.hall.valid then fn(colony, by[id]) end
  end
end

events.on(defines.events.on_entity_died, function(ev)
  local e = ev.entity
  if e.name ~= M.COACH then return end
  local rec = storage.coaches and storage.coaches[e.unit_number]
  if not rec then return end
  storage.coaches[e.unit_number] = nil
  each_origin(rec, function(colony, n)
    for _ = 1, n do mortality.record(colony, nil, nil, "train", true) end
    colony.hall.force.print({"colony-message.riders-killed", n})
  end)
end)

events.on(defines.events.on_object_destroyed, function(ev)
  local rec = ev.useful_id and storage.coaches and storage.coaches[ev.useful_id]
  if not rec then return end
  storage.coaches[ev.useful_id] = nil
  each_origin(rec, function(colony, n)
    local back = 0
    for _ = 1, n do
      if colony_mod.spawn_colonist(colony) then back = back + 1 end
    end
    if back > 0 then colony.hall.force.print({"colony-message.riders-home", back}) end
  end)
end)

return M
