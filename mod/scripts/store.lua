-- Versioned `storage` schema. Add a function to `migrations[n]` and bump SCHEMA when changing layout.
-- Rules: only plain data in storage (no functions); no math.random (use game.create_random_generator).
local M = {}
local SCHEMA = 1

local migrations = {
  [1] = function()
    storage.colonies = storage.colonies or {}
    storage.next_colony_id = storage.next_colony_id or 1
    storage.colony_chunks = storage.colony_chunks or {}   -- [surface_index][cx][cy] = colony_id
    storage.scheduled = storage.scheduled or {}           -- [tick] = { {handler=, data=}, ... }
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
