-- M2 Gleba food spike (#70): the feature, after s17_gleba pinned the engine facts.
-- Run: TICKS=19500 scripts/headless-spike.sh m2_gleba
--
-- Proves the whole opt-in path end to end with real colonists and real work spells: a hall + tent +
-- Smokehouse town, the Gleba Cuisine tech gating the four jam recipes, fruit and salt stocked in the hut,
-- a Smokehouse worker converting them into jam, and the resulting production flow visible in the vanilla
-- statistics (Lua inserts are otherwise invisible there, #89). Freshness laundering is already ruled out
-- by the s17 probe; this spike only checks the *colony* path.
local core = require("scripts.spike.core")
local colony = require("scripts.colony")
local territory = require("scripts.territory")
local labour = require("scripts.model.labour")
local housing = require("scripts.model.housing")
local gleba = require("scripts.model.gleba")
local tech_mod = require("scripts.tech")
local stats = require("scripts.stats")

core.register("m2_gleba", {
  issue = 70, auto = true,
  desc = "Gleba food: tech gates jam recipes, Smokehouse cures fruit into edible jam, flow is counted",
  usage = "",
  run = function(ctx)
    local s, p = ctx.surface, ctx.position
    ctx.flat_area(120, "grass-1")
    s.always_day, s.freeze_daytime, s.daytime = true, true, 0
    local function build(name, pos)
      return s.create_entity{name = name, position = pos, force = "player", raise_built = true}
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
    local ftech = f.technologies["colony-gleba-cuisine"]
    ctx.check("gleba cuisine needs food preservation and vanilla Gleba processing",
      ftech and ftech.prerequisites["colony-food-preservation"] ~= nil and
      ftech.prerequisites["yumako"] ~= nil and ftech.prerequisites["jellynut"] ~= nil)
    ctx.check("gleba cuisine costs frontier packs, it is not free",
      ftech and ftech.researched == false and ftech.enabled == true)
    ftech.researched = true
    tech_mod.sync_force(f)
    ctx.check("researching gleba cuisine unlocks all four jam recipes",
      f.recipes["colony-gleba-jam-yumako"].enabled == true and
      f.recipes["colony-gleba-jam-jellynut"].enabled == true and
      f.recipes["colony-gleba-jam-mash"].enabled == true and
      f.recipes["colony-gleba-jam-jelly"].enabled == true)

    -- ---------- the colony ----------
    local hall = build("colony-town-hall", {p.x, p.y})
    ctx.check("hall built", hall and hall.valid)
    storage.interval_override = 600
    local c = storage.colonies[territory.owner_at(s.index, p)]
    local tent = build("colony-housing-tent", {p.x + 6, p.y})
    ctx.check("tent registered", tent and tent.valid)
    local smoke = build("colony-smokehouse", {p.x - 6, p.y + 4})
    ctx.check("smokehouse built", smoke and smoke.valid)

    -- Stock enough for dozens of spells; a colonist-only start has no forager and no salt pan, so this spike
    -- tests the preserving chain, not upstream supply. Salt is also stocked in the hall so haulers can top up.
    if smoke and smoke.valid then
      for _, r in ipairs(gleba.RAW) do smoke.insert{name = r.item, count = 24} end
      smoke.insert{name = "colony-salt", count = 24}
    end
    if hall and hall.valid then hall.insert{name = "colony-salt", count = 20} end
    for _ = 1, 6 do colony.spawn_colonist(c) end

    -- ---------- deferred verdict ----------
    ctx.after(15000, function()
      ctx.check("smokehouse registered as a hut", c and smoke and c.huts[smoke.unit_number] ~= nil)
      -- The colony records its own Lua-driven production in the vanilla statistics (#89); a positive input
      -- flow for jam proves a real colonist work spell created it (and nothing else in this town can).
      local st = stats.stats(f, s)
      local made = st and st.get_input_count("colony-gleba-jam") or 0
      ctx.check("the smokehouse made jam", made >= 1, "jam production flow=" .. tostring(made))
      ctx.finish()
    end)
  end,
})
