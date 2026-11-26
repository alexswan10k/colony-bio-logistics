-- Pure EVA platform tile-repair rules (#69).
local repair = require("scripts.model.eva_repair")

describe("EVA tile repair", function()
  it("picks the most damaged reachable tile and spends a pack on it", function()
    local damaged = {
      {position = {x = 5, y = 0}, damage = 12},
      {position = {x = 1, y = 0}, damage = 80},
      {position = {x = 100, y = 0}, damage = 200},
    }
    local t = repair.task(damaged, {x = 0, y = 0}, 2)
    eq(t.position.x, 1)
    eq(t.spend, 1)
    eq(repair.applied(80, 100), 80)
    eq(repair.applied(60, 100), 60)
  end)

  it("ties break by position and nothing is dispatched without gear", function()
    local damaged = {{position = {x = 3, y = 1}, damage = 50}, {position = {x = 2, y = 9}, damage = 50}}
    eq(repair.task(damaged, {x = 0, y = 0}, 1).position.x, 2)
    eq(repair.task(damaged, {x = 0, y = 0}, 0), nil)
    eq(repair.task({}, {x = 0, y = 0}, 5), nil)
    eq(repair.task({{position = {x = 1, y = 0}, damage = 0.001}}, {x = 0, y = 0}, 5), nil)
  end)
end)
