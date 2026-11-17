---@diagnostic enable: undefined-field, missing-fields
-- PURE model: shared structural protection from a manned defensive post (M3 defence stack, #56 remainder).
--
-- A manned Armory (or a Watchtower with posted guards) grants a damage reduction to colony structures inside
-- its radius. The engine has no per-structure "take less damage" flag: `protected` / `destructible` only stop
-- targeting (s19_defence), so the adapter heals back the mitigated share on on_entity_damaged. This module
-- only decides HOW MUCH, from plain numbers and positions; no Factorio globals, no input mutation.
--
-- Everything here is deterministic: a point covered by two posts uses the NEAREST one, ties by numeric/string
-- key, so the same world always yields the same mitigation (and the two-run checksum stays comparable).
local M = {}

M.RADIUS = 24                 -- tiles: one evaluation-time lookup per damage event, no per-tick scan
M.PER_MILITIA = 0.10          -- reduction per equipped militia / posted guard
M.MAX_REDUCTION = 0.50        -- a full post is a backstop, never invulnerability

--- Reduction fraction for a post's manning count, clamped to [0, MAX_REDUCTION].
---@param manning number|nil equipped militia (Armory) or posted guards (Watchtower)
---@return number
function M.aura(manning)
  local n = tonumber(manning) or 0
  if n <= 0 then return 0 end
  local v = n * M.PER_MILITIA
  if v > M.MAX_REDUCTION then return M.MAX_REDUCTION end
  return v
end

--- The mitigation a point receives: the NEAREST covering post wins, ties by `key` then array order.
--- Posts are plain records {position={x=,y=}, strength=number, key=number|string}; `manning` may be supplied
--- instead of `strength` and is converted with `aura`. A point outside every radius reads 0.
---@param pos table|nil plain {x=, y=}
---@param posts table[]|nil
---@param radius number|nil override M.RADIUS
---@return number
function M.coverage(pos, posts, radius)
  if not (pos and pos.x and pos.y) or not posts or #posts == 0 then return 0 end
  local r2 = (radius or M.RADIUS) ^ 2
  local best, best_d2, best_key = nil, nil, nil
  for i, post in ipairs(posts) do
    local pp = post and post.position
    if pp and pp.x and pp.y then
      local dx, dy = pp.x - pos.x, pp.y - pos.y
      local d2 = dx * dx + dy * dy
      if d2 <= r2 then
        local key = tostring(post.key or i)
        local better = best == nil or d2 < best_d2
        if not better and d2 == best_d2 then better = key < best_key end
        if better then
          best, best_d2, best_key = post, d2, key
        end
      end
    end
  end
  if not best then return 0 end
  local strength = best.strength
  if strength == nil then strength = M.aura(best.manning) end
  if type(strength) ~= "number" or strength <= 0 then return 0 end
  if strength > 1 then return 1 end
  return strength
end

--- Is `pos` inside at least one manned post's radius? Bool form of `coverage`, for cheap callers.
---@param pos table|nil
---@param posts table[]|nil
---@param radius number|nil
---@return boolean
function M.covered(pos, posts, radius)
  return M.coverage(pos, posts, radius) > 0
end

--- Damage actually taken after the post's reduction. `reduction` is clamped: no negative or amplified hits.
---@param amount number
---@param reduction number|nil
---@return number
function M.apply_incoming(amount, reduction)
  local a = tonumber(amount) or 0
  local r = tonumber(reduction) or 0
  if r < 0 then r = 0 elseif r > 1 then r = 1 end
  local out = a * (1 - r)
  if out < 0 then return 0 end
  return out
end

return M
