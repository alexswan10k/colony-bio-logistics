local links = require("scripts.model.links")
local crates = require("scripts.model.crates")

describe("freight link identity (#52)", function()
  it("validates only positive integers as link ids", function()
    eq(links.validate_id(7), 7)
    eq(links.validate_id("12"), 12)
    eq(links.validate_id(0), nil)
    eq(links.validate_id(-3), nil)
    eq(links.validate_id(2.5), nil)
    eq(links.validate_id("not-a-number"), nil)
    eq(links.validate_id(nil), nil)
  end)
  it("validates only the two exact role words", function()
    eq(links.validate_role("export"), "export")
    eq(links.validate_role("import"), "import")
    eq(links.validate_role("EXPORT"), nil)
    eq(links.validate_role("admin"), nil)
    eq(links.validate_role(nil), nil)
  end)
  it("resolves the opposite slot by unit number", function()
    local link = {a = {colony_id = 1, un = 10, role = "export"},
                  b = {colony_id = 2, un = 20, role = "import"}}
    eq(links.peer(link, 10), link.b)
    eq(links.peer(link, 20), link.a)
    eq(links.peer(link, 30), nil)
    eq(links.slot(link, "export"), link.a)
    eq(links.slot(link, "import"), link.b)
  end)
  it("refuses self-links, stale halves, mixed forces/surfaces and wrong kinds", function()
    local function slot(cid, un, role) return {colony_id = cid, un = un, role = role, alive = true} end
    local a, b = slot(1, 10, "export"), slot(2, 20, "import")
    truthy(links.valid_pair(a, b, true, true, true))
    eq(links.valid_pair(slot(1, 10, "export"), slot(1, 20, "import"), true, true, true), false, "self-link")
    eq(links.valid_pair(slot(1, 10, "import"), slot(2, 20, "import"), true, true, true), false, "roles")
    eq(links.valid_pair(a, b, false, true, true), false, "different forces")
    eq(links.valid_pair(a, b, true, false, true), false, "different surfaces")
    eq(links.valid_pair(a, b, true, true, false), false, "not a link crate")
    local dead = slot(2, 20, "import"); dead.alive = false
    eq(links.valid_pair(a, dead, true, true, true), false, "stale half")
  end)
  it("caps the registry", function() eq(links.MAX_LINKS, 32) end)
end)

