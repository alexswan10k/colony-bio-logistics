-- Vulcanus integration (#70): pure rules only. The adapter reads the colonist's own surface and the live
-- Habitat Dome registry; everything decisive about heat exposure and the disease lives in the models.
local vulcanus = require("scripts.model.vulcanus")
local illness = require("scripts.model.illness")
local planet = require("scripts.planet")

describe("Vulcanus planet guard (#70)", function()
  it("recognises Vulcanus by planet association or a script-created surface name", function()
    eq(planet.is_vulcanus({planet = {name = "vulcanus"}}), true)
    eq(planet.is_vulcanus({name = "vulcanus"}), true)
    eq(planet.is_vulcanus({planet = {name = "vulcanus"}, name = "s25-vulcanus"}), true)
  end)

  it("is nil-safe and does not confuse other worlds or platforms with Vulcanus", function()
    eq(planet.is_vulcanus(nil), false)
    eq(planet.is_vulcanus({}), false)
    eq(planet.is_vulcanus({name = "nauvis"}), false)
    eq(planet.is_vulcanus({planet = {name = "gleba"}, name = "gleba"}), false)
    eq(planet.is_vulcanus({planet = {name = "fulgora"}, name = "fulgora"}), false)
    eq(planet.is_vulcanus({name = "platform-1", platform = {}}), false)  -- platform surfaces have no planet
    eq(planet.is_vulcanus({planet = {name = "vulcanus"}, name = "platform-1"}), true) -- planet wins over name
  end)

  it("stays hostile-world territory, so a Town Hall is still refused and a dome may found", function()
    local s = {planet = {name = "vulcanus"}, name = "vulcanus"}
    eq(planet.is_hostile(s), true)
    eq(planet.is_exotic(s), true)
    eq(planet.may_found(s, "colony-town-hall"), false)
    eq(planet.may_found(s, "colony-habitat-dome"), true)
  end)
end)

describe("Vulcanus heat rules (#70)", function()
  it("a dome's conditioned air is safe and the open air saturates", function()
    eq(vulcanus.exposure(0), 0)
    eq(vulcanus.exposure(vulcanus.DOME_SAFE), 0)
    eq(vulcanus.exposure(-2), 0)
    eq(vulcanus.exposure(nil), 1)                            -- no dome anywhere: full exposure
    eq(vulcanus.exposure(vulcanus.DOME_SAFE + 1), 1 / vulcanus.HEAT_SCALE)
    eq(vulcanus.exposure(vulcanus.DOME_SAFE + vulcanus.HEAT_SCALE), 1)
    eq(vulcanus.exposure(vulcanus.DOME_SAFE + vulcanus.HEAT_SCALE * 4), 1)
    near(vulcanus.exposure(vulcanus.DOME_SAFE + vulcanus.HEAT_SCALE / 2), 0.5, 1e-12)
  end)

  it("heat stroke uses the Vulcanus rates and is fatal if untreated", function()
    eq(illness.HEAT_RATE, vulcanus.HEAT_RATE)
    eq(illness.DISEASES.heat_stroke.fatal_after, vulcanus.FATAL_AFTER)
    eq(illness.catches("heat_stroke", 1, vulcanus.HEAT_RATE - 0.001), true)
    eq(illness.catches("heat_stroke", 1, vulcanus.HEAT_RATE + 0.001), false)
    eq(illness.catches("heat_stroke", vulcanus.exposure(vulcanus.DOME_SAFE), 0.999), false)
    local rec = {kind = "heat_stroke", age = 0}
    for _ = 1, vulcanus.FATAL_AFTER - 1 do eq(illness.step(rec), nil) end
    eq(illness.step(rec), "dies")
  end)

  it("pollution and spores still have their own independent rates", function()
    eq(illness.catches("lung", 1, illness.LUNG_RATE - 0.001), true)
    eq(illness.catches("swamp_fever", 1, illness.SWAMP_RATE - 0.001), true)
    eq(illness.catches("unknown_kind", 1, 0.999), false)
  end)
end)
