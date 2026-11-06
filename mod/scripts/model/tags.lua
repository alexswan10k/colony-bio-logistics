---@diagnostic enable: undefined-field, missing-fields
-- PURE: entity tags, the only channel that carries colony state through a blueprint (#36).
--
-- A blueprint stores a per-entity tag dictionary (BlueprintEntity.tags) and the game hands it back on build,
-- copy and revive, so that is where "this furnace is opted in" has to live - it is not part of the entity's
-- own settings. Two facts shape this file:
--   * a sparse table (a filter set only in row 3) has its numeric keys stringified on the way back out
--     (Tags concept), so every list here is a dense array of row records, never a sparse map;
--   * tags read off a built entity are untrusted input (another mod, a stale blueprint, a hand-edited save),
--     so decode validates and clamps instead of trusting.
local crates = require("scripts.model.crates")
local M = {}

M.TAG = "colony-bio-logistics"   -- namespace inside the entity's tag dictionary; other mods may add their own
M.MAX_REQUESTS = 3               -- supply rows a machine panel offers (gui.REQUEST_ROWS)

local function clamp_count(n)
  n = math.floor(tonumber(n) or crates.DEFAULT_COUNT)
  return math.max(0, math.min(n, crates.MAX_COUNT))
end

-- Rows are a possibly sparse list of {item=, count=}; the tag is a dense list of {row=, item=, count=}.
local function encode_rows(rows, max_rows)
  local out = {}
  for row = 1, max_rows do
    local r = rows and rows[row]
    if r and type(r.item) == "string" then
      out[#out + 1] = {row = row, item = r.item, count = clamp_count(r.count)}
    end
  end
  return out
end

local function decode_rows(list, max_rows)
  local out, seen = {}, {}
  if type(list) ~= "table" then return out end
  for _, r in ipairs(list) do
    local row = type(r) == "table" and tonumber(r.row) or nil
    if row and row >= 1 and row <= max_rows and row == math.floor(row) and not seen[row]
      and type(r.item) == "string" and r.item ~= "" then
      seen[row] = true
      out[row] = {item = r.item, count = clamp_count(r.count)}
    end
  end
  return out
end

-- colony.machines[un] -> payload. The opt-in flag itself is implied by the tag existing; `collect` and the
-- player's supply rows are the settings the player would be annoyed to redo.
function M.machine(m)
  return {machine = true, collect = m.collect and true or false,
    requests = encode_rows(m.requests, M.MAX_REQUESTS), priority = m.priority}
end

-- colony.crates[un] -> payload. Only a demand crate uses filters, and an empty filter list still travels so
-- a copied crate is cleared rather than inheriting the pasted-over crate's demands.
function M.crate(c)
  return {crate = true, filters = encode_rows(c.filters, crates.FILTER_ROWS),
    accept_all = c.accept_all ~= false, priority = c.priority}
end

-- Whole tag dictionary for `tags.set_blueprint_entity_tags`, or nil when the colony does not serve the
-- entity. Returned as a dictionary so a caller can merge it over whatever other mods already stored.
function M.dictionary(payload)
  return {[M.TAG] = payload}
end

-- The entity's tag dictionary -> {machine = {collect=, requests=}} or {crate = {filters=}}, or nil when the
-- dictionary says nothing about us. Rows land back in the sparse shape the registries use.
function M.decode(dict)
  if type(dict) ~= "table" then return nil end
  local t = dict[M.TAG]
  if type(t) ~= "table" then return nil end
  if t.machine then
    local p = t.priority and tonumber(t.priority)
    return {machine = {
      collect = t.collect ~= false,
      requests = decode_rows(t.requests, M.MAX_REQUESTS),
      priority = p and math.max(1, math.min(5, math.floor(p))) or nil,
    }}
  elseif t.crate then
    local p = t.priority and tonumber(t.priority)
    return {crate = {
      filters = decode_rows(t.filters, crates.FILTER_ROWS),
      accept_all = t.accept_all ~= false,
      priority = p and math.max(1, math.min(5, math.floor(p))) or nil,
    }}
  end
  return nil
end

return M
