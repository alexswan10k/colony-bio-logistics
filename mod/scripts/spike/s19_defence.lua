-- SPIKE Stage 0 (M3 defence stack): engine facts for militia / armour / damage / patrols.
-- /spike run s19_defence
-- No gameplay behaviour, no new prototypes, no schema. Every fact is asserted on the exact 2.1 binary the
-- game runs, mirroring s18_command. Module-local S is deliberately not save-safe (dev-only spike state).
--
-- Questions this closes (see PLAN.md Stage 0):
--  1. Does a colonist (small-biter-derived `unit`) expose attack_parameters / ai_settings / distraction_cooldown,
--     and does `ai_settings.allow_destroy_when_commands_fail` read back false from the live entity?
--  2. Is `is_military_target` true yet NOT writable at runtime (=> a distinct militia prototype is required)?
--  3. `LuaEntity:damage(amount, force, type?, source?, cause?)`: return value, on_entity_died `ev.cause`,
--     resistances applied inside damage(), and destructible=false as a no-op.
--  4. Do units have `character_armor` / `character_guns` inventories? (biggest Stage 1 risk)
--  5. Can equipment grids carry quality at all (item-side), and does removal return ItemWithQualityCount?
--  6. `attack_area + by_enemy` at a live nest, no `attack_move`, and survival of repeated failed paths.
--  7. Cost of damage() x N and one attack_area dispatch.
local core = require("scripts.spike.core")
local events = require("scripts.events")

local S   -- module-local spike state; not save-safe on purpose (dev-only)

-- Load-time handlers: they see both real events and the damage() calls synthesised here.
events.on(defines.events.on_entity_died, function(ev)
  if not (S and S.victim_un) then return end
  local e = ev.entity
  if not (e and e.valid) or e.unit_number ~= S.victim_un then return end
  S.died = {
    valid = true,
    cause_un = ev.cause and ev.cause.valid and ev.cause.unit_number or nil,
    cause_name = ev.cause and ev.cause.valid and ev.cause.name or nil,
    force = ev.force and ev.force.name or nil,
    damage_type = ev.damage_type and ev.damage_type.name or nil,
  }
end)

events.on(defines.events.on_entity_damaged, function(ev)
  if not (S and S.wall_un) then return end
  local e = ev.entity
  if not (e and e.valid) or e.unit_number ~= S.wall_un then return end
  S.damaged_n = (S.damaged_n or 0) + 1
  S.last_damaged = {
    amount = ev.original_damage_amount or ev.final_damage_amount or nil,
    damage_type = ev.damage_type and ev.damage_type.name or nil,
    cause_name = ev.cause and ev.cause.valid and ev.cause.name or nil,
  }
end)

events.on(defines.events.on_ai_command_completed, function(ev)
  if not S then return end
  local un = ev.unit_number
  if not un or not S.units[un] then return end
  local rec = S.units[un]
  rec.completions = rec.completions + 1
  rec.last = {result = tostring(ev.result), distracted = tostring(ev.was_distracted), tick = ev.tick}
end)

local function pos(e)
  if not (e and e.valid) then return "gone" end
  return string.format("%.2f,%.2f", e.position.x, e.position.y)
end

local function inv_of(e, idx)
  local ok, inv = pcall(function() return e.get_inventory(idx) end)
  return ok, inv
end

