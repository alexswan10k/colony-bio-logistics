-- Civil defence adapter (#61). Rules are in model/alarm.lua; this file listens for enemy damage, keeps the
-- alarms, and moves colonists in and out of shelter (the walking and arriving is in work.lua).
-- Peacetime cost is one cheap check per damage event; the alarm upkeep (one find_units per alarm plus a pass
-- over the colony's colonists) only runs every CHECK_TICKS while an alarm is up.
local events = require("scripts.events")
local scheduler = require("scripts.scheduler")
local territory = require("scripts.territory")
local alarm = require("scripts.model.alarm")
local work = require("scripts.work")
local M = {}

local colony_mod   -- injected by scripts.colony via M.bind
function M.bind(c) colony_mod = c end

-- Every place a colonist can hide, in a stable order: houses, then the Town Hall.
local function shelters(colony)
  local out = {}
  for _, h in ipairs(colony_mod.house_list(colony)) do
    if h.entity.valid then out[#out + 1] = h.entity end
  end
  if colony.hall.valid then out[#out + 1] = colony.hall end
  return out
end

local function threats(colony)
  local out = {}
  for _, a in ipairs(colony.alarms) do out[#out + 1] = a.pos end
  return out
end

-- Send colonist `un` (entity `e`) to shelter if it stands inside an alarm. Used by the alarm sweep and by
-- work.assign, so nobody walks off to a job in the middle of a raid.
local function take_cover(colony, un, e)
  local st = storage.unit_state[un]
  if st and alarm.EXEMPT[st.state] then return false end
  if not alarm.covers(colony.alarms, e.position) then return false end
  local list = shelters(colony)
  local i = alarm.shelter(list, e.position, threats(colony))
  if not i then return false end
  return work.send_to_shelter(colony, un, list[i])
end
work.take_cover = take_cover

local function all_clear(colony)
  local ids = {}
  for un in pairs(colony.colonists) do ids[#ids + 1] = un end
  table.sort(ids)
  local n = 0
  for _, un in ipairs(ids) do
    local st = storage.unit_state[un]
    if st and (st.state == "sheltered" or st.state == "to_shelter" or st.state == "exposed") then
      n = n + 1
      work.leave_shelter(colony, un)
    end
  end
  if colony.hall.valid then colony.hall.force.print({"colony-message.all-clear", n}) end
end

scheduler.register("shelter.check", function(d)
  local colony = storage.colonies[d.colony_id]
  if not (colony and colony.hall.valid and colony.alarms and #colony.alarms > 0) then
    if colony then colony.alarm_check = nil end
    return
  end
  local s = colony.hall.surface
  local hostile = {}
  for i, a in ipairs(colony.alarms) do
    local r = alarm.RADIUS
    hostile[i] = #s.find_units{area = {{a.pos.x - r, a.pos.y - r}, {a.pos.x + r, a.pos.y + r}}, force = "enemy",
      condition = "same"} > 0
  end
  local cleared
  colony.alarms, cleared = alarm.upkeep(colony.alarms, hostile, game.tick)
  if #colony.alarms == 0 then
    colony.alarm_check = nil
    all_clear(colony)
    return
  end
  -- Sweep: anyone still out in the open inside an alarm takes cover; anyone whose shelter fell runs again.
  local ids = {}
  for un, e in pairs(colony.colonists) do if e.valid then ids[#ids + 1] = un end end
  table.sort(ids)
  for _, un in ipairs(ids) do
    local e = colony.colonists[un]
    local st = storage.unit_state[un]
    local hiding = st and (st.state == "sheltered" or st.state == "to_shelter" or st.state == "exposed")
    if hiding and cleared > 0 and not (st.fled_from and alarm.covers(colony.alarms, st.fled_from)) then
      work.leave_shelter(colony, un)          -- the alarm it fled from is over; others may still be up
    else
      if hiding and st.state ~= "exposed" and not (st.shelter and st.shelter.valid) then
        e.destructible = true
        st.state = "exposed"
      end
      take_cover(colony, un, e)
    end
  end
  scheduler.after(alarm.CHECK_TICKS, "shelter.check", d)
end)

-- Raise an alarm for `colony` at `pos`, announcing the first one and starting the upkeep loop.
function M.raise(colony, pos)
  colony.alarms = colony.alarms or {}
  local quiet = #colony.alarms > 0
  colony.next_alarm = (colony.next_alarm or 0) + 1
  local a, new = alarm.raise(colony.alarms, pos, game.tick, colony.next_alarm)
  if not new then return a end
  if not quiet and colony.hall.valid then
    colony.hall.force.print({"colony-message.under-attack",
      colony_mod.gps(pos, colony.hall.surface)})
  end
  if not colony.alarm_check then
    colony.alarm_check = true
    scheduler.after(1, "shelter.check", {colony_id = colony.id})
  end
  return a
end

-- Anything of ours damaged by the enemy force inside a colony's territory raises (or refreshes) an alarm there.
events.on(defines.events.on_entity_damaged, function(ev)
  local f = ev.force
  if not (f and f.name == "enemy") then return end
  local e = ev.entity
  if not (e and e.valid) or e.force.name == "enemy" then return end
  local owner = territory.owner_at(e.surface.index, e.position)
  local colony = owner and storage.colonies[owner]
  if colony and colony.hall.valid and colony.hall.force == e.force then M.raise(colony, e.position) end
end)

return M
