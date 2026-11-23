-- Swamp Fever and spore exposure (#70): pure rules. The adapter checks the surface and calls
-- surface.pollute(pos, gleba.SPORE_PER_HARVEST); the catch roll and exposure scale live here.
local gleba = require("scripts.model.gleba")
local illness = require("scripts.model.illness")

describe("spore exposure (#70)", function()
  it("carries the agreed spores per harvest and full-exposure scale", function()
    eq(gleba.SPORE_PER_HARVEST, 15)   -- wiki: one yumako harvest yields 15 spores
    eq(gleba.SPORE_SCALE, 300)        -- named SCALE: the formula actually saturates at 150
  end)

  it("recognises only the raw Gleba inputs the Smokehouse can cure", function()
    for _, r in ipairs(gleba.RAW) do eq(gleba.is_raw(r.item), true) end
    eq(gleba.is_raw("yumako"), true)
    eq(gleba.is_raw("jelly"), true)
    eq(gleba.is_raw("colony-gleba-jam"), false)   -- the product is not a spore source
    eq(gleba.is_raw("colony-salt"), false)
    eq(gleba.is_raw("colony-meat"), false)
    eq(gleba.is_raw(nil), false)
  end)

  it("exposure starts at 0.5, rises linearly and clamps at 1", function()
    eq(gleba.exposure(0), 0.5)
    eq(gleba.exposure(300), 1)
    eq(gleba.exposure(600), 1)
    eq(gleba.exposure(299), 1)   -- already saturated well before SPORE_SCALE (at 150)
    eq(gleba.exposure(-5), 0.5)
    eq(gleba.exposure(nil), 0.5)
  end)

  it("exposure is a plain float below the clamp, with no rounding", function()
    near(gleba.exposure(75), 0.5 + 75 / gleba.SPORE_SCALE, 1e-12)
    near(gleba.exposure(100), 0.5 + 100 / gleba.SPORE_SCALE, 1e-12)
    near(gleba.exposure(149), 0.5 + 149 / gleba.SPORE_SCALE, 1e-12)
  end)

  it("only chop and forage harvests kick up spores", function()
    eq(gleba.emits_spores("chop"), true)
    eq(gleba.emits_spores("forage"), true)
    eq(gleba.emits_spores("mine"), false)
    eq(gleba.emits_spores("farm"), false)
    eq(gleba.emits_spores("forest"), false)
    eq(gleba.emits_spores("hunt"), false)
    eq(gleba.emits_spores("fish"), false)
    eq(gleba.emits_spores("build"), false)
    eq(gleba.emits_spores(nil), false)
  end)

  it("baseline spore exposure already carries the fever risk", function()
    -- exposure(0) == 0.5, so the effective catch chance is SWAMP_RATE / 2 == 0.02.
    eq(illness.catches("swamp_fever", gleba.exposure(0), 0.019), true)
    eq(illness.catches("swamp_fever", gleba.exposure(0), 0.021), false)
    eq(illness.catches("swamp_fever", gleba.exposure(300), 0.039), true)
    eq(illness.catches("swamp_fever", gleba.exposure(300), 0.041), false)
  end)
end)
