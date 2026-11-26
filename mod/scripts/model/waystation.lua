-- Waystation (#56): a separate territory node for one colony. Pure rules, no Factorio globals.
-- A waystation claims RADIUS tiles around itself and may be built inside territory or just outside its
-- boundary (ADJACENT tiles). Its circle is much bigger than the allowed gap, so every accepted placement
-- overlaps the old territory: the claim stays contiguous and destroying the node releases exactly its ring.
local M = {}

M.RADIUS = 96       -- tiles claimed around one waystation (twice territory.TOWER_RADIUS)
M.ADJACENT = 16     -- max gap from the entity itself to existing territory

-- Signed gap from `pos` to the nearest emitter circle: negative inside, 0 on the boundary, positive
-- outside. `emitters` is a plain list of {position = {x, y}, radius = number}; nil when there are none.
function M.gap(pos, emitters)
  if not pos then return nil end
  local px, py = pos.x or pos[1], pos.y or pos[2]
  if not (px and py) then return nil end
  local best
  for _, e in ipairs(emitters or {}) do
    -- Callers may pass territory.emitters records (entity + radius) or plain {position, radius} rows.
    local ep = e.position or (e.entity and e.entity.position)
    if ep then
      local ex, ey = ep.x or ep[1], ep.y or ep[2]
      if ex and ey then
        local dx, dy = px - ex, py - ey
        local g = math.sqrt(dx * dx + dy * dy) - (e.radius or 0)
        if best == nil or g < best then best = g end
      end
    end
  end
  return best
end

-- Inside territory or within `gap` tiles outside it. The default is the build rule; callers may pass a
-- different tolerance (tests pin the boundary, the adapter uses the stock value).
function M.can_place(pos, emitters, gap)
  local g = M.gap(pos, emitters)
  return g ~= nil and g <= (gap or M.ADJACENT)
end

return M
