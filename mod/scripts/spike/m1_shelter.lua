-- M1 civil defence spike (#61): an enemy hits a colonist out at the edge of town; that raises an alarm, the
-- colonists near it run to a shelter well away from the threat and cannot be hurt there, colonists elsewhere
-- keep working, the alarm holds while the enemy is about and clears after it is gone, and then everyone is
-- vulnerable again and back at work. Finally a real raid is let loose and survivors are logged (evidence only).
-- Run: TICKS=4800 scripts/headless-spike.sh m1_shelter
local core = require("scripts.spike.core")
local colony = require("scripts.colony")
local alarm = require("scripts.model.alarm")

local SHELTERING = {to_shelter = true, sheltered = true, exposed = true}

core.register("m1_shelter", {
  issue = 61, auto = true, desc = "civil defence: alarm on enemy damage, shelter, invulnerable inside, all-clear", usage = "",
  run = function(ctx)
    local s, p = ctx.surface, ctx.position
    ctx.flat_area(90, "grass-1")
    s.always_day, s.freeze_daytime = true, true
    local function build(name, pos)
      return s.create_entity{name = name, position = pos, force = "player", raise_built = true}
    end
    storage.interval_override = 150
    local hall = build("colony-town-hall", {p.x, p.y})
    local c
    for _, col in pairs(storage.colonies) do c = col end
    ctx.check("colony registered", c ~= nil and hall and hall.valid)
    if not c then return ctx.finish() end
    local tower = build("colony-watchtower", {p.x + 40, p.y})
    ctx.check("watchtower extends the territory east", tower and tower.valid)
    for i = 0, 3 do build("colony-housing-cabin", {p.x - 9 + i * 6, p.y - 8}) end
    hall.insert{name = "raw-fish", count = 400}
    c.accept_migrants = false             -- head counts only move by death
    for _ = 1, 8 do colony.spawn_colonist(c) end
    local threat = {x = p.x + 64, y = p.y}

    local ids = {}
    for un in pairs(c.colonists) do ids[#ids + 1] = un end
    table.sort(ids)
    local A, B = ids[1], ids[2]
    local function state(un) local st = storage.unit_state[un]; return st and st.state end

    local biter
    ctx.after(60, function()
      -- Two colonists out east, one enemy beside them standing still; it bites A once.
      for i, un in ipairs({A, B}) do
        local e = c.colonists[un]
        e.teleport({threat.x - 3 + i * 2, threat.y})
        e.commandable.set_command{type = defines.command.stop, ticks_to_wait = 600, distraction = defines.distraction.none}
      end
      biter = s.create_entity{name = "small-biter", position = {threat.x, threat.y + 6}, force = "enemy"}
      biter.commandable.set_command{type = defines.command.stop, ticks_to_wait = 4294967295, distraction = defines.distraction.none}
      c.colonists[A].damage(10, "enemy", "physical", biter)
      ctx.check("1 enemy damage inside the territory raises one alarm", #c.alarms == 1, #c.alarms .. " alarms")
    end)

    ctx.after(65, function()     -- the alarm sweep runs the tick after the alarm goes up
      ctx.check("1 the colonists beside it run for shelter", state(A) == "to_shelter" and state(B) == "to_shelter",
        tostring(state(A)) .. " / " .. tostring(state(B)))
      local others = 0
      for i = 3, #ids do if SHELTERING[state(ids[i]) or ""] then others = others + 1 end end
      ctx.check("1 colonists far from it are left alone", others == 0, others .. " others sheltering")
      local sh = storage.unit_state[A].shelter
      local dx, dy = sh.position.x - threat.x, sh.position.y - threat.y
      ctx.check("1 the shelter is well away from the threat", dx * dx + dy * dy >= alarm.SAFE * alarm.SAFE,
        string.format("%s at %.0f tiles", sh.name, math.sqrt(dx * dx + dy * dy)))
    end)

    ctx.after(1260, function()
      ctx.check("2 both arrive and shelter", state(A) == "sheltered" and state(B) == "sheltered",
        tostring(state(A)) .. " / " .. tostring(state(B)))
      local e = c.colonists[A]
      ctx.check("2 a sheltered colonist cannot be hurt", e and e.valid and e.destructible == false)
      local hp = e.health
      pcall(function() e.damage(50, "enemy", "physical", biter) end)
      ctx.check("2 damage does nothing in shelter", e.valid and e.health == hp, tostring(hp) .. " -> " .. tostring(e.valid and e.health))
      ctx.check("2 the alarm holds while the enemy is about", #c.alarms == 1)
      local cs = hall.custom_status
      ctx.check("2 the Town Hall shows the attack", cs and cs.label and cs.label[1] == "colony-advice.under-attack"
        and tostring(cs.label[2]) == "2", cs and cs.label and (tostring(cs.label[1]) .. " " .. tostring(cs.label[2])) or "no status")
      biter.destroy()
    end)

    ctx.after(1260 + alarm.CLEAR_TICKS + 2 * alarm.CHECK_TICKS + 30, function()
      ctx.check("3 the alarm clears once the enemy is gone", #c.alarms == 0, #c.alarms .. " alarms")
      local still, safe = 0, 0
      for _, un in ipairs(ids) do
        local e = c.colonists[un]
        if SHELTERING[state(un) or ""] then still = still + 1 end
        if e and e.valid and e.destructible == false then safe = safe + 1 end
      end
      ctx.check("3 everyone leaves shelter and is vulnerable again", still == 0 and safe == 0,
        still .. " sheltering, " .. safe .. " invulnerable")
      -- 4. A real raid: six biters told to attack the town. Evidence only: who survives, and did the alarm go up.
      ctx.raid = {alarm = false, t0 = game.tick}
      for i = 1, 6 do
        local b = s.create_entity{name = "small-biter", position = {threat.x, threat.y - 3 + i}, force = "enemy"}
        if b then
          b.commandable.set_command{type = defines.command.attack_area, destination = {p.x, p.y}, radius = 20,
            distraction = defines.distraction.by_anything}
        end
      end
      local function watch()
        if #c.alarms > 0 then ctx.raid.alarm = true end
        if game.tick - ctx.raid.t0 < 1500 then ctx.after(30, watch) end
      end
      watch()
    end)

    ctx.after(1260 + alarm.CLEAR_TICKS + 2 * alarm.CHECK_TICKS + 30 + 1560, function()
      c.pop_cache, c.pop_tick = nil, nil
      local sheltered = 0
      for un in pairs(c.colonists) do if state(un) == "sheltered" then sheltered = sheltered + 1 end end
      ctx.log(string.format("raid: alarm=%s alive=%d/8 dead=%d sheltered-now=%d biters-left=%d", tostring(ctx.raid.alarm),
        colony.live_colonists(c), c.fallen or 0, sheltered, s.count_entities_filtered{name = "small-biter", force = "enemy"}))
      ctx.check("4 a real raid raises the alarm", ctx.raid.alarm)
      ctx.finish()
    end)
  end,
})
