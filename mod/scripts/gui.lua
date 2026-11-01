-- Relative GUIs: (1) household panel on houses (needs/stock/occupants), (2) opt-in "colonist supply" panel on vanilla machines.
-- Thin adapter; rules live in model/housing.lua. Machine requests are stored on colony.machines[unit_number].
local events = require("scripts.events")
local scheduler = require("scripts.scheduler")
local territory = require("scripts.territory")
local housing = require("scripts.model.housing")
local labour = require("scripts.model.labour")
local jobs = require("scripts.model.jobs")
local mine_plan = require("scripts.model.mine_plan")
local haul_plan = require("scripts.model.haul_plan")
local work = require("scripts.work")
local M = {}
local colony_mod   -- injected via M.bind (runtime require is illegal)
function M.bind(c) colony_mod = c end

M.REQUEST_ROWS = 3
M.DEFAULT_COUNT = 20
local HOUSE_FRAME, MACHINE_FRAME, HUT_FRAME, INFO_FRAME =
  "colony_house_frame", "colony_machine_frame", "colony_hut_frame", "colony_info_frame"
local MACHINE_GUIS = {
  ["assembling-machine"] = "assembling_machine_gui", ["furnace"] = "furnace_gui", ["boiler"] = "boiler_gui", ["lab"] = "lab_gui",
}
M.MACHINE_GUIS = MACHINE_GUIS   -- selection tool (#35) opts in exactly the machines that have a panel

local function colony_at(e) local id = territory.owner_at(e.surface.index, e.position); return id and storage.colonies[id] end

-- ---------- household panel ----------
-- Per-colonist job locks live on the house, not the Town Hall: a house lists only its own handful of
-- occupants, so the panel stays usable when a town grows to hundreds of colonists.
local LOCK_OPTS = {{"auto", "A"}, {"haul", "H"}, {"forage", "F"}, {"chop", "C"}, {"mine", "M"}, {"farm", "G"}}

local function fill_roster(pane, colony, ids)
  colony.locks = colony.locks or {}
  if #ids == 0 then
    pane.add{type = "label", caption = {"colony-gui-info.roster-empty"}}
    return
  end
  for i, un in ipairs(ids) do
    local st = storage.unit_state[un]
    local job = st and st.job or "idle"
    local row = pane.add{type = "flow", direction = "horizontal"}
    row.style.vertical_align = "center"
    local name = row.add{type = "label", caption = {"colony-gui-info.colonist", i, {"colony-gui-info.job-" .. job}}}
    name.style.width = 110
    local lock = colony.locks[un]
    for _, opt in ipairs(LOCK_OPTS) do
      local locked = (lock or "auto") == opt[1]
      local b = row.add{type = "button", name = "colony_lock_" .. un .. "_" .. opt[1],
        caption = locked and "[" .. opt[2] .. "]" or opt[2], tooltip = {"colony-gui-info.lock-" .. opt[1]}}
      b.style.width = 34
    end
  end
end

local function fill_house(frame, h, colony)
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
  local demand = housing.demand(tier, stock, h.inflight, powered, h.occupants or 0)
  if #demand == 0 then frame.add{type = "label", caption = {"colony-gui.fully-stocked"}}
  else
    local want = {}
    for _, d in ipairs(demand) do
      local names = {}
      for _, item in ipairs(haul_plan.demand_items(d)) do names[#names + 1] = "[item=" .. item .. "]" end
      want[#want + 1] = table.concat(names, "/") .. " " .. d.count
    end
    frame.add{type = "label", caption = {"", {"colony-gui.requesting"}, " ", table.concat(want, "  ")}}
  end
  frame.add{type = "label", caption = {"colony-gui.house-hint"}}
  frame.add{type = "line"}
  frame.add{type = "label", caption = {"colony-gui-info.roster"}, style = "bold_label"}
  local pane = frame.add{type = "scroll-pane", name = "roster", direction = "vertical"}
  pane.style.maximal_height = 140
  local households = colony_mod.households(colony)
  fill_roster(pane, colony, households[h.entity.unit_number] or {})
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
  fill_house(body, h, colony)
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
  fill_house(frame.body, h, colony)
  scheduler.after(30, "gui.refresh_house", d)
end)

-- ---------- labour hut panel ----------
-- While the panel is open, the hut's working radius is drawn in the world (the same idea as the Town
-- Hall's territory rectangle) so "why is nothing being harvested?" is answerable at a glance.
local function draw_hut_range(h)
  rendering.draw_circle{color = {0.9, 0.9, 0.3, 0.7}, width = 2, filled = false,
    radius = colony_mod.HUT_RADIUS, target = h.entity, surface = h.entity.surface, time_to_live = 60}
end

local function fill_hut(frame, h)
  frame.clear()
  local def, tools, allowed, workers = work.hut_info(h)
  frame.add{type = "label", caption = {"colony-gui-hut.workers", workers, allowed}}
  local limit = h.limit or def.capacity
  local row = frame.add{type = "flow", direction = "horizontal"}
  row.style.vertical_align = "center"
  row.add{type = "label", caption = {"colony-gui-hut.limit"}, style = "bold_label"}
  local less = row.add{type = "button", name = "colony_hut_limit_less", caption = "-",
    tooltip = {"colony-gui-hut.limit-tt"}}
  less.style.width = 24
  local val = row.add{type = "label", caption = tostring(limit)}
  val.style.width = 24
  val.style.horizontal_align = "center"
  local more = row.add{type = "button", name = "colony_hut_limit_more", caption = "+",
    tooltip = {"colony-gui-hut.limit-tt"}}
  more.style.width = 24
  frame.add{type = "label", caption = {"colony-gui-hut.range", colony_mod.HUT_RADIUS}}
  frame.add{type = "label", caption = {"colony-gui-hut.tools", tools}}
  if tools > 0 then
    frame.add{type = "label", caption = {"colony-gui-hut.condition", labour.uses_left(h.wear), labour.TOOL_USES}}
  end
  frame.add{type = "label", caption = {"colony-gui-hut.tool-need", def.tool}}
  if def.capacity > tools then
    local want = def.capacity - tools - (h.inflight[def.tool] or 0)
    if want > 0 then
      frame.add{type = "label", caption = {"colony-gui-hut.delivering", def.tool, want}}
    end
  end
  if h.job == "farm" then
    frame.add{type = "label", caption = {"colony-gui-hut.farm-hint"}}
  end
  if h.job == "mine" then
    -- Ore priority (#74): which rock this hut goes for first, instead of always the closest one.
    frame.add{type = "line"}
    frame.add{type = "label", caption = {"colony-gui-hut.ore-priority"}, style = "bold_label"}
    local ranks = mine_plan.effective(h.ores)
    for _, ore in ipairs(mine_plan.ORES) do
      local row = frame.add{type = "flow", direction = "horizontal"}
      row.style.vertical_align = "center"
      local name = row.add{type = "label", caption = "[item=" .. ore .. "]"}
      name.style.width = 96
      row.add{type = "button", name = "colony_ore_" .. ore .. "_more", caption = "+",
        tooltip = {"colony-gui-hut.ore-more-tt"}}
      local rank = row.add{type = "label", caption = ranks[ore] > 0 and tostring(ranks[ore]) or {"colony-gui-info.off"}}
      rank.style.width = 24
      rank.style.horizontal_align = "center"
      row.add{type = "button", name = "colony_ore_" .. ore .. "_less", caption = "-",
        tooltip = {"colony-gui-hut.ore-less-tt"}}
    end
    frame.add{type = "label", caption = {"colony-gui-hut.ore-hint"}}
  end
  local sites = work.site_count(h)
  if sites == 0 then
    frame.add{type = "label", caption = {"colony-gui-hut.no-sites"}}
  else
    frame.add{type = "label", caption = {"colony-gui-hut.sites", sites}}
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
  draw_hut_range(h)
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
  draw_hut_range(h)
  scheduler.after(30, "gui.refresh_hut", d)
end)

-- ---------- colony overview + priority matrix (#38 #27) ----------
local function pct(x) return string.format("%.0f%%", math.min(math.max(x, 0), 9.99) * 100) end

local function fill_info(frame, colony)
  frame.clear()
  local st = colony_mod.stats(colony)
  local counts = work.job_counts(colony)
  local busy = 0
  for _, job in ipairs(jobs.JOBS) do busy = busy + (counts[job] or 0) end

  frame.add{type = "label", caption = {"colony-gui-info.population", st.pop, st.capacity}}
  frame.add{type = "label", caption = {"colony-gui-info.housing", st.tents, st.cabins, math.max(st.capacity - st.pop, 0)}}
  local colour = st.food_ratio < 0.5 and "red" or (st.food_ratio < 1 and "orange" or "green")
  frame.add{type = "label", caption = {"", {"colony-gui-info.food", st.food, st.food_target},
    "  [color=" .. colour .. "]" .. pct(st.food_ratio) .. "[/color]"}}
  local parts = st.parts
  frame.add{type = "label", caption = {"colony-gui-info.desirability", string.format("%.2f", st.d)}}
  frame.add{type = "label", caption = {"colony-gui-info.desirability-parts",
    string.format("%.2f", parts.food or 0), string.format("%.2f", parts.housing or 0),
    string.format("%.2f", parts.scenic or 0), string.format("%.2f", parts.leisure or 0),
    string.format("%.2f", parts.pollution or 0), string.format("%.2f", parts.deaths or 0)}}
  frame.add{type = "label", caption = {"colony-gui-info.jobs",
    counts.haul or 0, counts.forage or 0, counts.chop or 0, counts.mine or 0, math.max(st.pop - busy, 0)}}
  frame.add{type = "label", caption = {"colony-gui-info.territory", st.chunks, st.huts, st.machines, st.towers}}

  frame.add{type = "line"}
  frame.add{type = "checkbox", name = "colony_accept_migrants", state = colony.accept_migrants ~= false,
    caption = {"colony-gui-info.accept-migrants"}, tooltip = {"colony-gui-info.accept-migrants-tt"}}
  local cap_row = frame.add{type = "flow", direction = "horizontal"}
  cap_row.style.vertical_align = "center"
  cap_row.add{type = "label", caption = {"colony-gui-info.pop-target"}, style = "bold_label"}
  local less = cap_row.add{type = "button", name = "colony_pop_less", caption = "-",
    tooltip = {"colony-gui-info.pop-target-tt"}}
  less.style.width = 24
  local cap = cap_row.add{type = "label", caption = tostring(colony.pop_target or st.capacity)}
  cap.style.width = 32
  cap.style.horizontal_align = "center"
  local more = cap_row.add{type = "button", name = "colony_pop_more", caption = "+",
    tooltip = {"colony-gui-info.pop-target-tt"}}
  more.style.width = 24

  frame.add{type = "line"}
  frame.add{type = "label", caption = {"colony-gui-info.priority-title"}, style = "bold_label"}
  local p = jobs.effective(colony.priority)
  for _, job in ipairs(jobs.JOBS) do
    local row = frame.add{type = "flow", name = "prio_" .. job, direction = "horizontal"}
    row.style.vertical_align = "center"
    local name = row.add{type = "label", caption = {"colony-gui-info.job-" .. job}}
    name.style.width = 64
    row.add{type = "button", name = "colony_prio_" .. job .. "_more", caption = "+",
      tooltip = {"colony-gui-info.more-tt"}}
    local rank = row.add{type = "label", caption = p[job] > 0 and tostring(p[job]) or {"colony-gui-info.off"}}
    rank.style.width = 24
    rank.style.horizontal_align = "center"
    row.add{type = "button", name = "colony_prio_" .. job .. "_less", caption = "-",
      tooltip = {"colony-gui-info.less-tt"}}
  end
  if p.haul == 0 then frame.add{type = "label", caption = {"colony-gui-info.haul-off"}} end
  frame.add{type = "button", name = "colony_prio_reset", caption = {"colony-gui-info.reset"}}
  frame.add{type = "label", caption = {"colony-gui-info.priority-hint"}}

  -- Per-colonist locks live on each house (see fill_house); a town can have hundreds of colonists, so the
  -- Town Hall keeps to aggregate job counts and points at the houses for individual assignment.
  frame.add{type = "line"}
  frame.add{type = "label", caption = {"colony-gui-info.roster-moved"}}
end

local function open_info(player, e)
  local old = player.gui.relative[INFO_FRAME]; if old then old.destroy() end
  local colony = colony_at(e)
  if not colony then return end
  local frame = player.gui.relative.add{type = "frame", name = INFO_FRAME, direction = "vertical",
    caption = {"colony-gui-info.title"}, anchor = {gui = defines.relative_gui_type.container_gui,
      position = defines.relative_gui_position.right, names = {colony_mod.HALL}}}
  local body = frame.add{type = "flow", name = "body", direction = "vertical"}
  fill_info(body, colony)
  scheduler.after(30, "gui.refresh_info", {player_index = player.index, un = e.unit_number, colony_id = colony.id})
end

scheduler.register("gui.refresh_info", function(d)
  local player = game.get_player(d.player_index)
  local frame = player and player.valid and player.gui.relative[INFO_FRAME]
  local e = player and player.opened
  if not (frame and frame.valid and frame.visible and e and e.valid and e.unit_number == d.un) then return end
  local colony = storage.colonies[d.colony_id]
  if not (colony and colony.hall.valid) then return end
  fill_info(frame.body, colony)
  scheduler.after(30, "gui.refresh_info", d)
end)

events.on(defines.events.on_gui_click, function(ev)
  local name = ev.element.name
  local un, lock_job = name:match("^colony_lock_(%d+)_(%a+)$")
  if un then
    local player = game.get_player(ev.player_index)
    local e = player and player.opened
    if not (e and e.valid and (e.name == colony_mod.HALL or colony_mod.HOUSES[e.name])) then return end
    local colony = colony_at(e)
    if not colony then return end
    if lock_job ~= "auto" and not jobs.DEFAULT[lock_job] then return end   -- only roles the matrix knows
    colony.locks = colony.locks or {}
    colony.locks[tonumber(un)] = (lock_job ~= "auto") and lock_job or nil
    local house = colony.houses[e.unit_number]
    local frame = player.gui.relative[house and HOUSE_FRAME or INFO_FRAME]
    if frame and frame.body then
      if house then fill_house(frame.body, house, colony) else fill_info(frame.body, colony) end
    end
    return
  end
  if name == "colony_pop_less" or name == "colony_pop_more" then
    local player = game.get_player(ev.player_index)
    local e = player and player.opened
    if not (e and e.valid and e.name == colony_mod.HALL) then return end
    local colony = colony_at(e)
    if not colony then return end
    local capacity = colony_mod.capacity(colony)
    local cur = colony.pop_target or capacity
    local nxt = math.max(0, math.min(capacity, cur + (name == "colony_pop_more" and 1 or -1)))
    colony.pop_target = nxt >= capacity and nil or nxt
    local frame = player.gui.relative[INFO_FRAME]
    if frame and frame.body then fill_info(frame.body, colony) end
    return
  end
  local ore, ore_dir = name:match("^colony_ore_(.+)_(more|less)$")
  if ore then
    local player = game.get_player(ev.player_index)
    local e = player and player.opened
    if not (e and e.valid and labour.HUTS[e.name]) then return end
    local colony = colony_at(e)
    local h = colony and colony.huts[e.unit_number]
    if not (h and mine_plan.valid(ore)) then return end
    h.ores = h.ores or {}
    local rank = mine_plan.rank(h.ores, ore)
    if ore_dir == "more" then mine_plan.set(h.ores, ore, rank == 0 and 1 or math.max(1, rank - 1))
    else mine_plan.shift(h.ores, ore, 1) end
    local frame = player.gui.relative[HUT_FRAME]
    if frame and frame.body then fill_hut(frame.body, h) end
    return
  end
  if name == "colony_hut_limit_less" or name == "colony_hut_limit_more" then
    local player = game.get_player(ev.player_index)
    local e = player and player.opened
    if not (e and e.valid and labour.HUTS[e.name]) then return end
    local colony = colony_at(e)
    local h = colony and colony.huts[e.unit_number]
    if not h then return end
    local def = labour.HUTS[e.name]
    local cur = h.limit or def.capacity
    h.limit = math.max(0, math.min(def.capacity, cur + (name == "colony_hut_limit_more" and 1 or -1)))
    local frame = player.gui.relative[HUT_FRAME]
    if frame and frame.body then fill_hut(frame.body, h) end
    return
  end
  local job, dir = name:match("^colony_prio_(%a+)_(more|less)$")
  if not (job or name == "colony_prio_reset") then return end
  local player = game.get_player(ev.player_index)
  local e = player and player.opened
  if not (e and e.valid and e.name == colony_mod.HALL) then return end
  local colony = colony_at(e)
  if not colony then return end
  if name == "colony_prio_reset" then
    colony.priority = jobs.defaults()
  else
    colony.priority = colony.priority or jobs.defaults()
    if dir == "more" then
      local rank = jobs.rank(colony.priority, job)
      jobs.set(colony.priority, job, rank == 0 and 1 or math.max(1, rank - 1))
    else
      jobs.shift(colony.priority, job, 1)
    end
  end
  local frame = player.gui.relative[INFO_FRAME]
  if frame and frame.body then fill_info(frame.body, colony) end
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
  elseif e.name == colony_mod.HALL then open_info(player, e)
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
  if name == "colony_accept_migrants" then
    local player = game.get_player(ev.player_index)
    local e = player and player.opened
    if not (e and e.valid and e.name == colony_mod.HALL) then return end
    local colony = colony_at(e)
    if colony then colony.accept_migrants = ev.element.state end
    return
  end
  if name ~= "colony_supply_enabled" and name ~= "colony_supply_collect" then return end
  local player, e, colony, body = machine_ctx(ev)
  if not body then return end
  local m = colony.machines[e.unit_number]
  if name == "colony_supply_enabled" then
    m = colony_mod.set_machine(colony, e, ev.element.state)
    if m and m.enabled and #m.requests == 0 then m.requests = recipe_requests(e) end
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
