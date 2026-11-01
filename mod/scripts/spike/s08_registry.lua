-- SPIKE #8: Opt-in machine registry: gui.relative coverage, blueprint tag round-trip, paste/clone/destroy cleanup, dispatcher cost.
-- /spike run s08_registry [machines=5000] [seconds=10]
-- Interactive after run: open an assembler/furnace/lab/turret/boiler -> checkbox docked right. Tick it, copy into a blueprint, place it, copy/paste settings, clone.
local core = require("scripts.spike.core")
local events = require("scripts.events")

local S
local GUI_FOR_TYPE = {
  ["assembling-machine"] = "assembling_machine_gui", ["furnace"] = "furnace_gui",
  ["lab"] = "lab_gui", ["ammo-turret"] = "turret_gui", ["boiler"] = "boiler_gui",
  ["generator"] = "generator_gui", ["reactor"] = "reactor_gui",
}
local TAG = "colony_optin"

local function register(e)
  S.machines[e.unit_number] = e
  script.register_on_object_destroyed(e)
  rendering.draw_sprite{sprite = "utility/warning_icon", target = e, surface = e.surface, only_in_alt_mode = true,
    x_scale = 0.4, y_scale = 0.4}
end

events.on(defines.events.on_gui_opened, function(ev)
  if not S then return end
  local e = ev.entity
  if not (e and e.valid and ev.gui_type == defines.gui_type.entity) then return end
  local gui_name = GUI_FOR_TYPE[e.type]
  local player = game.get_player(ev.player_index)
  local old = player.gui.relative["colony_optin_frame"]
  if old then old.destroy() end
  local gt = gui_name and defines.relative_gui_type[gui_name]
  if not gt then S.ctx.log("[FAIL] no relative_gui_type for entity type " .. e.type .. " (gui=" .. tostring(gui_name) .. ")") return end
  local frame = player.gui.relative.add{type = "frame", name = "colony_optin_frame",
    anchor = {gui = gt, position = defines.relative_gui_position.right}}
  frame.add{type = "checkbox", name = "colony_optin_cb", caption = "Colony Direct Service", state = S.machines[e.unit_number] ~= nil}
  S.opened[ev.player_index] = e
end)

events.on(defines.events.on_gui_checked_state_changed, function(ev)
  if not (S and ev.element.name == "colony_optin_cb") then return end
  local e = S.opened[ev.player_index]
  if not (e and e.valid) then return end
  if ev.element.state then register(e) else S.machines[e.unit_number] = nil end
  S.ctx.log("toggle " .. e.name .. " -> " .. tostring(ev.element.state) .. " registry size " .. table_size(S.machines))
end)

events.on(defines.events.on_player_setup_blueprint, function(ev)
  if not S then return end
  local player = game.get_player(ev.player_index)
  local stack = ev.stack
  if not (stack and stack.valid_for_read) then stack = player.blueprint_to_setup end
  if not (stack and stack.valid_for_read) then stack = player.cursor_stack end
  if not (stack and stack.valid_for_read and stack.is_blueprint) then S.ctx.log("[ERR] no blueprint stack found in setup event") return end
  local n = 0
  for idx, ent in pairs(ev.mapping.get()) do
    if ent.valid and S.machines[ent.unit_number] then stack.set_blueprint_entity_tag(idx, TAG, true); n = n + 1 end
  end
  S.ctx.log("blueprint setup: tagged " .. n .. " opted-in entities")
end)

local function on_tagged_build(ev, label)
  if not S then return end
  local e = ev.entity or ev.created_entity
  local tags = ev.tags
  if e and e.valid and tags and tags[TAG] then
    register(e)
    S.ctx.log(label .. ": restored opt-in from tags on " .. e.name)
  end
end
events.on(defines.events.on_built_entity, function(ev) on_tagged_build(ev, "on_built_entity") end)
events.on(defines.events.on_robot_built_entity, function(ev) on_tagged_build(ev, "on_robot_built_entity") end)
events.on(defines.events.script_raised_revive, function(ev) on_tagged_build(ev, "script_raised_revive") end)

events.on(defines.events.on_entity_settings_pasted, function(ev)
  if not S then return end
  S.ctx.log("settings pasted " .. ev.source.name .. " -> " .. ev.destination.name .. " (does NOT carry opt-in unless we copy it)")
  if S.machines[ev.source.unit_number] then register(ev.destination) else S.machines[ev.destination.unit_number] = nil end
end)
events.on(defines.events.on_entity_cloned, function(ev)
  if not S then return end
  if S.machines[ev.source.unit_number] then register(ev.destination); S.ctx.log("clone: copied opt-in") end
end)
events.on(defines.events.on_object_destroyed, function(ev)
  if S and ev.useful_id and S.machines[ev.useful_id] then S.machines[ev.useful_id] = nil end
end)

events.on(defines.events.on_tick, function(ev)
  if not (S and S.bench) then return end
  local p = core.mkprof()
  local list = S.list
  for _ = 1, 10 do
    S.cursor = S.cursor + 1
    if S.cursor > #list then S.cursor = 1 end
    local m = list[S.cursor]
    if m and m.valid then
      local inv = m.get_inventory(defines.inventory.crafter_input)
      if inv and inv.is_empty() then m.insert{name = "iron-plate", count = 1} end
      S.work = S.work + 1
    end
  end
  p.stop(); S.acc.add(p); S.ticks = S.ticks + 1
  if ev.tick >= S.end_tick then
    S.bench = false
    S.acc.divide(S.ticks)
    S.ctx.log({"", "[PROF] dispatcher (10 machines/tick, ", #list, " registered) avg/tick: ", S.acc})
    S.ctx.log("machines processed: " .. S.work)
    S.ctx.finish()
  end
end)

core.register("s08_registry", {
  issue = 8, auto = false, desc = "opt-in registry: gui.relative, blueprint tags, cost", usage = "[machines=5000] [seconds=10]",
  run = function(ctx)
    S = {ctx = ctx, machines = {}, opened = {}, list = {}, cursor = 0, work = 0, ticks = 0, acc = core.mkprof()}
    S.acc.stop()
    local keys = {}
    for k in pairs(defines.relative_gui_type) do keys[#keys + 1] = k end
    table.sort(keys)
    ctx.log("defines.relative_gui_type:", table.concat(keys, ","))
    for t, g in pairs(GUI_FOR_TYPE) do
      ctx.check("relative gui exists for " .. t, defines.relative_gui_type[g] ~= nil, g)
    end
    local n, secs = tonumber(ctx.args[1]) or 5000, tonumber(ctx.args[2]) or 10
    local side = math.ceil(math.sqrt(n))
    local half = side * 3 / 2 + 2
    ctx.position = {x = ctx.position.x, y = ctx.position.y}
    ctx.flat_area(math.ceil(half))
    local p, count = ctx.position, 0
    local f = game.forces.player
    for i = 0, n - 1 do
      local x, y = (i % side) * 3 - half + 1.5 + p.x, math.floor(i / side) * 3 - half + 1.5 + p.y
      local am = ctx.surface.create_entity{name = "assembling-machine-1", position = {x, y}, force = f}
      if am then
        am.set_recipe("iron-gear-wheel")
        S.list[#S.list + 1] = am; S.machines[am.unit_number] = am; count = count + 1
      end
    end
    ctx.check("created " .. n .. " test machines", count == n, count)
    S.bench = true; S.end_tick = game.tick + secs * 60
    ctx.log("INTERACTIVE: also open an entity near spawn: boiler / lab / gun-turret / furnace to verify checkbox + blueprint round-trip. See [FAIL] lines for missing GUI types.")
  end,
})
