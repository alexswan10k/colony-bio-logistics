-- M1 blueprint spike (#36): does colony state survive a blueprint, a copy-paste and a revive?
-- Run: TICKS=400 scripts/headless-spike.sh m1_blueprint
-- The rule maths is covered by tests/model_test.lua; what only the engine can answer is whether per-entity
-- blueprint tags come back as `ev.tags`/`ghost.tags` and whether a revived ghost is ours to register again.
local core = require("scripts.spike.core")
local colony_mod = require("scripts.colony")
local crates = require("scripts.model.crates")
local tags = require("scripts.model.tags")

core.register("m1_blueprint", {
  issue = 36, auto = true, desc = "opt-in flag + crate filters survive blueprint/copy/revive", usage = "",
  run = function(ctx)
    local s, p = ctx.surface, ctx.position
    ctx.flat_area(80, "grass-1")
    local function build(name, pos)
      return s.create_entity{name = name, position = pos, force = "player", raise_built = true}
    end
    local hall = build("colony-town-hall", {p.x, p.y})
    ctx.check("hall built", hall and hall.valid)
    local colony
    for _, c in pairs(storage.colonies) do colony = c end
    if not (colony and hall) then return ctx.finish() end

    -- Two entities the colony serves, each with settings that exist only in our registry.
    local furnace = build("stone-furnace", {p.x + 6, p.y})
    local crate = build("colony-demand-crate", {p.x + 10, p.y})
    local plain = build("stone-furnace", {p.x + 6, p.y + 6})
    ctx.check("furnace + crate + plain furnace built", furnace and crate and plain)
    if not (furnace and crate and plain) then return ctx.finish() end

    local m = colony_mod.set_machine(colony, furnace, true)
    m.collect = false
    m.requests = {{item = "iron-ore", count = 20}, nil, {item = "coal", count = 5}}
    local c = colony.crates[crate.unit_number]
    crates.set_filter(c.filters, 1, "stone")
    crates.set_count(c.filters, 1, 120)

    -- ---------- encode ----------
    local machine_dict = colony_mod.entity_tags(furnace)
    local crate_dict = colony_mod.entity_tags(crate)
    ctx.check("an opted-in machine has tags", machine_dict and machine_dict[tags.TAG] ~= nil)
    ctx.check("a demand crate has tags", crate_dict and crate_dict[tags.TAG] ~= nil)
    ctx.check("an unserved machine has no tags", colony_mod.entity_tags(plain) == nil)

    -- ---------- blueprint write ----------
    local inv = game.create_inventory(2)
    local stack = inv[1]
    stack.set_stack{name = "blueprint"}
    local area = {{p.x + 4, p.y - 2}, {p.x + 12, p.y + 2}}
    ctx.probe("create_blueprint over the furnace + crate", function()
      return stack.create_blueprint{surface = s, force = "player", area = area}
    end)
    local ents = stack.get_blueprint_entities() or {}
    local index_of, seen = {}, {}
    for _, e in ipairs(ents) do index_of[e.name] = e.entity_number; seen[e.name] = true end
    ctx.check("blueprint contains both entities", seen["stone-furnace"] and seen["colony-demand-crate"],
      #ents .. " entities")

    -- A foreign tag must survive our write: another mod may be using the same blueprint entity.
    stack.set_blueprint_entity_tag(index_of["stone-furnace"], "someone-else", "keep me")
    local tagged = colony_mod.tag_blueprint(stack, {[index_of["stone-furnace"]] = furnace,
      [index_of["colony-demand-crate"]] = crate})
    ctx.check("tag_blueprint tagged both entities", tagged == 2, tagged)
    local ftags = stack.get_blueprint_entity_tags(index_of["stone-furnace"]) or {}
    local ctags = stack.get_blueprint_entity_tags(index_of["colony-demand-crate"]) or {}
    ctx.check("machine tags are in the blueprint", ftags[tags.TAG] ~= nil and ftags[tags.TAG].machine == true)
    ctx.check("crate tags are in the blueprint", ctags[tags.TAG] ~= nil and ctags[tags.TAG].crate == true)
    ctx.check("a foreign tag was not clobbered", ftags["someone-else"] == "keep me", ftags["someone-else"])

    -- ---------- build the blueprint somewhere else ----------
    local at = {x = p.x + 10, y = p.y + 20}
    ctx.probe("build_blueprint", function()
      return stack.build_blueprint{surface = s, force = "player", position = at, build_mode = defines.build_mode.forced,
        raise_built = true}
    end)
    local ghosts = s.find_entities_filtered{area = {{at.x - 2, at.y - 2}, {at.x + 12, at.y + 6}},
      type = "entity-ghost"}
    local ghost_of = {}
    for _, g in ipairs(ghosts) do ghost_of[g.ghost_name] = g end
    ctx.check("blueprint became ghosts", ghost_of["stone-furnace"] ~= nil and ghost_of["colony-demand-crate"] ~= nil,
      #ghosts .. " ghosts")
    local mg, cg = ghost_of["stone-furnace"], ghost_of["colony-demand-crate"]
    if not (mg and cg) then return ctx.finish() end
    ctx.check("the machine ghost carries the tags", mg.tags and mg.tags[tags.TAG] and mg.tags[tags.TAG].machine == true)
    ctx.check("the crate ghost carries the tags", cg.tags and cg.tags[tags.TAG] and cg.tags[tags.TAG].crate == true)

    -- ---------- revive (what the colony builder does) ----------
    -- `revive` returns (collided items, entity, proxy): the entity is the second value, not the first.
    local ok_f, new_furnace = ctx.probe("revive the machine ghost",
      function() return select(2, mg.revive{raise_revive = true}) end)
    local ok_c, new_crate = ctx.probe("revive the crate ghost",
      function() return select(2, cg.revive{raise_revive = true}) end)
    ctx.check("ghosts revived", ok_f and ok_c and new_furnace and new_furnace.valid and new_crate
      and new_crate.valid)
    if not (new_furnace and new_crate) then return ctx.finish() end
    local nm = colony.machines[new_furnace.unit_number]
    ctx.check("the rebuilt machine is opted in", nm ~= nil and nm.enabled == true)
    ctx.check("collect = false survived", nm ~= nil and nm.collect == false)
    ctx.check("supply rows survived", nm ~= nil and nm.requests[1] and nm.requests[1].item == "iron-ore"
      and nm.requests[1].count == 20 and nm.requests[3] and nm.requests[3].item == "coal"
      and nm.requests[3].count == 5, nm and nm.requests[3] and nm.requests[3].item or "missing")
    local nc = colony.crates[new_crate.unit_number]
    ctx.check("crate filters survived", nc and nc.filters[1] and nc.filters[1].item == "stone"
      and nc.filters[1].count == 120, nc and nc.filters[1] and nc.filters[1].item or "missing")

    -- ---------- copy-paste ----------
    -- The engine only raises on_entity_settings_pasted when the copy is done "as" a player, and a headless
    -- server starts with none, so make one - otherwise the event wiring would go untested.
    local pidx = ctx.player and ctx.player.index
    if not pidx then
      local ok, pl = pcall(function() return game.create_player{name = "spike"} end)
      pidx = ok and pl and pl.index or nil
    end
    ctx.log(pidx and ("copying as player " .. pidx) or "headless: no player, driving the handler directly")
    local a = build("stone-furnace", {p.x - 6, p.y + 6})
    local b = build("stone-furnace", {p.x - 6, p.y + 12})
    ctx.check("copy source + destination built", a ~= nil and b ~= nil)
    if not (a and b) then return ctx.finish() end
    local _, ma = ctx.probe("opt in the copy source", function() return colony_mod.set_machine(colony, a, true) end)
    ma.collect, ma.requests = false, {{item = "coal", count = 9}}
    -- copy_settings takes positional arguments (`takes_table = false` in the API): copy_settings(source).
    ctx.probe("copy_settings b <- a", function()
      if pidx then return b.copy_settings(a, pidx) end
      return colony_mod.copy_settings(a, b)      -- no player: drive the handler directly
    end)
    local mb = colony.machines[b.unit_number]
    ctx.check("copy-paste opts the destination in", mb ~= nil and mb.enabled == true)
    ctx.check("copy-paste carries collect + rows", mb ~= nil and mb.collect == false and mb.requests[1]
      and mb.requests[1].item == "coal" and mb.requests[1].count == 9,
      mb and mb.requests[1] and mb.requests[1].item or "missing")

    local d = build("stone-furnace", {p.x - 12, p.y + 6})
    local plain2 = build("stone-furnace", {p.x - 12, p.y + 12})
    ctx.check("clear-test furnaces built", d ~= nil and plain2 ~= nil)
    if not (d and plain2) then return ctx.finish() end
    colony_mod.set_machine(colony, d, true)
    ctx.probe("copy_settings d <- plain2", function()
      if pidx then return d.copy_settings(plain2, pidx) end
      return colony_mod.copy_settings(plain2, d)
    end)
    local md = colony.machines[d.unit_number]
    ctx.check("copying a plain machine turns the destination off", md and md.enabled == false,
      md and tostring(md.enabled) or "missing")

    local e = build("colony-demand-crate", {p.x - 6, p.y + 18})
    local f = build("colony-demand-crate", {p.x - 12, p.y + 18})
    ctx.check("crate copy pair built", e ~= nil and f ~= nil)
    if not (e and f) then return ctx.finish() end
    local ce, cf = colony.crates[e.unit_number], colony.crates[f.unit_number]
    crates.set_filter(ce.filters, 2, "wood"); crates.set_count(ce.filters, 2, 33)
    ctx.probe("copy_settings f <- e", function()
      if pidx then return f.copy_settings(e, pidx) end
      return colony_mod.copy_settings(e, f)
    end)
    ctx.check("copy-paste carries crate filters", cf.filters[2] and cf.filters[2].item == "wood"
      and cf.filters[2].count == 33, cf.filters[2] and cf.filters[2].item or "missing")

    ctx.check("the two machines do not share a row table", mb and mb.requests ~= ma.requests)
    ctx.finish()
  end,
})