describe("freight link trust boundary (#52)", function()
  local FILTERS = {{item = "iron-plate", count = 10}, [3] = {item = "wood", count = 400}}

  it("exports only above the reserve, clamped per row and per surplus", function()
    local wants = links.export_wants(FILTERS, {}, {}, {["iron-plate"] = 5, wood = 1000})
    eq(#wants, 2)
    eq(wants[1].item, "iron-plate"); eq(wants[1].count, 5)
    eq(wants[2].item, "wood"); eq(wants[2].count, 400)
  end)
  it("offers nothing at or below the reserve", function()
    eq(#links.export_wants(FILTERS, {}, {}, {["iron-plate"] = 0, wood = 1000}), 1, "wood still has surplus")
    local iron_only = {{item = "iron-plate", count = 10}}
    eq(#links.export_wants(iron_only, {}, {}, {["iron-plate"] = 0}), 0)
    eq(#links.export_wants(iron_only, {}, {}, {}), 0)
  end)
  it("0 reserve is an explicit opt-out: the row count is the only ceiling", function()
    local wants = links.export_wants({{item = "iron-plate", count = 10}}, {}, {}, {["iron-plate"] = 500})
    eq(wants[1].count, 10)
  end)
  it("subtracts already-claimed and in-flight units so two links cannot double count", function()
    local iron = {{item = "iron-plate", count = 10}}
    -- surplus has 4 left after the other link's claim, and 2 of this crate's hauls are already in flight
    local wants = links.export_wants(iron, {}, {["iron-plate"] = 2}, {["iron-plate"] = 4})
    eq(wants[1].count, 4)
  end)
  it("counts what sits in the crate, so a stalled train cannot pull the hall dry", function()
    local iron = {{item = "iron-plate", count = 10}}
    eq(#links.export_wants(iron, {["iron-plate"] = 10}, {}, {["iron-plate"] = 100}), 0)
    eq(links.export_wants(iron, {["iron-plate"] = 4}, {}, {["iron-plate"] = 100})[1].count, 6)
  end)
  it("uses the 50%/10 hysteresis so a half-full row does not trickle", function()
    local iron = {{item = "iron-plate", count = 10}}
    eq(#links.export_wants(iron, {["iron-plate"] = 7}, {}, {["iron-plate"] = 100}), 0, "have > 50% and deficit < 10")
    eq(links.export_wants(iron, {["iron-plate"] = 1}, {}, {["iron-plate"] = 100})[1].count, 9)
    eq(links.export_wants(iron, {["iron-plate"] = 0}, {}, {["iron-plate"] = 100})[1].count, 10)
  end)
  it("sorts export rows by item name for deterministic offers", function()
    local f = {{item = "wood", count = 10}, {item = "iron-plate", count = 10}, {item = "coal", count = 10}}
    local wants = links.export_wants(f, {}, {}, {wood = 100, ["iron-plate"] = 100, coal = 100})
    eq(wants[1].item, "coal"); eq(wants[2].item, "iron-plate"); eq(wants[3].item, "wood")
  end)
end)

describe("import crate provider (#52)", function()
  it("offers only filtered items that are actually inside", function()
    local filters = {{item = "coal", count = 50}, [2] = {item = "stone", count = 20}}
    local wants, available = links.import_wants(filters, {coal = 7, ["iron-plate"] = 99})
    eq(#wants, 1); eq(wants[1].item, "coal"); eq(wants[1].count, 7)
    eq(available.coal, 7); eq(available["iron-plate"], nil)
  end)
  it("accepts nothing with no filters (safe default)", function()
    local wants, available = links.import_wants({}, {coal = 50})
    eq(#wants, 0); eq(next(available), nil)
  end)
  it("honours an optional cap", function()
    local wants = links.import_wants({{item = "coal", count = 50}}, {coal = 40}, 20)
    eq(wants[1].count, 20)
  end)
end)

describe("link helpers (#52)", function()
  it("mirrors rows into a fresh table", function()
    local src = {{item = "coal", count = 10}, [3] = {item = "wood", count = 4}}
    local copy = links.mirror(src)
    truthy(copy ~= src); truthy(copy[1] ~= src[1])
    eq(copy[1].item, "coal"); eq(copy[3].count, 4)
    copy[1].count = 99
    eq(src[1].count, 10)
  end)
  it("lists only unpaired crates in another colony on the same force and surface", function()
    local entries = {
      {colony_id = 1, un = 11, kind = crates.LINK, force = "player", surface = 1, link = 4},
      {colony_id = 2, un = 21, kind = crates.LINK, force = "player", surface = 1},
      {colony_id = 3, un = 31, kind = crates.LINK, force = "enemy", surface = 1},
      {colony_id = 4, un = 41, kind = crates.LINK, force = "player", surface = 2},
      {colony_id = 5, un = 51, kind = crates.DEMAND, force = "player", surface = 1},
      {colony_id = 6, un = 61, kind = crates.LINK, force = "player", surface = 1, link = 9},
    }
    local list = links.candidates(entries, 1, "player", 1)
    eq(#list, 1); eq(list[1].colony_id, 2); eq(list[1].un, 21)
  end)
  it("sorts candidates by colony then unit number", function()
    local entries = {
      {colony_id = 3, un = 31, kind = crates.LINK, force = "p", surface = 1},
      {colony_id = 2, un = 25, kind = crates.LINK, force = "p", surface = 1},
      {colony_id = 2, un = 20, kind = crates.LINK, force = "p", surface = 1},
    }
    local list = links.candidates(entries, 1, "p", 1)
    eq(list[1].un, 20); eq(list[2].un, 25); eq(list[3].colony_id, 3)
  end)
end)
