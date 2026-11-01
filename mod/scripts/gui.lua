-- Relative GUIs: (1) household panel on houses (needs/stock/occupants), (2) opt-in "colonist supply" panel on vanilla machines.
-- Thin adapter; rules live in model/housing.lua. Machine requests are stored on colony.machines[unit_number].
local events = require("scripts.events")
local scheduler = require("scripts.scheduler")
local territory = require("scripts.territory")
local housing = require("scripts.model.housing")
local labour = require("scripts.model.labour")
local work = require("scripts.work")
local M = {}
local colony_mod   -- injected via M.bind (runtime require is illegal)
function M.bind(c) colony_mod = c end

M.REQUEST_ROWS = 3
M.DEFAULT_COUNT = 20
local HOUSE_FRAME, MACHINE_FRAME, HUT_FRAME = "colony_house_frame", "colony_machine_frame", "colony_hut_frame"
local MACHINE_GUIS = {
  ["assembling-machine"] = "assembling_machine_gui", ["furnace"] = "furnace_gui", ["boiler"] = "boiler_gui", ["lab"] = "lab_gui",
}

local function colony_at(e) local id = territory.owner_at(e.surface.index, e.position); return id and storage.colonies[id] end

-- ---------- household panel ----------
local function fill_house(frame, h)
  frame.clear()
  local tier = housing.TIERS[h.kind]
  local stock = colony_mod.house_stock(h)
  local powered = colony_mod.is_powered(h)
  frame.add{type = "label", caption = {"colony-gui.occupants", h.occupants or 0, tier.capacity}}
  for _, need in ipairs(tier.needs) do
    local ok = h.sat and h.sat[need.id]
    local line = frame.add{type = "flow", direction = "horizontal"}
    line.add{type = "label", caption = {"colony-gui.need-" .. need.id}, style = "bold_label"}
    line.add{type = "label", caption = ok == nil and "-" or (ok and "[color=green]OK[/color]" or "[color=red]MISSING[/color]")}
    local parts = {}
    for _, opt in ipairs(need.options) do
      if opt.power then parts[#parts + 1] = powered and "[color=green]powered[/color]" or "[color=gray]no power[/color]"
      else parts[#parts + 1] = string.format("[item=%s] %d (%.1f/colonist)", opt.item, stock[opt.item] or 0, opt.per) end
    end
    frame.add{type = "label", caption = "    " .. table.concat(parts, "  |  ")}
  end
  local demand = housing.demand(tier, stock, h.inflight, powered)
  if #demand == 0 then frame.add{type = "label", caption = {"colony-gui.fully-stocked"}}
  else
    local want = {}
    for _, d in ipairs(demand) do want[#want + 1] = string.format("[item=%s] %d", d.item, d.count) end
    frame.add{type = "label", caption = {"", {"colony-gui.requesting"}, " ", table.concat(want, "  ")}}
  end
  frame.add{type = "label", caption = {"colony-gui.house-hint"}}
end

local function open_house(player, e)
  local old = player.gui.relative[HOUSE_FRAME]; if old then old.destroy() end
  local colony = colony_at(e)
  local h = colony and colony.houses[e.unit_number]
  if not h then return end
  local frame = player.gui.relative.add{type = "frame", name = HOUSE_FRAME, direction = "vertical",
    caption = {"colony-gui.household"}, anchor = {gui = defines.relative_gui_type.container_gui,
      position = defines.relative_gui_position.right, names = {"colony-housing-tent", "colony-housing-cabin"}}}
  local body = frame.add{type = "flow", name = "body", direction = "vertical"}
  fill_house(body, h)
  scheduler.after(30, "gui.refresh_house", {player_index = player.index, un = e.unit_number, colony_id = colony.id})
end

scheduler.register("gui.refresh_house", function(d)
  local player = game.get_player(d.player_index)
  local frame = player and player.valid and player.gui.relative[HOUSE_FRAME]
  local e = player and player.opened
  if not (frame and frame.valid and frame.visible and e and e.valid and e.unit_number == d.un) then return end
  local colony = storage.colonies[d.colony_id]
  local h = colony and colony.houses[d.un]
  if not h then return end
  fill_house(frame.body, h)
  scheduler.after(30, "gui.refresh_house", d)
end)

-- ---------- labour hut panel ----------
local function fill_hut(frame, h)
  frame.clear()
  local def, tools, allowed, workers = work.hut_info(h)
  frame.add{type = "label", caption = {"colony-gui-hut.workers", workers, allowed}}
  frame.add{type = "label", caption = {"colony-gui-hut.tools", tools}}
  frame.add{type = "label", caption = {"colony-gui-hut.tool-need", def.tool}}
  if def.capacity > tools then
    local want = def.capacity - tools - (h.inflight[def.tool] or 0)
    if want > 0 then
      frame.add{type = "label", caption = string.format("Colonists will deliver: [item=%s] %d", def.tool, want)}
    end
  end
end

local function open_hut(player, e)
  local old = player.gui.relative[HUT_FRAME]; if old then old.destroy() end
  local colony = colony_at(e)
  local h = colony and colony.huts[e.unit_number]
  if not h then return end
  local hut_names = {}
  for name in pairs(labour.HUTS) do hut_names[#hut_names + 1] = name end
  local frame = player.gui.relative.add{type = "frame", name = HUT_FRAME, direction = "vertical",
    caption = e.localised_name, anchor = {gui = defines.relative_gui_type.container_gui,
      position = defines.relative_gui_position.right, names = hut_names}}
  local body = frame.add{type = "flow", name = "body", direction = "vertical"}
  fill_hut(body, h)
  scheduler.after(30, "gui.refresh_hut", {player_index = player.index, un = e.unit_number, colony_id = colony.id})
end

scheduler.register("gui.refresh_hut", function(d)
  local player = game.get_player(d.player_index)
  local frame = player and player.valid and player.gui.relative[HUT_FRAME]
  local e = player and player.opened
  if not (frame and frame.valid and frame.visible and e and e.valid and e.unit_number == d.un) then return end
  local colony = storage.colonies[d.colony_id]
  local h = colony and colony.huts[d.un]
  if not h then return end
  fill_hut(frame.body, h)
  scheduler.after(30, "gui.refresh_hut", d)
end)

-- ---------- machine supply panel ----------
local function recipe_requests(e)
  local out = {}
  local recipe = e.type == "assembling-machine" and e.get_recipe()
  if recipe then
    for _, ing in ipairs(recipe.ingredients) do
      if ing.type == "item" and #out < M.REQUEST_ROWS then out[#out + 1] = {item = ing.name, count = math.max(ing.amount * 5, 5)} end
    end
  end
  return out
end

local function fill_machine(frame, m, e)
  frame.clear()
  frame.add{type = "checkbox", name = "colony_supply_enabled", state = m ~= nil and m.enabled or false,
    caption = {"colony-gui.supply-enable"}, tooltip = {"colony-gui.supply-enable-tt"}}
  if not (m and m.enabled) then return end
  frame.add{type = "label", caption = {"colony-gui.supply-rows"}}
  for i = 1, M.REQUEST_ROWS do
    local req = m.requests[i]
    local row = frame.add{type = "flow", direction = "horizontal"}
    row.style.vertical_align = "center"
    row.add{type = "choose-elem-button", name = "colony_req_item_" .. i, elem_type = "item", item = req and req.item}
    local tf = row.add{type = "textfield", name = "colony_req_count_" .. i, text = req and tostring(req.count) or "",
      numeric = true, allow_decimal = false, allow_negative = false}
    tf.style.width = 60
    row.add{type = "label", caption = {"colony-gui.supply-keep"}}
  end
  frame.add{type = "checkbox", name = "colony_supply_collect", state = m.collect, caption = {"colony-gui.supply-collect"},
    tooltip = {"colony-gui.supply-collect-tt"}}
end

local function open_machine(player, e)
  local old = player.gui.relative[MACHINE_FRAME]; if old then old.destroy() end
  local gui_name = MACHINE_GUIS[e.type]
  local gt = gui_name and defines.relative_gui_type[gui_name]
  if not gt then return end
  local frame = player.gui.relative.add{type = "frame", name = MACHINE_FRAME, direction = "vertical",
    caption = {"colony-gui.supply-title"}, anchor = {gui = gt, position = defines.relative_gui_position.right}}
  local body = frame.add{type = "flow", name = "body", direction = "vertical"}
  local colony = colony_at(e)
  if not colony then body.add{type = "label", caption = {"colony-gui.supply-outside"}}; return end
  fill_machine(body, colony.machines[e.unit_number], e)
end

events.on(defines.events.on_gui_opened, function(ev)
  local player = game.get_player(ev.player_index)
  local e = ev.entity
  if not (player and e and e.valid and ev.gui_type == defines.gui_type.entity) then return end
  if colony_mod.HOUSES[e.name] then open_house(player, e)
  elseif labour.HUTS[e.name] then open_hut(player, e)
  elseif MACHINE_GUIS[e.type] then open_machine(player, e) end
end)

local function machine_ctx(ev)
  local player = game.get_player(ev.player_index)
  local e = player and player.opened
  if not (e and e.valid and player.opened_gui_type == defines.gui_type.entity) then return end
  local colony = colony_at(e)
  if not colony then return end
  local frame = player.gui.relative[MACHINE_FRAME]
  return player, e, colony, frame and frame.body
end

events.on(defines.events.on_gui_checked_state_changed, function(ev)
  local name = ev.element.name
  if name ~= "colony_supply_enabled" and name ~= "colony_supply_collect" then return end
  local player, e, colony, body = machine_ctx(ev)
  if not body then return end
  local m = colony.machines[e.unit_number]
  if name == "colony_supply_enabled" then
    if ev.element.state then
      m = m or {entity = e, requests = recipe_requests(e), collect = true, inflight = {}}
      m.enabled = true; colony.machines[e.unit_number] = m
    elseif m then m.enabled = false end
    fill_machine(body, m, e)
  elseif m then m.collect = ev.element.state end
end)

local function row_of(name) return tonumber(name:match("^colony_req_%a+_(%d+)$")) end

events.on(defines.events.on_gui_elem_changed, function(ev)
  local i = row_of(ev.element.name)
  if not (i and ev.element.name:find("colony_req_item_", 1, true)) then return end
  local _, e, colony = machine_ctx(ev)
  local m = colony and colony.machines[e.unit_number]
  if not m then return end
  local item = ev.element.elem_value
  if not item then m.requests[i] = nil
  else m.requests[i] = {item = item, count = m.requests[i] and m.requests[i].count or M.DEFAULT_COUNT} end
  local frame = game.get_player(ev.player_index).gui.relative[MACHINE_FRAME]
  if frame then fill_machine(frame.body, m, e) end
end)

events.on(defines.events.on_gui_text_changed, function(ev)
  local i = row_of(ev.element.name)
  if not (i and ev.element.name:find("colony_req_count_", 1, true)) then return end
  local _, e, colony = machine_ctx(ev)
  local m = colony and colony.machines[e.unit_number]
  local req = m and m.requests[i]
  if req then req.count = tonumber(ev.element.text) or 0 end
end)

return M
