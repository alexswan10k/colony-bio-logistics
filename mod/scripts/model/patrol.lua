---@diagnostic enable: undefined-field, missing-fields
-- PURE: autonomous militia patrols from player-placed Patrol Posts (M3 Stage 3, #57).
--
-- A post holds an ordered list of waypoints. A patrol walks that list in a loop, engages hostiles it sees with
-- `attack_area + by_enemy` (s19_defence proved there is no `attack_move`, and that this surrogate does not
-- complete while a target survives), and clears nests by treating them as area targets. Lease expiry is
-- therefore a plain-tick rule here; the adapter drives it with scheduler timers, never with a completion
-- event alone. Failed paths into a nest are bounded by an attempt count and a per-target blacklist so a
-- patrol can never be silently deleted (the militia prototype sets destroy_when_commands_fail = false) or
-- stuck forever on an unreachable target.
--
-- Every input is a plain table and is never mutated. No Factorio globals (game/storage/script/defines/surface).
local M = {}

M.LEASE_TICKS = 7200          -- ~2 min: a patrol is a long lease, not a one-minute whistle order
M.CHECK_TICKS = 45            -- adapter: idle waypoint/target rescan period
M.REACH = 2.0                 -- tiles: close enough to a waypoint to advance (a unit is ~0.5 tile wide)
M.RANGE = 16                  -- tiles: hostile detection, shared with garrison.RANGE / militia.RANGE
M.ENGAGE_RADIUS = 8           -- tiles: the attack_area radius used against a detected hostile or a nest
M.ENGAGE_TICKS = 30           -- adapter: re-check an in-progress engagement this often
M.ENGAGE_COOLDOWN = 600       -- ticks: stop pouring attacks into one target after this long
M.BLACKLIST_TICKS = 1800      -- ticks: an unreachable target is skipped this long
M.MAX_PATH_ATTEMPTS = 3       -- failed commands per target before it is blacklisted
M.POST_SQUAD = 2              -- militia a single post keeps patrolling at once

local ENGAGE_KINDS = {attack_area = true, attack = true, nest = true, engage = true}

--- True for either state the patrol adapter owns.
---@param st table|nil
---@return boolean
function M.is_patrol(st)
  return st ~= nil and (st.state == "patrolling" or st.state == "patrol-engage")
end

--- Tick at which a patrol lease started at `tick` expires.
---@param tick integer
---@return integer
function M.lease_tick(tick) return (tick or 0) + M.LEASE_TICKS end

--- A lease is expired only for a live patrol state with an elapsed tick.
---@param st table|nil
---@param tick integer
---@return boolean
function M.expired(st, tick)
  return M.is_patrol(st) and tick >= (st.until_tick or 0)
end

--- Ordered waypoints for one colony. Posts are sorted by their numeric id first, so two runs of the same
--- world always produce the same route regardless of pairs() order. Waypoints keep their in-post order.
---@param posts table[]|nil array of {id=number, colony_id=number, waypoints={{x=,y=},...}}
---@param colony_id any
---@return table[] array of {post=number, index=integer, x=number, y=number, key=string}
function M.route(posts, colony_id)
  local selected = {}
  for _, p in ipairs(posts or {}) do
    if p and type(p.id) == "number" and p.colony_id == colony_id then selected[#selected + 1] = p end
  end
  table.sort(selected, function(a, b) return a.id < b.id end)
  local out = {}
  for _, p in ipairs(selected) do
    for i, wp in ipairs(p.waypoints or {}) do
      if wp and type(wp.x) == "number" and type(wp.y) == "number" then
        out[#out + 1] = {post = p.id, index = i, x = wp.x, y = wp.y, key = p.id .. ":" .. i}
      end
    end
  end
  return out
end

--- The next waypoint in the loop and its index. Wraps to 1; nil for an empty route.
---@param route table[]|nil
---@param idx integer|nil current 1-based index
---@return table|nil, integer|nil
function M.next_waypoint(route, idx)
  if not route or #route == 0 then return nil, nil end
  local n, next = #route, (idx or 0) + 1
  if next > n then next = 1 end
  return route[next], next
end

--- Is `un` blacklisted at `tick`? Entries map a unit number to the expire tick; an entry is active while
--- that tick is still in the future. With no tick supplied any entry counts as active.
---@param blacklist table<number, number>|nil
---@param un number|nil
---@param tick integer|nil
---@return boolean
function M.blacklisted(blacklist, un, tick)
  if not (blacklist and un) then return false end
  local until_tick = blacklist[un]
  if not until_tick then return false end
  if tick == nil then return true end
  return until_tick > tick
end

--- A copy of `blacklist` with entries that expired at `tick` removed. No input mutation.
---@param blacklist table<number, number>|nil
---@param tick integer
---@return table<number, number>
function M.expire_blacklist(blacklist, tick)
  local out = {}
  for un, until_tick in pairs(blacklist or {}) do
    if until_tick > (tick or 0) then out[un] = until_tick end
  end
  return out
end

--- Nearest hostile to `pos` inside `range`, ties by unit number, skipping blacklisted units. The shape
--- mirrors garrison.nearest (array of {unit_number=, position=}). No input mutation.
---@param enemies table[]|nil
---@param pos table {x=,y=}
---@param range number|nil
---@param blacklist table<number, number>|nil
---@param tick integer|nil
---@return table|nil
function M.target_select(enemies, pos, range, blacklist, tick)
  local best, best_d, r2 = nil, nil, (range or M.RANGE) ^ 2
  for _, a in ipairs(enemies or {}) do
    local un = a and a.unit_number
    if un and a.position and not M.blacklisted(blacklist, un, tick) then
      local dx, dy = a.position.x - pos.x, a.position.y - pos.y
      local d = dx * dx + dy * dy
      if d <= r2 and (not best_d or d < best_d or (d == best_d and un < best.unit_number)) then
        best, best_d = a, d
      end
    end
  end
  return best
end

--- Distraction string for a neutral command description. Hostile/area attacks use by_enemy so the unit
--- retargets (s18/s19 proved attack_area + by_enemy is the only attack-move surrogate); travel uses none.
---@param kind string|nil
---@return string
function M.distraction_for(kind)
  return (kind and ENGAGE_KINDS[kind]) and "by_enemy" or "none"
end

--- End an engagement when the target is gone or the cooldown has elapsed.
---@param target_hp number|nil
---@param cooldown number|nil
---@return boolean
function M.should_disengage(target_hp, cooldown)
  if target_hp == nil or target_hp <= 0 then return true end
  return (cooldown or 0) <= 0
end

return M