core.register("s19_defence", {
  issue = "55/56/57", auto = false,
  desc = "Stage 0 M3 defence engine facts: damage/cause/resistances, is_military_target, ai_settings readback, units have no armour inventory, grid+quality, attack_area/distraction",
  usage = "",
  run = function(ctx)
    local s, p, f = ctx.surface, ctx.position, game.forces.player
    ctx.flat_area(40, "grass-1")
    S = {units = {}, damaged_n = 0, died = nil}

    local function spawn(dx, dy, name)
      local e = s.create_entity{name = name or "colony-colonist",
        position = {x = p.x + dx, y = p.y + dy}, force = f}
      if e and e.valid then
        S.units[e.unit_number] = {entity = e, completions = 0, last = nil}
      end
      return e
    end

    local unit = spawn(-10, 0)   -- the live colonist we interrogate
    ctx.check("[proto] colony-colonist spawned as a unit", unit and unit.valid and unit.type == "unit",
      unit and (unit.type .. "/" .. unit.name) or "none")

    -- ---------------------------------------------------------------- proto
    local proto = prototypes.entity["colony-colonist"]
    ctx.check("[proto] colony-colonist prototype loads", proto ~= nil)
    ctx.probe("[proto] prototype attack_parameters / distraction_cooldown / vision_distance", function()
      if not proto then return "no prototype" end
      local ap = proto.attack_parameters
      return "attack_parameters=" .. (ap and ("range=" .. tostring(ap.range)) or "nil")
        .. " distraction_cooldown=" .. tostring(proto.distraction_cooldown)
        .. " vision_distance=" .. tostring(proto.vision_distance)
    end)
    ctx.probe("[proto] prototype ai_settings fields (UnitAISettings)", function()
      if not proto then return "no prototype" end
      local a = proto.ai_settings
      if type(a) ~= "table" then return "ai_settings not exposed at runtime: " .. tostring(a) end
      return "destroy_when_commands_fail=" .. tostring(a.destroy_when_commands_fail)
        .. " allow_try_return_to_spawner=" .. tostring(a.allow_try_return_to_spawner)
        .. " do_separation=" .. tostring(a.do_separation)
    end)
    ctx.probe("[proto] allow_run_time_change_of_is_military_target", function()
      return tostring(proto and proto.allow_run_time_change_of_is_military_target)
    end)

    -- ------------------------------------------------- ai_settings readback
    local ais = unit and unit.valid and unit.ai_settings or nil
    ctx.check("[engine] ai_settings is readable on a live unit", ais ~= nil and ais.valid ~= false)
    ctx.check("[engine] ai_settings.allow_destroy_when_commands_fail reads back false",
      ais ~= nil and ais.allow_destroy_when_commands_fail == false,
      "allow_destroy_when_commands_fail=" .. tostring(ais and ais.allow_destroy_when_commands_fail))
    ctx.probe("[engine] ai_settings has NO destroy_when_commands_fail field (name differs from prototype)", function()
      local ok, val = pcall(function() return ais and ais.destroy_when_commands_fail end)
      return ok and ("read " .. tostring(val)) or ("access rejected: " .. tostring(val))
    end)
    ctx.probe("[engine] ai_settings other fields", function()
      if not ais then return "none" end
      return "allow_try_return_to_spawner=" .. tostring(ais.allow_try_return_to_spawner)
        .. " do_separation=" .. tostring(ais.do_separation)
        .. " join_attacks=" .. tostring(ais.join_attacks)
        .. " path_resolution_modifier=" .. tostring(ais.path_resolution_modifier)
        .. " size_in_group=" .. tostring(ais.size_in_group)
    end)
    -- The runtime struct is RW: prove we can flip it (this is what a militia prototype would set in data).
    ctx.probe("[engine] ai_settings.allow_destroy_when_commands_fail is writable at runtime", function()
      if not ais then return "no ai_settings" end
      local old = ais.allow_destroy_when_commands_fail
      local ok, err = pcall(function() ais.allow_destroy_when_commands_fail = true end)
      local now = ais.allow_destroy_when_commands_fail
      ais.allow_destroy_when_commands_fail = old   -- restore before any patrol probes
      return (ok and "write ok" or ("rejected: " .. tostring(err))) .. " (was " .. tostring(old) .. " now " .. tostring(now) .. ")"
    end)

    -- ------------------------------------------- is_military_target (write)
    if unit and unit.valid then
      ctx.probe("[engine] is_military_target value on colonist", function() return tostring(unit.is_military_target) end)
      ctx.check("[engine] colonist is_military_target == true (inherited from small-biter)",
        unit.is_military_target == true, tostring(unit.is_military_target))
      local ok, err = pcall(function() unit.is_military_target = false end)
      ctx.check("[engine] is_military_target is NOT writable at runtime (distinct prototype required)",
        not ok, ok and "write unexpectedly succeeded" or ("rejected: " .. tostring(err)))
      ctx.check("[engine] is_military_target unchanged after the rejected write", unit.is_military_target == true,
        tostring(unit.is_military_target))
    else
      ctx.check("[engine] colonist available for is_military_target probe", false)
    end

    -- -------------------------------------------------- damage: non-lethal
    local wall = s.create_entity{name = "stone-wall", position = {x = p.x - 14, y = p.y}, force = f}
    ctx.check("[engine] stone-wall target spawned", wall and wall.valid)
    if wall and wall.valid then
      S.wall_un = wall.unit_number
      local wall_proto = prototypes.entity["stone-wall"]
      local phys
      if wall_proto then
        local ok, rs = pcall(function() return wall_proto.resistances end)
        if ok and type(rs) == "table" then
          for _, rr in ipairs(rs) do if rr.type == "physical" then phys = rr break end end
        end
      end
      ctx.probe("[engine] stone-wall physical resistance from prototype", function()
        if not phys then return "none exposed" end
        return "decrease=" .. tostring(phys.decrease) .. " percent=" .. tostring(phys.percent)
      end)
      local hp0, dealt = wall.health, nil
      local okD, ret = pcall(function() return wall.damage(50, f, "physical", nil, nil) end)
      if okD then dealt = ret end
      local hp1 = wall.health
      ctx.check("[engine] damage() returned a float (actual damage applied after resistances)",
        okD and type(dealt) == "number", okD and ("dealt=" .. tostring(dealt)) or ("ERR " .. tostring(ret)))
      ctx.check("[engine] damage() reduced health by exactly the returned amount",
        type(dealt) == "number" and math.abs(dealt - (hp0 - hp1)) < 0.001,
        string.format("%.3f -> %.3f (lost %.3f, returned %s)", hp0, hp1, hp0 - hp1, tostring(dealt)))
      -- Prototype `resistances` is not exposed at runtime (probe above), but the *behaviour* is decisive:
      -- 50 raw physical became 37.6 health lost. The engine applied the wall's resistance inside damage(),
      -- so a pure damage model must NOT subtract resistances a second time.
      ctx.check("[engine] resistances applied inside damage() when type is supplied (dealt < raw 50)",
        type(dealt) == "number" and dealt < 50,
        "raw=50 dealt=" .. tostring(dealt) .. " phys_proto_exposed=" .. tostring(phys ~= nil))
      ctx.probe("[engine] on_entity_damaged fired for the typed hit", function()
        return "n=" .. tostring(S.damaged_n) .. " last=" .. tostring(S.last_damaged and S.last_damaged.damage_type)
      end)
    end

    -- ------------------------------------------- damage: destructible=false
    local dwall = s.create_entity{name = "stone-wall", position = {x = p.x - 11, y = p.y}, force = f}
    if dwall and dwall.valid then
      dwall.destructible = false
      local h0 = dwall.health
      local ok, ret = pcall(function() return dwall.damage(50, "enemy", "physical") end)
      ctx.check("[engine] damage to destructible=false is a no-op", dwall.valid and dwall.health == h0,
        "hp " .. tostring(h0) .. " -> " .. tostring(dwall.valid and dwall.health) .. " ret=" .. tostring(ret))
    else
      ctx.check("[engine] destructible=false wall spawned", false)
    end

    -- ----------------------------------------------- damage: lethal + cause
    local victim = s.create_entity{name = "stone-wall", position = {x = p.x - 8, y = p.y}, force = f}
    local cause  = s.create_entity{name = "small-biter", position = {x = p.x - 6, y = p.y + 1}, force = "enemy"}
    local source = s.create_entity{name = "small-biter", position = {x = p.x - 7, y = p.y + 1}, force = "enemy"}
    if victim and victim.valid and cause and cause.valid and source and source.valid then
      S.victim_un = victim.unit_number
      S.cause_un = cause.unit_number
      S.source_un = source.unit_number
      local ok, ret = pcall(function() return victim.damage(10000, "enemy", "physical", source, cause) end)
      ctx.probe("[engine] lethal damage() return", function() return tostring(ret) .. (ok and "" or " (ERR)") end)
    else
      ctx.check("[engine] lethal-damage actors spawned", false)
    end

    -- ------------------------------------------------- armour / grid slots
    ctx.probe("[engine] defines.inventory.character_armor / character_guns constants", function()
      return "armor=" .. tostring(defines.inventory.character_armor) .. " guns=" .. tostring(defines.inventory.character_guns)
    end)
    if unit and unit.valid then
      local okA, invA = inv_of(unit, defines.inventory.character_armor)
      local okG, invG = inv_of(unit, defines.inventory.character_guns)
      ctx.check("[engine] unit has NO character_armor inventory", okA and invA == nil,
        okA and tostring(invA) or ("ERR " .. tostring(invA)))
      ctx.check("[engine] unit has NO character_guns inventory", okG and invG == nil,
        okG and tostring(invG) or ("ERR " .. tostring(invG)))
      ctx.probe("[engine] unit .grid (direct equipment grid on the entity)", function()
        local ok, g = pcall(function() return unit.grid end)
        return ok and tostring(g) or ("ERR " .. tostring(g))
      end)
      local okR = pcall(function() return unit.resistances end)
      ctx.check("[engine] no per-unit resistances field on a unit (mitigation must be scripted)", not okR)
      ctx.probe("[engine] unit .resistances access result", function()
        local ok, r = pcall(function() return unit.resistances end)
        return ok and tostring(r) or ("rejected: " .. tostring(r))
      end)
    end
    -- Contrast: a real character does have character_armor (so the missing inventory is a unit property).
    local ch = s.create_entity{name = "character", position = {x = p.x - 10, y = p.y + 3}, force = f}
    if ch and ch.valid then
      local okC, invC = inv_of(ch, defines.inventory.character_armor)
      ctx.check("[engine] a character DOES have character_armor inventory (contrast with unit)",
        okC and invC ~= nil, okC and tostring(invC) or ("ERR " .. tostring(invC)))
    end

    -- ---------------------------------------------------- grid + quality
    local chest = s.create_entity{name = "wooden-chest", position = {x = p.x - 4, y = p.y - 4}, force = f}
    if chest and chest.valid then
      local inv = chest.get_inventory(defines.inventory.chest)
      local n = inv and inv.insert{name = "power-armor", count = 1} or 0
      local stack = (inv and n > 0) and inv[1] or nil
      local grid = stack and stack.grid or nil
      ctx.check("[engine] a power-armor item stack exposes an equipment grid", grid ~= nil,
        "inserted=" .. tostring(n) .. " grid=" .. tostring(grid))
      if grid then
        ctx.probe("[engine] uncommon quality prototype exists", function()
          return tostring(prototypes.quality["uncommon"] ~= nil)
        end)
        local eq = grid.put{name = "energy-shield-equipment", quality = "uncommon", position = {x = 0, y = 0}}
        ctx.check("[engine] grid:put{name, quality='uncommon'} succeeded", eq ~= nil, tostring(eq))
        if eq then
          ctx.probe("[engine] LuaEquipment.quality.name", function() return tostring(eq.quality and eq.quality.name) end)
          ctx.check("[engine] equipment quality is 'uncommon'", eq.quality and eq.quality.name == "uncommon",
            tostring(eq.quality and eq.quality.name))
          ctx.probe("[engine] grid shield / max_shield", function()
            return tostring(grid.shield) .. "/" .. tostring(grid.max_shield)
          end)
          ctx.check("[engine] grid.max_shield > 0 for a shield module", grid.max_shield > 0,
            tostring(grid.max_shield))
          ctx.probe("[engine] grid.get_contents() shape", function()
            local c = grid.get_contents()
            local first = c[1]
            local keys = {}
            if type(first) == "table" then
              for k in pairs(first) do keys[#keys + 1] = tostring(k) end
              table.sort(keys)
            end
            return tostring(#c) .. " entries; first=" .. tostring(first and first.name)
              .. " keys={" .. table.concat(keys, ",") .. "}"
          end)
          local taken = grid.take{equipment = eq}
          ctx.check("[engine] grid:take returns an ItemWithQualityCount", type(taken) == "table"
            and taken.name == "energy-shield-equipment", tostring(taken and taken.name))
          ctx.probe("[engine] ItemWithQualityCount (take) keys + quality", function()
            if type(taken) ~= "table" then return "not a table" end
            local keys = {}
            for k in pairs(taken) do keys[#keys + 1] = tostring(k) end
            table.sort(keys)
            return "count=" .. tostring(taken.count) .. " keys={" .. table.concat(keys, ",")
              .. "} quality_raw=" .. tostring(taken.quality) .. " quality_type=" .. type(taken.quality)
          end)
        end
      end
    else
      ctx.check("[engine] chest for grid/quality probe spawned", false)
    end

    -- ------------------------------------------- command / distraction / AI
    ctx.check("[engine] no defines.command.attack_move (use attack_area)", defines.command.attack_move == nil,
      "attack_move=" .. tostring(defines.command.attack_move) .. " attack_area=" .. tostring(defines.command.attack_area))
    ctx.check("[engine] defines.distraction.by_enemy exists", defines.distraction.by_enemy ~= nil)

    local nest = s.create_entity{name = "biter-spawner", position = {x = p.x + 22, y = p.y}, force = "enemy"}
    local ebiter = s.create_entity{name = "small-biter", position = {x = p.x + 20, y = p.y + 2}, force = "enemy"}
    local fighter = spawn(18, 0)
    if fighter and fighter.valid then
      fighter.commandable.set_command{type = defines.command.attack_area,
        destination = {x = p.x + 22, y = p.y}, radius = 8, distraction = defines.distraction.by_enemy}
      ctx.probe("[engine] attack_area issued at live nest", function()
        local c = fighter.commandable.command
        return "type=" .. tostring(c and c.type) .. " nest=" .. (nest and nest.valid and "alive" or "dead")
      end)
    end

    -- Repeated failed paths into a water pool. destroy_when_commands_fail=false must keep the unit alive.
    local wt = {}
    for x = p.x + 28, p.x + 32 do
      for y = p.y + 24, p.y + 28 do wt[#wt + 1] = {name = "water", position = {x, y}} end
    end
    s.set_tiles(wt)
    local stubborn = spawn(28, 22)
    local fpath = function()
      if stubborn and stubborn.valid then
        stubborn.commandable.set_command{type = defines.command.go_to_location,
          destination = {x = p.x + 30, y = p.y + 26}, radius = 0.5,
          distraction = defines.distraction.none}
      end
    end
    fpath()
    for _, t in ipairs({60, 120, 180, 240}) do ctx.after(t, fpath) end

    -- Contrast probe: a biter WITH allow_destroy_when_commands_fail=true may be deleted on failed paths.
    local doomed = s.create_entity{name = "small-biter", position = {x = p.x + 28, y = p.y + 20}, force = "enemy"}
    if doomed and doomed.valid then
      local okSet = pcall(function() doomed.ai_settings.allow_destroy_when_commands_fail = true end)
      ctx.probe("[engine] biter allow_destroy_when_commands_fail=true writable", function()
        return tostring(okSet) .. " -> " .. tostring(doomed.ai_settings.allow_destroy_when_commands_fail)
      end)
      ctx.after(30, function()
        if doomed and doomed.valid then
          doomed.commandable.set_command{type = defines.command.go_to_location,
            destination = {x = p.x + 30, y = p.y + 26}, radius = 0.5, distraction = defines.distraction.none}
        end
      end)
      S.doomed = doomed
    end

    -- --------------------------------------------------------------- cost
    local cost_target = s.create_entity{name = "stone-wall", position = {x = p.x - 14, y = p.y + 2}, force = f}
    if cost_target and cost_target.valid then
      ctx.profile("[cost] damage() x 200 (health reset each call)", function()
        for _ = 1, 200 do
          cost_target.health = cost_target.max_health
          cost_target.damage(1, f, "physical")
        end
      end, 20)
    end
    if fighter and fighter.valid then
      ctx.profile("[cost] one attack_area dispatch", function()
        fighter.commandable.set_command{type = defines.command.attack_area,
          destination = {x = p.x + 22, y = p.y}, radius = 8, distraction = defines.distraction.by_enemy}
      end, 20)
    end

    -- ----------------------------------------------------- deferred checks
    ctx.after(90, function()
      local d = S.died
      ctx.check("[engine] lethal damage() raised on_entity_died", d ~= nil and d.valid == true)
      ctx.check("[engine] on_entity_died ev.cause is the damage() cause entity",
        d and d.cause_un == S.cause_un,
        "cause_un=" .. tostring(d and d.cause_un) .. " expected=" .. tostring(S.cause_un)
          .. " name=" .. tostring(d and d.cause_name))
      ctx.probe("[engine] on_entity_died ev.force / ev.damage_type (mortality.lua inputs)", function()
        return "force=" .. tostring(d and d.force) .. " damage_type=" .. tostring(d and d.damage_type)
      end)
    end)

    ctx.after(900, function()
      ctx.check("[engine] destroy_when_commands_fail=false unit survived repeated failed paths",
        stubborn and stubborn.valid, pos(stubborn))
      if fighter and fighter.valid then
        local r = S.units[fighter.unit_number]
        ctx.log("[engine] attack_area: at=" .. pos(fighter) .. " completions=" .. r.completions
          .. " last=" .. tostring(r.last and r.last.result) .. " distracted=" .. tostring(r.last and r.last.distracted)
          .. " nest=" .. (nest and nest.valid and "alive" or "dead")
          .. " biter=" .. (ebiter and ebiter.valid and "alive" or "dead"))
        ctx.check("[engine] attack_area did not destroy the militia-to-be", fighter.valid, pos(fighter))
      end
      if S.doomed then
        ctx.log("[engine] biter with allow_destroy_when_commands_fail=true survived=" .. tostring(S.doomed.valid))
      end
      ctx.log("[engine] ai_settings readback on stubborn: allow_destroy_when_commands_fail="
        .. tostring(stubborn and stubborn.valid and stubborn.ai_settings.allow_destroy_when_commands_fail))
      ctx.finish()
    end)
  end,
})
