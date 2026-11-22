-- Theatre (#48 slice B): short-range, worker-free Inspired quality 1.5. Everything here is pure;
-- the adapter owns entities and hands in plain positions and occupant counts.
local theatre = require("scripts.model.theatre")
local inspiration = require("scripts.model.inspiration")
local advice = require("scripts.model.advice")

describe("theatre (Inspired quality 1.5, #48 slice B)", function()
  it("carries the agreed radius and the shared quality constant", function()
    eq(theatre.RADIUS, 16)
    eq(theatre.QUALITY, 1.5)
    eq(theatre.QUALITY, inspiration.THEATRE)   -- no drift from the research/work rule
    eq(theatre.QUALITY, inspiration.QUALITY.theatre)
    -- The 1.25 (Tavern) work-tick case is pinned in inspiration_test.lua; the Theatre case is new.
    eq(inspiration.work_ticks(480, 1.5), 320)
  end)

  it("no theatres means nobody is served and coverage is zero", function()
    local served, coverage = theatre.serve({}, {{position = {x = 0, y = 0}, occupants = 5}})
    eq(next(served), nil)
    near(coverage, 0, 1e-12)
    local served2, coverage2 = theatre.serve(nil, {{position = {x = 0, y = 0}, occupants = 5}})
    eq(next(served2), nil)
    near(coverage2, 0, 1e-12)
  end)

  it("serves a house inside the radius, not one outside, and weighs coverage by residents", function()
    local houses = {
      {position = {x = 0, y = 0}, occupants = 3},    -- 10 tiles from the theatre: inside
      {position = {x = 30, y = 0}, occupants = 2},   -- 20 tiles away: outside (Tavern would reach it)
    }
    local served, coverage = theatre.serve({{position = {x = 10, y = 0}}}, houses)
    eq(served[1], true)
    eq(served[2], nil)
    near(coverage, 3 / 5, 1e-12)
  end)

  it("includes the radius boundary with <=, using squared distance", function()
    local houses = {
      {position = {x = 0, y = 0}, occupants = 1},       -- exactly 16 from the theatre: served
      {position = {x = 32.001, y = 0}, occupants = 1},  -- 16.001 away: just past it, not served
      {position = {x = 0, y = 16}, occupants = 1},      -- 22.6 away on the diagonal: not served
    }
    local served, coverage = theatre.serve({{position = {x = 16, y = 0}}}, houses)
    eq(served[1], true)
    eq(served[2], nil)
    eq(served[3], nil)                 -- 0,16 is 22.6 tiles from (16,0): not served
    near(coverage, 1 / 3, 1e-12)
  end)

  it("any theatre in range is enough; multiple houses and multiple theatres", function()
    local theatres = {{position = {x = 100, y = 100}}, {position = {x = -10, y = -10}}}
    local houses = {
      {position = {x = 0, y = 0}, occupants = 1},        -- near the second
      {position = {x = 110, y = 100}, occupants = 2},    -- near the first
      {position = {x = 0, y = 50}, occupants = 1},       -- near neither
    }
    local served, coverage = theatre.serve(theatres, houses)
    eq(served[1], true)
    eq(served[2], true)
    eq(served[3], nil)
    near(coverage, 3 / 4, 1e-12)
  end)

  it("an empty house is never served and is not in the coverage denominator", function()
    local houses = {
      {position = {x = 0, y = 0}, occupants = 0},   -- empty, right next to the theatre
      {position = {x = 0, y = 0}, occupants = 4},
    }
    local served, coverage = theatre.serve({{position = {x = 0, y = 0}}}, houses)
    eq(served[1], nil)
    eq(served[2], true)
    near(coverage, 1, 1e-12)
    -- A town of only empty houses has no residents, so no divide-by-zero and a zero coverage.
    local served2, coverage2 = theatre.serve({{position = {x = 0, y = 0}}},
      {{position = {x = 0, y = 0}, occupants = 0}})
    eq(next(served2), nil)
    near(coverage2, 0, 1e-12)
  end)

  it("is deterministic: served indices and coverage are a pure function of the arrays", function()
    local theatres = {{position = {x = 1, y = 2}}, {position = {x = -5, y = 5}}}
    local houses = {
      {position = {x = 2, y = 2}, occupants = 3},
      {position = {x = 30, y = 0}, occupants = 1},
      {position = {x = -5, y = 10}, occupants = 2},
    }
    local a, ca = theatre.serve(theatres, houses)
    local b, cb = theatre.serve(theatres, houses)
    near(ca, cb, 0)
    for i = 1, #houses do eq(a[i] and true or nil, b[i] and true or nil) end
  end)

  it("the advice report mirrors a Tavern's shape without the ale state", function()
    local idle = advice.theatre{}
    eq(idle.level, "amber")
    eq(idle.key, "theatre-idle")
    eq(#idle.args, 2); eq(idle.args[1], 0); eq(idle.args[2], 0)
    local serving = advice.theatre{houses = 2, inspired = 9}
    eq(serving.level, "green")
    eq(serving.key, "theatre-serving")
    eq(#serving.args, 2); eq(serving.args[1], 2); eq(serving.args[2], 9)
  end)
end)
