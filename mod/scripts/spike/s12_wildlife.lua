-- SPIKE #79: can the colony get *real* hunting - a hunter that shoots a live animal - without the colony
-- becoming a combat faction? Docile game on its own force, killed by a commanded attack.
-- /spike run s12_wildlife
-- Headless: TICKS=1600 scripts/headless-spike.sh s12_wildlife
local core = require("scripts.spike.core")
local events = require("scripts.events")
local wildlife = require("scripts.wildlife")

core.register("s12_wildlife", {
  issue = 79, auto = true, desc = "roaming game: neutral force, commanded hunt, kill credit", usage = "",
  run = function(ctx)
    local s, p = ctx.surface, ctx.position
    ctx.flat_area(40)
    -- Capture what we need *now*: six hundred ticks later the entity is gone and reading it errors
    -- ("LuaEntity API call when LuaEntity was invalid").
    local deaths = {}
    events.on(defines.events.on_entity_died, function(ev)
      deaths[#deaths + 1] = {name = ev.entity.name,
        cause = ev.cause and ev.cause.name, cause_unit = ev.cause and ev.cause.unit_number,
        force = ev.force and ev.force.name,
        damage_type = ev.damage_type and ev.damage_type.name}
    end)

    local force, colonist, boar
    ctx.probe("wildlife.ensure_force()", function() force = wildlife.ensure_force(); return force.name end)
    ctx.check("the wildlife force exists", force ~= nil and game.forces["colony-wildlife"] ~= nil)

    -- --- a docile animal on its own force ------------------------------------------------------------
    colonist = s.create_entity{name = "colony-colonist", position = {p.x, p.y}, force = "player"}
    boar = wildlife.spawn(s, force, {p.x + 10, p.y})
    ctx.check("an animal can be spawned on the wildlife force",
      boar ~= nil and boar.valid and boar.force.name == "colony-wildlife",
      boar and boar.valid and boar.force.name)

    if boar and boar.valid then
      local alive0 = boar.health
      ctx.check("nobody is at war with the wildlife (player side)",
        game.forces.player.get_cease_fire(force) == true)
      ctx.check("nobody is at war with the wildlife (wildlife side)",
        force.get_cease_fire(game.forces.player) == true)
      wildlife.roam(boar)
      local start_pos = {x = boar.position.x, y = boar.position.y}

      -- An *uncommanded* colonist standing next to game must not start a fight: `vision_distance` 1 means
      -- colonists do not acquire targets, so the new ranged attack changes nothing about normal behaviour.
      ctx.after(240, function()
        if boar.valid then
          ctx.check("idle colonist did not auto-attack the animal", boar.health == alive0,
            boar.health .. " of " .. alive0)
        end
        ctx.check("game stays put unless told otherwise (wander keeps it near)",
          boar.valid and (boar.position.x - start_pos.x) ^ 2 + (boar.position.y - start_pos.y) ^ 2 < 40 * 40)
      end)

      -- --- the hunt: a commanded attack, from range ------------------------------------------------
      ctx.check("an animal is commandable (wander/attack/flee are available)", boar.commandable ~= nil)
      ctx.after(300, function()
        if boar.valid then
          colonist.commandable.set_command{type = defines.command.attack, target = boar,
            distraction = defines.distraction.none}
        end
      end)

      ctx.after(900, function()
        local d = math.sqrt((colonist.position.x - (boar.valid and boar.position.x or 0)) ^ 2 +
                            (colonist.position.y - (boar.valid and boar.position.y or 0)) ^ 2)
        ctx.check("the hunter killed the animal", not boar.valid, boar.valid and (boar.health .. " hp") or nil)
        ctx.check("the hunter never had to touch it (it shot from range)",
          not boar.valid or d > 2, string.format("%.1f tiles", d))
        ctx.check("the animal never fought back (cease-fire + wander survives being shot)",
          colonist.valid and colonist.health == colonist.max_health,
          colonist.valid and colonist.health .. "/" .. colonist.max_health)
        local died
        for _, ev in ipairs(deaths) do if ev.name == "colony-wild-boar" then died = ev end end
        ctx.check("on_entity_died fired for the animal", died ~= nil)
        if died then
          ctx.check("...with ev.cause = the hunter (that is how the meat is credited)",
            died.cause_unit ~= nil and died.cause_unit == colonist.unit_number, died.cause)
          ctx.log("death: force=" .. tostring(died.force) .. " cause=" .. tostring(died.cause) ..
            " damage_type=" .. tostring(died.damage_type))
        end
      end)

      -- --- roaming: does the engine move animals on its own? ---------------------------------------
      ctx.after(920, function()
        local b = wildlife.spawn(s, force, {p.x - 12, p.y})
        if not b then
          ctx.check("a second animal could be spawned", false, "no free spot")
          return
        end
        boar = b
        wildlife.roam(b)
        local pos = {x = b.position.x, y = b.position.y}
        ctx.after(500, function()
          if not b.valid then
            ctx.check("the roaming animal survived (nothing shoots it)", false, "died while roaming")
            return
          end
          local moved = math.sqrt((b.position.x - pos.x) ^ 2 + (b.position.y - pos.y) ^ 2)
          ctx.check("wander actually moves the animal", moved > 0.5, string.format("%.2f tiles", moved))
          ctx.check("and nothing attacks it while it roams (no aggro from the wildlife force)",
            b.health == b.max_health, b.health .. "/" .. b.max_health)
          ctx.finish()
        end)
      end)
    else
      ctx.finish()
    end
  end,
})
