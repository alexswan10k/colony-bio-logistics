-- M1 breeding spike (#88): an opposite-sex pair in one house with their provisions met and a free bed has a
-- child; the child counts toward occupancy, is never assigned work, eats half portions, and grows into an adult.
-- Run: TICKS=8000 scripts/headless-spike.sh m1_breed
local core = require("scripts.spike.core")
local colony = require("scripts.colony")
local breeding = require("scripts.model.breeding")

core.register("m1_breed", {
  issue = 88, auto = true, desc = "natural reproduction: births, children don't work, children grow up", usage = "",
  run = function(ctx)
    local s, p = ctx.surface, ctx.position
    ctx.flat_area(60, "grass-1")
    s.always_day, s.freeze_daytime = true, true
    local function build(name, pos)
      return s.create_entity{name = name, position = pos, force = "player", raise_built = true}
    end
    storage.interval_override = 150
    local hall = build("colony-town-hall", {p.x, p.y})
    local cabin = build("colony-housing-cabin", {p.x + 6, p.y})
    local c
    for _, col in pairs(storage.colonies) do c = col end
    ctx.check("colony registered", c ~= nil and hall and hall.valid)
    if not c then return ctx.finish() end
    c.accept_migrants = false
    hall.insert{name = "raw-fish", count = 200}
    cabin.insert{name = "raw-fish", count = 60}   -- shelves full: provisions met without waiting on haulers
    ctx.check("cabin registered and stocked", cabin and cabin.valid and c.houses[cabin.unit_number] ~= nil)
    for _ = 1, 2 do colony.spawn_colonist(c) end
    ctx.check("two colonists spawned", colony.live_colonists(c) == 2, colony.live_colonists(c))
    local households = colony.households(c)
    local pair = households[cabin.unit_number] or {}
    ctx.check("the pair shares the house", #pair == 2, #pair .. " residents")
    local sexes = {}
    for _, un in ipairs(pair) do sexes[#sexes + 1] = breeding.sex_of(un) end
    table.sort(sexes)
    ctx.check("one adult of each sex", table.concat(sexes, ",") == "female,male", table.concat(sexes, ","))

    local born_at, child_un
    ctx.after(6500, function()
      for un, rec in pairs(storage.age or {}) do
        if rec.stage == "child" then born_at, child_un = rec.born, un end
      end
      ctx.check("a child was born within the window", child_un ~= nil,
        child_un and ("born at t=" .. tostring(born_at)) or "no birth after ~6500 ticks")
      if child_un then
        local ust = storage.unit_state[child_un]
        ctx.check("the child was never given a job",
          ust == nil or ust.job == "child" or ust.state == "child",
          ust and ("job=" .. tostring(ust.job) .. " state=" .. tostring(ust.state)) or "no work state")
        ctx.check("the child counts toward occupancy", colony.live_colonists(c) == 3, colony.live_colonists(c))
      end
      -- Cheat the child's birthday into the past: one evaluation later it must have grown up.
      if storage.age and storage.age[child_un] then
        storage.age[child_un].born = game.tick - breeding.CHILD_TICKS - 1
      end
      ctx.after(400, function()
        local rec = storage.age and storage.age[child_un]
        ctx.check("the child grew into an adult", rec and rec.stage == "adult", rec and rec.stage or "no record")
        local ust = storage.unit_state[child_un]
        ctx.check("the grown colonist joined the workforce",
          ust == nil or ust.job ~= "child", ust and ("job=" .. tostring(ust.job)) or "unassigned")
        ctx.finish()
      end)
    end)
  end,
})
