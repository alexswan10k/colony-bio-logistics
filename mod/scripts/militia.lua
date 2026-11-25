-- Militia adapter (M3 defence stack, #55). All combat rules live in pure models (model/militia.lua,
-- model/armour.lua); this file only resolves live entities, issues engine commands, calls LuaEntity:damage
-- on a confirmed engagement, and applies armour mitigation as a scripted heal-back on on_entity_damaged.
-- Stage 0 (s19_defence) proved units have no armour inventory/grid/resistances, so armour is pure data on
-- unit_state.gear and the heal-back event is the ONLY mitigation path. Bind via M.bind (no runtime require).
local events = require("scripts.events")
local scheduler = require("scripts.scheduler")
local work = require("scripts.work")
local armory = require("scripts.armory")
local militia_model = require("scripts.model.militia")
local armour = require("scripts.model.armour")
local garrison = require("scripts.model.garrison")
local M = {}

local colony_mod   -- injected by scripts.colony via M.bind
function M.bind(c) colony_mod = c end

M.RANGE = garrison.RANGE       -- scan a militia's surroundings like a posted guard (16 tiles)
M.ATTACK_RANGE = 14            -- the colonist hitscan range; script strikes only land within it
M.SCAN_TICKS = 45
M.STRIKE_TICKS = 20

-- What lives on storage.unit_state[un].gear (plain data only, survives a Command Whistle lease):
--   {weapon=, quality=, armour=, armour_quality=, uses=, ammo_count=, source_armory=}
-- `source_armory` is a unit number (never an entity ref): gear drawn from an Armory goes back there and its
-- post's equipped count is claimed while the militia holds it (M3 Stage 2, #56).

local function militia_entity(colony, un)
  local e = colony and colony.colonists and colony.colonists[un]
  return e and e.valid and e or nil
end

-- True while the unit is an on-duty militia. Used by colony.reassign_workforce so a lock change actually
-- reaches work.assign even though the unit is not "idle" (review finding 3).
function M.is_duty(st)
  return st ~= nil and st.job == "militia"
    and (st.state == "militia-hold" or st.state == "militia-fight")
end

local function quality_of(stack)
  local q = stack and stack.quality
  if type(q) == "string" then return q end
  return (q and q.name) or "normal"
end

