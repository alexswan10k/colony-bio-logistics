-- Colony Ledger (#92): which of the colony's numbers become circuit signals, in what order and mode.
-- Everything here is pure: the engine half (logistic sections, the wire) is proved by spike s14_circuit.
local ls = require("scripts.model.ledger_signal")
local tags = require("scripts.model.tags")

describe("colony ledger signals (#92)", function()
  local function rows(list)
    local out = {}
    for _, r in ipairs(list) do out[#out + 1] = {item = r[1], total = r[2], target = r[3]} end
    return out
  end

  local function names(list)
    local out = {}
    for i, r in ipairs(list) do out[i] = r.item .. "=" .. r.count end
    return table.concat(out, " ")
  end

  it("publishes stock as the colony total, biggest first", function()
    local list = ls.publish(rows{{"iron-plate", 12}, {"wood", 300}, {"coal", 4}}, "stock")
    eq(names(list), "wood=300 iron-plate=12 coal=4")
  end)

  it("drops zero and negative signals instead of filling a slot with 0", function()
    local list = ls.publish(rows{{"iron-plate", 0}, {"wood", 3}, {"coal", -9}}, "stock")
    eq(names(list), "wood=3")
  end)

  it("breaks count ties with the hall ledger's category order, then the item name", function()
    -- Both 50: food sorts before raw goods in model/ledger.lua's ORDER, so the list is stable between passes.
    eq(names(ls.publish(rows{{"wood", 50}, {"colony-forage", 50}}, "stock")), "colony-forage=50 wood=50")
    -- No ORDER entry for either: the name decides, so two runs can never disagree.
    eq(names(ls.publish(rows{{"zebra-thing", 5}, {"aaa-thing", 5}}, "stock")), "aaa-thing=5 zebra-thing=5")
  end)

  it("ignores duplicate rows and malformed ones", function()
    local list = ls.publish({{item = "wood", total = 5}, {item = "wood", total = 99}, {item = "", total = 4},
      {total = 7}, "not a row"}, "stock")
    eq(names(list), "wood=5")
  end)

  it("caps the published list at the limit", function()
    local many = {}
    for i = 1, 60 do many[#many + 1] = {"item-" .. i, i} end
    local list = ls.publish(rows(many), "stock", 20)
    eq(#list, 20)
    eq(list[1].item, "item-60")     -- the biggest survive the cap
    eq(list[20].item, "item-41")
  end)

  it("defaults the cap to two sections' worth", function()
    eq(ls.MAX_SIGNALS, 20)
    eq(ls.MAX_SECTIONS, 2)
    local many = {}
    for i = 1, 60 do many[#many + 1] = {"item-" .. i, i} end
    eq(#ls.publish(rows(many), "stock"), ls.MAX_SIGNALS * ls.MAX_SECTIONS)
  end)

  it("want mode publishes the shortfall against the quota target", function()
    local list = ls.publish(rows{{"iron-plate", 40, 100}, {"wood", 300, 200}}, "want")
    eq(names(list), "iron-plate=60")
  end)

  it("want mode drops items already at or above target, so a wire reads 0 as nothing needed", function()
    eq(#ls.publish(rows{{"wood", 200, 200}, {"coal", 400, 200}}, "want"), 0)
  end)

  it("want mode treats a missing target as 0 rather than inventing demand", function()
    eq(#ls.publish(rows{{"colony-bread", 3}}, "want"), 0)
  end)

  it("an unknown mode falls back to stock", function()
    eq(ls.mode("nonsense"), "stock")
    eq(ls.mode(nil), "stock")
    eq(ls.mode("want"), "want")
    eq(names(ls.publish(rows{{"wood", 7, 100}}, "WANT")), "wood=7")
  end)

  it("clamps a total the engine would reject as a signal", function()
    eq(ls.value(3e9, "stock"), ls.MAX_VALUE)
    eq(ls.value(12, "stock"), 12)
    eq(ls.value(nil, "stock"), 0)
  end)

  it("always yields at least one section, so an empty ledger clears what it published before", function()
    eq(#ls.chunk(ls.publish({}, "stock")), 1)
    eq(#ls.chunk({}) , 1)
  end)

  it("chunks a long list into sections of 20", function()
    local list = {}
    for i = 1, 45 do list[i] = {item = "item-" .. i, count = i} end
    local sections = ls.chunk(list, 20)
    eq(#sections, 3)
    eq(#sections[1], 20)
    eq(#sections[2], 20)
    eq(#sections[3], 5)
    eq(sections[3][5].item, "item-45")
  end)

  it("summarises the wire for the panel", function()
    eq(ls.summary({}), "no signals (nothing in stock)")
    eq(ls.summary({{item = "wood", count = 300}}), "1 signal: 300 wood")
    eq(ls.summary({{item = "wood", count = 300}, {item = "iron-plate", count = 12}}, 1),
      "2 signals: 300 wood, ...")
  end)

  it("the publish mode survives a blueprint as a tag, and anything unknown decodes to stock", function()
    eq(tags.decode(tags.dictionary(tags.ledger({mode = "want"}))).ledger.mode, "want")
    eq(tags.decode(tags.dictionary(tags.ledger({mode = "stock"}))).ledger.mode, "stock")
    eq(tags.decode(tags.dictionary(tags.ledger({mode = "sideways"}))).ledger.mode, "stock")
    eq(tags.decode(tags.dictionary(tags.ledger(nil))).ledger.mode, "stock")
    -- and it does not impersonate the other payloads
    local d = tags.decode(tags.dictionary(tags.ledger({mode = "want"})))
    eq(d.machine, nil); eq(d.crate, nil)
  end)
end)
