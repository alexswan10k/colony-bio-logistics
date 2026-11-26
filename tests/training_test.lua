-- Pure Space Training Center rules (#69).
local training = require("scripts.model.training")

describe("space training center", function()
  it("never launches a town below the bootstrap population", function()
    eq(training.pop_ok(4, 100, nil), false)
    eq(training.pop_ok(5, 100, 200), false)
    eq(training.pop_ok(5, 200, 200), true)
    eq(training.pop_ok(5, 100, nil), true)
  end)

  it("requires rations and water for one launch", function()
    eq(next(training.missing({["colony-canned-meat"] = 2, ["colony-water"] = 2})), nil)
    eq(training.missing({["colony-canned-meat"] = 1, ["colony-water"] = 2})["colony-canned-meat"], 1)
    eq(training.can_launch(6, 100, nil, {["colony-canned-meat"] = 2, ["colony-water"] = 2}), true)
    eq(training.can_launch(3, 100, nil, {["colony-canned-meat"] = 2, ["colony-water"] = 2}), false)
  end)
end)
