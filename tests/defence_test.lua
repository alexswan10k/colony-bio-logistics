-- Pure-model tests for M3 Stage 2: the shared structural aura and the Armory's gear depot rules.
-- No Factorio globals; every input is a plain table and must come back unchanged.
local defence = require("scripts.model.defence")
local armour = require("scripts.model.armour")

describe("defence aura", function()
  it("aura scales with manning and is clamped", function()
    eq(defence.aura(0), 0)
    eq(defence.aura(nil), 0)
    eq(defence.aura(1), defence.PER_MILITIA)
    eq(defence.aura(4), 4 * defence.PER_MILITIA)
    eq(defence.aura(100), defence.MAX_REDUCTION)
    truthy(defence.MAX_REDUCTION <= 1, "reduction stays a fraction")
  end)

  it("an unarmed post grants nothing", function()
    eq(defence.aura(-3), 0)
    local posts = {{position = {x = 0, y = 0}, manning = 0, key = 1}}
    eq(defence.coverage({x = 0, y = 0}, posts), 0)
    eq(defence.covered({x = 0, y = 0}, posts), false)
  end)

  it("coverage uses the nearest covering post, not the strongest", function()
    local posts = {
      {position = {x = 0, y = 0}, strength = 0.1, key = 10},
      {position = {x = 5, y = 0}, strength = 0.4, key = 20},
    }
    near(defence.coverage({x = 4.9, y = 0}, posts), 0.4)
    near(defence.coverage({x = 0.1, y = 0}, posts), 0.1)
  end)

  it("ties break deterministically by key", function()
    local a = {position = {x = 0, y = 0}, strength = 0.1, key = "b"}
    local b = {position = {x = 2, y = 0}, strength = 0.4, key = "a"}
    near(defence.coverage({x = 1, y = 0}, {a, b}), 0.4)
    near(defence.coverage({x = 1, y = 0}, {b, a}), 0.4)
  end)

  it("points outside every radius are uncovered", function()
    local posts = {{position = {x = 0, y = 0}, strength = 0.5, key = 1}}
    eq(defence.covered({x = defence.RADIUS + 1, y = 0}, posts), false)
    eq(defence.covered(nil, posts), false)
    eq(defence.covered({x = 0, y = 0}, {}), false)
    eq(defence.coverage({x = 1, y = 1}, nil), 0)
  end)

  it("apply_incoming never amplifies or heals damage", function()
    near(defence.apply_incoming(100, 0.25), 75)
    near(defence.apply_incoming(100, 1), 0)
    near(defence.apply_incoming(100, 2), 0)
    near(defence.apply_incoming(100, -1), 100)
    near(defence.apply_incoming(0, 0.5), 0)
  end)
end)

describe("cross-planet endgame armour (#69)", function()
  it("siege plating is the strongest quality-scaled mitigation, still clamped", function()
    near(armour.mitigation(armour.SIEGE, "normal"), 0.55)
    near(armour.mitigation(armour.SIEGE, "rare"), 0.55 * 1.3)
    near(armour.mitigation(armour.SIEGE, "legendary"), armour.MAX_MITIGATION)
    eq(armour.best({[armour.SIEGE] = 1, ["power-armor-mk2"] = 1}), armour.SIEGE)
  end)

  it("a shield never uses percentage mitigation", function()
    truthy(armour.is_shield(armour.SHIELD))
    eq(armour.is_shield(armour.SIEGE), false)
    eq(armour.mitigation(armour.SHIELD, "legendary"), 0)
  end)

  it("a shield absorbs only what its finite pool holds, then recharges", function()
    local a, left = armour.shield_drain(armour.SHIELD_CAPACITY, 20)
    eq(a, 20); eq(left, 40)
    local b, empty = armour.shield_drain(40, 100)
    eq(b, 40); eq(empty, 0)
    local c, none = armour.shield_drain(0, 10)
    eq(c, 0); eq(none, 0)
    near(armour.shield_recharge(0, 100), 10)
    eq(armour.shield_recharge(59, 1000), armour.SHIELD_CAPACITY)
  end)

  it("an Armory asks for endgame armour only when it is unlocked", function()
    local base = armour.armory_targets(2)
    eq(#base, 4)
    local raw = {}
    for _, row in ipairs(base) do raw[#raw + 1] = row.item end
    local unlocked = {[armour.SIEGE] = true, [armour.SHIELD] = true}
    local more = armour.armory_targets(2, unlocked)
    eq(#more, 6)
    eq(more[5].item, armour.SIEGE); eq(more[5].count, 2)
    eq(more[6].item, armour.SHIELD)
    eq(#armour.armory_targets(0, unlocked), 0)
  end)
end)

describe("armory gear stock rules", function()
  it("targets scale with manning, and a limit of 0 wants nothing", function()
    eq(#armour.armory_targets(0), 0)
    for _, row in ipairs(armour.armory_targets(2)) do truthy(row.count > 0, row.item .. " target") end
    eq(armour.armory_targets(2)[1].count, 2)
    eq(armour.armory_targets(2)[3].count, 20)
  end)

  it("draw_gear hands out only what exists, in want order, without mutation", function()
    local counts = {["colony-rifle"] = 1, ["firearm-magazine"] = 5}
    local wants = {{item = "colony-rifle", count = 2}, {item = "heavy-armor", count = 1},
      {item = "firearm-magazine", count = 3}}
    local grants = armour.draw_gear(counts, wants)
    eq(#grants, 2)
    eq(grants[1].item, "colony-rifle"); eq(grants[1].count, 1)
    eq(grants[2].item, "firearm-magazine"); eq(grants[2].count, 3)
    eq(counts["colony-rifle"], 1); eq(counts["firearm-magazine"], 5)
    eq(wants[1].count, 2)
  end)

  it("draw_gear handles empty/duplicate wants deterministically", function()
    eq(#armour.draw_gear(nil, nil), 0)
    local grants = armour.draw_gear({["colony-arrow"] = 5}, {{item = "colony-arrow", count = 3},
      {item = "colony-arrow", count = 3}})
    eq(#grants, 2)
    eq(grants[1].count, 3); eq(grants[2].count, 2)
  end)

  it("restock_deficit counts inflight and never mutates inputs", function()
    local counts, inflight = {["colony-rifle"] = 1}, {["colony-rifle"] = 1}
    local targets = {{item = "colony-rifle", count = 3}, {item = "heavy-armor", count = 1}}
    local demands = armour.restock_deficit(counts, targets, inflight)
    eq(#demands, 2)
    eq(demands[1].count, 1)
    eq(demands[2].count, 1)
    eq(counts["colony-rifle"], 1); eq(inflight["colony-rifle"], 1)
    eq(targets[1].count, 3)
  end)

  it("restock_deficit emits nothing when stocked or with no targets", function()
    eq(#armour.restock_deficit({["colony-rifle"] = 3}, {{item = "colony-rifle", count = 3}}, nil), 0)
    eq(#armour.restock_deficit({}, nil, nil), 0)
  end)
end)
