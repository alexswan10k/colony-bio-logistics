-- Territory rules: distance-based radius around Town Hall and Watchtowers (#15 simplified).
-- Territory is a smooth circle of tiles centered on the buildings.
local M = {}

M.HALL_RADIUS = 64     -- tile radius around Town Hall
M.TOWER_RADIUS = 48    -- tile radius around each Watchtower
M.HALL_RADIUS_SQ = M.HALL_RADIUS * M.HALL_RADIUS
M.TOWER_RADIUS_SQ = M.TOWER_RADIUS * M.TOWER_RADIUS

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
      local hall = colony.hall
      if hall and hall.valid then
        local dx = px - hall.position.x
        local dy = py - hall.position.y
        if dx * dx + dy * dy <= M.HALL_RADIUS_SQ then
          return id
        end
      end
      for _, tower in pairs(colony.towers or {}) do
        if tower and tower.valid then
          local dx = px - tower.position.x
          local dy = py - tower.position.y
          if dx * dx + dy * dy <= M.TOWER_RADIUS_SQ then
            return id
          end
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

  if colony.hall and colony.hall.valid then
    add_circle(colony.hall.position, M.HALL_RADIUS)
  end
  for _, tower in pairs(colony.towers or {}) do
    if tower.valid then
      add_circle(tower.position, M.TOWER_RADIUS)
    end
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
