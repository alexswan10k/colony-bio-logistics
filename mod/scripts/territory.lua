-- Chunk-granular territory index (decision #15: 32x32 chunks).
-- storage.colony_chunks[surface_index][cx][cy] = colony_id
local M = {}

function M.chunk_of(pos)
  local x = pos.x or pos[1]; local y = pos.y or pos[2]
  return math.floor(x / 32), math.floor(y / 32)
end

function M.owner_at(surface_index, pos)
  local cx, cy = M.chunk_of(pos)
  local s = storage.colony_chunks[surface_index]
  return s and s[cx] and s[cx][cy] or nil
end

-- Claim all chunks within `radius_chunks` (Chebyshev) of the chunk containing `pos`. Returns #newly claimed.
-- Does not overwrite chunks owned by another colony (ownership conflicts = open question).
function M.claim_around(surface_index, colony_id, pos, radius_chunks)
  local cx0, cy0 = M.chunk_of(pos)
  local s = storage.colony_chunks
  s[surface_index] = s[surface_index] or {}
  local n = 0
  for cx = cx0 - radius_chunks, cx0 + radius_chunks do
    s[surface_index][cx] = s[surface_index][cx] or {}
    for cy = cy0 - radius_chunks, cy0 + radius_chunks do
      if s[surface_index][cx][cy] == nil then
        s[surface_index][cx][cy] = colony_id
        n = n + 1
      end
    end
  end
  return n
end

function M.release_colony(colony_id)
  for _, cols in pairs(storage.colony_chunks) do
    for _, col in pairs(cols) do
      for cy, id in pairs(col) do if id == colony_id then col[cy] = nil end end
    end
  end
end

return M
