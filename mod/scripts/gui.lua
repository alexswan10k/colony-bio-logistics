-- Relative GUIs: (1) household panel on houses (needs/stock/occupants), (2) opt-in "colonist supply" panel on vanilla machines.
-- Thin adapter; rules live in model/housing.lua. Machine requests are stored on colony.machines[unit_number].
local events = require("scripts.events")
local scheduler = require("scripts.scheduler")
local territory = require("scripts.territory")
local housing = require("scripts.model.housing")
local labour = require("scripts.model.labour")
local jobs = require("scripts.model.jobs")
local mine_plan = require("scripts.model.mine_plan")
local crates = require("scripts.model.crates")
local haul_plan = require("scripts.model.haul_plan")
local farm = require("scripts.model.farm")
local advice = require("scripts.model.advice")
local milestones = require("scripts.model.milestones")
local work = require("scripts.work")
local M = {}
local colony_mod   -- injected via M.bind (runtime require is illegal)
function M.bind(c) colony_mod = c end

M.REQUEST_ROWS = 3
M.DEFAULT_COUNT = 20
local HOUSE_FRAME, MACHINE_FRAME, HUT_FRAME, INFO_FRAME, CRATE_FRAME =
  "colony_house_frame", "colony_machine_frame", "colony_hut_frame", "colony_info_frame", "colony_crate_frame"
