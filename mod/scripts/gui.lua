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
local desirability = require("scripts.model.desirability")
local breeding = require("scripts.model.breeding")
local garrison = require("scripts.model.garrison")
local milestones = require("scripts.model.milestones")
local tags = require("scripts.model.tags")
local quota = require("scripts.model.quota")
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
local fill_crate, crate_ctx, machine_ctx, fill_machine   -- defined with crate/machine panels below; click handler needs them


-- ---------- "what is holding it back" (model/advice.lua) ----------
local COLOURS = {red = "red", amber = "orange", green = "green"}
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
  {"hunt", "T"}, {"fish", "I"}, {"preserve", "P"}, {"construct", "B"}, {"research", "R"}, {"heal", "D"}, {"guard", "V"}}

local function fill_roster(pane, colony, ids)
  colony.locks = colony.locks or {}
  if #ids == 0 then
    pane.add{type = "label", caption = {"colony-gui-info.roster-empty"}}
    return
  end
  for i, un in ipairs(ids) do
    local st = storage.unit_state[un]
    local job = st and st.job or "idle"
    local rec = storage.age and storage.age[un]
    local mark = rec and rec.stage == "child" and "🧒" or (breeding.sex_of(un) == "female" and "♀" or "♂")
    local row = pane.add{type = "flow", direction = "horizontal"}
    row.style.vertical_align = "center"
    local name = row.add{type = "label", caption = {"colony-gui-info.colonist-marked", mark, i, {"colony-gui-info.job-" .. job}}}
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
  frame.add{type = "checkbox", name = "colony_house_logistics", state = h.logistics_enabled ~= false,
    caption = {"colony-gui.logistics-enable"}, tooltip = {"colony-gui.logistics-enable-tt"}}
  local p_row = frame.add{type = "flow", direction = "horizontal"}
  p_row.style.vertical_align = "center"
  p_row.add{type = "label", caption = {"colony-gui.priority-label"}, tooltip = {"colony-gui.building-priority-tt"}, style = "bold_label"}
  local p_less = p_row.add{type = "button", name = "colony_house_prio_less", caption = "-", tooltip = {"colony-gui.priority-less-tt"}}
  p_less.style.width = 24
  local p_val = p_row.add{type = "label", caption = tostring(h.priority or 3), tooltip = {"colony-gui.building-priority-tt"}}
  p_val.style.width = 24
  p_val.style.horizontal_align = "center"
  local p_more = p_row.add{type = "button", name = "colony_house_prio_more", caption = "+", tooltip = {"colony-gui.priority-more-tt"}}
  p_more.style.width = 24
  frame.add{type = "line"}
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
      else parts[#parts + 1] = string.format("[item=%s] %d (%.1f/colonist per %ds)", opt.item, stock[opt.item] or 0, opt.per, math.floor(colony_mod.interval() / 60)) end
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
  if not unchanged(frame, {colony_mod.house_stock(h), h.sat, h.occupants, h.inflight, colony_mod.is_powered(h), roster, h.logistics_enabled, h.priority}) then
    fill_house(frame.body, h, colony)
  end
  scheduler.after(30, "gui.refresh_house", d)
end)

