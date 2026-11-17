-- M2 Gleba food spike (#70): the feature, after s17_gleba pinned the engine facts.
-- Run: TICKS=19500 scripts/headless-spike.sh m2_gleba
--
-- Proves the whole opt-in path end to end with real colonists and real work spells, including the two gates
-- the review required:
--   * NEGATIVE tech case: a town with Food Preservation but WITHOUT Gleba Cuisine makes no jam at all,
--     even with a Smokehouse stuffed with fruit + salt; after research the same town makes jam.
--   * FRESHNESS case: a Smokehouse holding only near-spoiled fruit closes its slots / reports missing inputs
--     (it must not turn 99.9%-spoiled yumako into fresh jam), and fresh fruit reopens it.
-- The production verdict uses the colony's own production flow (#89), which only rises on a real work spell.
local core = require("scripts.spike.core")
local colony = require("scripts.colony")
local territory = require("scripts.territory")
local labour = require("scripts.model.labour")
local housing = require("scripts.model.housing")
local gleba = require("scripts.model.gleba")
local tech_mod = require("scripts.tech")
local stats = require("scripts.stats")
local work = require("scripts.work")

core.register("m2_gleba", {
  issue = 70, auto = true,
  desc = "Gleba food: tech gate blocks production before research, over-ripe fruit is refused, jam made after",
  usage = "",
  run = function(ctx)
    local s, p = ctx.surface, ctx.position
    ctx.flat_area(120, "grass-1")
    s.always_day, s.freeze_daytime, s.daytime = true, true, 0
    local function build(name, pos)
      return s.create_entity{name = name, position = pos, force = "player", raise_built = true}
    end
    local function jam_flow(f)
      local st = stats.stats(f, s)
      return st and st.get_input_count("colony-gleba-jam") or 0
    end

    -- ---------- prototypes and gate ----------
    ctx.check("jam item and all four recipes exist",
      prototypes.item["colony-gleba-jam"] ~= nil and
      prototypes.recipe["colony-gleba-jam-yumako"] ~= nil and
      prototypes.recipe["colony-gleba-jam-jellynut"] ~= nil and
      prototypes.recipe["colony-gleba-jam-mash"] ~= nil and
      prototypes.recipe["colony-gleba-jam-jelly"] ~= nil)
    ctx.check("raw Gleba fruit is not on a house's menu", (function()
      local menu = {}
      for _, opt in ipairs(housing.FOOD) do menu[opt.item] = true end
      for _, r in ipairs(gleba.RAW) do if menu[r.item] then return false end end
      return menu["colony-gleba-jam"] == true
    end)())
    ctx.check("smokehouse keeps every raw Gleba input", (function()
      local keep = labour.HUTS["colony-smokehouse"].keep or {}
      local set = {}
      for _, item in ipairs(keep) do set[item] = true end
      for _, r in ipairs(gleba.RAW) do if not set[r.item] then return false end end
      return true
    end)())

    local f = game.forces.player
    local ftech = f.technologies[gleba.TECH]
    ctx.check("gleba cuisine needs food preservation and vanilla Gleba processing",
      ftech and ftech.prerequisites["colony-food-preservation"] ~= nil and
      ftech.prerequisites["yumako"] ~= nil and ftech.prerequisites["jellynut"] ~= nil)
    ctx.check("gleba cuisine starts unresearched but enabled",
      ftech and ftech.researched == false and ftech.enabled == true)
    ctx.check("the jam recipes start locked", f.recipes["colony-gleba-jam-yumako"].enabled == false)
    -- Deliberately do NOT research here: the negative production case needs the colony to run ungated.

    -- ---------- the colony ----------
    local hall = build("colony-town-hall", {p.x, p.y})
    ctx.check("hall built", hall and hall.valid)
    storage.interval_override = 600
    local c = storage.colonies[territory.owner_at(s.index, p)]
    local tent = build("colony-housing-tent", {p.x + 6, p.y})
    ctx.check("tent registered", tent and tent.valid)
    local smoke = build("colony-smokehouse", {p.x - 6, p.y + 4})
    ctx.check("smokehouse built", smoke and smoke.valid)

    -- A complete pantry so nobody starves during the 19500-tick run (there is no farm or hunter here).
    if hall and hall.valid then
      hall.insert{name = "colony-preserved-meat", count = 200}
      hall.insert{name = "colony-salt", count = 20}
    end
    if smoke and smoke.valid then
      smoke.insert{name = "yumako", count = 48}
      smoke.insert{name = "colony-salt", count = 24}
    end
    for _ = 1, 6 do colony.spawn_colonist(c) end
    local hut = c and smoke and c.huts[smoke.unit_number]

    -- ---------- phase 1: tech is still unresearched ----------
    ctx.after(3000, function()
      ctx.check("smokehouse registered as a hut", hut ~= nil)
      local before = jam_flow(f)
      ctx.check("Gleba Cuisine unresearched: no colony jam is produced", before == 0,
        "jam production flow=" .. tostring(before))

      -- Research now; the same town and the same stock must become productive.
      ftech.researched = true
      tech_mod.sync_force(f)
      ctx.check("researching gleba cuisine unlocks all four jam recipes",
        f.recipes["colony-gleba-jam-yumako"].enabled == true and
        f.recipes["colony-gleba-jam-jellynut"].enabled == true and
        f.recipes["colony-gleba-jam-mash"].enabled == true and
        f.recipes["colony-gleba-jam-jelly"].enabled == true)

      -- Freshness gate: reading the real stacks, not just their counts, is what closes over-ripe huts.
      ctx.check("fresh fruit keeps the smokehouse's slots open", hut ~= nil and
        work.hut_inputs_missing(c, hut) == false)
      local inv = smoke.get_inventory(defines.inventory.chest)
      for i = 1, #inv do
        local st = inv[i]
        if st.valid_for_read and st.name == "yumako" then st.spoil_tick = game.tick + 600 end
      end
      ctx.check("over-ripe fruit still exists as yumako (not yet spoilage)",
        inv.get_item_count("yumako") > 0, "yumako=" .. tostring(inv.get_item_count("yumako")))
      ctx.check("over-ripe fruit closes the smokehouse's slots", hut ~= nil and
        work.hut_inputs_missing(c, hut) == true)
      for i = 1, #inv do
        local st = inv[i]
        if st.valid_for_read and st.name == "yumako" then st.spoil_percent = 0 end
      end
      ctx.check("reviving the fruit reopens the smokehouse", hut ~= nil and
        work.hut_inputs_missing(c, hut) == false)

      -- ---------- phase 2: now gated on and stocked with fresh fruit ----------
      ctx.after(12000, function()
        local after = jam_flow(f)
        ctx.check("Gleba Cuisine researched: the smokehouse makes jam", after >= 1,
          "jam production flow=" .. tostring(after))
        ctx.finish()
      end)
    end)
  end,
})
