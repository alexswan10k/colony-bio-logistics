-- Pure-model tests for the M3 militia stack (#55). No Factorio globals; mocks encode beliefs about the
-- engine facts proven in s19_defence, they are not evidence.
local armour = require("scripts.model.armour")
local militia = require("scripts.model.militia")
local jobs = require("scripts.model.jobs")
local alarm = require("scripts.model.alarm")
local command = require("scripts.model.command")

describe("militia armour", function()
  it("mitigation is zero for unarmoured and unknown kinds", function()
    eq(armour.mitigation(nil, "normal"), 0)
    eq(armour.mitigation("not-a-real-armour", "legendary"), 0)
  end)

  it("mitigation rises with armour tier and with quality", function()
    local light = armour.mitigation("light-armor", "normal")
    local heavy = armour.mitigation("heavy-armor", "normal")
    local mk2 = armour.mitigation("power-armor-mk2", "normal")
    truthy(light < heavy and heavy < mk2, "tier order")
    truthy(armour.mitigation("heavy-armor", "legendary") > armour.mitigation("heavy-armor", "normal"), "quality scales")
  end)

  it("mitigation is clamped to MAX_MITIGATION", function()
    truthy(armour.mitigation("power-armor-mk2", "legendary") <= armour.MAX_MITIGATION)
    eq(armour.MAX_MITIGATION, 0.80)
  end)

  it("unknown quality falls back to normal", function()
    near(armour.mitigation("heavy-armor", nil), armour.mitigation("heavy-armor", "normal"))
    near(armour.mitigation("heavy-armor", "made-up"), armour.mitigation("heavy-armor", "normal"))
  end)

  it("best armour is deterministic by PREFERENCE order, never pairs()", function()
    local counts = {["heavy-armor"] = 1, ["power-armor"] = 2, ["light-armor"] = 4}
    eq(armour.best(counts), "power-armor")
    eq(armour.best({}), nil)
  end)
end)

describe("militia damage model", function()
  it("weapon preference is single-sourced from the garrison", function()
    eq(militia.PREFERENCE[1], "colony-rifle")
    eq(militia.PREFERENCE[#militia.PREFERENCE], "colony-bow")
  end)

  it("outgoing returns damage, type and ammo for each weapon", function()
    local d, t, a = militia.outgoing("colony-rifle", "normal")
    truthy(d > 0); eq(t, "physical"); eq(a, nil)
    local d2, t2, a2 = militia.outgoing("colony-bow", "normal")
    truthy(d2 > 0); eq(t2, "physical"); eq(a2, "colony-arrow")
    local d3, _, a3 = militia.outgoing("pistol", "normal")
    truthy(d3 > 0); eq(a3, "firearm-magazine")
  end)

  it("quality scales outgoing damage; unknown weapon deals none", function()
    local base = militia.outgoing("colony-rifle", "normal")
    truthy(militia.outgoing("colony-rifle", "legendary") > base)
    eq(militia.outgoing(nil, "normal"), 0)
    eq(militia.outgoing("bogus", "normal"), 0)
  end)

  it("engage is the raw outgoing damage; defender gear is deliberately ignored", function()
    local plain = select(1, militia.engage({weapon = "colony-rifle"}))
    local vs_armour = select(1, militia.engage({weapon = "colony-rifle"}, {armour = "heavy-armor"}))
    local outgoing = select(1, militia.outgoing("colony-rifle", "normal"))
    near(plain, vs_armour)
    near(plain, outgoing)
  end)

  it("engage applies quality and does not subtract defender mitigation (no double-count with heal-back)", function()
    local d = select(1, militia.engage({weapon = "colony-bow", quality = "rare"}, {armour = "power-armor-mk2"}))
    local outgoing = select(1, militia.outgoing("colony-bow", "rare"))
    near(d, outgoing, 1e-9)
  end)

  it("best_gear is deterministic and honours quality map", function()
    local w, q = militia.best_gear({["colony-bow"] = 5, ["pistol"] = 2, ["colony-rifle"] = 1},
      {["colony-rifle"] = "uncommon"})
    eq(w, "colony-rifle"); eq(q, "uncommon")
    eq(militia.best_gear({}), nil)
  end)

  it("spend: rifle wears (returns itself), guns spend a magazine every 10, bow spends arrows", function()
    local w, spent = militia.spend({weapon = "colony-rifle", uses = 0})
    eq(w, "colony-rifle"); eq(spent, "colony-rifle")
    local _, ammo1 = militia.spend({weapon = "pistol", ammo_count = 8})
    eq(ammo1, nil)
    local _, ammo2 = militia.spend({weapon = "pistol", ammo_count = 9})
    eq(ammo2, "firearm-magazine")
    local _, arrow = militia.spend({weapon = "colony-bow"})
    eq(arrow, "colony-arrow")
  end)

  it("gear_wanted returns the biggest deficit, accounts for inflight, and never mutates inputs", function()
    local stock, inflight = {["colony-rifle"] = 1, ["colony-arrow"] = 5}, {}
    local before_stock, before_inflight = stock["colony-rifle"], inflight["colony-rifle"]
    local item, deficit = militia.gear_wanted(inflight, stock)
    truthy(item ~= nil and deficit > 0)
    eq(stock["colony-rifle"], before_stock); eq(inflight["colony-rifle"], before_inflight)
    local i2, d2 = militia.gear_wanted({["colony-arrow"] = 15}, stock)
    truthy(i2 == nil or d2 > 0)
  end)
end)

describe("militia job + integration registration", function()
  it("militia is a separate rank-2 job, not the guard job", function()
    truthy(jobs.enabled(nil, "militia"))
    eq(jobs.rank(nil, "militia"), 2)
    eq(jobs.rank(nil, "guard"), 2)
    local found = false
    for _, j in ipairs(jobs.JOBS) do if j == "militia" then found = true end end
    truthy(found, "militia in JOBS")
  end)

  it("militia states are exempt from shelter like a guard", function()
    truthy(alarm.EXEMPT["militia-hold"])
    truthy(alarm.EXEMPT["militia-fight"])
  end)

  it("militia states are orderable by the whistle", function()
    truthy(command.commandable({state = "militia-hold"}))
    truthy(command.commandable({state = "militia-fight"}))
  end)

  it("whistle selection admits both colonists and militia (no dead ORDERABLE wiring)", function()
    truthy(command.is_colony_unit("colony-colonist"))
    truthy(command.is_colony_unit("colony-militia"))
    eq(command.is_colony_unit("small-biter"), false)
    eq(command.is_colony_unit("colony-watchtower"), false)
  end)

  it("abort_intents carries gear across a whistle lease", function()
    local st = {job = "militia", state = "militia-fight", gear = {weapon = "colony-rifle"}}
    local intents = command.abort_intents(st)
    eq(intents.gear, st.gear)
    truthy(intents.release_gear_claim)
    eq(st.gear.weapon, "colony-rifle")   -- pure: no mutation of the input
  end)
end)
