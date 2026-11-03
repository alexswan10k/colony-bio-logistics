-- Wildlife (#79, design §3.1): the roaming game a Hunting Lodge works.
--
-- The game is a `unit` on its own force (prototypes/wildlife.lua). Nobody is at war with that force, so a
-- hunter can shoot an animal without starting a war: no retaliation, no aggro to the colony, no turret fire,
-- and biters ignore it. That is the point - real engine combat (a commanded attack, real damage, a real
-- death) without the colony becoming a combat faction.
--
-- This module owns the force, the herd and the wander commands. The hunters themselves are a labour hut in
-- scripts/work.lua, and what a kill is worth is `model/hunting.lua`.
local territory = require("scripts.territory")
local M = {}

M.FORCE = "colony-wildlife"
M.ANIMAL = "colony-wild-boar"
M.PER_CHUNK = 0.5          -- animals wanted per owned chunk
M.CAP = 12                 -- hard cap per colony: the herd must never grow with the town
M.SPAWN_PER_PASS = 1       -- one animal per evaluation, so a wiped-out herd comes back slowly
M.ROAM_TICKS = 1800        -- re-issue the wander order this often (cheap insurance, not per tick)

-- Pure deterministic "random" in 0..1 from three integers. The mod must not call math.random (a desync and
-- a determinism-gate failure), and the spawn point has to be reproducible from (colony, tick, index) anyway.
local function hash(a, b, c)
  local x = (a * 73856093 + b * 19349663 + c * 83492791) % 4294967296
  x = (x * 1664525 + 1013904223) % 4294967296
  return x / 4294967296
end
M.hash = hash

-- The wildlife force exists once and is at peace with every force that matters. Idempotent, so it is safe to
-- call on every evaluation (a save made before this existed, or a force deleted by `/c`, just gets it back).
function M.ensure_force()
  local force = game.forces[M.FORCE]
  if not force then force = game.create_force(M.FORCE) end
  for _, name in ipairs({"player", "enemy", "neutral"}) do
    local other = game.forces[name]
    if other then
      force.set_cease_fire(other, true)
      other.set_cease_fire(force, true)
    end
  end
  return force
end

-- Place one animal near `pos`, nudged to a spot it can actually stand on. Returns nil if there is no room.
function M.spawn(surface, force, pos, radius)
  local p = surface.find_non_colliding_position(M.ANIMAL, pos, radius or 12, 0.5)
  if not p then return nil end
  return surface.create_entity{name = M.ANIMAL, position = p, force = force}
end

-- "Chill": the engine walks the animal around by itself. `distraction = none` keeps it wandering even when
-- it is being shot at, which is exactly the docile behaviour we want (a hunter is not a threat to it).
function M.roam(animal)
  if not (animal and animal.valid) then return end
  animal.commandable.set_command{type = defines.command.wander, distraction = defines.distraction.none}
end

-- Owned chunks in a stable order, so a spawn point never depends on `pairs` order.
function M.chunks(colony)
  return territory.chunks(colony)
end

function M.target_count(chunks) return math.min(M.CAP, math.floor(chunks * M.PER_CHUNK)) end

-- One evaluation's worth of wildlife work: prune the dead, nudge the herd, top it up slowly.
function M.tick(colony, tick)
  tick = tick or game.tick
  local force = M.ensure_force()
  local animals = colony.animals
  if not animals then animals = {}; colony.animals = animals end
  local ids, live = {}, 0
  for un, rec in pairs(animals) do
    if rec.entity.valid then ids[#ids + 1] = un; live = live + 1 else animals[un] = nil end
  end
  table.sort(ids)
  for _, un in ipairs(ids) do
    local rec = animals[un]
    if tick >= (rec.roam_at or 0) then
      rec.roam_at = tick + M.ROAM_TICKS
      M.roam(rec.entity)
    end
  end
  local chunks = M.chunks(colony)
  local want = M.target_count(#chunks)
  for i = 1, math.min(M.SPAWN_PER_PASS, want - live) do
    local c = chunks[1 + math.floor(hash(colony.id, tick, i) * #chunks)]
    local pos = {x = c[1] * 32 + hash(colony.id, tick, i + 17) * 32, y = c[2] * 32 + hash(colony.id, tick, i + 31) * 32}
    local e = M.spawn(game.surfaces[colony.surface_index], force, pos, 16)
    if e then
      animals[e.unit_number] = {entity = e, roam_at = tick + M.ROAM_TICKS}
      live = live + 1
    end
  end
  return live
end

return M
