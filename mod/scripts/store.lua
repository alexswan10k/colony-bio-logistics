-- Versioned `storage` schema. Add a function to `migrations[n]` and bump SCHEMA when changing layout.
-- Rules: only plain data in storage (no functions); no math.random (use game.create_random_generator).
local M = {}
local SCHEMA = 28

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
  [7] = function()
    -- watchtowers (territory expansion) and per-colonist job locks (#38 roster)
    for _, c in pairs(storage.colonies) do
      c.towers = c.towers or {}
      c.locks = c.locks or {}
    end
  end,
  [8] = function()
    -- player-placed farm plots (#44): [unit_number] = {entity, colony_id, stage, ripe_at}
    for _, c in pairs(storage.colonies) do c.plots = c.plots or {} end
  end,
  [9] = function()
    -- colony logistics crates (#33): [unit_number] = {entity, kind, colony_id, filters, inflight}
    for _, c in pairs(storage.colonies) do c.crates = c.crates or {} end
  end,
  [10] = function()
    -- construction (#37): ghost / damage registries refreshed by construct.scan
    for _, c in pairs(storage.colonies) do
      c.ghosts, c.repairs, c.ghost_blocked = c.ghosts or {}, c.repairs or {}, c.ghost_blocked or {}
    end
  end,
  [11] = function()
    -- machine index (#75): assignment reads cached demand/output sets instead of walking the registry
    for _, c in pairs(storage.colonies) do
      c.machine_cache, c.machine_dirty, c.machine_cursor = nil, true, 1
      c.machine_offer_cursor, c.collect_offer_cursor = nil, nil
      c.pop_cache, c.food_cache, c.stock_cache = nil, nil, nil
      for _, m in pairs(c.machines or {}) do m.has_output, m.need, m.damaged = nil, nil, nil end
    end
  end,
  [12] = function()
    -- compost bins (#78): [unit_number] = {entity, colony_id}
    for _, c in pairs(storage.colonies) do c.bins = c.bins or {}; c.compost_timer = nil end
  end,
  [13] = function()
    -- wildlife (#79): herd registry [unit_number] = {entity, roam_at}; the force is re-ensured on evaluation
    for _, c in pairs(storage.colonies) do c.animals = c.animals or {} end
  end,
  [14] = function()
    -- salt pans (#81): [unit_number] = {entity, colony_id, next_at}
    for _, c in pairs(storage.colonies) do c.salt_pans = c.salt_pans or {} end
  end,
  [15] = function()
    -- cursor overlays (#83): [player_index] = {render_objects...}
    storage.cursor_overlays = storage.cursor_overlays or {}
  end,
  [16] = function()
    -- harvest quotas (#84): [item] = target_number
    for _, c in pairs(storage.colonies) do c.quotas = c.quotas or {} end
  end,
  [17] = function()
    -- workforce headcount targets (#73): [job] = target_count
    for _, c in pairs(storage.colonies) do c.job_targets = c.job_targets or {} end
  end,
  [18] = function()
    -- colony wells (#43): [unit_number] = {entity, colony_id, next_at}
    for _, c in pairs(storage.colonies) do c.wells = c.wells or {} end
  end,
  [19] = function()
    -- territory is derived from the live hall/towers now, so the chunk index is dead weight; the population
    -- target gave way to plain housing capacity when the info panel lost its +/- buttons
    storage.colony_chunks = nil
    for _, c in pairs(storage.colonies) do c.pop_target = nil; c.house_index, c.reassign_tick = nil, nil end
  end,
  [20] = function()
    -- carried-goods sprites over colonists: [unit_number] = {item, obj}. Colonies gain alerted/feedback_at/
    -- workshop_at lazily (all nil-safe), and milestones catch up on the next evaluation.
    storage.carry_sprites = storage.carry_sprites or {}
  end,
  [21] = function()
    -- Motor Pools (#60): colony.pools [unit_number] = {entity, colony_id, inflight, out}; storage.trucks
    -- [truck unit_number] = {entity, colony_id, driver, pool, trips}.
    storage.trucks = storage.trucks or {}
    for _, c in pairs(storage.colonies) do c.pools = c.pools or {} end
  end,
  [22] = function()
    -- Taverns (#48): colony.taverns [unit_number] = {entity, colony_id, inflight, owed, houses, inspired}; houses
    -- gain `inspired` and colonies `recreation` on their next evaluation.
    for _, c in pairs(storage.colonies) do c.taverns = c.taverns or {} end
  end,
  [23] = function()
    -- Passenger rail (#49): colony.platforms [unit_number] = {entity, colony_id, stop}; storage.coaches
    -- [wagon unit_number] = {groups = {{from, n, stops}}, text}.
    storage.coaches = storage.coaches or {}
    for _, c in pairs(storage.colonies) do c.platforms = c.platforms or {} end
  end,
  [24] = function()
    -- Permanent death (#53): colony.cemeteries [unit_number] = {entity, colony_id, graves}; colonies count
    -- `fallen` (every death) and `buried` (deaths laid in a cemetery).
    for _, c in pairs(storage.colonies) do
      c.cemeteries = c.cemeteries or {}
      c.fallen, c.buried = c.fallen or 0, c.buried or 0
    end
  end,
  [25] = function()
    -- Civil defence (#61): colony.alarms = array of {pos, ends, id}; colonists gain the to_shelter / sheltered /
    -- exposed states, and `alarm_check` marks a running upkeep loop.
    for _, c in pairs(storage.colonies) do c.alarms = c.alarms or {} end
  end,
  [26] = function()
    -- Commuter outposts (#50): storage.commuters [unit_number] = {home, ends}; colony.canteens [unit_number] =
    -- {entity, colony_id, inflight}; colony.away = the colony's commuters out at work (their beds are held);
    -- colonies gain deficit / commuters_here / meal_owed on their next evaluation; coach groups gain kind/home.
    storage.commuters = storage.commuters or {}
    for _, c in pairs(storage.colonies) do
      c.canteens = c.canteens or {}
      c.away = c.away or 0
    end
  end,
  [27] = function()
    -- Illness (#47): storage.sick [unit_number] = {kind = "lung"|"poison", age}; colonies gain sick_count /
    -- sick_lung / sick_poison on their next evaluation; "heal" joins the job matrix at its default rank.
    storage.sick = storage.sick or {}
  end,
  [28] = function()
    -- Natural reproduction (#88): storage.age [unit_number] = {stage = "adult"|"child", born = tick}; children
    -- count toward occupancy but never receive jobs. Colony labels are now {mode, obj} records (the mode says
    -- whether the label is only shown in alt-mode, as sleeping colonists are labelled outside it).
    storage.age = storage.age or {}
    for un, rec in pairs(storage.unit_labels or {}) do
      if type(rec) ~= "table" then storage.unit_labels[un] = {mode = "alt", obj = rec} end
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
