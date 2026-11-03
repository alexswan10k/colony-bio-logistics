-- PURE: turns plain facts about the colony into "what is holding it back" lines for the panels.
-- Each result is {level = "red"|"amber", key = locale key under colony-advice, args = {...}}; the GUI
-- adapter gathers the facts and renders the lines, so the rules here stay testable offline.
local M = {}

local function add(out, level, key, ...) out[#out + 1] = {level = level, key = key, args = {...}} end

-- Colony-wide blockers, most severe first. facts:
--   pop, capacity, food, haul_rank (0 = hauling off), haulers (colonists on haul now), houses,
--   hall_stock {item -> n}, tool_gaps {{tool=, short=}} (huts that lack that tool), idle
function M.colony(f)
  local out = {}
  if (f.haul_rank or 1) == 0 then add(out, "red", "haul-off") end
  if f.pop > 0 and f.food <= 0 then add(out, "red", "no-food") end
  if (f.houses or 0) == 0 then add(out, "red", "no-houses")
  elseif f.pop >= f.capacity then add(out, "amber", "no-beds") end
  for _, g in ipairs(f.tool_gaps or {}) do
    if (f.hall_stock[g.tool] or 0) <= 0 then add(out, "amber", "no-tool", g.tool, g.short) end
  end
  if f.pop > 0 and (f.haul_rank or 1) > 0 and (f.haulers or 0) == 0 then add(out, "amber", "no-haulers") end
  return out
end

-- Why a hut has fewer workers than its capacity, or nil when it is simply working. facts:
--   needs_tool, tool, tools, capacity, limit, workers, hall_stock (of the tool), inflight (tool on the way),
--   inputs_missing (supply-gated hut lacks inputs), sites (nil = not applicable), haul_rank
function M.hut(f)
  if (f.limit or f.capacity) == 0 then return "paused" end
  if f.needs_tool and f.tools == 0 then
    if (f.inflight or 0) > 0 then return "tool-coming" end
    if (f.hall_stock or 0) <= 0 then return "no-tool-in-hall", f.tool end
    if (f.haul_rank or 1) == 0 then return "haul-off" end
    return "tool-waiting"
  end
  if f.inputs_missing then return "no-inputs" end
  if f.sites ~= nil and f.sites == 0 then return "no-sites" end
  if f.workers == 0 and f.tools > 0 then return "no-workers" end
  return nil
end

-- State of one machine request row. have = in the machine, inflight = on a hauler, stock = colony stock.
function M.request(f)
  if f.have >= f.count then return "stocked" end
  if (f.inflight or 0) > 0 then return "delivering" end
  if (f.stock or 0) <= 0 then return "no-stock" end
  if (f.haul_rank or 1) == 0 then return "haul-off" end
  return "queued"
end

return M
