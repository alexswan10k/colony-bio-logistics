-- Versioned `storage` schema. Add a function to `migrations[n]` and bump SCHEMA when changing layout.
-- Rules: only plain data in storage (no functions); no math.random (use game.create_random_generator).
local M = {}
local SCHEMA = 6

local migrations = {
  [1] = function()
    storage.colonies = storage.colonies or {}
    storage.next_colony_id = storage.next_colony_id or 1
    storage.colony_chunks = storage.colony_chunks or {}   -- [surface_index][cx][cy] = colony_id
    storage.scheduled = storage.scheduled or {}           -- [tick] = { {handler=, data=}, ... }
    storage.unit_labels = storage.unit_labels or {}        -- [unit_number] = rendering_id
  end,
  [2] = function()
    storage.unit_state = storage.unit_state or {}         -- [unit_number] = {colony_id, job, state, target_pos, yield}
  end,
  [3] = function()
    storage.unit_tools = storage.unit_tools or {}         -- [unit_number] = {axe = uses_left, pick = uses_left}
  end,
  [4] = function()
    for _, c in pairs(storage.colonies) do c.machines = c.machines or {} end   -- opt-in machine supply registry
  end,
  [5] = function()
    for _, c in pairs(storage.colonies) do c.huts = c.huts or {}; c.racks = nil end   -- labour buildings replace racks/per-colonist tools
    storage.unit_tools = nil
    storage.unit_labels = storage.unit_labels or {}
  end,
  [6] = function()
    -- forage patches are world entities now (no per-hut spawned bushes); seed existing colonies once on load
    for id, c in pairs(storage.colonies) do
      c.forage_seeded = nil
      for _, h in pairs(c.huts or {}) do h.patches = nil; h.wear = h.wear or 0; h.colony_id = h.colony_id or id end
    end
  end,
}

function M.migrate()
  storage.schema = storage.schema or 0
  while storage.schema < SCHEMA do
    local n = storage.schema + 1
    migrations[n]()
    storage.schema = n
  end
end

function M.init() M.migrate() end

return M