-- ---------- labour hut panel ----------
-- While the panel is open, the hut's working radius is drawn in the world (the same idea as the Town
-- Hall's territory rectangle) so "why is nothing being harvested?" is answerable at a glance.
local function draw_hut_range(h, sites)
  -- A garrisoned tower draws its engagement circle instead: that is the radius that matters (#56).
  if h.job == "guard" then
    rendering.draw_circle{color = {0.95, 0.45, 0.15, 0.7}, width = 2, filled = false,
      radius = garrison.RANGE, target = h.entity, surface = h.entity.surface, time_to_live = 60}
    return
  end
  if sites == nil and h.job ~= "preserve" and h.job ~= "fish" and h.job ~= "research" and h.job ~= "heal" then
    sites = work.site_count(h)
  end
  local r = (h.job == "forage" and colony_mod.FORAGE_RADIUS or colony_mod.HUT_RADIUS)
  local is_empty = (sites ~= nil and sites == 0)
  local color = is_empty and {1.0, 0.25, 0.25, 0.75} or {0.9, 0.9, 0.3, 0.7}
  local width = is_empty and 3 or 2
  rendering.draw_circle{color = color, width = width, filled = false,
    radius = r, target = h.entity, surface = h.entity.surface, time_to_live = 60}
end

local function item(name) return {"item-name." .. name} end

-- Why this hut is short of workers (model/advice.lua): a locale key under colony-advice, its arguments, and the
-- level it is shown at. A hut short of a tool is told what the colony's Toolsmith makes of it (work.tool_gap).
function M.hut_reason(h, def, tools, workers)
  local colony = storage.colonies[h.colony_id]
  local sites
  if h.job ~= "preserve" and h.job ~= "fish" and h.job ~= "research" and h.job ~= "heal" and h.job ~= "guard" then
    sites = work.site_count(h)
  end
  local inputs_missing = false
  if not def.tool and workers == 0 then
    local inv = h.entity.type == "lab" and h.entity.get_inventory(defines.inventory.lab_input)
      or h.entity.get_inventory(defines.inventory.chest)
    inputs_missing = true
    for _, item in ipairs(def.keep or {}) do
      if inv and inv.get_item_count(item) > 0 then inputs_missing = false end
    end
  end
  local met, quota_item
  if colony then met, quota_item = work.hut_quota_met(colony, h) end
  local nothing = colony ~= nil and h.entity.name == "colony-toolsmith" and #work.toolsmith_wanted(colony) == 0
  local reason, arg = advice.hut{quota_item = met and quota_item or nil, nothing_to_do = nothing,
    needs_tool = def.tool ~= nil, tool = def.tool, tools = tools, capacity = def.capacity,
    limit = h.limit, workers = workers, inflight = def.tool and (h.inflight[def.tool] or 0) or 0,
    hall_stock = def.tool and colony and colony_mod.stock_count(colony, def.tool) or 0, sites = sites,
    inputs_missing = inputs_missing, haul_rank = colony and jobs.effective(colony.priority).haul or 1}
  if h.job == "guard" and reason == "paused" then return nil end   -- unmanned tower: a standing choice, not a fault
  if not reason then return nil end
  if reason == "quota-met" then return "hut-quota-met", {item(arg)}, "green" end
  if reason == "nothing-to-do" then return "hut-nothing-to-do", {}, "green" end
  if reason == "no-sites" then return "hut-no-sites", {}, "red" end
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
  frame.add{type = "checkbox", name = "colony_hut_logistics", state = h.logistics_enabled ~= false,
    caption = {"colony-gui.logistics-enable"}, tooltip = {"colony-gui.logistics-enable-tt"}}
  local p_row = frame.add{type = "flow", direction = "horizontal"}
  p_row.style.vertical_align = "center"
  p_row.add{type = "label", caption = {"colony-gui.priority-label"}, tooltip = {"colony-gui.building-priority-tt"}, style = "bold_label"}
  local p_less = p_row.add{type = "button", name = "colony_hut_prio_less", caption = "-", tooltip = {"colony-gui.priority-less-tt"}}
  p_less.style.width = 24
  local p_val = p_row.add{type = "label", caption = tostring(h.priority or 3), tooltip = {"colony-gui.building-priority-tt"}}
  p_val.style.width = 24
  p_val.style.horizontal_align = "center"
  local p_more = p_row.add{type = "button", name = "colony_hut_prio_more", caption = "+", tooltip = {"colony-gui.priority-more-tt"}}
  p_more.style.width = 24
  frame.add{type = "line"}
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
  local r = (h.job == "forage" and colony_mod.FORAGE_RADIUS or (h.job == "guard" and garrison.RANGE) or colony_mod.HUT_RADIUS)
  frame.add{type = "label", caption = {"colony-gui-hut.range", r}}
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
    if def.keep and #def.keep > 0 then
      local inv = h.entity.type == "lab"
        and h.entity.get_inventory(defines.inventory.lab_input)
        or h.entity.get_inventory(defines.inventory.chest)
      local parts = {}
      for _, item in ipairs(def.keep) do
        parts[#parts + 1] = string.format("[item=%s] %d", item, inv and inv.get_item_count(item) or 0)
      end
      frame.add{type = "label", caption = {"colony-gui-hut.inputs", table.concat(parts, "  ")}}
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
  local hut_res = (h.job == "forage" and "colony-forage")
    or (h.job == "chop" and "wood")
    or (h.job == "farm" and "colony-produce")
    or (h.job == "hunt" and "colony-meat")
    or (h.job == "fish" and "colony-fish")
  if hut_res then
    local colony = storage.colonies[h.colony_id]
    if colony then
      local q_row = frame.add{type = "flow", direction = "horizontal"}
      q_row.style.vertical_align = "center"
      q_row.add{type = "label", caption = {"colony-gui-hut.quota-target"}, style = "bold_label"}
      local b_less = q_row.add{type = "button", name = "colony_quota_" .. hut_res .. "_less", caption = "-",
        tooltip = {"colony-gui-hut.quota-less-tt"}}
      b_less.style.width = 18; b_less.style.height = 20
      local base_tgt = colony_mod.base_quota_target(colony, hut_res)
      local eff_tgt = colony_mod.quota_target(colony, hut_res)
      local extra = eff_tgt - base_tgt
      local txt = (base_tgt == 0) and {"colony-gui-info.quota-unlimited"}
        or (extra > 0 and (tostring(base_tgt) .. " (+" .. extra .. ")") or tostring(base_tgt))
      local q_lbl = q_row.add{type = "label", caption = txt}
      q_lbl.style.width = 68; q_lbl.style.horizontal_align = "center"
      q_lbl.tooltip = {"colony-gui-info.quota-target-tt",
        (base_tgt == 0) and {"colony-gui-info.quota-unlimited"} or tostring(eff_tgt),
        (base_tgt == 0) and {"colony-gui-info.quota-unlimited"} or tostring(base_tgt),
        tostring(extra)}
      local b_more = q_row.add{type = "button", name = "colony_quota_" .. hut_res .. "_more", caption = "+",
        tooltip = {"colony-gui-hut.quota-more-tt"}}
      b_more.style.width = 18; b_more.style.height = 20

      local cb = q_row.add{type = "checkbox", name = "colony_hut_overflow_" .. hut_res,
        state = colony_mod.overflow_allowed(colony, hut_res),
        caption = {"colony-gui-hut.idle-collect"}, tooltip = {"colony-gui-hut.idle-collect-tt"}}
      cb.style.left_margin = 8
    end
  end
  if h.job == "mine" then
    -- Ore priority (#74): which rock this hut goes for first, instead of always the closest one.
    frame.add{type = "line"}
    frame.add{type = "label", caption = {"colony-gui-hut.ore-priority"}, style = "bold_label"}
    local ranks = mine_plan.effective(h.ores)
    local colony = storage.colonies[h.colony_id]
    for _, ore in ipairs(mine_plan.ORES) do
      local row = frame.add{type = "flow", direction = "horizontal"}
      row.style.vertical_align = "center"
      local name = row.add{type = "label", caption = "[item=" .. ore .. "]"}
      name.style.width = 64
      row.add{type = "button", name = "colony_ore_" .. ore .. "_less", caption = "-",
        tooltip = {"colony-gui-hut.ore-less-tt"}}
      local rank = row.add{type = "label", caption = ranks[ore] > 0 and tostring(ranks[ore]) or {"colony-gui-info.off"}}
      rank.style.width = 24
      rank.style.horizontal_align = "center"
      row.add{type = "button", name = "colony_ore_" .. ore .. "_more", caption = "+",
        tooltip = {"colony-gui-hut.ore-more-tt"}}
      if colony then
        local qb_less = row.add{type = "button", name = "colony_quota_" .. ore .. "_less", caption = "-",
          tooltip = {"colony-gui-hut.quota-less-tt"}}
        qb_less.style.width = 18; qb_less.style.height = 20
        local base_tgt = colony_mod.base_quota_target(colony, ore)
        local eff_tgt = colony_mod.quota_target(colony, ore)
        local extra = eff_tgt - base_tgt
        local txt = (base_tgt == 0) and {"colony-gui-info.quota-unlimited"}
          or (extra > 0 and (tostring(base_tgt) .. " (+" .. extra .. ")") or tostring(base_tgt))
        local q_lbl = row.add{type = "label", caption = txt}
        q_lbl.style.width = 54; q_lbl.style.horizontal_align = "center"
        q_lbl.tooltip = {"colony-gui-info.quota-target-tt",
          (base_tgt == 0) and {"colony-gui-info.quota-unlimited"} or tostring(eff_tgt),
          (base_tgt == 0) and {"colony-gui-info.quota-unlimited"} or tostring(base_tgt),
          tostring(extra)}
        local qb_more = row.add{type = "button", name = "colony_quota_" .. ore .. "_more", caption = "+",
          tooltip = {"colony-gui-hut.quota-more-tt"}}
        qb_more.style.width = 18; qb_more.style.height = 20

        local ocb = row.add{type = "checkbox", name = "colony_hut_overflow_" .. ore,
          state = colony_mod.overflow_allowed(colony, ore),
          tooltip = {"colony-gui-hut.idle-collect-tt"}}
        ocb.style.left_margin = 4
      end
    end
    frame.add{type = "label", caption = {"colony-gui-hut.ore-hint"}}
  end
  if h.job ~= "preserve" and h.job ~= "fish" and h.job ~= "research" and h.job ~= "heal" and h.job ~= "guard" then
    local sites = work.site_count(h)
    if sites > 0 then
      frame.add{type = "label", caption = {"colony-gui-hut.sites", sites}}
    else
      local warn = frame.add{type = "label", caption = {"", "[color=red]⚠ [/color]", {"colony-gui-hut.no-sites"}}, style = "bold_label"}
      local lbl = frame.add{type = "label", caption = {"colony-gui-hut.sites", 0}}
      lbl.style.font_color = {1, 0.3, 0.3}
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
      h.entity.get_item_count("colony-fertilizer"), h.logistics_enabled, h.priority, colony and colony.quotas}) then
    fill_hut(frame.body, h)
  end
  draw_hut_range(h)
  scheduler.after(30, "gui.refresh_hut", d)
end)

