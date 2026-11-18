-- Pure tourism rules (#51). These are the anti-exploit predicates the headless spike exercises through the
-- real engine; here they are pinned offline so a change to the payout rule cannot pass unnoticed.
local t = require("scripts.model.tourism")
local tr = require("scripts.model.transit")
local des = require("scripts.model.desirability")

describe("tourism (#51)", function()
  it("rejects a self-host and a missing host at departure", function()
    eq(t.host_ok(1, 2), true)
    eq(t.host_ok(1, 1), false)
    eq(t.host_ok(1, nil), false)
    eq(t.host_ok(nil, 2), false)
  end)

  it("sends at most one new tourist per evaluation, less those waiting", function()
    eq(t.departures(5, 2, 0, t.MAX_SEND_PER_EVAL), 1)
    eq(t.departures(5, 2, 1, t.MAX_SEND_PER_EVAL), 0)
    eq(t.departures(0, 2, 0, 1), 0)
    eq(t.departures(5, 0, 0, 1), 0)
    eq(t.departures(5, -2, 0, 1), 0)
  end)

  it("counts only free Spa places after visitors, riders and waiters", function()
    eq(t.host_capacity(1, 0, 0, 0), t.SPA_CAPACITY)
    eq(t.host_capacity(1, 1, 0, 1), 0)
    eq(t.host_capacity(2, 2, 1, 0), 1)
    eq(t.host_capacity(0, 0, 0, 0), 0)
  end)

  it("counts every tourist away from a home exactly once", function()
    eq(t.away_count(1, 2, 1), 4)
    eq(t.away_count(nil, nil, nil), 0)
  end)

  it("ends a visit at its expiry or at nightfall", function()
    eq(t.visit_over(5999, 6000, false), false)
    eq(t.visit_over(6000, 6000, false), true)
    eq(t.visit_over(1, 6000, true), true)
  end)

  it("pays only for a visited return group alighting at its own, different home", function()
    local good = {kind = "tourist_return", home = 1, host = 2, from = 2, visited = true, n = 2}
    eq(t.earns_insight(good, 1), true)
    eq(t.earns_insight(good, 2), false)                       -- alighting at the host
    eq(t.earns_insight(good, 3), false)                       -- a third colony on the line
    local self_host = {kind = "tourist_return", home = 1, host = 1, visited = true, n = 1}
    eq(t.earns_insight(self_host, 1), false)
    local unvisited = {kind = "tourist_return", home = 1, host = 2, visited = false, n = 1}
    eq(t.earns_insight(unvisited, 1), false)
    local outbound = {kind = "tourist", home = 1, host = 2, visited = nil, n = 1}
    eq(t.earns_insight(outbound, 1), false)
    eq(t.earns_insight(outbound, 2), false)
    eq(t.earns_insight(nil, 1), false)
    eq(t.earns_insight({kind = "commute", home = 1, n = 1}, 1), false)
  end)

  it("credits every rider of each genuine return batch, even two batches in one tick", function()
    local b1 = {kind = "tourist_return", home = 1, host = 2, visited = true, n = 2}
    local b2 = {kind = "tourist_return", home = 1, host = 2, visited = true, n = 1}
    eq(t.credited(b1, 1), 2)
    eq(t.credited(b2, 1), 1)
    eq(t.credited(b1, 1) + t.credited(b2, 1), 3, "no legitimate rider is lost to a batch throttle")
    eq(t.credited({kind = "tourist_return", home = 1, host = 1, visited = true, n = 2}, 1), 0)
    eq(t.credited({kind = "tourist_return", home = 1, host = 2, visited = false, n = 2}, 1), 0)
  end)

  it("halves the stat over twelve evaluations", function()
    near(t.decay(1, t.INSIGHT_HALF_LIFE), 0.5 ^ (1 / 12))
    near(t.decay(2, 12), 2 * 0.5 ^ (1 / 12))
    local v = 1
    for _ = 1, 12 do v = t.decay(v) end
    near(v, 0.5, 1e-9)
    eq(t.decay(nil), 0)
  end)

  it("home bonus saturates and hospitality is per visitor, both bonus-only", function()
    near(t.tourism_bonus(0), 0)
    near(t.tourism_bonus(1), t.W_TOURISM)
    near(t.tourism_bonus(10), t.W_TOURISM)
    near(t.hospitality_bonus(0), 0)
    near(t.hospitality_bonus(1), t.W_HOSPITALITY)
    near(t.hospitality_bonus(2), 2 * t.W_HOSPITALITY)
    near(t.hospitality_bonus(10), 2 * t.W_HOSPITALITY)
  end)

  it("desirability counts the two new parts as bonuses, never penalties", function()
    local base = des.compute({food_ratio = 1, free_housing_ratio = 1})
    local home, hp = des.compute({food_ratio = 1, free_housing_ratio = 1, tourism = 1})
    near(home - base, des.defaults.w_tourism)
    near(hp.tourism, des.defaults.w_tourism)
    local host, op = des.compute({food_ratio = 1, free_housing_ratio = 1, hospitality = 2})
    near(host - base, 2 * des.defaults.w_hospitality)
    near(op.hospitality, 2 * des.defaults.w_hospitality)
  end)

  it("an outbound tourist group gets off only at its host", function()
    local groups = {{from = 1, home = 1, host = 2, n = 2, stops = 0, kind = "tourist"}}
    local off, left, offs = tr.alight(groups, 1, 10, 10)
    eq(off, 0); eq(#left, 1); eq(left[1].stops, 1)
    off, left, offs = tr.alight(left, 3, 10, 10)
    eq(off, 0); eq(#left, 1); eq(left[1].stops, 2)
    off, left, offs = tr.alight(left, 2, 0, 0)
    eq(off, 2); eq(#left, 0); eq(#offs, 1)
    eq(offs[1].kind, "tourist"); eq(offs[1].host, 2); eq(offs[1].visited, nil)
    eq(t.earns_insight(offs[1], 2), false)
  end)

  it("a diverted tourist group comes home after four stops and still pays nothing", function()
    local g = {{from = 1, home = 1, host = 9, n = 2, stops = tr.RETURN_AFTER, kind = "tourist", visited = nil}}
    local off, left, offs = tr.alight(g, 1, 10, 10)
    eq(off, 2); eq(#left, 0); eq(offs[1].host, 9)
    eq(t.earns_insight(offs[1], 1), false)
  end)

  it("a return group gets off only at home and carries visited/host through", function()
    local g = {{from = 2, home = 1, host = 2, n = 2, stops = 0, kind = "tourist_return", visited = true}}
    local off, left = tr.alight(g, 2, 10, 10)
    eq(off, 0); eq(#left, 1); eq(left[1].visited, true); eq(left[1].host, 2)
    off, left, offs = tr.alight(left, 3, 10, 10)
    eq(off, 0); eq(#left, 1)
    off, left, offs = tr.alight(left, 1, 0, 0)
    eq(off, 2); eq(#left, 0); eq(offs[1].kind, "tourist_return")
    eq(offs[1].visited, true); eq(offs[1].host, 2)
    eq(t.earns_insight(offs[1], 1), true)
  end)

  it("a second arrival has no group left to pay from", function()
    local g = {{from = 2, home = 1, host = 2, n = 2, stops = 0, kind = "tourist_return", visited = true}}
    local off, left = tr.alight(g, 1, 0, 0)
    eq(off, 2)
    local off2, left2, offs2 = tr.alight(left, 1, 0, 0)
    eq(off2, 0); eq(#left2, 0); eq(#offs2, 0)
  end)

  it("legacy migrant, commuter and return groups keep their old alight behaviour", function()
    local off, left, offs = tr.alight({{from = 1, n = 3, stops = 0}}, 2, 2, 0)
    eq(off, 2); eq(left[1].n, 1); eq(offs[1].kind, nil); eq(offs[1].visited, nil)
    off = tr.alight({{from = 1, home = 3, n = 2, stops = 0, kind = "return"}}, 3, 0, 0)
    eq(off, 2)
  end)
end)
