-- Militia adapter (M3 defence stack, #55). All combat rules live in pure models (model/militia.lua,
-- model/armour.lua); this file only resolves live entities, issues engine commands, calls LuaEntity:damage
-- on a confirmed engagement, and applies armour mitigation as a scripted heal-back on on_entity_damaged.
-- Stage 0 (s19_defence) proved units have no armour inventory/grid/resistances, so armour is pure data on
-- unit_state.gear and the heal-back event is the ONLY mitigation path. Bind via M.bind (no runtime require).
local events = require("scripts.events")
local scheduler = require("scripts.scheduler")
local work = require("scripts.work")
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
--   {weapon=, quality=, armour=, armour_quality=, uses=, ammo_count=}

local function militia_entity(colony, un)
  local e = colony and colony.colonists and colony.colonists[un]
  return e and e.valid and e or nil
end

local function quality_of(stack)
  local q = stack and stack.quality
  if type(q) == "string" then return q end
  return (q and q.name) or "normal"
end

-- Colony stock, with item qualities, read from the Town Hall. Gear is issued from (and ammo spent out of)
-- this single depot, so two militia can never draw the same physical item.
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

-- Draw weapon and armour (one each) from the hall into pure-data gear. Quality is read from the live stack
-- and stored as a string. `opts` lets a spike inject exact gear without depending on random stock.
function M.issue_gear(colony, st, e, opts)
  st.gear = st.gear or {}
  local gear = st.gear
  local counts, quals = hall_stock(colony)
  opts = opts or {}
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
      gear.armour, gear.armour_quality = arm, aq or "normal"
    end
  end
  return gear
end

-- Spawn a ready militia unit (used by the spike and by conversion). Registered in the colony roster like a
-- colonist, so mortality, death cleanup and the command whistle all find it by unit number.
function M.spawn(colony, at, opts)
  local hall = colony and colony.hall
  if not (hall and hall.valid) then return nil end
  local pos = hall.surface.find_non_colliding_position("colony-militia", at or hall.position, 10, 0.5)
  if not pos then return nil end
  local e = hall.surface.create_entity{name = "colony-militia", position = pos, force = hall.force}
  if not e then return nil end
  colony.colonists[e.unit_number] = e
  colony.pop_cache, colony.pop_tick = nil, nil
  script.register_on_object_destroyed(e)
  local st = {colony_id = colony.id, job = "militia", state = "militia-hold"}
  storage.unit_state[e.unit_number] = st
  M.issue_gear(colony, st, e, opts)
  work.set_label(e, "militia", true)
  scheduler.after(M.SCAN_TICKS + (e.unit_number * 29) % 120, "militia.scan", {un = e.unit_number})
  return e
end

-- Convert an existing colonist into a militia prototype, migrating all per-unit storage keys to the new unit
-- number. The old entity is destroyed only AFTER the migration, so work.lua's on_object_destroyed cleanup
-- finds nothing to remove under the old number. Rendering objects tied to the old entity are recreated by the
-- state machine. Returns the new unit number (or nil on failure).
function M.convert(colony, un, e, st)
  if e.name == "colony-militia" then return un end
  local pos = e.surface.find_non_colliding_position("colony-militia", e.position, 6, 0.5)
  if not pos then return nil end
  local new = e.surface.create_entity{name = "colony-militia", position = pos, force = e.force}
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
  if colony.away and colony.away[un] then colony.away[nun] = colony.away[un]; colony.away[un] = nil end
  script.register_on_object_destroyed(new)
  work.set_label(new, "militia", true)
  e.destroy()
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
  -- Already a militia: keep an on-duty state; a fresh/idle one re-enters the hold scan.
  if st.state == "militia-hold" or st.state == "militia-fight" then return end
  st.job = "militia"
  st.state = "militia-hold"
  st.gear = st.gear or {}
  M.issue_gear(colony, st, e)
  work.set_label(e, "militia", true)
  scheduler.after(M.SCAN_TICKS + (un * 29) % 120, "militia.scan", {un = un})
end

-- Command Whistle hook: a militia's gear is pure data and is carried across the lease by abort_intents; this
-- guard clears any stale engagement timers so a released unit cannot be struck by an old callback (#58 pattern).
function M.release_claim(un, st)
  if st then st.site, st.attempts = nil, nil end
end

local function end_engagement(colony, un, st)
  local gear = st.gear or {}
  local weapon = gear.weapon
  local def = weapon and militia_model.WEAPONS[weapon]
  if def then
    local _, spent, ammo_count = militia_model.spend(gear)
    gear.ammo_count = ammo_count
    -- Wear applies to every wear weapon (rifle/bow), independently of ammo spend.
    if def.wear then
      gear.uses = (gear.uses or 0) + 1
      if gear.uses >= (def.uses or 1) then gear.weapon, gear.uses = nil, 0 end
    end
    -- Ammo (a magazine or an arrow) is spent out of colony stock, never a colony.machines row (#59). A
    -- rifle's `spent == weapon` is its own break, already handled by wear above.
    if spent and spent ~= weapon then remove_from_hall(colony, spent, 1) end
  end
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
    local damage, dtype = militia_model.engage(st.gear, {})
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
  local mitigation = armour.mitigation(gear.armour, gear.armour_quality)
  if mitigation <= 0 then return end
  local applied = ev.final_damage_amount or ev.original_damage_amount or 0
  if applied <= 0 then return end
  local hp = e.health
  -- Armour never revives: if the engine already took this unit to 0 health (a lethal hit), do not heal.
  if hp <= 0 then return end
  local healed = math.min(applied * mitigation, e.max_health - hp)
  if healed > 0 then e.health = hp + healed end
end)

return M
