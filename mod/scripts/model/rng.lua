---@diagnostic enable: undefined-field, missing-fields
-- Deterministic PRNG (LCG) for pure models/sims. In-game code should use game.create_random_generator.
local M = {}
function M.new(seed)
  local s = seed or 1
  local r = {}
  function r.next() s = (s * 1103515245 + 12345) % 2147483648; return s / 2147483648 end
  function r.int(lo, hi) return lo + math.floor(r.next() * (hi - lo + 1)) end
  return r
end
return M
