-- M2 cold chain spike (#45): the late-food tier - canning, cold storage, and the rails that carry it.
-- The engine facts (spoil_percent read/write, a downward write revives a stack; extending spoil_tick is
-- forbidden; the refrigerated wagon inventory is reachable) are answered by s15_spoil; this spike is the
-- feature: crates registered as refrigerators, the cold pass reviving near-spoiled goods inside them, the
-- cannery converting preserved food into canned goods through real colonist work, and the tech gating it.
-- Run: TICKS=19500 scripts/headless-spike.sh m2_cold
local core = require("scripts.spike.core")
local colony = require("scripts.colony")
local territory = require("scripts.territory")
local cold = require("scripts.cold")
local labour = require("scripts.model.labour")
local tech_mod = require("scripts.tech")
local work = require("scripts.work")

core.register("m2_cold", {
  issue = 45, auto = true,
  desc = "cold chain: cannery cures preserved -> canned, refrigerators freeze spoilage, wagon cargo stays fresh",
  usage = "",
  run = function(ctx)
    local s, p = ctx.surface, ctx.position
    ctx.flat_area(120, "grass-1")
    s.always_day, s.freeze_daytime, s.daytime = true, true, 0
    local function build(name, pos)
      return s.create_entity{name = name, position = pos, force = "player", raise_built = true}
    end

    -- ---------- prototypes ----------
    ctx.check("colony-cannery is an item and a building",
      prototypes.entity["colony-cannery"] ~= nil and prototypes.item["colony-cannery"] ~= nil)
    ctx.check("colony-refrigerated-warehouse is an item and a building",
      prototypes.entity["colony-refrigerated-warehouse"] ~= nil and prototypes.item["colony-refrigerated-warehouse"] ~= nil)
    ctx.check("colony-refrigerated-wagon is an item and a cargo wagon",
      prototypes.entity["colony-refrigerated-wagon"] ~= nil and prototypes.item["colony-refrigerated-wagon"] ~= nil
        and prototypes.entity["colony-refrigerated-wagon"].type == "cargo-wagon")
    ctx.check("canned goods exist with colony food stack size",
      prototypes.item["colony-canned-meat"] ~= nil and prototypes.item["colony-canned-fish"] ~= nil
        and prototypes.item["colony-canned-meat"].stack_size == 100)
    ctx.check("cannery is a labour hut on the preserve job (no tool)",
      labour.HUTS["colony-cannery"] ~= nil and labour.HUTS["colony-cannery"].job == "preserve"
        and labour.HUTS["colony-cannery"].tool == nil)

    -- The tech gates the whole tier; check prereqs and pack type on the force, like m2_ledger does.
    local f = game.forces.player
    local ftech = f.technologies["colony-cold-chain"]
    local prereqs = ftech and ftech.prerequisites or {}
    local names = {}
    for n in pairs(prereqs) do names[#names + 1] = n end
    table.sort(names)
    ctx.check("cold chain needs preserved food", prereqs["colony-food-preservation"] ~= nil, table.concat(names, ","))
    local ing = ftech and ftech.research_unit_ingredients and ftech.research_unit_ingredients[1]
    ctx.check("cold chain costs frontier packs", ing and ing.name == "colony-frontier-pack",
      ing and ing.name or "?")
    ctx.check("cold chain researches, it is not free", ftech ~= nil and ftech.researched == false and ftech.enabled == true)

    ftech.researched = true
    tech_mod.sync_force(f)
    ctx.check("researching cold chain unlocks the canning recipes",
      f.recipes["colony-canned-meat"].enabled == true and f.recipes["colony-canned-fish"].enabled == true)
    ctx.check("researching cold chain unlocks the buildings",
      f.recipes["colony-cannery"].enabled == true and f.recipes["colony-refrigerated-warehouse"].enabled == true
        and f.recipes["colony-refrigerated-wagon"].enabled == true)

    -- ---------- the colony ----------
    local hall = build("colony-town-hall", {p.x, p.y})
    ctx.check("hall built", hall and hall.valid)
    storage.interval_override = 600
    local c = storage.colonies[territory.owner_at(s.index, p)]
    local tent = build("colony-housing-tent", {p.x + 6, p.y})
    ctx.check("tent registered", tent and tent.valid)

    -- Refrigerated warehouse, placed like any colony building, registered as a crate of kind refrigerator.
    local fridge = build("colony-refrigerated-warehouse", {p.x + 12, p.y + 4})
    ctx.check("refrigerated warehouse built", fridge and fridge.valid)
    if fridge and fridge.valid and c and c.crates then
      local rec = c.crates[fridge.unit_number]
      ctx.check("refrigerated warehouse registered as a refrigerator crate",
        rec and rec.kind == "refrigerator", rec and tostring(rec.kind))
    end

    -- ---------- the cold pass ----------
    -- Seed goods that are near-spoiled, prove the pass freezes them (engine forbids extending spoil_tick,
    -- but spoil_percent write-down revives them), and prove an ordinary chest nearby keeps decaying.
    hall.insert{name = "colony-preserved-meat", count = 4}
    if fridge and fridge.valid then
      fridge.insert{name = "colony-preserved-meat", count = 2}
      local finv = fridge.get_inventory(defines.inventory.chest)
      local fstack = finv[1]
      if fstack and fstack.valid_for_read then
        fstack.spoil_tick = game.tick + 1
        ctx.check("warehouse stack is near-spoiled before the pass", fstack.spoil_percent > 0.99,
          tostring(fstack.spoil_percent))
      end
    end
    local control_chest = s.create_entity{name = "iron-chest", position = {p.x + 16, p.y + 4}, force = "player", raise_built = true}
    control_chest.insert{name = "colony-preserved-meat", count = 1}
    local cstack = control_chest.get_inventory(defines.inventory.chest)[1]
    cstack.spoil_tick = game.tick + 1
    local restamped = cold.pause_all()
    ctx.check("cold pass restamped the refrigerated stacks", restamped >= 1, tostring(restamped))
    if fridge and fridge.valid then
      local fstack = fridge.get_inventory(defines.inventory.chest)[1]
      ctx.check("warehouse stack was revived", fstack.spoil_percent == 0, tostring(fstack.spoil_percent))
    end
    ctx.check("control chest was NOT revived", cstack.spoil_percent > 0.99, tostring(cstack.spoil_percent))

    -- The wagon rides the same cold chain.
    for x = -3, 20 do
      s.create_entity{name = "straight-rail", position = {p.x + 40 + x * 2, p.y}, direction = defines.direction.east,
        force = "player", raise_built = true}
    end
    local wagon = s.create_entity{name = "colony-refrigerated-wagon", position = {p.x + 40, p.y},
      direction = defines.direction.east, force = "player", raise_built = true}
    ctx.check("refrigerated wagon placed", wagon ~= nil)
    if wagon then
      local winv = wagon.get_inventory(defines.inventory.cargo_wagon)
      winv.insert{name = "colony-preserved-fish", count = 1}
      local wstack = winv[1]
      wstack.spoil_tick = game.tick + 1
      ctx.check("wagon stack near-spoiled before the pass", wstack.spoil_percent > 0.99,
        tostring(wstack.spoil_percent))
      cold.pause_all()
      ctx.check("wagon stack was revived", wstack.spoil_percent == 0, tostring(wstack.spoil_percent))
    end

    -- ---------- the cannery pipeline ----------
    local cannery = build("colony-cannery", {p.x - 8, p.y + 8})
    ctx.check("cannery built", cannery and cannery.valid)
    if cannery and cannery.valid then
      cannery.insert{name = "colony-preserved-meat", count = 3}
      cannery.insert{name = "colony-preserved-fish", count = 3}
      cannery.insert{name = "iron-plate", count = 6}
      cannery.insert{name = "colony-water", count = 4}
    end
    -- Seed the workforce directly: migration is deliberately slow after the bootstrap window (#88), and this
    -- spike tests the cannery, not the town growth curve.
    for _ = 1, 6 do colony.spawn_colonist(c) end

    -- Defer the verdict to the end of the world tick: colonists need the whole run to haul materials,
    -- be assigned to the cannery, and carry the output back. TICKS=19500 leaves the whole path well before
    -- the benchmark ends.
    ctx.after(15000, function()
      ctx.check("cannery registered as a hut", c and c.huts[cannery.unit_number] ~= nil)
      -- Diagnostics: the colonist must arrive and the cannery must be staffed.
      -- The starvation race is real in this town (no farm, no forager, no hunt), so the verdict leans on the
      -- work loop's own counter (mirrors the Toolsmith's tools_made), not on whatever is left in storage.
      ctx.check("the cannery has canned something", work.cans_made >= 1, "cans_made=" .. tostring(work.cans_made))
      ctx.finish()
    end)
  end,
})
