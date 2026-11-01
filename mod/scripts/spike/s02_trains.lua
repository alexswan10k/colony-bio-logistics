-- SPIKE #2: Passenger coach / commuter train feasibility.
-- /spike run s02_trains
-- Part A (API): can characters / units be passengers of a cargo wagon (coach)? Expect: NO for cargo wagon.
-- Part B (events): build 2 stops + loco/coach/loco, run a schedule, log on_train_changed_state + station identification.
-- Part B depends on exact rail/stop placement; failures are reported, not fatal.
local core = require("scripts.spike.core")
local events = require("scripts.events")
local S

events.on(defines.events.on_train_changed_state, function(ev)
  if not S then return end
  local t = ev.train
  local st = t.station
  S.ctx.log(string.format("train %d state %s -> %s station=%s", t.id, tostring(ev.old_state), tostring(t.state),
    st and st.backer_name or "nil"))
  if t.state == defines.train_state.wait_station and st then
    S.arrivals = S.arrivals + 1
    S.ctx.check("wait_station yields station entity (usable for Passenger Platform lookup)", st.valid, st.backer_name)
    -- adjacency check for a would-be Passenger Platform:
    local near = S.ctx.surface.find_entities_filtered{position = st.position, radius = 4, name = "wooden-chest"}
    S.ctx.log("platform-adjacency lookup via find_entities (chests near stop): " .. #near)
  end
end)

core.register("s02_trains", {
  issue = 2, auto = false, desc = "coach passengers + train state hooks", usage = "",
  run = function(ctx)
    ctx.flat_area(45)
    local s, p = ctx.surface, ctx.position
    local y = math.floor(p.y)
    y = (y % 2 == 0) and y + 1 or y   -- rails sit on odd coords
    local x0 = (p.x - 30); x0 = (x0 % 2 == 0) and x0 + 1 or x0
    local rails = 0
    for i = 0, 29 do
      if s.create_entity{name = "straight-rail", position = {x0 + 2 * i, y}, direction = defines.direction.east, force = "player"} then
        rails = rails + 1
      end
    end
    ctx.check("laid 30 straight rails", rails == 30, rails)
    local function try_stop(xe, name)
      for _, d in ipairs({defines.direction.east, defines.direction.west}) do
        for _, dy in ipairs({-2, 2}) do
          local params = {name = "train-stop", position = {xe, y + dy}, direction = d, force = "player"}
          if s.can_place_entity(params) then
            local e = s.create_entity(params)
            if e then e.backer_name = name; return e end
          end
        end
      end
    end
    local A = try_stop(x0 + 52, "SPIKE-A")
    local B = try_stop(x0 + 6, "SPIKE-B")
    ctx.check("train stops placed", A ~= nil and B ~= nil, "A=" .. tostring(A ~= nil) .. " B=" .. tostring(B ~= nil))

    local coach_name = prototypes.entity["colony-passenger-coach"] and "colony-passenger-coach" or "cargo-wagon"
    local lx = x0 + 14
    local loco1 = s.create_entity{name = "locomotive", position = {lx, y}, direction = defines.direction.east, force = "player"}
    local coach = s.create_entity{name = coach_name, position = {lx + 7, y}, direction = defines.direction.east, force = "player"}
    local loco2 = s.create_entity{name = "locomotive", position = {lx + 14, y}, direction = defines.direction.west, force = "player"}
    ctx.check("train assembled (" .. coach_name .. ")", loco1 and coach and loco2, tostring(loco1 and coach and loco2))
    if not (loco1 and coach and loco2) then ctx.finish() return end
    for _, l in ipairs({loco1, loco2}) do l.get_fuel_inventory().insert{name = "coal", count = 40} end

    -- Part A
    local char = s.create_entity{name = "character", position = {lx, y + 6}, force = "player"}
    local unit = s.create_entity{name = "colony-colonist", position = {lx + 4, y + 8}, force = "player"}
    ctx.probe("coach.set_passenger(character)", function() coach.set_passenger(char); local ps = coach.get_passenger(); return ps and "seated" or "NOT seated" end)
    ctx.probe("coach.set_driver(character)", function() coach.set_driver(char); local d = coach.get_driver(); return d and "seated" or "NOT seated" end)
    ctx.probe("coach.get_passenger() after attempts", function() return tostring(coach.get_passenger()) end)
    ctx.probe("loco.set_passenger(character)", function() loco1.set_passenger(char); return loco1.get_passenger() and "seated" or "NOT seated" end)
    ctx.probe("coach.set_passenger(UNIT)", function() coach.set_passenger(unit); return coach.get_passenger() and "seated" or "NOT seated" end)
    ctx.probe("loco.set_passenger(UNIT)", function() loco1.set_passenger(unit); return loco1.get_passenger() and "seated" or "NOT seated" end)
    ctx.log("CONCLUSION GUIDE: if only characters can sit (and not on cargo wagons), commuting must be abstracted (despawn colonists into storage keyed by wagon unit_number; respawn at destination).")

    -- Part B
    S = {ctx = ctx, arrivals = 0}
    if A and B then
      local train = loco1.train
      train.schedule = {current = 1, records = {
        {station = "SPIKE-A", wait_conditions = {{type = "time", ticks = 120, compare_type = "and"}}},
        {station = "SPIKE-B", wait_conditions = {{type = "time", ticks = 120, compare_type = "and"}}},
      }}
      train.manual_mode = false
      ctx.after(60 * 40, function()
        ctx.check("train reached >= 2 stations in 40s", S.arrivals >= 2, S.arrivals .. " arrivals")
        ctx.probe("coach destroyed with data attached - event?", function() return "design: on_object_destroyed(wagon) must return/kill abstract colonists" end)
        ctx.finish()
      end)
    else
      ctx.finish()
    end
  end,
})
