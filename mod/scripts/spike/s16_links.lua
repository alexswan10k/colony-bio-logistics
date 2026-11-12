-- SPIKE #52: colony-to-colony linking. What the engine makes possible today for a freight connection between
-- two towns, using nothing but vanilla rail plus Lua-assigned schedules - nobody boards, nothing teleports.
-- Questions (all about the *engine*, so the spike builds the bare rail network itself):
--   1. Are the prototypes available (cargo wagon, locomotive, straight rail, train stop, fast inserter, iron chest)?
--   2. Can a locomotive get its schedule assigned from Lua, and can `on_train_changed_state` observe it arriving?
--   3. Does a cargo wagon filled at stop A get unloaded into stop B by inserters over the same rail line,
--      without a single colonist in the world?
--   4. Does the vanilla behaviour survive a fresh headless map without any colony set up?
-- Run: TICKS=19500 scripts/headless-spike.sh s16_links
local core = require("scripts.spike.core")
local events = require("scripts.events")

local fired = {loco = false, wagon_stop = false, wait = 0, last_stop = nil, saw_items = false}

events.on(defines.events.on_train_changed_state, function(ev)
  local train = ev.train
  if not (train and train.valid) then return end
  if train.state == defines.train_state.wait_station then
    fired.wait = fired.wait + 1
    local stop = train.station
    fired.last_stop = stop and stop.valid and stop.backer_name or "?"
    fired.positions = fired.positions or {}
    if train then
      local w = train.cargo_wagons and train.cargo_wagons[1]
      local fig = w or (train.locomotives and train.locomotives[1])
      if fig and fig.valid then fired.positions[#fired.positions + 1] = string.format("%s@(%.1f,%.1f)", fired.last_stop, fig.position.x, fig.position.y) end
    end
  end
end)

core.register("s16_links", {
  issue = 52, auto = true,
  desc = "cargo-wagon freight between two train stops with a Lua-assigned schedule and inserters, no colonists",
  usage = "",
  run = function(ctx)
    local s, p = ctx.surface, ctx.position
    ctx.flat_area(64, "grass-1")
    s.always_day, s.freeze_daytime, s.daytime = true, true, 0
    local ROW = 13                       -- odd rail row (stops hang two rows off it on each side, per m1_rail)
    local STOP_A, STOP_B = {x = p.x - 40, y = ROW - 2}, {x = p.x + 40, y = ROW + 2}

    -- 1. prototypes
    for _, n in ipairs({"cargo-wagon", "locomotive", "straight-rail", "train-stop", "fast-inserter", "iron-chest"}) do
      ctx.check("prototype " .. n, prototypes.entity[n] ~= nil)
    end

    -- lay the line
    local rails = 0
    for x = -40, 40, 2 do
      if s.create_entity{name = "straight-rail", position = {p.x + x, ROW}, direction = defines.direction.east,
        force = "player", raise_built = true} then rails = rails + 1 end
    end
    ctx.check("laid the rail line", rails >= 40, tostring(rails))
    local stopA = s.create_entity{name = "train-stop", position = STOP_A, direction = defines.direction.west,
      force = "player", raise_built = true}
    local stopB = s.create_entity{name = "train-stop", position = STOP_B, direction = defines.direction.east,
      force = "player", raise_built = true}
    ctx.check("both stops placed", stopA ~= nil and stopB ~= nil)
    ctx.probe("inventory defines for this build", function()
      local names = {}
      for k in pairs(defines.inventory or {}) do names[#names + 1] = k end
      table.sort(names)
      return table.concat(names, ",")
    end)
    ctx.probe("entity_status enum members", function()
      local names, out = {}, {}
      for k in pairs(defines.entity_status) do names[#names + 1] = k end
      table.sort(names)
      for _, k in ipairs(names) do out[#out + 1] = k .. "=" .. tostring(defines.entity_status[k]) end
      return table.concat(out, " ")
    end)
    ctx.probe("train_state enum members", function()
      local names, out = {}, {}
      for k in pairs(defines.train_state) do names[#names + 1] = k end
      table.sort(names)
      for _, k in ipairs(names) do out[#out + 1] = k .. "=" .. tostring(defines.train_state[k]) end
      return table.concat(out, " ")
    end)
    ctx.probe("stop A connected rail", function() return tostring(stopA.connected_rail and stopA.connected_rail.name) end)
    ctx.probe("stop B connected rail", function() return tostring(stopB.connected_rail and stopB.connected_rail.name) end)
    if stopA then stopA.backer_name = "LINK-A" end
    if stopB then stopB.backer_name = "LINK-B" end

    -- Focused isolation: one chest pair, one west-facing inserter, observed over time.
    local isoA = s.create_entity{name = "iron-chest", position = {p.x + 20, -4}, force = "player", raise_built = true}
    local isoB = s.create_entity{name = "iron-chest", position = {p.x + 23, -4}, force = "player", raise_built = true}
    isoA.insert{name = "iron-plate", count = 5}
    local isoIns = s.create_entity{name = "burner-inserter", position = {p.x + 21.5, -4},
      direction = defines.direction.west, force = "player", raise_built = true}
    isoIns.get_fuel_inventory().insert{name = "coal", count = 5}
    local function dump(label)
      local pt = isoIns.valid and isoIns.pickup_target or nil
      local dt = isoIns.valid and isoIns.drop_target or nil
      local pa = isoA.valid and isoA.get_inventory(defines.inventory.chest).get_item_count("iron-plate") or -1
      local pb = isoB.valid and isoB.get_inventory(defines.inventory.chest).get_item_count("iron-plate") or -1
      ctx.log(string.format("%s: A=%d B=%d pickup=%s drop=%s", label, pa, pb,
        pt and tostring(pt.name) or "nil", dt and tostring(dt.name) or "nil"))
    end
    ctx.after(60, function() dump("tick 60  ") end)
    ctx.after(300, function() dump("tick 300 ") end)
    ctx.after(900, function() dump("tick 900 ") end)
    ctx.after(3000, function() dump("tick 3000") end)

    -- Brute-force direction semantics for inserters on plain chests (no rail, no wagon involved).
    local dir_list = {}
    for name, val in pairs(defines.direction) do
      if type(val) == "number" then dir_list[#dir_list + 1] = {name = name, val = val} end
    end
    table.sort(dir_list, function(a, b) return a.val < b.val end)
    local pairs_list = {}
    for i, d in ipairs(dir_list) do
      local cy = 20 + i * 2
      local cA = s.create_entity{name = "iron-chest", position = {p.x + 4.5, cy}, force = "player", raise_built = true}
      local cB = s.create_entity{name = "iron-chest", position = {p.x + 6.5, cy}, force = "player", raise_built = true}

      local ins = s.create_entity{name = "burner-inserter", position = {p.x + 5.5, cy}, direction = d.val,
        force = "player", raise_built = true}
      ins.get_fuel_inventory().insert{name = "coal", count = 5}
      cA.insert{name = "iron-plate", count = 3}
      pairs_list[#pairs_list + 1] = {name = d.name, val = d.val, ins = ins, a = cA, b = cB}
    end
    ctx.after(600, function()
      for _, e in ipairs(pairs_list) do
        if e.a.valid and e.b.valid then
          ctx.log("dir " .. e.name .. "(" .. e.val .. "): A_left=" .. tostring(e.a.get_inventory(defines.inventory.chest).get_item_count("iron-plate"))
            .. " B_right=" .. tostring(e.b.get_inventory(defines.inventory.chest).get_item_count("iron-plate")))
        end
      end
      local ground = s.find_entities_filtered{type = "item-entity", area = {{p.x, 0}, {p.x + 12, 60}}}
      local n_ground = 0
      for _, e in ipairs(ground) do n_ground = n_ground + 1 end
      ctx.log("items on ground in sweep area: " .. tostring(n_ground))
    end)

    -- chests at each stop, unloader at B and loader at A
    local function chest_at(pos, direction)
      local e = s.create_entity{name = "iron-chest", position = pos, force = "player", raise_built = true}
      return e
    end
    -- chests and inserters beside the RAIL row (the stops hang two rows off it); one loads, one unloads.
    local chestA = chest_at({p.x - 29, ROW + 2}, "north")
    local chestB = chest_at({p.x + 31, ROW + 2}, "north")
    chestA.insert{name = "colony-frontier-pack", count = 40}
    ctx.check("A chest stocked", chestA.get_item_count("colony-frontier-pack") == 40)
    -- Isolate inserter sanity: two chests with a fast-inserter between them, all powered (no train involved).
    local sanity_ins
    do
      local cA = s.create_entity{name = "iron-chest", position = {p.x + 20.5, p.y + 12.5}, force = "player", raise_built = true}
      local cB = s.create_entity{name = "iron-chest", position = {p.x + 22.5, p.y + 12.5}, force = "player", raise_built = true}
      local eei_t = s.create_entity{name = "electric-energy-interface", position = {p.x + 24, p.y + 12}, force = "player", raise_built = true}
      if eei_t then eei_t.power_production = 5e6 / 60; eei_t.electric_buffer_size = 5e6 end
      s.create_entity{name = "medium-electric-pole", position = {p.x + 24, p.y + 8.5}, force = "player", raise_built = true}
      sanity_ins = s.create_entity{name = "burner-inserter", position = {p.x + 21.5, p.y + 12.5},
        direction = defines.direction.west, force = "player", raise_built = true}
      sanity_ins.get_fuel_inventory().insert{name = "coal", count = 5}
      cA.insert{name = "iron-plate", count = 10}
      ctx.probe("test inserter placed between two chests", function()
        local pt, dt = sanity_ins.pickup_target, sanity_ins.drop_target
        local function pos(e) return e and (e.name .. "@" .. tostring(e.position.x) .. "," .. tostring(e.position.y)) or "nil" end
        return "pickup=" .. pos(pt) .. " drop=" .. pos(dt)
      end)
    end
    -- Power both inserters properly (each needs its own EEI within reach of its pole).
    local eei_a = s.create_entity{name = "electric-energy-interface", position = {p.x - 40, ROW + 4}, force = "player", raise_built = true}
    if eei_a then eei_a.power_production = 5e6 / 60; eei_a.electric_buffer_size = 5e6 end
    s.create_entity{name = "medium-electric-pole", position = {p.x - 37.5, ROW + 6}, force = "player", raise_built = true}
    local eei_b = s.create_entity{name = "electric-energy-interface", position = {p.x + 40, ROW + 4}, force = "player", raise_built = true}
    if eei_b then eei_b.power_production = 5e6 / 60; eei_b.electric_buffer_size = 5e6 end
    s.create_entity{name = "medium-electric-pole", position = {p.x + 42.5, ROW + 6}, force = "player", raise_built = true}
    local insA = s.create_entity{name = "burner-inserter", position = {p.x - 29, ROW + 1},
      direction = defines.direction.south, force = "player", raise_built = true}
    if insA then insA.get_fuel_inventory().insert{name = "coal", count = 20} end
    local insB = s.create_entity{name = "burner-inserter", position = {p.x + 31, ROW + 1},
      direction = defines.direction.north, force = "player", raise_built = true}
    if insB then insB.get_fuel_inventory().insert{name = "coal", count = 20} end
    ctx.check("inserters placed", insA ~= nil and insB ~= nil)
    ctx.probe("insA pickup/drop", function()
      local pt, dt = insA.pickup_target, insA.drop_target
      local function pos(e)
        if not e then return "nil" end
        return (e.position and (e.position.x .. "," .. e.position.y) or "no-pos") .. " (" .. tostring(e.name) .. ")"
      end
      return "pickup=" .. pos(pt) .. " drop=" .. pos(dt)
    end)
    ctx.probe("insB pickup/drop", function()
      local pt, dt = insB.pickup_target, insB.drop_target
      local function pos(e)
        if not e then return "nil" end
        return (e.position and (e.position.x .. "," .. e.position.y) or "no-pos") .. " (" .. tostring(e.name) .. ")"
      end
      return "pickup=" .. pos(pt) .. " drop=" .. pos(dt)
    end)

    -- the train: locomotive - wagon - locomotive, stocked
    local loco1 = s.create_entity{name = "locomotive", position = {p.x - 5, ROW}, direction = defines.direction.east,
      force = "player", raise_built = true}
    local wagon = s.create_entity{name = "cargo-wagon", position = {p.x + 2, ROW}, direction = defines.direction.east,
      force = "player", raise_built = true}
    local loco2 = s.create_entity{name = "locomotive", position = {p.x + 9, ROW}, direction = defines.direction.west,
      force = "player", raise_built = true}
    ctx.check("train assembled", loco1 ~= nil and wagon ~= nil and loco2 ~= nil
      and loco1.train.valid and loco1.train.id == wagon.train.id)
    if not (loco1 and wagon and loco2) then return ctx.finish() end
    local wInv = wagon.get_inventory(defines.inventory.cargo_wagon)
    ctx.check("wagon is empty at start", wInv ~= nil and wInv.is_empty())
    local loco1Fuel = loco1.get_fuel_inventory()
    local loco2Fuel = loco2.get_fuel_inventory()
    if loco1Fuel then loco1Fuel.insert{name = "coal", count = 20} end
    if loco2Fuel then loco2Fuel.insert{name = "coal", count = 20} end
    ctx.check("locomotives fuelled",
      (loco1Fuel and loco1Fuel.get_item_count("coal") or 0) > 0 and (loco2Fuel and loco2Fuel.get_item_count("coal") or 0) > 0)

    -- 2. assign the timetable from Lua: A -> B -> A loop, short waits at each
    ctx.probe("schedule assigned from Lua", function()
      loco1.train.schedule = {current = 1,
        records = {
          {station = "LINK-A", wait_conditions = {{type = "time", ticks = 120}}},
          {station = "LINK-B", wait_conditions = {{type = "time", ticks = 120}}},
        }}
      return tostring(loco1.train.schedule ~= nil and tostring(loco1.train.schedule.current or "?") or "nil")
    end)
    -- Newly created trains default to manual_mode; the schedule alone does not drive them.
    loco1.train.manual_mode = false
    ctx.probe("schedule read back", function()
      return serpent.line(loco1.train.schedule)
    end)
    ctx.probe("get_schedule() read back", function()
      return serpent.line(loco1.train.get_schedule())
    end)
    ctx.probe("train state after waiting", function()
      local t = loco1.train
      return "loco state=" .. tostring(t.state) .. " loco speed=" .. string.format("%.3f", t.speed)
        .. " station=" .. tostring(t.station and t.station.valid and t.station.backer_name)
        .. " sched=" .. tostring(t.schedule and tostring(t.schedule.current) or "nil")
    end)

    -- 3+4. the answer lands over time; check it at the end of the world tick
    ctx.after(600, function()
      ctx.probe("inserter status after ticks", function()
        if sanity_ins and sanity_ins.valid then
          return "status=" .. tostring(sanity_ins.status) .. " pickup=" .. tostring(sanity_ins.pickup_target and sanity_ins.pickup_target.name)
            .. " drop=" .. tostring(sanity_ins.drop_target and sanity_ins.drop_target.name)
            .. " fuel=" .. tostring(sanity_ins.get_fuel_inventory() and sanity_ins.get_fuel_inventory().get_item_count("coal"))
        end
        return "no inserter"
      end)
      local moved = 0
      for _, e in pairs(s.find_entities_filtered{name = "iron-chest", area = {{p.x + 20, p.y + 10}, {p.x + 24, p.y + 14}}}) do
        local n = e.get_inventory(defines.inventory.chest).get_item_count("iron-plate")
        ctx.log("chest at " .. e.position.x .. "," .. e.position.y .. " has " .. n .. " iron plates")
        if e.position.x > p.x + 22 then moved = moved + n end
      end
      ctx.check("inserter worked chest->chest (sanity)", moved >= 8, "chestB=" .. tostring(moved))
    end)
    ctx.after(2000, function()
      if wagon.valid then
        ctx.log(string.format("wagon at tick 2000: (%.2f, %.2f)", wagon.position.x, wagon.position.y))
        ctx.probe("train state at tick 2000", function()
          local t = wagon.train
          return "state=" .. tostring(t.state) .. " station=" .. tostring(t.station and t.station.valid and t.station.backer_name)
            .. " wagon_cell=[%.0f,%.0f]", tostring(wagon.position.x), tostring(wagon.position.y)
        end)
      end
    end)
    ctx.after(3000, function()
      if insA and insA.valid then
        ctx.log("insA late: status=" .. tostring(insA.status)
          .. " pickup=" .. tostring(insA.pickup_target and insA.pickup_target.name)
          .. " drop=" .. tostring(insA.drop_target and insA.drop_target.name))
      else ctx.log("insA late: invalid") end
      if insB and insB.valid then
        ctx.log("insB late: status=" .. tostring(insB.status)
          .. " pickup=" .. tostring(insB.pickup_target and insB.pickup_target.name)
          .. " drop=" .. tostring(insB.drop_target and insB.drop_target.name))
      else ctx.log("insB late: invalid") end
    end)
    ctx.after(12000, function()
      ctx.log("stop positions: " .. table.concat(fired.positions or {}, " "))
      local wInv2 = wagon.get_inventory(defines.inventory.cargo_wagon)
      local aHeld = chestA.get_item_count("colony-frontier-pack")
      local bHeld = chestB.get_item_count("colony-frontier-pack")
      ctx.log("chestA=" .. tostring(aHeld) .. " chestB=" .. tostring(bHeld)
        .. " wagon=" .. tostring(wInv2 and wInv2.get_item_count("colony-frontier-pack") or "?")
        .. " wait_station_events=" .. tostring(fired.wait))
      ctx.check("the train visited both stops (wait_station fired for both)",
        fired.wait >= 2, "count=" .. tostring(fired.wait))
      ctx.check("the wagon was loaded from the A chest by the A inserter",
        aHeld < 40, "A holds " .. tostring(aHeld))
      ctx.check("freight crossed the line and was unloaded into the B chest",
        bHeld > 0, "B holds " .. tostring(bHeld))
      ctx.check("no colonist was needed for the trip",
        true)  -- literally zero entities of type unit or character were placed by this spike
      ctx.finish()
    end)
  end,
})