-- ---------- colony overview + priority matrix (#38 #27) ----------
local function pct(x) return string.format("%.0f%%", math.min(math.max(x, 0), 9.99) * 100) end

local function build_info(body, colony)
  body.clear()

  -- 1. Advice box container (stable presence)
  local adv_box = body.add{type = "flow", name = "adv_box", direction = "vertical"}
  adv_box.add{type = "label", name = "adv_title", caption = {"colony-advice.title"}, style = "bold_label"}
  adv_box.add{type = "flow", name = "adv_list", direction = "vertical"}
  body.add{type = "line", name = "adv_line"}

  -- 2. Fixed status rows (never collapse height or pop in/out)
  body.add{type = "label", name = "status_growth"}
  body.add{type = "label", name = "status_milestone"}
  body.add{type = "label", name = "status_pop"}
  body.add{type = "label", name = "status_housing"}
  body.add{type = "label", name = "status_food"}
  body.add{type = "label", name = "status_community"}
  body.add{type = "label", name = "status_desirability"}
  body.add{type = "label", name = "status_desirability_parts"}
  body.add{type = "label", name = "status_desirability_inputs"}
  body.add{type = "label", name = "status_jobs"}
  body.add{type = "label", name = "status_territory"}
  body.add{type = "label", name = "status_construction"}

  -- 3. Resources ledger
  body.add{type = "line", name = "res_line"}
  body.add{type = "label", name = "res_title", caption = {"colony-gui-info.resources-title"}, style = "bold_label"}
  local res_scroll = body.add{type = "scroll-pane", name = "res_scroll", direction = "vertical"}
  res_scroll.style.maximal_height = 160
  local res_table = res_scroll.add{type = "table", name = "res_table", column_count = 7, draw_horizontal_lines = true}
  res_table.style.horizontal_spacing = 8
  local h1 = res_table.add{type = "label", caption = {"colony-gui-info.res-item"}, style = "bold_label"}
  h1.style.width = 90
  local h2 = res_table.add{type = "label", caption = {"colony-gui-info.res-stock"}, style = "bold_label"}
  h2.style.width = 40; h2.style.horizontal_align = "right"
  local h3 = res_table.add{type = "label", caption = {"colony-gui-info.res-huts"}, style = "bold_label"}
  h3.style.width = 40; h3.style.horizontal_align = "right"
  local h4 = res_table.add{type = "label", caption = {"colony-gui-info.res-transit"}, style = "bold_label"}
  h4.style.width = 40; h4.style.horizontal_align = "right"
  local h5 = res_table.add{type = "label", caption = {"colony-gui-info.res-total"}, style = "bold_label"}
  h5.style.width = 45; h5.style.horizontal_align = "right"
  local h6 = res_table.add{type = "label", caption = {"colony-gui-info.res-quota"}, style = "bold_label"}
  h6.style.width = 110; h6.style.horizontal_align = "center"
  local h7 = res_table.add{type = "label", caption = {"colony-gui-info.res-idle-collect"}, style = "bold_label"}
  h7.style.width = 45; h7.style.horizontal_align = "center"
  h7.tooltip = {"colony-gui-info.res-idle-collect-tt"}

  -- 4. Colony settings
  body.add{type = "line", name = "opts_line"}
  body.add{type = "checkbox", name = "colony_accept_migrants", state = colony.accept_migrants ~= false,
    caption = {"colony-gui-info.accept-migrants"}, tooltip = {"colony-gui-info.accept-migrants-tt"}}
  local sp_row = body.add{type = "flow", name = "sp_row", direction = "horizontal"}
  sp_row.style.vertical_align = "center"
  sp_row.add{type = "label", caption = {"colony-gui-info.storage-priority"}, style = "bold_label"}
  local sp_less = sp_row.add{type = "button", name = "colony_hall_sprio_less", caption = "-", tooltip = {"colony-gui.priority-less-tt"}}
  sp_less.style.width = 24
  local sp_val = sp_row.add{type = "label", name = "sp_val", caption = tostring(colony.storage_priority or 3), tooltip = {"colony-gui-crate.storage-priority-tt"}}
  sp_val.style.width = 24; sp_val.style.horizontal_align = "center"
  local sp_more = sp_row.add{type = "button", name = "colony_hall_sprio_more", caption = "+", tooltip = {"colony-gui.priority-more-tt"}}
  sp_more.style.width = 24

  -- 5. Workforce & priorities
  body.add{type = "line", name = "wf_line"}
  body.add{type = "label", name = "wf_title", caption = {"colony-gui-info.workforce-title"}, style = "bold_label"}
  local wf_table = body.add{type = "table", name = "wf_table", column_count = 4, draw_horizontal_lines = false}
  wf_table.style.horizontal_spacing = 6
  local wh1 = wf_table.add{type = "label", caption = {"colony-gui-info.wf-job"}, style = "bold_label"}
  wh1.style.width = 68
  local wh2 = wf_table.add{type = "label", caption = {"colony-gui-info.wf-workers"}, style = "bold_label"}
  wh2.style.width = 46; wh2.style.horizontal_align = "center"
  local wh3 = wf_table.add{type = "label", caption = {"colony-gui-info.wf-priority"}, style = "bold_label"}
  wh3.style.width = 66; wh3.style.horizontal_align = "center"
  local wh4 = wf_table.add{type = "label", caption = {"colony-gui-info.wf-target"}, style = "bold_label"}
  wh4.style.width = 82; wh4.style.horizontal_align = "center"

  for _, job in ipairs(jobs.JOBS) do
    local j_name = wf_table.add{type = "label", caption = {"colony-gui-info.job-" .. job}}
    j_name.style.width = 68
    local w_lbl = wf_table.add{type = "label", name = "wf_wlbl_" .. job, caption = "0"}
    w_lbl.style.width = 46; w_lbl.style.horizontal_align = "center"

    local p_flow = wf_table.add{type = "flow", name = "wf_pflow_" .. job, direction = "horizontal"}
    p_flow.style.vertical_align = "center"
    local b_less = p_flow.add{type = "button", name = "colony_prio_" .. job .. "_less", caption = "-",
      tooltip = {"colony-gui-info.less-tt"}}
    b_less.style.width = 18; b_less.style.height = 20
    local rank_lbl = p_flow.add{type = "label", name = "wf_rank_" .. job, caption = "1"}
    rank_lbl.style.width = 24; rank_lbl.style.horizontal_align = "center"
    local b_more = p_flow.add{type = "button", name = "colony_prio_" .. job .. "_more", caption = "+",
      tooltip = {"colony-gui-info.more-tt"}}
    b_more.style.width = 18; b_more.style.height = 20

    local t_flow = wf_table.add{type = "flow", name = "wf_tflow_" .. job, direction = "horizontal"}
    t_flow.style.vertical_align = "center"
    local tb_less = t_flow.add{type = "button", name = "colony_target_" .. job .. "_less", caption = "-",
      tooltip = {"colony-gui-info.target-less-tt"}}
    tb_less.style.width = 18; tb_less.style.height = 20
    local tgt_lbl = t_flow.add{type = "label", name = "wf_tgt_" .. job, caption = {"colony-gui-info.auto"}}
    tgt_lbl.style.width = 38; tgt_lbl.style.horizontal_align = "center"
    local tb_more = t_flow.add{type = "button", name = "colony_target_" .. job .. "_more", caption = "+",
      tooltip = {"colony-gui-info.target-more-tt"}}
    tb_more.style.width = 18; tb_more.style.height = 20
  end

  local haul_off = body.add{type = "label", name = "wf_haul_off", caption = {"colony-gui-info.haul-off"}}
  haul_off.visible = false
  local btn_row = body.add{type = "flow", name = "btn_row", direction = "horizontal"}
  btn_row.add{type = "button", name = "colony_prio_reset", caption = {"colony-gui-info.reset-priority"}}
  btn_row.add{type = "button", name = "colony_target_reset", caption = {"colony-gui-info.reset-target"}}
  body.add{type = "label", name = "wf_hint", caption = {"colony-gui-info.workforce-hint"}}

  body.add{type = "line", name = "roster_line"}
  body.add{type = "label", name = "roster_moved", caption = {"colony-gui-info.roster-moved"}}
end

local function update_info(body, colony)
  local st = colony_mod.stats(colony)
  local counts = work.job_counts(colony)
  local busy = 0
  for _, job in ipairs(jobs.JOBS) do busy = busy + (counts[job] or 0) end

  -- 1. Advice
  local problems = M.colony_advice(colony, st, counts)
  local adv_box = body.adv_box
  if adv_box and adv_box.adv_list then
    local adv_sig = serpent.line(problems, {comment = false, sortkeys = true})
    if not adv_box.tags or adv_box.tags.sig ~= adv_sig then
      adv_box.tags = {sig = adv_sig}
      local adv_list = adv_box.adv_list
      adv_list.clear()
      if #problems == 0 then
        adv_list.add{type = "label", caption = {"", "[color=green]", {"colony-advice.no-issues"}, "[/color]"}}
      else
        for _, a in ipairs(problems) do
          local args = a.args
          if a.key == "no-tool" then args = {{"item-name." .. a.args[1]}, a.args[2]} end
          add_advice_line(adv_list, a.level, a.key, args[1], args[2])
        end
      end
    end
  end

  -- 2. Status labels
  local g = advice.growth{pop = st.pop, capacity = st.capacity, d = st.d, parts = st.parts, accept = colony.accept_migrants}
  local gcol = g.level == "green" and "green" or (g.level == "red" and "red" or "orange")
  if body.status_growth then
    body.status_growth.caption = {"", "[color=" .. gcol .. "]",
      {"colony-status." .. g.key, g.args[1] and {"colony-advice.factor-" .. g.args[1]} or ""}, "[/color]"}
  end

  local facts, researched = colony_mod.milestone_facts(colony.hall.force)
  local nxt = milestones.next(facts, researched)
  if body.status_milestone then
    if nxt then
      body.status_milestone.caption = {"colony-gui-info.next-milestone", {"technology-name." .. nxt.tech},
        nxt.have, nxt.need}
      body.status_milestone.tooltip = {"colony-milestone." .. nxt.tech}
    else
      body.status_milestone.caption = {"colony-gui-info.milestones-done"}
      body.status_milestone.tooltip = ""
    end
  end

  if body.status_pop then
    body.status_pop.caption = {"colony-gui-info.population", st.pop, st.capacity}
  end

  if body.status_housing then
    body.status_housing.caption = {"colony-gui-info.housing", st.tents, st.cabins, st.homesteads or 0, st.apartments or 0, math.max(st.capacity - st.pop, 0)}
  end

  local colour = st.food_ratio < 0.5 and "red" or (st.food_ratio < 1 and "orange" or "green")
  if body.status_food then
    body.status_food.caption = {"", {"colony-gui-info.food", st.food, st.food_target},
      "  [color=" .. colour .. "]" .. pct(st.food_ratio) .. "[/color]"}
  end

  if body.status_community then
    local comm_parts = {}
    if (st.sick or 0) > 0 then
      comm_parts[#comm_parts + 1] = tostring(st.sick) .. " sick"
    end
    if (st.fallen or 0) > 0 then
      comm_parts[#comm_parts + 1] = tostring(st.fallen) .. " dead"
    end
    if (st.away or 0) > 0 or (st.commuters_here or 0) > 0 then
      comm_parts[#comm_parts + 1] = tostring(st.away or 0) .. " away, " .. tostring(st.commuters_here or 0) .. " commuters"
    end
    if #comm_parts == 0 then
      body.status_community.caption = {"colony-gui-info.healthy"}
    else
      body.status_community.caption = {"colony-gui-info.community", table.concat(comm_parts, " | ")}
    end
  end

  local parts = st.parts
  if body.status_desirability then
    body.status_desirability.caption = {"colony-gui-info.desirability", string.format("%.2f", st.d),
      string.format("%.2f", desirability.defaults.migrate_in), string.format("%.2f", desirability.defaults.leave_below)}
  end
  if body.status_desirability_parts then
    body.status_desirability_parts.caption = {"colony-gui-info.desirability-parts",
      string.format("%.2f", parts.food or 0), string.format("%.2f", parts.housing or 0),
      string.format("%.2f", parts.scenic or 0), string.format("%.2f", parts.leisure or 0),
      string.format("%.2f", parts.pollution or 0), string.format("%.2f", parts.deaths or 0),
      string.format("%.2f", parts.recreation or 0), string.format("%.2f", parts.sickness or 0),
      string.format("%.2f", parts.tents or 0), string.format("%.2f", parts.jobs or 0),
      string.format("%.2f", parts.privacy or 0)}
  end
  if body.status_desirability_inputs then
    body.status_desirability_inputs.caption = {"colony-gui-info.desirability-inputs",
      string.format("%.2f", st.scenic or 0), string.format("%.2f", st.pollution or 0)}
  end
  if body.status_jobs then
    body.status_jobs.caption = {"colony-gui-info.jobs",
      counts.haul or 0, counts.forage or 0, counts.chop or 0, counts.mine or 0, counts.farm or 0,
      counts.hunt or 0, counts.fish or 0, counts.preserve or 0, counts.construct or 0,
      counts.research or 0, counts.heal or 0, counts.guard or 0, math.max(st.pop - busy, 0)}
  end
  if body.status_territory then
    body.status_territory.caption = {"colony-gui-info.territory", st.chunks, st.huts, st.machines, st.towers, st.crates}
  end
  if body.status_construction then
    body.status_construction.caption = {"colony-gui-info.construction", st.ghosts or 0, st.damaged or 0}
  end

  -- 3. Resources ledger
  local ledger_data = colony_mod.ledger_snapshot(colony)
  local res_scroll = body.res_scroll
  local res_table = res_scroll and res_scroll.res_table
  if res_table and ledger_data and ledger_data.items then
    for _, it in ipairs(ledger_data.items) do
      local item_key = it.item
      if not res_table["res_stock_" .. item_key] then
        local name_lbl = res_table.add{type = "label", name = "res_name_" .. item_key,
          caption = {"", "[item=" .. item_key .. "] ", {"item-name." .. item_key}}}
        name_lbl.style.width = 90
        local l_stock = res_table.add{type = "label", name = "res_stock_" .. item_key, caption = "0"}
        l_stock.style.width = 40; l_stock.style.horizontal_align = "right"
        local l_huts = res_table.add{type = "label", name = "res_huts_" .. item_key, caption = "-"}
        l_huts.style.width = 40; l_huts.style.horizontal_align = "right"
        local l_trans = res_table.add{type = "label", name = "res_trans_" .. item_key, caption = "-"}
        l_trans.style.width = 40; l_trans.style.horizontal_align = "right"
        local l_tot = res_table.add{type = "label", name = "res_tot_" .. item_key, caption = "0", style = "bold_label"}
        l_tot.style.width = 45; l_tot.style.horizontal_align = "right"

        if quota.RESOURCES[item_key] then
          local q_flow = res_table.add{type = "flow", name = "res_qflow_" .. item_key, direction = "horizontal"}
          q_flow.style.vertical_align = "center"
          local b_less = q_flow.add{type = "button", name = "colony_quota_" .. item_key .. "_less", caption = "-",
            tooltip = {"colony-gui-info.quota-less-tt"}}
          b_less.style.width = 18; b_less.style.height = 20
          local q_lbl = q_flow.add{type = "label", name = "res_qlbl_" .. item_key, caption = ""}
          q_lbl.style.width = 68; q_lbl.style.horizontal_align = "center"
          local b_more = q_flow.add{type = "button", name = "colony_quota_" .. item_key .. "_more", caption = "+",
            tooltip = {"colony-gui-info.quota-more-tt"}}
          b_more.style.width = 18; b_more.style.height = 20
        else
          local dash = res_table.add{type = "label", name = "res_qdash_" .. item_key, caption = "-"}
          dash.style.width = 110; dash.style.horizontal_align = "center"
        end

        if quota.RESOURCES[item_key] and quota.RESOURCES[item_key].job then
          local cb = res_table.add{type = "checkbox", name = "colony_overflow_" .. item_key,
            state = colony_mod.overflow_allowed(colony, item_key),
            tooltip = {"colony-gui-info.res-idle-collect-tt"}}
          cb.style.horizontal_align = "center"
        else
          local dash2 = res_table.add{type = "label", name = "res_idledash_" .. item_key, caption = "-"}
          dash2.style.width = 45; dash2.style.horizontal_align = "center"
        end
      end

      local name_lbl = res_table["res_name_" .. item_key]
      if name_lbl then
        local tt = {"", {"item-name." .. item_key}, "\n", {"colony-gui-info.tt-stock", it.stock}}
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
      end

      local l_stock = res_table["res_stock_" .. item_key]
      if l_stock then l_stock.caption = tostring(it.stock) end
      local l_huts = res_table["res_huts_" .. item_key]
      if l_huts then l_huts.caption = it.huts > 0 and tostring(it.huts) or "-" end
      local l_trans = res_table["res_trans_" .. item_key]
      if l_trans then l_trans.caption = it.transit > 0 and tostring(it.transit) or "-" end
      local l_tot = res_table["res_tot_" .. item_key]
      if l_tot then l_tot.caption = tostring(it.total) end

      if quota.RESOURCES[item_key] then
        local base_tgt = colony_mod.base_quota_target(colony, item_key)
        local eff_tgt = colony_mod.quota_target(colony, item_key)
        local extra = eff_tgt - base_tgt
        local txt = (base_tgt == 0) and {"colony-gui-info.quota-unlimited"}
          or (extra > 0 and (tostring(base_tgt) .. " (+" .. extra .. ")") or tostring(base_tgt))
        local q_flow = res_table["res_qflow_" .. item_key]
        local q_lbl = q_flow and q_flow["res_qlbl_" .. item_key]
        if q_lbl then
          q_lbl.caption = txt
          q_lbl.tooltip = {"colony-gui-info.quota-target-tt",
            (base_tgt == 0) and {"colony-gui-info.quota-unlimited"} or tostring(eff_tgt),
            (base_tgt == 0) and {"colony-gui-info.quota-unlimited"} or tostring(base_tgt),
            tostring(extra)}
        end
        local cb = res_table["colony_overflow_" .. item_key]
        if cb then
          cb.state = colony_mod.overflow_allowed(colony, item_key)
        end
      end
    end
  end

  -- 4. Options
  if body.colony_accept_migrants then
    body.colony_accept_migrants.state = colony.accept_migrants ~= false
  end
  local sp_row = body.sp_row
  if sp_row and sp_row.sp_val then
    sp_row.sp_val.caption = tostring(colony.storage_priority or 3)
  end

  -- 5. Workforce table
  local p = jobs.effective(colony.priority)
  local wf_table = body.wf_table
  if wf_table then
    for _, job in ipairs(jobs.JOBS) do
      local cur = counts[job] or 0
      local w_lbl = wf_table["wf_wlbl_" .. job]
      if w_lbl then w_lbl.caption = tostring(cur) end
      local p_flow = wf_table["wf_pflow_" .. job]
      local rank_lbl = p_flow and p_flow["wf_rank_" .. job]
      if rank_lbl then rank_lbl.caption = p[job] > 0 and tostring(p[job]) or {"colony-gui-info.off"} end
      local tgt = colony_mod.job_target(colony, job)
      local tgt_text = tgt ~= nil and tostring(tgt) or {"colony-gui-info.auto"}
      local t_flow = wf_table["wf_tflow_" .. job]
      local tgt_lbl = t_flow and t_flow["wf_tgt_" .. job]
      if tgt_lbl then tgt_lbl.caption = tgt_text end
    end
  end
  if body.wf_haul_off then
    body.wf_haul_off.visible = (p.haul == 0)
  end
end

local function fill_info(frame, colony)
  if not frame.status_pop then
    build_info(frame, colony)
  end
  update_info(frame, colony)
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
      colony.job_targets, colony.accept_migrants, colony.storage_priority, colony.quotas}) then
    fill_info(frame.body, colony)
  end
  scheduler.after(30, "gui.refresh_info", d)
end)

events.on(defines.events.on_gui_click, function(ev)
  local name = ev.element.name
  local q_item, q_dir = name:match("^colony_quota_(.-)_(%a+)$")
  if q_item and (q_dir == "more" or q_dir == "less") then
    local player = game.get_player(ev.player_index)
    local e = player and player.opened
    if not (e and e.valid) then return end
    local colony = colony_at(e)
    if not colony then return end
    local base = colony_mod.base_quota_target(colony, q_item)
    local is_tool = quota.RESOURCES[q_item] and quota.RESOURCES[q_item].category == "tool" and q_item ~= "colony-arrow"
    local step = is_tool and (ev.shift and 5 or 1) or (ev.shift and 50 or 10)
    local new_tgt
    if q_dir == "more" then
      if base == 0 and not is_tool then new_tgt = 10
      else new_tgt = base + step end
    else
      if base <= step then new_tgt = 0 -- 0 = unlimited or none
      else new_tgt = base - step end
    end
    colony_mod.set_quota(colony, q_item, new_tgt)
    local frame = player.gui.relative[INFO_FRAME]
    if frame and frame.body then fill_info(frame.body, colony) end
    local hut_frame = player.gui.relative[HUT_FRAME]
    if hut_frame and hut_frame.body and colony.huts then
      local h = colony.huts[e.unit_number]
      if h then fill_hut(hut_frame.body, h) end
    end
    return
  end
  local prio_type, prio_dir = name:match("^colony_(%a+)_prio_(%a+)$")
  if prio_type and (prio_dir == "more" or prio_dir == "less") then
    local player = game.get_player(ev.player_index)
    local e = player and player.opened
    if not (e and e.valid) then return end
    local colony = colony_at(e)
    if not colony then return end
    local delta = prio_dir == "more" and -1 or 1
    if prio_type == "house" and colony.houses then
      local h = colony.houses[e.unit_number]
      if h then
        local cur = h.priority or 3
        h.priority = math.max(1, math.min(5, cur + delta))
        local frame = player.gui.relative[HOUSE_FRAME]
        if frame and frame.body then fill_house(frame.body, h, colony) end
      end
    elseif prio_type == "hut" and colony.huts then
      local h = colony.huts[e.unit_number]
      if h then
        local cur = h.priority or 3
        h.priority = math.max(1, math.min(5, cur + delta))
        colony_mod.reassign_workforce(colony)
        local frame = player.gui.relative[HUT_FRAME]
        if frame and frame.body then fill_hut(frame.body, h) end
      end
    elseif prio_type == "crate" then
      local _, c, _, body, e = crate_ctx(ev)
      if c then
        local cur = c.priority or 3
        c.priority = math.max(1, math.min(5, cur + delta))
        if e.type == "entity-ghost" then e.tags = tags.dictionary(tags.crate(c)) end
        if body then fill_crate(body, c) end
      end
    elseif prio_type == "machine" then
      local player, e, colony, body, m = machine_ctx(ev)
      if m then
        local cur = m.priority or 4
        m.priority = math.max(1, math.min(5, cur + delta))
        if e.type == "entity-ghost" then e.tags = tags.dictionary(tags.machine(m)) end
        if body then fill_machine(body, m, e) end
      end
    end
    return
  end
  if name == "colony_hall_sprio_less" or name == "colony_hall_sprio_more" then
    local player = game.get_player(ev.player_index)
    local e = player and player.opened
    if not (e and e.valid and e.name == colony_mod.HALL) then return end
    local colony = colony_at(e)
    if not colony then return end
    local delta = name == "colony_hall_sprio_more" and -1 or 1
    local cur = colony.storage_priority or 3
    colony.storage_priority = math.max(1, math.min(5, cur + delta))
    local frame = player.gui.relative[INFO_FRAME]
    if frame and frame.body then fill_info(frame.body, colony) end
    return
  end
  local clear_row = tonumber(name:match("^colony_crate_clear_(%d+)$"))
  if clear_row then
    local _, c, _, body = crate_ctx(ev)
    if c then
      c.filters[clear_row] = nil
      if body then fill_crate(body, c) end
    end
    return
  end
  local ore, ore_dir = name:match("^colony_ore_(.-)_(%a+)$")
  if ore and (ore_dir == "more" or ore_dir == "less") then
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
  local target_job, target_dir = name:match("^colony_target_(%a+)_(%a+)$")
  if (target_job and (target_dir == "more" or target_dir == "less")) or name == "colony_target_reset" then
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
  local job, dir = name:match("^colony_prio_(%a+)_(%a+)$")
  if not ((job and (dir == "more" or dir == "less")) or name == "colony_prio_reset") then return end
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
  frame.add{type = "checkbox", name = "colony_crate_logistics", state = c.logistics_enabled ~= false,
    caption = {"colony-gui.logistics-enable"}, tooltip = {"colony-gui.logistics-enable-tt"}}
  local is_wh = c.kind == crates.WAREHOUSE
  local p_lbl = is_wh and {"colony-gui-crate.storage-priority"} or {"colony-gui.priority-label"}
  local p_tt = is_wh and {"colony-gui-crate.storage-priority-tt"} or {"colony-gui.building-priority-tt"}
  local p_row = frame.add{type = "flow", direction = "horizontal"}
  p_row.style.vertical_align = "center"
  p_row.add{type = "label", caption = p_lbl, tooltip = p_tt, style = "bold_label"}
  local p_less = p_row.add{type = "button", name = "colony_crate_prio_less", caption = "-", tooltip = {"colony-gui.priority-less-tt"}}
  p_less.style.width = 24
  local p_val = p_row.add{type = "label", caption = tostring(c.priority or (is_wh and 2 or 3)), tooltip = p_tt}
  p_val.style.width = 24
  p_val.style.horizontal_align = "center"
  local p_more = p_row.add{type = "button", name = "colony_crate_prio_more", caption = "+", tooltip = {"colony-gui.priority-more-tt"}}
  p_more.style.width = 24
  frame.add{type = "line"}
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
  elseif is_wh then
    frame.add{type = "label", caption = {"colony-gui-crate.warehouse-hint"}}
    frame.add{type = "checkbox", name = "colony_warehouse_all", state = c.accept_all ~= false,
      caption = {"colony-gui-crate.accept-all"}, tooltip = {"colony-gui-crate.accept-all-tt"}}
    if c.accept_all == false then
      frame.add{type = "label", caption = {"colony-gui-crate.whitelist-label"}, style = "bold_label"}
      c.filters = c.filters or {}
      for i = 1, crates.FILTER_ROWS do
        local f = c.filters[i]
        local row = frame.add{type = "flow", direction = "horizontal"}
        row.style.vertical_align = "center"
        row.add{type = "choose-elem-button", name = "colony_crate_item_" .. i, elem_type = "item", item = f and f.item}
        local clear = row.add{type = "button", name = "colony_crate_clear_" .. i, caption = "x",
          tooltip = {"colony-gui-crate.clear-tt"}}
        clear.style.width = 24
      end
    end
  else
    frame.add{type = "label", caption = {"colony-gui-crate.supply-hint"}}
  end
  frame.add{type = "line"}
  frame.add{type = "label", caption = {"colony-gui-crate.contents"}, style = "bold_label"}
  if #contents == 0 then frame.add{type = "label", caption = {"colony-gui-crate.empty"}} end
  for _, item in ipairs(contents) do
    frame.add{type = "label", caption = {"", "[item=" .. item.name .. "]", " " .. item.count}}
  end
end

local function copy_rows(rows)
  local out = {}
  for row, r in pairs(rows or {}) do
    if r and r.item then out[row] = {item = r.item, count = r.count} end
  end
  return out
end

local function open_crate(player, e)
  local old = player.gui.relative[CRATE_FRAME]; if old then old.destroy() end
  local name = (e.type == "entity-ghost") and e.ghost_name or e.name
  local names = {colony_mod.SUPPLY_CRATE, colony_mod.DEMAND_CRATE, colony_mod.WAREHOUSE}
  if e.type == "entity-ghost" then
    names = {"entity-ghost", colony_mod.SUPPLY_CRATE, colony_mod.DEMAND_CRATE, colony_mod.WAREHOUSE}
  end
  local frame = player.gui.relative.add{type = "frame", name = CRATE_FRAME, direction = "vertical",
    caption = e.localised_name, anchor = {gui = defines.relative_gui_type.container_gui,
      position = defines.relative_gui_position.right,
      names = names}}
  local body = frame.add{type = "flow", name = "body", direction = "vertical"}
  local colony = colony_at(e)
  if not colony then body.add{type = "label", caption = {"colony-gui-crate.outside"}}; return end
  local c
  if e.type == "entity-ghost" then
    local payload = e.tags and tags.decode(e.tags)
    local kind = colony_mod.CRATES[name]
    if payload and payload.crate then
      c = {entity = e, kind = kind, colony_id = colony.id,
        filters = copy_rows(payload.crate.filters),
        accept_all = payload.crate.accept_all,
        priority = payload.crate.priority or 3,
        logistics_enabled = true}
    else
      c = {entity = e, kind = kind, colony_id = colony.id,
        filters = {},
        accept_all = (kind == crates.WAREHOUSE and true or nil),
        priority = 3,
        logistics_enabled = true}
    end
  else
    c = colony.crates and colony.crates[e.unit_number]
  end
  if not c then body.add{type = "label", caption = {"colony-gui-crate.outside"}}; return end
  fill_crate(body, c)
end

function crate_ctx(ev)
  local player = game.get_player(ev.player_index)
  local e = player and player.opened
  if not (e and e.valid and player.opened_gui_type == defines.gui_type.entity) then return end
  local colony = colony_at(e)
  if not colony then return end
  local c
  if e.type == "entity-ghost" then
    local name = e.ghost_name
    local payload = e.tags and tags.decode(e.tags)
    local kind = colony_mod.CRATES[name]
    if payload and payload.crate then
      c = {entity = e, kind = kind, colony_id = colony.id,
        filters = copy_rows(payload.crate.filters),
        accept_all = payload.crate.accept_all,
        priority = payload.crate.priority or 3,
        logistics_enabled = true}
    else
      c = {entity = e, kind = kind, colony_id = colony.id,
        filters = {},
        accept_all = (kind == crates.WAREHOUSE and true or nil),
        priority = 3,
        logistics_enabled = true}
    end
  else
    c = colony.crates and colony.crates[e.unit_number]
  end
  if not c then return end
  local frame = player.gui.relative[CRATE_FRAME]
  return player, c, colony, frame and frame.body, e
end

-- ---------- machine supply panel ----------
local function req_status(e, m, req)
  local colony = colony_at(e)
  local have = e.valid and (e.type ~= "entity-ghost" and e.get_item_count(req.item) or 0) or 0
  local state = advice.request{have = have, count = req.count, inflight = m.inflight and m.inflight[req.item] or 0,
    stock = colony and colony_mod.stock_count(colony, req.item) or 0,
    haul_rank = colony and jobs.effective(colony.priority).haul or 1}
  local lvl = (state == "no-stock" or state == "haul-off") and "red" or (state == "queued" and "orange" or "green")
  return {"", "[color=" .. lvl .. "]", {"colony-advice.req-" .. state}, "[/color]"}
end

function fill_machine(frame, m, e)
  frame.clear()
  frame.add{type = "checkbox", name = "colony_supply_enabled", state = m ~= nil and m.enabled or false,
    caption = {"colony-gui.supply-enable"}, tooltip = {"colony-gui.supply-enable-tt"}}
  if not (m and m.enabled) then return end
  local p_row = frame.add{type = "flow", direction = "horizontal"}
  p_row.style.vertical_align = "center"
  p_row.add{type = "label", caption = {"colony-gui.priority-label"}, tooltip = {"colony-gui.building-priority-tt"}, style = "bold_label"}
  local p_less = p_row.add{type = "button", name = "colony_machine_prio_less", caption = "-", tooltip = {"colony-gui.priority-less-tt"}}
  p_less.style.width = 24
  local p_val = p_row.add{type = "label", caption = tostring(m.priority or 4), tooltip = {"colony-gui.building-priority-tt"}}
  p_val.style.width = 24
  p_val.style.horizontal_align = "center"
  local p_more = p_row.add{type = "button", name = "colony_machine_prio_more", caption = "+", tooltip = {"colony-gui.priority-more-tt"}}
  p_more.style.width = 24
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
  local type = (e.type == "entity-ghost") and e.ghost_type or e.type
  local gui_name = MACHINE_GUIS[type]
  local gt = gui_name and defines.relative_gui_type[gui_name]
  if not gt then return end
  local frame = player.gui.relative.add{type = "frame", name = MACHINE_FRAME, direction = "vertical",
    caption = {"colony-gui.supply-title"}, anchor = {gui = gt, position = defines.relative_gui_position.right}}
  local body = frame.add{type = "flow", name = "body", direction = "vertical"}
  local colony = colony_at(e)
  if not colony then body.add{type = "label", caption = {"colony-gui.supply-outside"}}; return end
  local m
  if e.type == "entity-ghost" then
    local payload = e.tags and tags.decode(e.tags)
    if payload and payload.machine then
      m = {entity = e, enabled = true, collect = payload.machine.collect ~= false,
        requests = copy_rows(payload.machine.requests),
        priority = payload.machine.priority or 4}
    end
  else
    m = colony.machines and colony.machines[e.unit_number]
  end
  fill_machine(body, m, e)
  scheduler.after(30, "gui.refresh_machine", {player_index = player.index, un = e.unit_number})
end

-- Request status lines are updated in place: rebuilding the panel would drop focus from a count being typed.
scheduler.register("gui.refresh_machine", function(d)
  local player = game.get_player(d.player_index)
  local frame = player and player.valid and player.gui.relative[MACHINE_FRAME]
  local e = player and player.opened
  if not (frame and frame.valid and frame.visible and e and e.valid and e.unit_number == d.un) then return end
  local colony = colony_at(e)
  local m
  if e.type == "entity-ghost" then
    local payload = e.tags and tags.decode(e.tags)
    if payload and payload.machine then
      m = {entity = e, enabled = true, collect = payload.machine.collect ~= false,
        requests = copy_rows(payload.machine.requests),
        priority = payload.machine.priority or 4}
    end
  else
    m = colony and colony.machines and colony.machines[e.unit_number]
  end
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
  local name = (e.type == "entity-ghost") and e.ghost_name or e.name
  local type = (e.type == "entity-ghost") and e.ghost_type or e.type
  if colony_mod.HOUSES[name] then open_house(player, e)
  elseif labour.HUTS[name] then open_hut(player, e)
  elseif name == colony_mod.HALL then open_info(player, e)
  elseif colony_mod.CRATES[name] then open_crate(player, e)
  elseif MACHINE_GUIS[type] then open_machine(player, e) end
end)

machine_ctx = function(ev)
  local player = game.get_player(ev.player_index)
  local e = player and player.opened
  if not (e and e.valid and player.opened_gui_type == defines.gui_type.entity) then return end
  local colony = colony_at(e)
  if not colony then return end
  local m
  if e.type == "entity-ghost" then
    local payload = e.tags and tags.decode(e.tags)
    if payload and payload.machine then
      m = {entity = e, enabled = true, collect = payload.machine.collect ~= false,
        requests = copy_rows(payload.machine.requests),
        priority = payload.machine.priority or 4}
    end
  else
    m = colony.machines and colony.machines[e.unit_number]
  end
  local frame = player.gui.relative[MACHINE_FRAME]
  return player, e, colony, frame and frame.body, m
end

events.on(defines.events.on_gui_checked_state_changed, function(ev)
  local name = ev.element.name
  if name == "colony_house_logistics" then
    local player = game.get_player(ev.player_index)
    local e = player and player.opened
    if not (e and e.valid and colony_mod.HOUSES[e.name]) then return end
    local colony = colony_at(e)
    local h = colony and colony.houses[e.unit_number]
    if h then h.logistics_enabled = ev.element.state end
    return
  end
  if name == "colony_hut_logistics" then
    local player = game.get_player(ev.player_index)
    local e = player and player.opened
    if not (e and e.valid and labour.HUTS[e.name]) then return end
    local colony = colony_at(e)
    local h = colony and colony.huts[e.unit_number]
    if h then
      h.logistics_enabled = ev.element.state
      colony_mod.reassign_workforce(colony)
    end
    return
  end
  if name == "colony_crate_logistics" then
    local _, c, _, _, e = crate_ctx(ev)
    if c then
      c.logistics_enabled = ev.element.state
      if e and e.type == "entity-ghost" then e.tags = tags.dictionary(tags.crate(c)) end
    end
    return
  end
  if name == "colony_warehouse_all" then
    local _, c, _, body, e = crate_ctx(ev)
    if c then
      c.accept_all = ev.element.state
      if body then fill_crate(body, c) end
      if e and e.type == "entity-ghost" then e.tags = tags.dictionary(tags.crate(c)) end
    end
    return
  end
  if name == "colony_accept_migrants" then
    local player = game.get_player(ev.player_index)
    local e = player and player.opened
    if not (e and e.valid and e.name == colony_mod.HALL) then return end
    local colony = colony_at(e)
    if colony then colony.accept_migrants = ev.element.state end
    return
  end
  local overflow_item = name:match("^colony_overflow_(.+)$") or name:match("^colony_hut_overflow_(.+)$")
  if overflow_item then
    local player = game.get_player(ev.player_index)
    local e = player and player.opened
    if not (e and e.valid) then return end
    local colony = colony_at(e)
    if colony then
      colony_mod.set_overflow(colony, overflow_item, ev.element.state)
      local frame = player.gui.relative[INFO_FRAME]
      if frame and frame.body then fill_info(frame.body, colony) end
      local hut_frame = player.gui.relative[HUT_FRAME]
      if hut_frame and hut_frame.body and colony.huts then
        local h = colony.huts[e.unit_number]
        if h then fill_hut(hut_frame.body, h) end
      end
    end
    return
  end
  if name ~= "colony_supply_enabled" and name ~= "colony_supply_collect" then return end
  local player, e, colony, body, m = machine_ctx(ev)
  if not body then return end
  if name == "colony_supply_enabled" then
    if e.type == "entity-ghost" then
      if ev.element.state then
        m = {entity = e, enabled = true, collect = true, priority = 4, requests = colony_mod.default_requests(e)}
        e.tags = tags.dictionary(tags.machine(m))
      else
        m = nil
        e.tags = nil
      end
    else
      m = colony_mod.set_machine(colony, e, ev.element.state)
    end
    fill_machine(body, m, e)
  elseif m then
    m.collect = ev.element.state
    if e.type == "entity-ghost" then e.tags = tags.dictionary(tags.machine(m)) end
  end
end)

local function row_of(name) return tonumber(name:match("^colony_req_%a+_(%d+)$")) end

events.on(defines.events.on_gui_elem_changed, function(ev)
  local row = tonumber(ev.element.name:match("^colony_crate_item_(%d+)$"))
  if row then
    local _, c, _, body, e = crate_ctx(ev)
    if c then
      crates.set_filter(c.filters, row, ev.element.elem_value)
      if body then fill_crate(body, c) end
      if e and e.type == "entity-ghost" then e.tags = tags.dictionary(tags.crate(c)) end
    end
    return
  end
  local i = row_of(ev.element.name)
  if not (i and ev.element.name:find("colony_req_item_", 1, true)) then return end
  local player, e, colony, body, m = machine_ctx(ev)
  if not m then return end
  local item = ev.element.elem_value
  if not item then m.requests[i] = nil
  else m.requests[i] = {item = item, count = m.requests[i] and m.requests[i].count or M.DEFAULT_COUNT} end
  if e.type == "entity-ghost" then e.tags = tags.dictionary(tags.machine(m)) end
  local frame = player and player.gui.relative[MACHINE_FRAME]
  if frame and frame.body then fill_machine(frame.body, m, e) end
end)

events.on(defines.events.on_gui_text_changed, function(ev)
  local row = tonumber(ev.element.name:match("^colony_crate_count_(%d+)$"))
  if row then
    local _, c, _, _, e = crate_ctx(ev)
    if c then
      crates.set_count(c.filters, row, ev.element.text)
      if e and e.type == "entity-ghost" then e.tags = tags.dictionary(tags.crate(c)) end
    end
    return
  end
  local i = row_of(ev.element.name)
  if not (i and ev.element.name:find("colony_req_count_", 1, true)) then return end
  local player, e, colony, body, m = machine_ctx(ev)
  local req = m and m.requests[i]
  if req then
    req.count = tonumber(ev.element.text) or 0
    if e.type == "entity-ghost" then e.tags = tags.dictionary(tags.machine(m)) end
  end
end)

return M
