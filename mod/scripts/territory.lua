-- Territory rules: distance-based radius around Town Hall and Watchtowers (#15 simplified), extended by
-- Habitat Domes (#63) and Waystations (#56). Territory is a smooth circle of tiles centered on the buildings.
local core = require("scripts.model.core")
local waystation = require("scripts.model.waystation")
local M = {}

M.HALL_RADIUS = 64     -- tile radius around Town Hall
M.TOWER_RADIUS = 48    -- tile radius around each Watchtower
M.DOME_RADIUS = 64     -- tile radius around a Habitat Dome (also a colony core)
M.WAYSTATION_RADIUS = waystation.RADIUS   -- one rule, shared with the placement model
M.HALL_RADIUS_SQ = M.HALL_RADIUS * M.HALL_RADIUS
M.TOWER_RADIUS_SQ = M.TOWER_RADIUS * M.TOWER_RADIUS
M.DOME_RADIUS_SQ = M.DOME_RADIUS * M.DOME_RADIUS

function M.core_radius(name)
  if name == core.HALL then return M.HALL_RADIUS end
  if name == core.DOME then return M.DOME_RADIUS end
  return nil
end

-- Deterministic emitter list for one colony: the core entity (hall, which may be a dome) first, then domes
-- and towers in numeric unit-number order. Invalid emitters are skipped, never removed from the colony's
-- tables. Records may hold a LuaEntity directly (as towers do today) or as `rec.entity` (as dome records may).
local function sorted_keys(tbl)
  local keys = {}
  for k in pairs(tbl or {}) do
    if type(k) == "number" then keys[#keys + 1] = k end
  end
  table.sort(keys)
  return keys
end

local function entity_of(rec)
  if type(rec) == "table" and rec.entity then return rec.entity end
  return rec
end

-- A founding core is listed twice by design: once as `colony.hall` and once in `colony.domes`. owner_at
-- returns the same colony id either way, chunks dedupes by chunk key, and the area/overlay consumers union
-- or dedupe the circle — so the duplicate is harmless and keeps the registries independent.
function M.emitters(colony)
  local out = {}
  if not colony then return out end
  local hall = entity_of(colony.hall)
  if hall and hall.valid then
    out[#out + 1] = {entity = hall, radius = M.core_radius(hall.name) or M.HALL_RADIUS, name = hall.name}
  end
  for _, k in ipairs(sorted_keys(colony.domes)) do
    local dome = entity_of(colony.domes[k])
    if dome and dome.valid then
      out[#out + 1] = {entity = dome, radius = M.core_radius(dome.name) or M.DOME_RADIUS, name = dome.name}
    end
  end
  for _, k in ipairs(sorted_keys(colony.towers)) do
    local tower = entity_of(colony.towers[k])
    if tower and tower.valid then
      out[#out + 1] = {entity = tower, radius = M.TOWER_RADIUS, name = tower.name}
    end
  end
  for _, k in ipairs(sorted_keys(colony.waystations)) do
    local ws = entity_of(colony.waystations[k])
    if ws and ws.valid then
      out[#out + 1] = {entity = ws, radius = M.WAYSTATION_RADIUS, name = ws.name}
    end
  end
  return out
end

-- The colony whose territory the position joins if a Waystation is built there: the closest circle by
-- signed gap, accepted only within the Waystation's adjacency tolerance. Colonies are walked in numeric id
-- order so an overlap resolves the same way on both sides of a save/load (owner_at uses the same rule).
function M.owner_near(surface_index, pos, tolerance)
  if not pos then return nil end
  local best_id, best_gap
  for id = 1, (storage.next_colony_id or 1) - 1 do
    local colony = storage.colonies[id]
    if colony and colony.surface_index == surface_index then
      local g = waystation.gap(pos, M.emitters(colony))
      if g and (best_gap == nil or g < best_gap) then
        best_id, best_gap = id, g
      end
    end
  end
  if best_id and best_gap <= (tolerance or waystation.ADJACENT) then return best_id end
  return nil
end

function M.owner_at(surface_index, pos)
  if not pos then return nil end
  local px = pos.x or pos[1]
  local py = pos.y or pos[2]
  if not (px and py) then return nil end
  -- Walk colony ids in numeric order: `pairs` order over storage.colonies could change after a save/load and
  -- pick a different owner where two territories overlap, which is a desync.
  for id = 1, (storage.next_colony_id or 1) - 1 do
    local colony = storage.colonies[id]
    if colony and colony.surface_index == surface_index then
      for _, e in ipairs(M.emitters(colony)) do
        local p = e.entity.position
        local dx = px - p.x
        local dy = py - p.y
        if dx * dx + dy * dy <= e.radius * e.radius then
          return id
        end
      end
    end
  end
  return nil
end

-- Returns a sorted, deduplicated list of {cx, cy} chunk coordinates covered by the colony's territory radius.
function M.chunks(colony)
  if not colony then return {} end
  local seen = {}
  local out = {}

  local function add_circle(pos, radius)
    if not pos then return end
    local px = pos.x or pos[1]
    local py = pos.y or pos[2]
    local min_cx = math.floor((px - radius) / 32)
    local max_cx = math.floor((px + radius) / 32)
    local min_cy = math.floor((py - radius) / 32)
    local max_cy = math.floor((py + radius) / 32)
    local r2 = radius * radius
    for cx = min_cx, max_cx do
      for cy = min_cy, max_cy do
        local key = cx .. ":" .. cy
        if not seen[key] then
          local closest_x = math.max(cx * 32, math.min(px, (cx + 1) * 32))
          local closest_y = math.max(cy * 32, math.min(py, (cy + 1) * 32))
          local dx = px - closest_x
          local dy = py - closest_y
          if dx * dx + dy * dy <= r2 then
            seen[key] = true
            out[#out + 1] = {cx, cy}
          end
        end
      end
    end
  end

  for _, e in ipairs(M.emitters(colony)) do
    add_circle(e.entity.position, e.radius)
  end
  table.sort(out, function(a, b) return a[1] < b[1] or (a[1] == b[1] and a[2] < b[2]) end)
  return out
end

-- Backward compatibility helpers: chunk maths is still used for seeding forage (one patch roll per chunk).
function M.chunk_of(pos)
  local x = pos.x or pos[1]; local y = pos.y or pos[2]
  return math.floor((x or 0) / 32), math.floor((y or 0) / 32)
end

return M
