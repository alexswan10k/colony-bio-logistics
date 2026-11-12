-- Colony Ledger adapter (#92): a 1x1 constant combinator the colony writes its own numbers onto.
--
-- The rules (what becomes a signal, in which order, capped at how many) live in model/ledger_signal.lua;
-- this file only talks to the engine: it holds the registry, rewrites the combinator's logistic sections
-- every PUBLISH_TICKS, and answers the GUI.
--
-- Engine facts this relies on (proved by spike s14_circuit):
--   * a constant combinator's signals are its logistic sections; `LuaLogisticSection.filters` is RW, and a
--     filter's `min` is the value that reaches the wire (`max` is ignored);
--   * assigning a whole new filter array clears the slots it no longer mentions, so a shrinking ledger never
--     leaves a stale signal behind;
--   * sections sum onto one network, so more than MAX_SIGNALS items can be published by adding a section;
--   * `LuaWireConnector` methods are called with `.` (they are bound), everything else here uses `:`.
local scheduler = require("scripts.scheduler")
local ls = require("scripts.model.ledger_signal")
local tags = require("scripts.model.tags")

local colony_mod   -- injected by scripts.colony via M.bind (runtime require is illegal)
local M = {}

function M.bind(c) colony_mod = c end

M.NAME = "colony-ledger"
M.MAX_SIGNALS = ls.MAX_SIGNALS   -- re-exported so the panel reports the same ceiling the pass uses
M.MAX_SECTIONS = ls.MAX_SECTIONS
M.PUBLISH_TICKS = 60        -- fast enough for a belt condition, cheap enough to ignore (one publish ~0.03 ms)
M.HANDLER = "colony.ledger"

-- 60 ticks is the publish period; a pass is ~0.03 ms for a full 20-signal section, so a town full of
-- ledgers still costs less than a tick of `fullness` in a big base.

---@param rec table
---@return table[]
function M.published(rec)
  return rec and rec.published or {}
end

---@param rec table
---@return string
function M.mode_of(rec)
  return ls.mode(rec and rec.mode)
end

-- The published list the ledger *would* write right now. Shared by the publish pass and the panel preview,
-- so the panel never shows a number the wire does not carry.
---@param colony table
---@param rec table
---@return table[]
function M.collect(colony, rec)
  local snap = colony_mod.ledger_snapshot(colony)
  local mode = M.mode_of(rec)
  local rows = {}
  for _, row in ipairs(snap.items or {}) do
    rows[#rows + 1] = {
      item = row.item,
      total = row.total,
      -- Only `want` mode needs the target, and quota_target walks the demand graph: skip it for stock.
      target = (mode == "want") and colony_mod.quota_target(colony, row.item) or nil,
    }
  end
  return ls.publish(rows, mode)
end

-- Write one ledger's filters. Returns how many signals it now carries.
---@param rec table
---@param list table[]
---@return integer
function M.write(rec, list)
  local e = rec and rec.entity
  if not (e and e.valid) then return 0 end
  local behavior = e.get_or_create_control_behavior()
  if not behavior then return 0 end
  behavior.enabled = true     -- a player who turns it off gets it back on the next pass, not a dead ledger
  local chunks = ls.chunk(list, ls.MAX_SIGNALS)
  for i = 1, #chunks do
    local section = behavior.get_section(i) or behavior.add_section()
    if not section then break end
    local filters = {}
    for _, row in ipairs(chunks[i]) do
      -- `min` is the value that reaches the wire; the engine rejects anything outside int32.
      filters[#filters + 1] = {value = {type = "item", name = row.item, quality = "normal"},
        min = math.min(row.count, ls.MAX_VALUE)}
    end
    section.filters = filters
  end
  -- Sections the town no longer fills: remove from the end, because removing one renumbers the rest.
  local guard = behavior.sections_count
  while behavior.sections_count > #chunks and guard > 0 do
    guard = guard - 1
    if not behavior.remove_section(behavior.sections_count) then break end
  end
  return #list
end

---@param colony table
---@param rec table
---@return integer
function M.publish_one(colony, rec)
  if not (rec and rec.entity and rec.entity.valid) then return 0 end
  local list = M.collect(colony, rec)
  rec.published, rec.published_tick = list, game.tick
  return M.write(rec, list)
end

-- Publish every ledger of one colony. Returns the number of live ledgers (the timer stops at zero).
---@param colony table
---@return integer
function M.publish(colony)
  local live = 0
  local dead
  for un, rec in pairs(colony.ledgers or {}) do
    if rec.entity and rec.entity.valid then
      live = live + 1
      M.publish_one(colony, rec)
    else
      dead = dead or {}
      dead[#dead + 1] = un
    end
  end
  for _, un in ipairs(dead or {}) do colony.ledgers[un] = nil end
  return live
end

-- One timer chain per colony, started by the first ledger and stopped by the last one going away, so a
-- town with no ledger pays nothing at all.
---@param colony table
function M.schedule(colony)
  if colony.ledger_timer then return end
  colony.ledger_timer = true
  scheduler.after(M.PUBLISH_TICKS, M.HANDLER, {colony_id = colony.id})
end

-- Called from the build path, inside the colony that owns the ground.
---@param colony table
---@param e LuaEntity
---@param dict table|nil blueprint tags carried by the build
---@return table
function M.register(colony, e, dict)
  colony.ledgers = colony.ledgers or {}
  local rec = {entity = e, colony_id = colony.id, mode = ls.DEFAULT_MODE, published = {}}
  colony.ledgers[e.unit_number] = rec
  script.register_on_object_destroyed(e)
  M.schedule(colony)
  if dict then
    local payload = tags.decode(dict)
    if payload and payload.ledger then rec.mode = ls.mode(payload.ledger.mode) end
  end
  -- Publish on the build tick: a player who places a ledger sees its numbers on the wire immediately.
  M.publish_one(colony, rec)
  return rec
end

-- Change the publish mode from the panel and refresh the wire at once (no waiting for the next pass).
---@param colony table
---@param rec table
---@param mode string
---@return boolean
function M.set_mode(colony, rec, mode)
  if not (rec and rec.entity and rec.entity.valid) then return false end
  local new = ls.mode(mode)
  if rec.mode == new then return true end
  rec.mode = new
  M.publish_one(colony, rec)
  return true
end

scheduler.register(M.HANDLER, function(d)
  local colony = storage.colonies and storage.colonies[d.colony_id]
  if not colony then return end
  if M.publish(colony) > 0 then
    scheduler.after(M.PUBLISH_TICKS, M.HANDLER, d)
  else
    colony.ledger_timer = nil   -- nothing left to publish; the next ledger placed restarts the chain
  end
end)

return M
