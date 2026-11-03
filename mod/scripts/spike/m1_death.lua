-- M1 permanent death spike (#53): a colonist killed by a biter is struck off and counted once, with a Grave where it
-- fell; once a Cemetery is built the next death (run over by a car) is buried there instead and mourning halves; a
-- Passenger Coach destroyed with riders kills them, and one removed any other way sends them home.
-- Run: TICKS=1500 scripts/headless-spike.sh m1_death
local core = require("scripts.spike.core")
local colony = require("scripts.colony")
local desirability = require("scripts.model.desirability")
local mortality = require("scripts.model.mortality")

local ROW = 19

core.register("m1_death", {
  issue = 53, auto = true, desc = "permadeath: any death counted once, grave or cemetery, coach riders", usage = "",
  run = function(ctx)
    local s, p = ctx.surface, ctx.position
    ctx.flat_area(60, "grass-1")
    s.always_day, s.freeze_daytime = true, true
    local function build(name, pos, dir)
      return s.create_entity{name = name, position = pos, direction = dir, force = "player", raise_built = true}
    end
    storage.interval_override = 150
    local hall = build("colony-town-hall", {p.x, p.y})
    local c
    for _, col in pairs(storage.colonies) do c = col end
    ctx.check("colony registered", c ~= nil and hall and hall.valid)
    if not c then return ctx.finish() end
    for i = 0, 3 do build("colony-housing-cabin", {p.x - 9 + i * 6, p.y - 8}) end
    hall.insert{name = "raw-fish", count = 200}
    for _ = 1, 8 do colony.spawn_colonist(c) end
    local pop0 = colony.live_colonists(c)
    ctx.check("eight colonists", pop0 == 8, pop0 .. " colonists")

    local function pick()
      local best
      for un, e in pairs(c.colonists) do if e.valid and (not best or un > best) then best = un end end
      return best, best and c.colonists[best]
    end
    local function graves_near(pos)
      return s.count_entities_filtered{name = "colony-grave", position = pos, radius = 2}
    end
    local function graves() return s.count_entities_filtered{name = "colony-grave"} end

    -- 1. Killed by a biter: struck off, counted once, Grave where it fell, cause "enemy".
    local biter = s.create_entity{name = "small-biter", position = {p.x + 40, p.y + 40}, force = "enemy"}
    local un, victim = pick()
    local at = victim.position
    victim.die("enemy", biter)
    biter.destroy()
    c.pop_cache, c.pop_tick = nil, nil
    ctx.check("1 biter kill struck the colonist off the roster", c.colonists[un] == nil and colony.live_colonists(c) == pop0 - 1)
    ctx.check("1 counted once as a death", c.fallen == 1 and #c.deaths == 1, "fallen=" .. tostring(c.fallen) .. " deaths=" .. #c.deaths)
    ctx.check("1 cause recorded as enemy", c.last_death == "enemy", tostring(c.last_death))
    ctx.check("1 a Grave marks where it fell", graves_near(at) == 1, graves_near(at) .. " graves")

    -- 2. Cemetery built: the next death (run over by a car) is buried there, no field Grave.
    local cem = build("colony-cemetery", {p.x + 8, p.y + 6})
    ctx.check("2 cemetery registered", cem and cem.valid and c.cemeteries[cem.unit_number] ~= nil)
    local car = s.create_entity{name = "car", position = {p.x - 30, p.y + 30}, force = "player"}
    un, victim = pick()
    at = victim.position
    victim.die("player", car)
    ctx.check("2 cause recorded as vehicle", c.last_death == "vehicle", tostring(c.last_death))
    ctx.check("2 buried in the cemetery, no field grave", c.cemeteries[cem.unit_number].graves == 1 and c.buried == 1
      and graves() == 1, "graves=" .. c.cemeteries[cem.unit_number].graves .. " field=" .. graves())

    -- 3. Coach destroyed with three riders aboard: three deaths for the colony they boarded from.
    for x = 1, 41, 2 do s.create_entity{name = "straight-rail", position = {p.x + x, p.y + ROW}, direction = defines.direction.east, force = "player"} end
    local coach1 = s.create_entity{name = "colony-passenger-coach", position = {p.x + 11, p.y + ROW}, direction = defines.direction.east, force = "player"}
    local coach2 = s.create_entity{name = "colony-passenger-coach", position = {p.x + 31, p.y + ROW}, direction = defines.direction.east, force = "player"}
    ctx.check("3 two coaches on the rails", coach1 and coach2 and coach1.valid and coach2.valid)
    if not (coach1 and coach2) then return ctx.finish() end
    storage.coaches = storage.coaches or {}
    for _, w in ipairs({coach1, coach2}) do script.register_on_object_destroyed(w) end
    storage.coaches[coach1.unit_number] = {groups = {{from = c.id, n = 3, stops = 1}}}
    storage.coaches[coach2.unit_number] = {groups = {{from = c.id, n = 2, stops = 1}}}
    local fallen, id1 = c.fallen, coach1.unit_number
    coach1.die()
    ctx.check("3 wrecked coach: riders counted dead", c.fallen == fallen + 3 and storage.coaches[id1] == nil,
      "fallen " .. fallen .. " -> " .. c.fallen)
    ctx.check("3 riders buried in the cemetery", c.cemeteries[cem.unit_number].graves == 4, c.cemeteries[cem.unit_number].graves .. " graves")

    -- 4. Coach mined/removed: riders walk home, no deaths.
    c.pop_cache, c.pop_tick = nil, nil
    local pop_before, fallen_before = colony.live_colonists(c), c.fallen
    coach2.destroy()
    ctx.after(5, function()
      c.pop_cache, c.pop_tick = nil, nil
      ctx.check("4 removed coach: riders back in town, nobody died", colony.live_colonists(c) == pop_before + 2
        and c.fallen == fallen_before, "pop " .. pop_before .. " -> " .. colony.live_colonists(c))
    end)

    -- 5. After evaluations: mourning uses the cemetery half-life, tooltip and hall stats.
    ctx.after(700, function()
      local want = 0
      for _, age in ipairs(c.deaths) do
        want = want + desirability.defaults.death_penalty * 0.5 ^ (age / mortality.BURIED_HALFLIFE)
      end
      local got = c.d_parts and c.d_parts.deaths or 0
      ctx.check("5 death penalty decays at the cemetery half-life", math.abs(got + want) < 1e-9 and want > 0,
        string.format("parts.deaths=%.4f want=-%.4f", got, want))
      local cs = cem.custom_status
      ctx.check("5 cemetery tooltip shows plots used", cs and cs.label and cs.label[1] == "colony-status.cemetery-room",
        cs and cs.label and tostring(cs.label[1]) or "no status")
      local st = colony.stats(c)
      -- Any starvation in this underfed test town goes through the same path, so the books must still balance:
      -- one entry per death, and every death after the cemetery went up is in it.
      ctx.check("5 hall stats: every death counted once, all but the first buried", st.fallen >= 5
        and st.fallen == #c.deaths and st.buried == st.fallen - 1 and graves() == 1,
        st.fallen .. " dead / " .. #c.deaths .. " penalties / " .. st.buried .. " buried, last=" .. tostring(c.last_death))
      ctx.finish()
    end)
  end,
})
