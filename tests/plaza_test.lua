-- Scenic Plaza (#48 slice B): a free, flat scenic-score bonus inside the hall's sample radius.
-- Everything here is pure; the adapter counts plazes and adds the term after desirability's sum.
local plaza = require("scripts.model.plaza")
local advice = require("scripts.model.advice")

describe("plaza (scenic score, #48 slice B)", function()
  it("carries the agreed step and cap", function()
    near(plaza.STEP, 0.2, 1e-12)
    near(plaza.CAP, 0.4, 1e-12)
  end)

  it("in_radius uses squared distance and includes the boundary", function()
    local centre = {x = 0, y = 0}
    eq(plaza.in_radius({x = 0, y = 0}, centre, 40), true)
    eq(plaza.in_radius({x = 40, y = 0}, centre, 40), true)      -- exactly 40
    eq(plaza.in_radius({x = 0, y = -40}, centre, 40), true)
    eq(plaza.in_radius({x = 40.001, y = 0}, centre, 40), false) -- just past it
    eq(plaza.in_radius({x = 30, y = 30}, centre, 40), false)    -- diagonal 42.4 > 40
    eq(plaza.in_radius({x = 24, y = 24}, centre, 40), true)     -- diagonal 33.9 < 40
  end)

  it("in_radius is nil-safe", function()
    local centre, pos = {x = 0, y = 0}, {x = 1, y = 1}
    eq(plaza.in_radius(nil, centre, 40), false)
    eq(plaza.in_radius(pos, nil, 40), false)
    eq(plaza.in_radius(pos, centre, nil), false)
    eq(plaza.in_radius(nil, nil, nil), false)
  end)

  it("bonus is STEP per plaza until CAP, then flat; no rounding", function()
    near(plaza.bonus(0), 0, 1e-12)
    near(plaza.bonus(1), 0.2, 1e-12)
    near(plaza.bonus(2), 0.4, 1e-12)
    near(plaza.bonus(10), 0.4, 1e-12)
    near(plaza.bonus(nil), 0, 1e-12)
    near(plaza.bonus(-3), 0, 1e-12)
  end)

  it("the advice report is a single plaza-scenic key carrying count and bonus", function()
    local none = advice.plaza{count = 0, bonus = 0}
    eq(none.level, "amber")
    eq(none.key, "plaza-scenic")
    eq(#none.args, 2); eq(none.args[1], 0); near(none.args[2], 0, 1e-12)
    local some = advice.plaza{count = 2, bonus = plaza.bonus(2)}
    eq(some.level, "green")
    eq(some.key, "plaza-scenic")
    eq(#some.args, 2); eq(some.args[1], 2); near(some.args[2], 0.4, 1e-12)
    eq(advice.plaza{}.level, "amber")   -- nil-safe defaults
  end)
end)
