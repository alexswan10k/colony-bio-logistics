-- Pure-model tests for M3 Stage 3: patrol route ordering, deterministic target selection, blacklist
-- expiry and no input mutation. No Factorio globals; every input is a plain table.
local patrol = require("scripts.model.patrol")

describe("patrol route", function()
  local posts = {
    {id = 30, colony_id = 2, waypoints = {{x = 3, y = 0}}},
    {id = 10, colony_id = 1, waypoints = {{x = 1, y = 0}, {x = 2, y = 0}}},
    {id = 20, colony_id = 1, waypoints = {{x = 4, y = 0}}},
  }

  it("filters by colony and sorts posts by id", function()
    local r = patrol.route(posts, 1)
    eq(#r, 3)
    eq(r[1].x, 1); eq(r[1].post, 10); eq(r[1].key, "10:1")
    eq(r[2].x, 2); eq(r[2].key, "10:2")
    eq(r[3].x, 4); eq(r[3].post, 20); eq(r[3].key, "20:1")
  end)

  it("is independent of the input iteration order", function()
    local a = patrol.route(posts, 1)
    local b = patrol.route({posts[3], posts[1], posts[2]}, 1)
    eq(#a, #b)
    for i = 1, #a do eq(a[i].key, b[i].key) end
  end)

  it("an empty/no post colony has an empty route", function()
    eq(#patrol.route(posts, 99), 0)
    eq(#patrol.route(nil, 1), 0)
  end)

  it("loops: next_waypoint wraps around and an empty route yields nil", function()
    local r = patrol.route(posts, 1)
    local wp, idx = patrol.next_waypoint(r, 3)
    eq(wp.key, "10:1"); eq(idx, 1)
    local w2, i2 = patrol.next_waypoint(r, 1)
    eq(w2.key, "10:2"); eq(i2, 2)
    local none, ni = patrol.next_waypoint({}, 0)
    eq(none, nil); eq(ni, nil)
    local first = patrol.next_waypoint(r, 0)
    eq(first.key, "10:1")
  end)

  it("does not mutate its input", function()
    local before = #posts[2].waypoints
    patrol.route(posts, 1)
    eq(#posts[2].waypoints, before)
    eq(posts[2].id, 10)
  end)
end)

describe("patrol target selection", function()
  local pos = {x = 0, y = 0}
  local enemies = {
    {unit_number = 9, position = {x = 5, y = 0}},
    {unit_number = 4, position = {x = -5, y = 0}},
    {unit_number = 7, position = {x = 5, y = 0}},
    {unit_number = 2, position = {x = 40, y = 0}},   -- out of range
  }

  it("picks the nearest enemy", function()
    eq(patrol.target_select(enemies, pos, 16).unit_number, 4)
  end)

  it("ties by unit number", function()
    local near = {{unit_number = 9, position = {x = 5, y = 0}}, {unit_number = 7, position = {x = 5, y = 0}}}
    eq(patrol.target_select(near, pos, 16).unit_number, 7)
    eq(patrol.target_select({near[2], near[1]}, pos, 16).unit_number, 7)
  end)

  it("skips blacklisted units and respects range", function()
    local pick = patrol.target_select(enemies, pos, 16, {[4] = 1000}, 500)
    eq(pick.unit_number, 7)
    eq(patrol.target_select(enemies, pos, 4), nil)
  end)

  it("blacklist entries expire", function()
    truthy(patrol.blacklisted({[4] = 1000}, 4, 999))
    truthy(not patrol.blacklisted({[4] = 1000}, 4, 1000))
    truthy(not patrol.blacklisted({[4] = 1000}, 9, 999))
    local live = patrol.expire_blacklist({[4] = 1000, [7] = 2000}, 1500)
    eq(live[4], nil); eq(live[7], 2000)
    -- expire_blacklist must not mutate
    local src = {[4] = 1000, [7] = 2000}
    patrol.expire_blacklist(src, 1500)
    eq(src[4], 1000)
  end)

  it("does not mutate the enemy list", function()
    local n = #enemies
    patrol.target_select(enemies, pos, 16, {[4] = 1000}, 500)
    eq(#enemies, n); eq(enemies[1].unit_number, 9)
  end)
end)

describe("patrol decisions", function()
  it("distraction_for maps attack kinds to by_enemy", function()
    eq(patrol.distraction_for("attack_area"), "by_enemy")
    eq(patrol.distraction_for("nest"), "by_enemy")
    eq(patrol.distraction_for("attack"), "by_enemy")
    eq(patrol.distraction_for("move"), "none")
    eq(patrol.distraction_for(nil), "none")
  end)

  it("should_disengage on a dead or timed-out target", function()
    truthy(patrol.should_disengage(0, 100))
    truthy(patrol.should_disengage(nil, 100))
    truthy(patrol.should_disengage(30, 0))
    truthy(not patrol.should_disengage(30, 100))
  end)

  it("lease expiry only applies to live patrol states", function()
    eq(patrol.lease_tick(1000), 1000 + patrol.LEASE_TICKS)
    truthy(patrol.is_patrol({state = "patrolling"}))
    truthy(patrol.is_patrol({state = "patrol-engage"}))
    truthy(not patrol.is_patrol({state = "commanded"}))
    truthy(patrol.expired({state = "patrolling", until_tick = 100}, 100))
    truthy(not patrol.expired({state = "patrolling", until_tick = 100}, 99))
    truthy(not patrol.expired({state = "commanded", until_tick = 100}, 200))
  end)
end)