-- Issue armour into pure gear data. A Personal Shield Pack (#69) starts with a full charge; its absorption
-- and recharge are pure armour-model rules, applied by the single damage handler and the scan below.
local function set_armour(gear, item, q)
  gear.armour, gear.armour_quality = item, q
  if armour.is_shield(item) then gear.shield = armour.SHIELD_CAPACITY end
end

-- Colony stock, with item qualities, read from the Town Hall. Gear is issued from (and ammo spent out of)
-- this single depot, so two militia can never draw the same physical item, and a Watchtower's stock room is
-- never a source (review finding 5: no garrison starvation).
local function hall_stock(colony)
  local counts, quals = {}, {}
  local hall = colony and colony.hall
  if not (hall and hall.valid) then return counts, quals end
  local inv = hall.get_inventory(defines.inventory.chest)
  if not inv then return counts, quals end
  for _, stack in ipairs(inv.get_contents()) do
    if stack and stack.name then
      counts[stack.name] = (counts[stack.name] or 0) + (stack.count or 1)
      quals[stack.name] = quality_of(stack)
    end
  end
  return counts, quals
end

local function remove_from_hall(colony, item, count)
  local hall = colony and colony.hall
  if not (hall and hall.valid) or not item then return 0 end
  local n = hall.remove_item{name = item, count = count or 1}
  -- LuaEntity has no arbitrary fields in 2.1; invalidate the colony's plain-data stock cache instead.
  if colony then colony.ledger_cache = nil; colony.stock_cache = nil end
  return n
end

-- Return a militia's physical gear to the hall. Called on death and on demobilisation (review finding 5),
-- so a rifle is never lost with its owner and a lock change hands the items back to common stock.
function M.return_gear(colony, st, un)
  local gear = st and st.gear
  if not gear then return end
  local hall = colony and colony.hall
  local source = colony and colony.armories and gear.source_armory
    and colony.armories[gear.source_armory] or nil
  for _, item in ipairs({gear.weapon, gear.armour}) do
    if item then
      -- A mined or full Armory falls back to the hall, so gear is never dropped with its owner.
      if source and armory.put(colony, source, item, 1) > 0 then
        -- returned to its source
      elseif hall and hall.valid then
        hall.insert{name = item, count = 1}
      end
    end
  end
  st.gear = nil
  if colony then
    armory.clear_equipped(colony, un)
    colony.ledger_cache = nil; colony.stock_cache = nil
  end
end

-- Draw weapon and armour (one each) from the hall into pure-data gear. Quality is read from the live stack
-- and stored as a string. `opts` lets a spike inject exact gear without depending on random stock.
function M.issue_gear(colony, st, e, opts)
  st.gear = st.gear or {}
  local gear = st.gear
  opts = opts or {}
  -- A stocked Armory in range is the militia's depot (#56 remainder). Gear drawn from it is claimed on the
  -- Armory record, so the post becomes "manned" and cannot be stripped of the same item twice. Spike `opts`
  -- force the old hall path on purpose (exact gear without depending on random world stock).
  local got_source
  if not (opts.weapon or opts.armour) and e and e.valid and colony and colony.armories then
    local function wanted(counts, quals)
      local list = {}
      if not gear.weapon then
        local w = militia_model.best_gear(counts, quals)
        if w then list[#list + 1] = {item = w, count = 1} end
      end
      if not gear.armour then
        local a = armour.best(counts, quals)
        if a then list[#list + 1] = {item = a, count = 1} end
      end
      return list
    end
    local a, grants = armory.gear_source(colony, e.position, wanted)
    if a and #grants > 0 then
      local _, quals = armory.contents(a)
      for _, g in ipairs(grants) do
        if armory.take(a, g.item, g.count) > 0 then
          local q = quals[g.item] or "normal"
          if militia_model.WEAPONS[g.item] and not gear.weapon then
            gear.weapon, gear.quality, gear.uses, gear.ammo_count = g.item, q, 0, 0
          elseif not gear.armour then
            set_armour(gear, g.item, q)
          end
          gear.source_armory = a.entity.unit_number
          got_source = a
        end
      end
      if got_source then armory.mark_equipped(colony, e.unit_number, got_source) end
    end
  end
  -- Hall fills whatever the Armory could not supply (and is the only source for spike-injected gear).
  local counts, quals = hall_stock(colony)
  if not gear.weapon then
    local weapon, wq
    if opts.weapon then weapon, wq = opts.weapon, opts.quality or "normal"
    else weapon, wq = militia_model.best_gear(counts, quals) end
    if weapon then
      remove_from_hall(colony, weapon, 1)
      gear.weapon, gear.quality, gear.uses, gear.ammo_count = weapon, wq or "normal", 0, 0
    end
  end
  if not gear.armour then
    local arm, aq
    if opts.armour then arm, aq = opts.armour, opts.armour_quality or "normal"
    else arm, aq = armour.best(counts, quals) end
    if arm then
      remove_from_hall(colony, arm, 1)
      set_armour(gear, arm, aq or "normal")
    end
  end
  return gear
end

-- The ONE initialisation routine for an on-duty militia, shared by spawn, convert and assign. Every creation
-- path must end here: state, gear, label and the first scan timer. (Review finding 1.)
function M.init(colony, un, e, st, opts)
  st.colony_id = colony.id
  st.job = "militia"
  st.state = "militia-hold"
  st.gear = st.gear or {}
  M.issue_gear(colony, st, e, opts)
  work.set_label(e, "militia", true)
  scheduler.after(M.SCAN_TICKS + (un * 29) % 120, "militia.scan", {un = un})
  return st
end

-- Swap a unit to a different prototype, migrating all per-unit storage keys to the new unit number. The old
-- entity is destroyed only AFTER the migration, so work.lua's on_object_destroyed cleanup finds nothing to
-- remove under the old number. Returns new_unit_number, new_entity (or nil on failure).
local function swap_entity(colony, un, e, st, new_name)
  local pos = e.surface.find_non_colliding_position(new_name, e.position, 6, 0.5)
  if not pos then return nil end
  local new = e.surface.create_entity{name = new_name, position = pos, force = e.force}
  if not new then return nil end
  local nun = new.unit_number
  colony.colonists[nun], colony.colonists[un] = new, nil
  storage.unit_state[nun], storage.unit_state[un] = st, nil
  st.colony_id = colony.id
  if colony.locks and colony.locks[un] then
    colony.locks[nun] = colony.locks[un]; colony.locks[un] = nil
  end
  for _, key in ipairs({"unit_labels", "carry_sprites", "sick", "age"}) do
    local t = storage[key]
    if t and t[un] then t[nun] = t[un]; t[un] = nil end
  end
  -- colony.away is a commuter COUNT (not a per-unit map), so there is nothing to migrate here.
  script.register_on_object_destroyed(new)
  e.destroy()
  return nun, new
end

-- Spawn a ready militia unit (used by the spike). Registered in the colony roster like a colonist, so
-- mortality, death cleanup and the command whistle all find it by unit number.
function M.spawn(colony, at, opts)
  local hall = colony and colony.hall
  if not (hall and hall.valid) then return nil end
  local pos = hall.surface.find_non_colliding_position("colony-militia", at or hall.position, 10, 0.5)
  if not pos then return nil end
  local e = hall.surface.create_entity{name = "colony-militia", position = pos, force = hall.force}
  if not e then return nil end
  colony.colonists[e.unit_number] = e
  colony.locks = colony.locks or {}
  colony.locks[e.unit_number] = "militia"   -- same lock a GUI-locked/converted militia carries
  colony.pop_cache, colony.pop_tick = nil, nil
  script.register_on_object_destroyed(e)
  local st = {}
  storage.unit_state[e.unit_number] = st
  M.init(colony, e.unit_number, e, st, opts)
  return e
end

-- Convert an existing colonist (the real player path: GUI lock -> work.assign -> militia.assign). The swap
-- migrates storage, then M.init arms and starts the new unit; it is NOT left inert (review finding 1).
function M.convert(colony, un, e, st)
  work.release(st)   -- return any carry, undo claims; idempotent for an idle colonist
  local nun, new = swap_entity(colony, un, e, st, "colony-militia")
  if not nun then return nil end
  M.init(colony, nun, new, st)
  return nun
end

-- Hand a militia back to the workforce: return its gear, swap it to a civilian, and re-assign it so the
-- player's new lock takes effect. Called by work.assign when the unit is no longer locked to militia.
function M.demobilize(colony, un, e, st)
  M.return_gear(colony, st, un)
  local nun, new = swap_entity(colony, un, e, st, "colony-colonist")
  if not nun then return nil end
  storage.unit_state[nun] = {colony_id = colony.id, state = "idle"}
  work.clear_label(nun)
  work.assign(colony, nun)
  return nun
end

-- Called by work.assign for the militia job. If the unit is still a civilian colonist, convert it; the new
-- unit number is returned and work.assign simply hands off. The state machine itself is driven by schedulers.
function M.assign(colony, un, e, st)
  if not (colony and e and e.valid) then return end
  if e.name ~= "colony-militia" then
    local nun = M.convert(colony, un, e, st)
    return nun
  end
  -- Already a militia on duty: keep its state (a redundant reassign is a no-op).
  if st.state == "militia-hold" or st.state == "militia-fight" then return end
  -- A militia returning from a whistle lease / sleep / idle re-enters duty with its existing gear.
  M.init(colony, un, e, st)
end

-- Command Whistle hook: a militia's gear is pure data and is carried across the lease by abort_intents; this
-- guard clears any stale engagement timers so a released unit cannot be struck by an old callback (#58 pattern).
function M.release_claim(un, st)
  if st then st.site, st.attempts = nil, nil end
end

-- One completed engagement's wear/ammo spend, shared by the militia state machine and a patrol's engagement.
-- The damage rule itself is `model/militia.engage`; this is only the adapter's bookkeeping, so a patrol never
-- invents a second combat rule (M3 Stage 3, #57).
local function spend_one(colony, st)
  local gear = st.gear or {}
  local weapon = gear.weapon
  local def = weapon and militia_model.WEAPONS[weapon]
  if not def then return end
  local _, spent, ammo_count = militia_model.spend(gear)
  gear.ammo_count = ammo_count
  -- Wear applies to every wear weapon (rifle/bow), independently of ammo spend.
  if def.wear then
    gear.uses = (gear.uses or 0) + 1
    if gear.uses >= (def.uses or 1) then gear.weapon, gear.uses = nil, 0 end
  end
  -- Ammo (a magazine or an arrow) is spent out of the gear's own depot, never a colony.machines row (#59).
  -- A rifle's `spent == weapon` is its own break, already handled by wear above.
  if spent and spent ~= weapon then
    local src = colony and colony.armories and gear.source_armory
      and colony.armories[gear.source_armory] or nil
    if not (src and armory.take(src, spent, 1) > 0) then remove_from_hall(colony, spent, 1) end
  end
end

-- Patrol engagement (M3 Stage 3): the patrol adapter owns the route/lease, but the damage AND the wear are
-- exactly Stage 1's model/militia rules - one scripted strike inside the hitscan range, no new combat rule.
function M.patrol_strike(colony, un, st, target)
  if not (colony and st and target and target.valid and target.health > 0) then return false end
  local e = militia_entity(colony, un)
  if not e then return false end
  local dx, dy = target.position.x - e.position.x, target.position.y - e.position.y
  if dx * dx + dy * dy > M.ATTACK_RANGE * M.ATTACK_RANGE then return false end
  local damage, dtype = militia_model.engage(st.gear)
  target.damage(damage, e.force, dtype, e, e)   -- cause = militia: mortality attribution stays honest
  spend_one(colony, st)
  return true
end

local function end_engagement(colony, un, st)
  spend_one(colony, st)
  st.site, st.attempts = nil, nil
  st.state = "militia-hold"
  local e = militia_entity(colony, un)
  if e and e.valid then
    e.commandable.set_command{type = defines.command.stop, ticks_to_wait = 4294967295,
      distraction = defines.distraction.none}
  end
  scheduler.after(M.SCAN_TICKS + (un * 29) % 120, "militia.scan", {un = un})
end

local function scan(d)
  local st = storage.unit_state[d.un]
  if not (st and st.job == "militia" and st.state == "militia-hold") then return end
  local colony = storage.colonies[st.colony_id]
  if not colony then return end
  local e = militia_entity(colony, d.un)
  if not e then return end
  -- Off duty at night like guards and every other colonist; the morning assignment re-posts them (#86).
  if work.is_sleep_time(e.surface) then work.assign(colony, d.un); return end
  M.issue_gear(colony, st, e)
  -- A shield recharges a little each scan (event-driven, never per tick); the pure rule caps it at capacity.
  if st.gear and armour.is_shield(st.gear.armour) then
    st.gear.shield = armour.shield_recharge(st.gear.shield, M.SCAN_TICKS)
  end
  if not (st.gear and st.gear.weapon) then
    -- Nothing to fight with: hand the unit back to the workforce rather than leaving a permanent empty post.
    work.assign(colony, d.un)
    return
  end
  local pos, r = e.position, M.RANGE
  local list = {}
  for _, en in ipairs(e.surface.find_entities_filtered{type = "unit", force = "enemy",
      area = {{pos.x - r, pos.y - r}, {pos.x + r, pos.y + r}}}) do
    if en.valid then list[#list + 1] = {unit_number = en.unit_number, position = en.position, entity = en} end
  end
  local pick = garrison.nearest(list, pos, r)
  if pick then
    st.site, st.attempts = pick.entity, 1
    st.state = "militia-fight"
    work.command_attack(e, pick.entity)
    scheduler.after(M.STRIKE_TICKS, "militia.strike", {un = d.un})
    return
  end
  scheduler.after(M.SCAN_TICKS + (d.un * 29) % 120, "militia.scan", {un = d.un})
end
scheduler.register("militia.scan", scan)

local function strike(d)
  local st = storage.unit_state[d.un]
  if not (st and st.job == "militia" and st.state == "militia-fight") then return end
  local colony = storage.colonies[st.colony_id]
  if not colony then return end
  local e = militia_entity(colony, d.un)
  if not e then return end
  local target = st.site
  if not (target and target.valid and target.health > 0) then
    end_engagement(colony, d.un, st)
    return
  end
  -- Only land a scripted strike inside the unit's attack range; the engine command walks it into range.
  local dx, dy = target.position.x - e.position.x, target.position.y - e.position.y
  if dx * dx + dy * dy <= M.ATTACK_RANGE * M.ATTACK_RANGE then
    local damage, dtype = militia_model.engage(st.gear)
    -- Dot form passes all five params (damage, force, type, source, cause); colon would add a 6th self arg.
    target.damage(damage, e.force, dtype, e, e)   -- cause = militia: on_entity_died attribution stays honest
  end
  scheduler.after(M.STRIKE_TICKS, "militia.strike", {un = d.un})
end
scheduler.register("militia.strike", strike)

-- Armour mitigation is applied here and ONLY here: heal back the mitigated share of the damage the engine
-- actually applied. Setting entity.health directly does not raise on_entity_damaged, so there is no recursion.
-- The colonist has no native resistance path (s19_defence), so there is no second subtraction to double-count.
events.on(defines.events.on_entity_damaged, function(ev)
  local e = ev.entity
  if not (e and e.valid and e.name == "colony-militia") then return end
  local st = storage.unit_state and storage.unit_state[e.unit_number]
  local gear = st and st.gear
  if not (gear and gear.armour) then return end
  local applied = ev.final_damage_amount or ev.original_damage_amount or 0
  if applied <= 0 then return end
  local hp = e.health
  -- Armour never revives: if the engine already took this unit to 0 health (a lethal hit), do not heal.
  if hp <= 0 then return end
  local healed = 0
  if armour.is_shield(gear.armour) then
    -- The Fulgora shield is a flat, finite pool rather than a percentage (#69): the absorbed part is healed
    -- back and the charge is spent now, then refilled by the scan timer. No second percentage applies.
    local absorbed, left = armour.shield_drain(gear.shield, applied)
    gear.shield = left
    healed = absorbed
  else
    local mitigation = armour.mitigation(gear.armour, gear.armour_quality)
    if mitigation <= 0 then return end
    healed = applied * mitigation
  end
  healed = math.min(healed, e.max_health - hp)
  if healed > 0 then e.health = hp + healed end
end)

-- A dead militia's physical gear goes back to the hall (review finding 5), once, before cleanup erases state.
events.on(defines.events.on_entity_died, function(ev)
  local e = ev.entity
  -- A just-killed entity can already be invalid at handler time (cf. mortality.lua): check the name only.
  if not (e and e.name == "colony-militia") then return end
  local st = storage.unit_state and storage.unit_state[e.unit_number]
  if not st then return end
  local colony = storage.colonies[st.colony_id]
  if colony then M.return_gear(colony, st, e.unit_number) end
end)

return M
