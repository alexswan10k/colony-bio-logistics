---@diagnostic enable: undefined-field, missing-fields
-- PURE: Command Whistle (#58, design §7.2) - temporary, leased RTS orders on colonists. Nothing here touches
-- the engine: the adapter passes plain unit records and reads back intents/state/command descriptions.
-- Precedence: sleep, shelter, travel, commute and driving own a unit and are NEVER commandable. Everything else
-- (idle, work trips, guards, hunters, haulers) can be ordered; the order aborts the trip and parks the unit in
-- `state = "commanded"` for a lease, then work.assign resumes normally. Job locks, quotas and hut limits are
-- untouched - this is a lease on a unit, not a career change.
local M = {}

M.ORDERS = {MOVE = "move", ATTACK_MOVE = "attack_move", ATTACK = "attack", STOP = "stop"}
M.LEASE_TICKS = 3600          -- ~1 min: a temporary order, not a new job
M.MAX_SELECT = 200            -- deterministic cap; also the bound on one dispatch (spike: 200 commands ~0.24 ms)
M.CLICK_TARGET_RADIUS = 3     -- adapter: an enemy under the cursor turns a plain order into ATTACK
M.WATCHDOG_TICKS = 300        -- adapter: leased-state expiry / nightfall check, only while a lease is live

-- States another subsystem owns. Ordering one of these would strand a train, a coach, a truck driver, a
-- sleeper inside a house or a colonist indoors during an alarm, so they are refused outright.
-- Entity names the whistle may select/order. A militia is a colonist in uniform, not a different kind of
-- unit (#55): both must be selectable or the ORDERABLE/gear-carry wiring for militia is unreachable dead code.
M.UNIT_NAMES = {["colony-colonist"] = true, ["colony-militia"] = true}
function M.is_colony_unit(name) return M.UNIT_NAMES[name] == true end

M.PROTECTED = {
  child = true, to_bed = true, sleeping = true,
  to_shelter = true, sheltered = true, exposed = true,
  to_platform = true, waiting_train = true,
  driving = true, to_park = true,
}
-- States that are a colonist doing ordinary colony work. A colonist in any other non-nil state is refused
-- (fail closed), so a future subsystem's new trip state cannot be silently corrupted by an order.
M.ORDERABLE = {
  to_construct = true, building = true, repairing = true,
  to_pickup = true, to_house = true, to_hut = true, to_machine = true, to_crate = true,
  to_pool = true, to_tavern = true, to_bin = true, to_hall = true,
  to_site = true, working = true, hunting = true,
  to_tower = true, guarding = true, ["guarding-fight"] = true,
  -- M3 militia (#55): a whistle order preempts a militia exactly like a guard. Its gear is pure data in
  -- st.gear and is carried across the lease by abort_intents (see below), so the order loses nothing.
  to_militia = true, ["militia-hold"] = true, ["militia-fight"] = true,
  -- M3 patrol (#57): a whistle order PREEMPTS a patrol - the player always has the final say. The patrol
  -- adapter releases the route claim (abort_intents.release_patrol) and the militia gear rides the lease.
  patrolling = true, ["patrol-engage"] = true,
  -- Re-ordering an already commanded unit replaces its lease (last writer wins between players).
  commanded = true,
}

-- ctx = {is_child, is_truck, is_commuter, driving, alarm_covers}. `alarm_covers` is accepted for callers that
-- have it but is redundant: every shelter state is protected above. `st` may be nil (a colonist with no
-- recorded state is idle and therefore orderable).
function M.commandable(st, ctx)
  ctx = ctx or {}
  if ctx.is_child or ctx.is_truck or ctx.is_commuter or ctx.driving then return false end
  local state = st and st.state
  if not state or state == "idle" then return true end
  if M.PROTECTED[state] then return false end
  return M.ORDERABLE[state] == true
end

-- Accept either storage's map form {[un]=true} or an array of unit numbers/records. Always returns a fresh,
-- deduped, numerically sorted array capped at MAX_SELECT, so every downstream step is deterministic.
local function to_list(src)
  local out, seen = {}, {}
  if not src then return out end
  for k, v in pairs(src) do
    local un
    if type(k) == "number" and type(v) == "boolean" then un = k
    elseif type(v) == "number" then un = v
    elseif type(k) == "number" and type(v) == "table" then un = type(v.un) == "number" and v.un or k end
    if un and not seen[un] then seen[un] = true; out[#out + 1] = un end
  end
  table.sort(out)
  return out
end
M.to_list = to_list

-- mode "set" (replace), "add" (union), "remove" (subtract), "clear" (empty).
function M.select(current, candidates, mode)
  local set = {}
  if mode == "clear" then
    -- nothing to copy, nothing to add
  elseif mode == "remove" then
    for _, un in ipairs(to_list(current)) do set[un] = true end
    for _, un in ipairs(to_list(candidates)) do set[un] = nil end
  else
    if mode ~= "set" then
      for _, un in ipairs(to_list(current)) do set[un] = true end
    end
    for _, un in ipairs(to_list(candidates)) do set[un] = true end
  end
  local out = {}
  for un in pairs(set) do out[#out + 1] = un end
  table.sort(out)
  while #out > M.MAX_SELECT do table.remove(out) end   -- drop the largest unit numbers; stable
  return out
end

-- What the adapter must undo before it overwrites unit_state. Pure data; the input is never mutated.
-- `work.release` handles carry/claim/car/trailer; hut slot, sprite and label belong to the command adapter.
function M.abort_intents(st)
  st = st or {}
  return {
    release_carry = st.carry ~= nil,
    free_hut_slot = st.hut ~= nil,
    free_site_claim = st.site_key or false,
    return_car = st.car ~= nil,
    return_trailer = st.trailer ~= nil,
    clear_carry_sprite = true,
    clear_label = true,
    restore_destructible = false,   -- never re-enable a sheltered colonist by ordering it
    -- M3 militia (#55): gear is pure data on unit_state. Carry it into the lease instead of dropping it,
    -- and flag that any in-flight gear haul claim must be released so no item is lost or double-claimed.
    gear = st.gear,
    release_gear_claim = st.job == "militia",
    -- M3 patrol (#57): the route claim (colony.patrols[un]) is a lease too. The adapter drops it before the
    -- state is overwritten; the physical gear is NOT returned - abort_intents.gear carries it into the order
    -- exactly as for a militia, so preemption never loses a rifle.
    release_patrol = st.state == "patrolling" or st.state == "patrol-engage",
    old_job = st.job or "idle",
    old_state = st.state or "idle",
  }
end

-- Neutral command descriptions; the adapter maps the `kind` strings to defines.command / defines.distraction.
-- There is no `attack_move` in 2.1 (s18_command): ATTACK_MOVE is `attack_area` with by_enemy distraction.
function M.command_for(kind, target)
  target = target or {}
  local dest = target.position or target.destination or {x = 0, y = 0}
  if kind == M.ORDERS.MOVE then
    return {kind = "go_to_location", destination = {x = dest.x, y = dest.y},
      radius = target.radius or 1.5, distraction = "none"}
  elseif kind == M.ORDERS.ATTACK_MOVE then
    return {kind = "attack_area", destination = {x = dest.x, y = dest.y},
      radius = target.radius or 8, distraction = "by_enemy"}
  elseif kind == M.ORDERS.ATTACK then
    return {kind = "attack", target_un = target.enemy_un, distraction = "none"}
  end
  return {kind = "stop", ticks_to_wait = 0, distraction = "none"}
end

-- ctx = {colonies = {[un]=colony_id}, jobs = {[un]=job}, owner = player_index}. STOP releases rather than
-- leases, so it returns no states; the adapter drops any existing lease for those units.
function M.plan(selection, kind, target, tick, ctx)
  ctx, target, tick = ctx or {}, target or {}, tick or 0
  local states, commands = {}, {}
  local stop = kind == M.ORDERS.STOP
  for _, un in ipairs(to_list(selection)) do
    if not stop then
      states[un] = {
        colony_id = ctx.colonies and ctx.colonies[un] or nil,
        job = ctx.jobs and ctx.jobs[un] or "idle",
        state = "commanded", order = kind, until_tick = tick + M.LEASE_TICKS,
        lease_owner = ctx.owner,
      }
    end
    commands[un] = M.command_for(kind, target)
  end
  return {states = states, commands = commands}
end

function M.is_commanded(st)
  return st ~= nil and st.state == "commanded"
end

function M.expired(st, tick)
  return M.is_commanded(st) and tick >= (st.until_tick or 0)
end

-- The adapter normalises defines.behavior_result to "success"/"fail"/"in_progress"/"deleted" before calling.
-- Only a still-live in_progress result keeps the lease; anything else (including a missing tick) releases it.
function M.after_completion(st, result, tick)
  if not M.is_commanded(st) then return "keep" end
  if tick and M.expired(st, tick) then return "release_to_work" end
  if result == "in_progress" then return "keep" end
  return "release_to_work"
end

function M.label_for(kind)
  if kind == M.ORDERS.ATTACK or kind == M.ORDERS.ATTACK_MOVE then return "⚑ attacking" end
  if kind == M.ORDERS.STOP then return "⚑ stopped" end
  return "⚑ moving"
end

-- Plain-data cleanup for a disconnecting player. `markers_removed` are render objects the adapter destroys;
-- `released` are unit numbers whose leases that player owned and must now be handed back to work.
function M.drop_player(data, pi)
  data = data or {}
  local out = {selection = {}, markers = {}, owner = {}, released = {},
    markers_removed = data.markers and data.markers[pi] or {}}
  for idx, sel in pairs(data.selection or {}) do
    if idx ~= pi then out.selection[idx] = sel end
  end
  for idx, marks in pairs(data.markers or {}) do
    if idx ~= pi then out.markers[idx] = marks end
  end
  local released
  for un, owner in pairs(data.owner or {}) do
    if owner == pi then
      released = released or {}
      released[#released + 1] = un
    else
      out.owner[un] = owner
    end
  end
  if released then
    table.sort(released)
    out.released = released
  end
  return out
end

return M