local MACHINE_GUIS = {
  ["assembling-machine"] = "assembling_machine_gui", ["furnace"] = "furnace_gui", ["boiler"] = "boiler_gui", ["lab"] = "lab_gui",
}
M.MACHINE_GUIS = MACHINE_GUIS   -- selection tool (#35) opts in exactly the machines that have a panel

local function colony_at(e) return colony_mod.colony_of(e) end
local fill_crate, crate_ctx   -- defined with the crate panel below; the click handler above needs them


-- ---------- "what is holding it back" (model/advice.lua) ----------
local COLOURS = {red = "red", amber = "orange"}
local function add_advice_line(frame, level, key, ...)
  frame.add{type = "label", caption = {"", "[color=" .. COLOURS[level] .. "]", {"colony-advice." .. key, ...}, "[/color]"}}
end

function M.colony_advice(colony, st, counts)
  local stock = colony_mod.stock_table(colony)
  local merged = colony_mod.tool_gaps(colony)
  return advice.colony{pop = st.pop, capacity = st.capacity, food = st.food,
    haul_rank = jobs.effective(colony.priority).haul, haulers = counts.haul or 0,
    houses = st.tents + st.cabins + (st.homesteads or 0) + (st.apartments or 0),
    hall_stock = stock, tool_gaps = merged}
end

-- A panel is rebuilt only when what it shows has changed. Rebuilding every half second reset scroll
-- positions and swallowed hovers and clicks; the signature is a cheap digest of the same inputs.
local function unchanged(frame, sig)
  local text = serpent.line(sig, {comment = false, sortkeys = true})
  if frame.tags and frame.tags.sig == text then return true end
  frame.tags = {sig = text}
  return false
end

-- ---------- household panel ----------
-- Per-colonist job locks live on the house, not the Town Hall: a house lists only its own handful of
-- occupants, so the panel stays usable when a town grows to hundreds of colonists.
local LOCK_OPTS = {{"auto", "A"}, {"haul", "H"}, {"forage", "F"}, {"chop", "C"}, {"mine", "M"}, {"farm", "G"},
  {"hunt", "T"}, {"fish", "I"}, {"preserve", "P"}, {"construct", "B"}, {"research", "R"}, {"heal", "D"}}

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
    name.style.width = 150
    local items, selected = {}, 1
    local lock = colony.locks[un] or "auto"
    for k, opt in ipairs(LOCK_OPTS) do
      items[k] = opt[1] == "auto" and {"colony-gui-info.lock-auto-short"} or {"colony-gui-info.job-" .. opt[1]}
      if opt[1] == lock then selected = k end
    end
    local dd = row.add{type = "drop-down", name = "colony_lock_" .. un, items = items, selected_index = selected,
      tooltip = {"colony-gui-info.lock-dropdown-tt"}}
    dd.style.width = 130
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
    line.add{type = "label", caption = ok == nil and "-" or (ok and {"colony-gui.ok"} or {"colony-gui.missing"})}
    local parts = {}
    for _, opt in ipairs(need.options) do
      if opt.power then parts[#parts + 1] = powered and {"colony-gui.powered"} or {"colony-gui.no-power"}
      else parts[#parts + 1] = string.format("[item=%s] %d (%.1f/colonist)", opt.item, stock[opt.item] or 0, opt.per) end
    end
    local caption = {"", "    "}
    for i, part in ipairs(parts) do
      if i > 1 then caption[#caption + 1] = "  |  " end
      caption[#caption + 1] = part
    end
    frame.add{type = "label", caption = caption}
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
      position = defines.relative_gui_position.right,
      names = {"colony-housing-tent", "colony-housing-cabin", "colony-housing-homestead", "colony-housing-apartment"}}}
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
  local roster = {}
  for _, un in ipairs(colony_mod.households(colony)[d.un] or {}) do
    local st = storage.unit_state[un]
    roster[#roster + 1] = {un, st and st.job, colony.locks and colony.locks[un]}
  end
  if not unchanged(frame, {colony_mod.house_stock(h), h.sat, h.occupants, h.inflight, colony_mod.is_powered(h), roster}) then
    fill_house(frame.body, h, colony)
  end
  scheduler.after(30, "gui.refresh_house", d)
end)

-- ---------- labour hut panel ----------
-- While the panel is open, the hut's working radius is drawn in the world (the same idea as the Town
-- Hall's territory rectangle) so "why is nothing being harvested?" is answerable at a glance.
local function draw_hut_range(h)
  rendering.draw_circle{color = {0.9, 0.9, 0.3, 0.7}, width = 2, filled = false,
    radius = colony_mod.HUT_RADIUS, target = h.entity, surface = h.entity.surface, time_to_live = 60}
end

local function item(name) return {"item-name." .. name} end

-- Why this hut is short of workers (model/advice.lua): a locale key under colony-advice, its arguments, and the
-- level it is shown at. A hut short of a tool is told what the colony's Toolsmith makes of it (work.tool_gap).
function M.hut_reason(h, def, tools, workers)
  local colony = storage.colonies[h.colony_id]
  local sites
  if h.job ~= "preserve" and h.job ~= "fish" and h.job ~= "research" and h.job ~= "heal" then sites = work.site_count(h) end
  local inputs_missing = false
  if not def.tool and workers == 0 then
    local inv = h.entity.type == "lab" and h.entity.get_inventory(defines.inventory.lab_input)
      or h.entity.get_inventory(defines.inventory.chest)
    inputs_missing = true
    for _, item in ipairs(def.keep or {}) do
      if inv and inv.get_item_count(item) > 0 then inputs_missing = false end
    end
  end
  local reason, arg = advice.hut{needs_tool = def.tool ~= nil, tool = def.tool, tools = tools, capacity = def.capacity,
    limit = h.limit, workers = workers, inflight = def.tool and (h.inflight[def.tool] or 0) or 0,
    hall_stock = def.tool and colony and colony_mod.stock_count(colony, def.tool) or 0, sites = sites,
    inputs_missing = inputs_missing, haul_rank = colony and jobs.effective(colony.priority).haul or 1}
  if not reason then return nil end
  if reason == "no-tool-in-hall" then
    local kind, ingredient, n
    if colony then kind, ingredient, n = work.tool_gap(colony, arg) end
    if kind == "making" then return "hut-tool-crafting", {item(arg)}, "amber" end
    if kind == "short" then return "hut-tool-ingredients", {item(arg), n, item(ingredient)}, "red" end
    return "hut-no-tool-in-hall", {item(arg)}, "red"
  end
  return "hut-" .. reason, {}, reason == "haul-off" and "red" or "amber"
end

local function fill_hut(frame, h)
  frame.clear()
  local def, tools, allowed, workers = work.hut_info(h)
  frame.add{type = "label", caption = {"colony-gui-hut.workers", workers, allowed}}
  local reason, args, level = M.hut_reason(h, def, tools, workers)
  if reason then
    add_advice_line(frame, level, reason, args[1], args[2], args[3])
  end
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
  if def.tool then
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
  else
    local inv = h.entity.type == "lab"
      and h.entity.get_inventory(defines.inventory.lab_input)
      or h.entity.get_inventory(defines.inventory.chest)
    local parts = {}
    for _, item in ipairs(def.keep or {}) do
      parts[#parts + 1] = string.format("[item=%s] %d", item, inv and inv.get_item_count(item) or 0)
    end
    frame.add{type = "label", caption = {"colony-gui-hut.inputs", table.concat(parts, "  ")}}
  end
  if h.job == "research" then
    local force = h.entity.force
    local tech = force and force.current_research
    if tech then
      local pct = math.floor((force.research_progress or 0) * 100)
      frame.add{type = "label", caption = {"colony-gui-hut.research-active", tech.localised_name, pct}}
    else
      frame.add{type = "label", caption = {"colony-gui-hut.research-idle"}}
    end
  end
  if h.job == "farm" then
    local colony = storage.colonies[h.colony_id]
    local fallow, growing, ripe, fertilized = 0, 0, 0, 0
    local r2 = colony_mod.HUT_RADIUS * colony_mod.HUT_RADIUS
    if colony and colony.plots then
      for _, p in pairs(colony.plots) do
        if p.entity.valid and (p.entity.position.x - h.entity.position.x)^2 + (p.entity.position.y - h.entity.position.y)^2 <= r2 then
          if p.stage == farm.RIPE then ripe = ripe + 1
          elseif p.stage == farm.GROWING then growing = growing + 1
          else fallow = fallow + 1 end
          if p.fertilized then fertilized = fertilized + 1 end
        end
      end
    end
    local fert_cnt = h.entity.get_item_count("colony-fertilizer")
    frame.add{type = "label", caption = {"colony-gui-hut.farm-plots-summary", fallow, growing, ripe, fertilized}}
    frame.add{type = "label", caption = {"colony-gui-hut.farm-fertilizer", fert_cnt}}
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
  if h.job ~= "preserve" and h.job ~= "fish" and h.job ~= "research" and h.job ~= "heal" then
    local sites = work.site_count(h)
    if sites > 0 then frame.add{type = "label", caption = {"colony-gui-hut.sites", sites}} end
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
  local _, tools, allowed, workers = work.hut_info(h)
  local reason = M.hut_reason(h, labour.HUTS[h.entity.name], tools, workers)
  if not unchanged(frame, {tools, allowed, workers, h.limit, h.wear, h.inflight, h.ores, reason, work.site_count(h),
      h.entity.get_item_count("colony-fertilizer")}) then
    fill_hut(frame.body, h)
  end
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

  local problems = M.colony_advice(colony, st, counts)
  if #problems > 0 then
    frame.add{type = "label", caption = {"colony-advice.title"}, style = "bold_label"}
    for _, a in ipairs(problems) do
      local args = a.args
      if a.key == "no-tool" then args = {{"item-name." .. a.args[1]}, a.args[2]} end
      add_advice_line(frame, a.level, a.key, args[1], args[2])
    end
    frame.add{type = "line"}
  end
  -- Growth first: the one question every glance at the hall is asking (model/advice.growth).
  local g = advice.growth{pop = st.pop, capacity = st.capacity, d = st.d, parts = st.parts, accept = colony.accept_migrants}
  local gcol = g.level == "green" and "green" or (g.level == "red" and "red" or "orange")
  frame.add{type = "label", caption = {"", "[color=" .. gcol .. "]",
    {"colony-status." .. g.key, g.args[1] and {"colony-advice.factor-" .. g.args[1]} or ""}, "[/color]"}}
  local facts, researched = colony_mod.milestone_facts(colony.hall.force)
  local nxt = milestones.next(facts, researched)
  if nxt then
    frame.add{type = "label", caption = {"colony-gui-info.next-milestone", {"technology-name." .. nxt.tech},
      nxt.have, nxt.need}, tooltip = {"technology-description." .. nxt.tech}}
  end
  frame.add{type = "label", caption = {"colony-gui-info.population", st.pop, st.capacity}}
  frame.add{type = "label", caption = {"colony-gui-info.housing", st.tents, st.cabins, st.homesteads or 0, st.apartments or 0, math.max(st.capacity - st.pop, 0)}}
  local colour = st.food_ratio < 0.5 and "red" or (st.food_ratio < 1 and "orange" or "green")
  frame.add{type = "label", caption = {"", {"colony-gui-info.food", st.food, st.food_target},
    "  [color=" .. colour .. "]" .. pct(st.food_ratio) .. "[/color]"}}
  if (st.away or 0) > 0 or (st.commuters_here or 0) > 0 then
    frame.add{type = "label", caption = {"colony-gui-info.commuters", st.away or 0, st.commuters_here or 0}}
  end
  if (st.sick or 0) > 0 then
    frame.add{type = "label", caption = {"colony-gui-info.sick", st.sick, st.sick_lung or 0, st.sick_poison or 0}}
  end
  if (st.fallen or 0) > 0 then
    frame.add{type = "label", caption = {"colony-gui-info.fallen", st.fallen, st.buried or 0}}
  end
  local parts = st.parts
  frame.add{type = "label", caption = {"colony-gui-info.desirability", string.format("%.2f", st.d)}}
  frame.add{type = "label", caption = {"colony-gui-info.desirability-parts",
    string.format("%.2f", parts.food or 0), string.format("%.2f", parts.housing or 0),
    string.format("%.2f", parts.scenic or 0), string.format("%.2f", parts.leisure or 0),
    string.format("%.2f", parts.pollution or 0), string.format("%.2f", parts.deaths or 0),
    string.format("%.2f", parts.recreation or 0), string.format("%.2f", parts.sickness or 0)}}
  frame.add{type = "label", caption = {"colony-gui-info.desirability-inputs",
    string.format("%.2f", st.scenic or 0), string.format("%.2f", st.pollution or 0)}}
  frame.add{type = "label", caption = {"colony-gui-info.jobs",
    counts.haul or 0, counts.forage or 0, counts.chop or 0, counts.mine or 0, counts.farm or 0,
    counts.hunt or 0, counts.fish or 0, counts.preserve or 0, counts.construct or 0,
    counts.research or 0, counts.heal or 0, math.max(st.pop - busy, 0)}}
  frame.add{type = "label", caption = {"colony-gui-info.territory", st.chunks, st.huts, st.machines, st.towers, st.crates}}
  if st.ghosts > 0 or st.damaged > 0 then
    frame.add{type = "label", caption = {"colony-gui-info.construction", st.ghosts, st.damaged}}
  end

  -- Colony resource ledger (#82): Town Hall aggregate inventory + huts + in-transit yields
  frame.add{type = "line"}
  frame.add{type = "label", caption = {"colony-gui-info.resources-title"}, style = "bold_label"}
  local ledger_data = colony_mod.ledger_snapshot(colony)
  if not ledger_data or #ledger_data.items == 0 then
    frame.add{type = "label", caption = {"colony-gui-info.resources-empty"}}
  else
    local scroll = frame.add{type = "scroll-pane", direction = "vertical"}
    scroll.style.maximal_height = 160
    local table_gui = scroll.add{type = "table", column_count = 5, draw_horizontal_lines = true}
    table_gui.style.horizontal_spacing = 8
    local h1 = table_gui.add{type = "label", caption = {"colony-gui-info.res-item"}, style = "bold_label"}
    h1.style.width = 90
    local h2 = table_gui.add{type = "label", caption = {"colony-gui-info.res-stock"}, style = "bold_label"}
    h2.style.width = 45; h2.style.horizontal_align = "right"
    local h3 = table_gui.add{type = "label", caption = {"colony-gui-info.res-huts"}, style = "bold_label"}
    h3.style.width = 45; h3.style.horizontal_align = "right"
    local h4 = table_gui.add{type = "label", caption = {"colony-gui-info.res-transit"}, style = "bold_label"}
    h4.style.width = 45; h4.style.horizontal_align = "right"
    local h5 = table_gui.add{type = "label", caption = {"colony-gui-info.res-total"}, style = "bold_label"}
    h5.style.width = 45; h5.style.horizontal_align = "right"

    for _, it in ipairs(ledger_data.items) do
      local name_lbl = table_gui.add{type = "label", caption = {"", "[item=" .. it.item .. "] ", {"item-name." .. it.item}}}
      name_lbl.style.width = 90

      local tt = {"", {"item-name." .. it.item}, "\n", {"colony-gui-info.tt-stock", it.stock}}
      if it.huts > 0 then
        tt[#tt + 1] = "\n"
        tt[#tt + 1] = {"colony-gui-info.tt-huts", it.huts}
        for hut_name, count in pairs(it.hut_details) do
          tt[#tt + 1] = "\n  • " .. count .. " in "
          tt[#tt + 1] = {"entity-name." .. hut_name}
        end
      end
      if it.transit > 0 then
        tt[#tt + 1] = "\n"
        tt[#tt + 1] = {"colony-gui-info.tt-transit", it.transit}
      end
      name_lbl.tooltip = tt

      local l_stock = table_gui.add{type = "label", caption = tostring(it.stock)}
      l_stock.style.width = 45; l_stock.style.horizontal_align = "right"
      local l_huts = table_gui.add{type = "label", caption = it.huts > 0 and tostring(it.huts) or "-"}
      l_huts.style.width = 45; l_huts.style.horizontal_align = "right"
      local l_trans = table_gui.add{type = "label", caption = it.transit > 0 and tostring(it.transit) or "-"}
      l_trans.style.width = 45; l_trans.style.horizontal_align = "right"
      local l_tot = table_gui.add{type = "label", caption = tostring(it.total), style = "bold_label"}
      l_tot.style.width = 45; l_tot.style.horizontal_align = "right"
    end
  end

  frame.add{type = "line"}
  frame.add{type = "checkbox", name = "colony_accept_migrants", state = colony.accept_migrants ~= false,
    caption = {"colony-gui-info.accept-migrants"}, tooltip = {"colony-gui-info.accept-migrants-tt"}}

  frame.add{type = "line"}
  frame.add{type = "label", caption = {"colony-gui-info.workforce-title"}, style = "bold_label"}
  local table_gui = frame.add{type = "table", column_count = 4, draw_horizontal_lines = false}
  table_gui.style.horizontal_spacing = 6
  local h1 = table_gui.add{type = "label", caption = {"colony-gui-info.wf-job"}, style = "bold_label"}
  h1.style.width = 68
  local h2 = table_gui.add{type = "label", caption = {"colony-gui-info.wf-workers"}, style = "bold_label"}
  h2.style.width = 46; h2.style.horizontal_align = "center"
  local h3 = table_gui.add{type = "label", caption = {"colony-gui-info.wf-priority"}, style = "bold_label"}
  h3.style.width = 66; h3.style.horizontal_align = "center"
  local h4 = table_gui.add{type = "label", caption = {"colony-gui-info.wf-target"}, style = "bold_label"}
  h4.style.width = 82; h4.style.horizontal_align = "center"

  local p = jobs.effective(colony.priority)
  for _, job in ipairs(jobs.JOBS) do
    local name = table_gui.add{type = "label", caption = {"colony-gui-info.job-" .. job}}
    name.style.width = 68

    local cur = counts[job] or 0
    local w_lbl = table_gui.add{type = "label", caption = tostring(cur)}
    w_lbl.style.width = 46; w_lbl.style.horizontal_align = "center"

    local p_flow = table_gui.add{type = "flow", direction = "horizontal"}
    p_flow.style.vertical_align = "center"
    local b_less = p_flow.add{type = "button", name = "colony_prio_" .. job .. "_less", caption = "-",
      tooltip = {"colony-gui-info.less-tt"}}
    b_less.style.width = 18; b_less.style.height = 20
    local rank_lbl = p_flow.add{type = "label", caption = p[job] > 0 and tostring(p[job]) or {"colony-gui-info.off"}}
    rank_lbl.style.width = 24; rank_lbl.style.horizontal_align = "center"
    local b_more = p_flow.add{type = "button", name = "colony_prio_" .. job .. "_more", caption = "+",
      tooltip = {"colony-gui-info.more-tt"}}
    b_more.style.width = 18; b_more.style.height = 20

    local t_flow = table_gui.add{type = "flow", direction = "horizontal"}
    t_flow.style.vertical_align = "center"
    local tb_less = t_flow.add{type = "button", name = "colony_target_" .. job .. "_less", caption = "-",
      tooltip = {"colony-gui-info.target-less-tt"}}
    tb_less.style.width = 18; tb_less.style.height = 20
    local tgt = colony_mod.job_target(colony, job)
    local tgt_text = tgt ~= nil and tostring(tgt) or {"colony-gui-info.auto"}
    local tgt_lbl = t_flow.add{type = "label", caption = tgt_text}
    tgt_lbl.style.width = 38; tgt_lbl.style.horizontal_align = "center"
    local tb_more = t_flow.add{type = "button", name = "colony_target_" .. job .. "_more", caption = "+",
      tooltip = {"colony-gui-info.target-more-tt"}}
    tb_more.style.width = 18; tb_more.style.height = 20
  end

  if p.haul == 0 then frame.add{type = "label", caption = {"colony-gui-info.haul-off"}} end
  local btn_row = frame.add{type = "flow", direction = "horizontal"}
  btn_row.add{type = "button", name = "colony_prio_reset", caption = {"colony-gui-info.reset-priority"}}
  btn_row.add{type = "button", name = "colony_target_reset", caption = {"colony-gui-info.reset-target"}}
  frame.add{type = "label", caption = {"colony-gui-info.workforce-hint"}}

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
  local body = frame.add{type = "scroll-pane", name = "body", direction = "vertical"}
  body.style.maximal_height = 640
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
  local st = colony_mod.stats(colony)
  local counts = work.job_counts(colony)
  local ledger = colony_mod.ledger_snapshot(colony)
  if not unchanged(frame, {st, counts, ledger and ledger.items, M.colony_advice(colony, st, counts), colony.priority,
      colony.job_targets, colony.accept_migrants}) then
    fill_info(frame.body, colony)
  end
  scheduler.after(30, "gui.refresh_info", d)
end)

events.on(defines.events.on_gui_click, function(ev)
  local name = ev.element.name
  local clear_row = tonumber(name:match("^colony_crate_clear_(%d+)$"))
  if clear_row then
    local _, c, _, body = crate_ctx(ev)
    if c then
      c.filters[clear_row] = nil
      if body then fill_crate(body, c) end
    end
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
    if ore_dir == "more" then
      if rank == 0 then mine_plan.set(h.ores, ore, mine_plan.MAX_RANK)
      elseif rank > 1 then mine_plan.set(h.ores, ore, rank - 1) end
    else
      if rank > 0 and rank < mine_plan.MAX_RANK then mine_plan.set(h.ores, ore, rank + 1)
      elseif rank == mine_plan.MAX_RANK then mine_plan.set(h.ores, ore, 0) end
    end
    colony_mod.reassign_workforce(colony)
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
    colony_mod.reassign_workforce(colony)
    local frame = player.gui.relative[HUT_FRAME]
    if frame and frame.body then fill_hut(frame.body, h) end
    return
  end
  local target_job, target_dir = name:match("^colony_target_(%a+)_(more|less)$")
  if target_job or name == "colony_target_reset" then
    local player = game.get_player(ev.player_index)
    local e = player and player.opened
    if not (e and e.valid and e.name == colony_mod.HALL) then return end
    local colony = colony_at(e)
    if not colony then return end
    if name == "colony_target_reset" then
      colony.job_targets = {}
      for un in pairs(colony.colonists or {}) do
        local st = storage.unit_state and storage.unit_state[un]
        if st and st.state == "idle" then work.assign(colony, un) end
      end
    else
      local delta = target_dir == "more" and 1 or -1
      colony_mod.shift_job_target(colony, target_job, delta)
    end
    local frame = player.gui.relative[INFO_FRAME]
    if frame and frame.body then fill_info(frame.body, colony) end
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
    local cur = jobs.rank(colony.priority, job)
    if dir == "more" then
      if cur == 0 then jobs.set(colony.priority, job, jobs.MAX_RANK)
      elseif cur > 1 then jobs.set(colony.priority, job, cur - 1) end
    else
      if cur > 0 and cur < jobs.MAX_RANK then jobs.set(colony.priority, job, cur + 1)
      elseif cur == jobs.MAX_RANK then jobs.set(colony.priority, job, 0) end
    end
  end
  colony_mod.reassign_workforce(colony)
  local frame = player.gui.relative[INFO_FRAME]
  if frame and frame.body then fill_info(frame.body, colony) end
end)

events.on(defines.events.on_gui_selection_state_changed, function(ev)
  local un = tonumber(ev.element.name:match("^colony_lock_(%d+)$"))
  if not un then return end
  local player = game.get_player(ev.player_index)
  local e = player and player.opened
  if not (e and e.valid and colony_mod.HOUSES[e.name]) then return end
  local colony = colony_at(e)
  local opt = LOCK_OPTS[ev.element.selected_index]
  if not (colony and opt) then return end
  if opt[1] ~= "auto" and not jobs.DEFAULT[opt[1]] then return end   -- only roles the matrix knows
  colony.locks = colony.locks or {}
  colony.locks[un] = opt[1] ~= "auto" and opt[1] or nil
end)

-- ---------- colony crates (#33) ----------
-- Supply: a provider the colony empties. Demand: a requester the player fills with filters. Warehouse:
-- bulk stock (no panel controls; it is a source and an overflow sink for the haul planner).
local function crate_contents(c)
  local inv = c.entity.get_inventory(defines.inventory.chest)
  local out, map = {}, {}
  if inv then
    for _, item in ipairs(inv.get_contents()) do
      out[#out + 1] = item
      map[item.name] = item.count
    end
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out, map
end

function fill_crate(frame, c)
  frame.clear()
  local contents, map = crate_contents(c)
  if c.kind == crates.DEMAND then
    frame.add{type = "label", caption = {"colony-gui-crate.filters"}}
    for i = 1, crates.FILTER_ROWS do
      local f = c.filters[i]
      local row = frame.add{type = "flow", direction = "horizontal"}
      row.style.vertical_align = "center"
      row.add{type = "choose-elem-button", name = "colony_crate_item_" .. i, elem_type = "item", item = f and f.item}
      local tf = row.add{type = "textfield", name = "colony_crate_count_" .. i,
        text = f and f.count and tostring(f.count) or tostring(crates.DEFAULT_COUNT),
        numeric = true, allow_decimal = false, allow_negative = false}
      tf.style.width = 60
      row.add{type = "label", caption = {"colony-gui-crate.keep"}}
      local clear = row.add{type = "button", name = "colony_crate_clear_" .. i, caption = "x",
        tooltip = {"colony-gui-crate.clear-tt"}}
      clear.style.width = 24
    end
    local n, target = crates.filled(c.filters, map)
    frame.add{type = "label", caption = {"colony-gui-crate.filled", n, target}}
  else
    frame.add{type = "label",
      caption = c.kind == crates.SUPPLY and {"colony-gui-crate.supply-hint"} or {"colony-gui-crate.warehouse-hint"}}
  end
  frame.add{type = "line"}
  frame.add{type = "label", caption = {"colony-gui-crate.contents"}, style = "bold_label"}
  if #contents == 0 then frame.add{type = "label", caption = {"colony-gui-crate.empty"}} end
  for _, item in ipairs(contents) do
    frame.add{type = "label", caption = {"", "[item=" .. item.name .. "]", " " .. item.count}}
  end
end

local function open_crate(player, e)
  local old = player.gui.relative[CRATE_FRAME]; if old then old.destroy() end
  local frame = player.gui.relative.add{type = "frame", name = CRATE_FRAME, direction = "vertical",
    caption = e.localised_name, anchor = {gui = defines.relative_gui_type.container_gui,
      position = defines.relative_gui_position.right,
      names = {colony_mod.SUPPLY_CRATE, colony_mod.DEMAND_CRATE, colony_mod.WAREHOUSE}}}
  local body = frame.add{type = "flow", name = "body", direction = "vertical"}
  local colony = colony_at(e)
  local c = colony and colony.crates[e.unit_number]
  if not c then body.add{type = "label", caption = {"colony-gui-crate.outside"}}; return end
  fill_crate(body, c)
end

function crate_ctx(ev)
  local player = game.get_player(ev.player_index)
  local e = player and player.opened
  if not (e and e.valid and player.opened_gui_type == defines.gui_type.entity) then return end
  local colony = colony_at(e)
  local c = colony and colony.crates[e.unit_number]
  if not c then return end
  local frame = player.gui.relative[CRATE_FRAME]
  return player, c, colony, frame and frame.body
end

-- ---------- machine supply panel ----------
local function req_status(e, m, req)
  local colony = colony_at(e)
  local state = advice.request{have = e.get_item_count(req.item), count = req.count, inflight = m.inflight and m.inflight[req.item] or 0,
    stock = colony and colony_mod.stock_count(colony, req.item) or 0,
    haul_rank = colony and jobs.effective(colony.priority).haul or 1}
  local lvl = (state == "no-stock" or state == "haul-off") and "red" or (state == "queued" and "orange" or "green")
  return {"", "[color=" .. lvl .. "]", {"colony-advice.req-" .. state}, "[/color]"}
end

local function fill_machine(frame, m, e)
  frame.clear()
  frame.add{type = "checkbox", name = "colony_supply_enabled", state = m ~= nil and m.enabled or false,
    caption = {"colony-gui.supply-enable"}, tooltip = {"colony-gui.supply-enable-tt"}}
  if not (m and m.enabled) then return end
  frame.add{type = "label", caption = {"colony-gui.supply-rows"}}
  for i = 1, M.REQUEST_ROWS do
    local req = m.requests[i]
    local row = frame.add{type = "flow", name = "colony_req_row_" .. i, direction = "horizontal"}
    row.style.vertical_align = "center"
    row.add{type = "choose-elem-button", name = "colony_req_item_" .. i, elem_type = "item", item = req and req.item}
    local tf = row.add{type = "textfield", name = "colony_req_count_" .. i, text = req and tostring(req.count) or "",
      numeric = true, allow_decimal = false, allow_negative = false}
    tf.style.width = 60
    row.add{type = "label", caption = {"colony-gui.supply-keep"}}
    if req then row.add{type = "label", name = "status", caption = req_status(e, m, req)} end
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
  scheduler.after(30, "gui.refresh_machine", {player_index = player.index, un = e.unit_number})
end

-- Request status lines are updated in place: rebuilding the panel would drop focus from a count being typed.
scheduler.register("gui.refresh_machine", function(d)
  local player = game.get_player(d.player_index)
  local frame = player and player.valid and player.gui.relative[MACHINE_FRAME]
  local e = player and player.opened
  if not (frame and frame.valid and frame.visible and e and e.valid and e.unit_number == d.un) then return end
  local colony = colony_at(e)
  local m = colony and colony.machines[e.unit_number]
  if m and m.enabled then
    for i = 1, M.REQUEST_ROWS do
      local row, req = frame.body["colony_req_row_" .. i], m.requests[i]
      local label = row and row.status
      if label and req then label.caption = req_status(e, m, req) end
    end
  end
  scheduler.after(30, "gui.refresh_machine", d)
end)

events.on(defines.events.on_gui_opened, function(ev)
  local player = game.get_player(ev.player_index)
  local e = ev.entity
  if not (player and e and e.valid and ev.gui_type == defines.gui_type.entity) then return end
  if colony_mod.HOUSES[e.name] then open_house(player, e)
  elseif labour.HUTS[e.name] then open_hut(player, e)
  elseif e.name == colony_mod.HALL then open_info(player, e)
  elseif colony_mod.CRATES[e.name] then open_crate(player, e)
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
    fill_machine(body, m, e)
  elseif m then m.collect = ev.element.state end
end)

local function row_of(name) return tonumber(name:match("^colony_req_%a+_(%d+)$")) end

events.on(defines.events.on_gui_elem_changed, function(ev)
  local row = tonumber(ev.element.name:match("^colony_crate_item_(%d+)$"))
  if row then
    local _, c, _, body = crate_ctx(ev)
    if c then
      crates.set_filter(c.filters, row, ev.element.elem_value)
      if body then fill_crate(body, c) end
    end
    return
  end
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
  local row = tonumber(ev.element.name:match("^colony_crate_count_(%d+)$"))
  if row then
    local _, c = crate_ctx(ev)
    if c then crates.set_count(c.filters, row, ev.element.text) end
    return
  end
  local i = row_of(ev.element.name)
  if not (i and ev.element.name:find("colony_req_count_", 1, true)) then return end
  local _, e, colony = machine_ctx(ev)
  local m = colony and colony.machines[e.unit_number]
  local req = m and m.requests[i]
  if req then req.count = tonumber(ev.element.text) or 0 end
end)

return M
