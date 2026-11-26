-- Pure Resort rules (#69): capacity, doubled insight payout and doubled hospitality weight.
local resorts = require("scripts.model.resorts")

describe("resorts", function()
  it("a resort hosts four visitors on top of the spa capacity", function()
    eq(resorts.host_capacity(1, 0, 0, 0, 0), 2)
    eq(resorts.host_capacity(1, 1, 0, 0, 0), 6)
    eq(resorts.host_capacity(0, 1, 3, 2, 1), 0)
  end)

  it("a resort visit pays double insights", function()
    eq(resorts.insights(false, 3), 3)
    eq(resorts.insights(true, 3), 6)
    eq(resorts.insights(nil, nil), 0)
  end)

  it("a resort host gets double the hospitality weight", function()
    eq(resorts.hospitality(false, 3), 3)
    eq(resorts.hospitality(true, 3), 6)
    eq(resorts.hospitality(nil, nil), 0)
  end)
end)
