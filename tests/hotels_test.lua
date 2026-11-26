-- Pure Grand Hotel rules (#69).
local hotels = require("scripts.model.hotels")

describe("Grand Hotels", function()
  it("serves at most one ale per guest", function()
    eq(hotels.served(3, 5), 3)
    eq(hotels.served(9, 5), 5)
    eq(hotels.served(nil, nil), 0)
  end)

  it("only earns the premium while every guest is served", function()
    eq(hotels.premium(5, 5), true)
    eq(hotels.premium(4, 5), false)
    eq(hotels.premium(0, 0), false)
  end)
end)
