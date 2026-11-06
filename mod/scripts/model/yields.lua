---@diagnostic enable: undefined-field, missing-fields
-- PURE: every "how much comes back from one trip" number in the colony loop, in one place.
--
-- Balance (#41) is only arguable if the tables in `sim/` read the same constants the game runs on. Before this
-- module each number lived next to its job (`work.M.YIELD`, `fishing.FISH_PER_TRIP`, `hunting.MEAT_PER_KILL`,
-- `farm.YIELD_BASE`, `salt.TICKS_PER_SALT`, `labour.TOOL_USES`), which made the sim's copy a belief rather than
-- evidence. The job modules keep their old names as aliases so call sites and tests read naturally; the numbers
-- themselves only exist here.
local M = {}

-- --- harvest, per completed trip -------------------------------------------------------------------------
M.FORAGE = {item = "colony-forage", count = 4}
M.CHOP = {item = "wood", count = 4}
M.MINE_PER_TRIP = 5         -- resource units mined per trip; each unit becomes exactly one item (design §4.2)
M.FISH = {item = "colony-fish", count = 5}
M.HUNT = {item = "colony-meat", count = 6}
M.FARM_BASE = 8             -- produce per harvest at fertility 1.0 (the plot cycle is the real cost)

-- --- timing ----------------------------------------------------------------------------------------------
M.WORK_TICKS = 480          -- ticks of work animation per trip (8 s)
M.CARRY_CAP = 20            -- items a colonist can carry

-- --- tools -----------------------------------------------------------------------------------------------
M.TOOL_USES = 30            -- trips before one tool in the hut wears out
M.STEEL_TOOL_USES = 45      -- steel-axe/pickaxe/hoe (#95): 1.5x trips per tool
M.STEEL_WORK_MULT = 0.8     -- steel-axe/pickaxe/hoe (#95): 20% faster work spells (480 -> 384 ticks)

-- --- salt + preservation ---------------------------------------------------------------------------------
M.SALT_TICKS = 1800         -- ticks per salt from one pan (30 s), worker-free
M.SALT_CAP = 8              -- a pan fills to here and stops
M.CURE = {salt = 1, raw = 1, out = 1}   -- one raw + one salt -> one preserved item

-- --- water -----------------------------------------------------------------------------------------------
M.WATER_TICKS = 600         -- ticks per water bucket from one well (10 s), worker-free
M.WATER_CAP = 12            -- a well fills to here and stops

-- --- food ------------------------------------------------------------------------------------------------
M.FOOD_PER_INTERVAL = 1     -- food items one colonist eats per colony interval (colony.INTERVAL = 600 ticks)

return M
