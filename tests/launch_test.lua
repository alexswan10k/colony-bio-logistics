-- Pure rules for the exact character-in-platform launch path (#69).
local launch = require("scripts.model.launch")

describe("platform launch path", function()
  it("requires a hub and a training centre as well as a viable town", function()
    eq(launch.can_launch(6, 100, nil, true, true), true)
    eq(launch.can_launch(6, 100, nil, false, true), false)
    eq(launch.can_launch(6, 100, nil, true, false), false)
    eq(launch.can_launch(4, 100, nil, true, true), false)
    eq(launch.can_launch(6, 100, 200, true, true), false)
    eq(launch.can_launch(6, 200, 200, true, true), true)
  end)

  it("packs one pod item", function()
    local m = launch.manifest()
    eq(m[launch.POD_ITEM], 1)
    m[launch.POD_ITEM] = 5   -- caller may mutate its own copy
    eq(launch.manifest()[launch.POD_ITEM], 1)
    eq(launch.CHARACTER, "character")
  end)
end)
