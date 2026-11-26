-- Waystation (#56): pure placement rules and their territory-adapter wiring. A Waystation is a separate
-- territory node - it may be placed just outside the boundary, but its big circle must still overlap it.
local mock = require("tests.mock_factorio")
local ws = require("scripts.model.waystation")

describe("waystation placement rules", function()
  it("uses a fixed, shared radius and adjacency gap", function()
    eq(ws.RADIUS, 96, "twice the watchtower's 48-tile radius")
    eq(ws.ADJACENT, 16)
  end)
  it("measures a signed gap to the nearest emitter circle", function()
    -- A hall at the origin (radius 64) and a tower at +80 (radius 48).
    local emitters = {{position = {x = 0, y = 0}, radius = 64}, {position = {x = 80, y = 0}, radius = 48}}
    near(ws.gap({x = 10, y = 0}, emitters), -54, 1e-9, "inside the hall")
    near(ws.gap({x = 0, y = 64}, emitters), 0, 1e-9, "on the hall boundary")
    near(ws.gap({x = 90, y = 0}, emitters), -38, 1e-9, "inside the tower, which is nearer")
    near(ws.gap({x = 0, y = 62}, emitters), -2, 1e-9, "just inside the hall on the y axis")
  end)
  it("accepts inside and just-outside placements, rejects a distant one", function()
    local emitters = {{position = {x = 0, y = 0}, radius = 64}}
    eq(ws.can_place({x = 60, y = 0}, emitters), true, "inside")
    eq(ws.can_place({x = 79, y = 0}, emitters), true, "15 tiles outside: within ADJACENT")
    eq(ws.can_place({x = 80, y = 0}, emitters), true, "exactly ADJACENT tiles outside")
    eq(ws.can_place({x = 81, y = 0}, emitters), false, "17 tiles outside")
    eq(ws.can_place({x = 80, y = 0}, emitters, 0), false, "a caller can demand inside-only")
  end)
  it("accepts array positions and no emitters", function()
    eq(ws.can_place({0, 0}, {{position = {0, 0}, radius = 64}}), true)
    eq(ws.gap({x = 0, y = 0}, nil), nil)
    eq(ws.can_place({x = 0, y = 0}, nil), false)
    eq(ws.can_place(nil, nil), false)
    eq(ws.gap({x = 0, y = 0}, {{position = {x = 0, y = 0}}}), 0, "a missing radius reads as zero")
  end)
end)

describe("waystation territory wiring", function()
  local function setup()
    local env = mock.install(); env = env.reset()
    require("scripts.store").init()
    storage.colonies = {}
    storage.next_colony_id = 8
    return require("scripts.territory")
  end
  local function colony_with_hall(t)
    storage.colonies[1] = {id = 1, surface_index = 1, hall = {valid = true, position = {x = 0, y = 0},
      name = "colony-town-hall"}, towers = {}}
    return storage.colonies[1]
  end

  it("a waystation is a 96-tile emitter, after the core/domes/towers", function()
    local t = setup()
    local c = colony_with_hall(t)
    c.towers[5] = {valid = true, position = {x = 10, y = 0}, name = "colony-watchtower"}
    c.waystations = {[3] = {valid = true, position = {x = 70, y = 0}, name = "colony-waystation"}}
    local e = t.emitters(c)
    eq(#e, 3)
    eq(e[3].entity, c.waystations[3]); eq(e[3].radius, 96); eq(e[3].name, "colony-waystation")
    -- The claim is contiguous with the hall: its near edge (70 - 96 = -26) is well inside the hall circle.
    eq(t.owner_at(1, {x = 140, y = 0}), 1, "the ring reaches 166 tiles from the hall")
    eq(t.owner_at(1, {x = 170, y = 0}), nil, "and stops there")
    truthy(#t.chunks(c) > 0, "the waystation contributes claimed chunks")
  end)
  it("owner_near adopts inside and adjacent positions, never a far one", function()
    local t = setup()
    local c = colony_with_hall(t)
    eq(t.owner_near(1, {x = 50, y = 0}), 1, "inside the hall")
    eq(t.owner_near(1, {x = 80, y = 0}), 1, "16 tiles outside")
    eq(t.owner_near(1, {x = 81, y = 0}), nil, "17 tiles outside")
    eq(t.owner_near(1, {x = 80, y = 0}, 0), nil, "a caller can demand inside-only")
    eq(t.owner_near(2, {x = 0, y = 0}), nil, "wrong surface")
    eq(t.owner_near(1, nil), nil)
  end)
  it("owner_near picks the nearest colony deterministically", function()
    local t = setup()
    colony_with_hall(t)
    storage.colonies[2] = {id = 2, surface_index = 1, hall = {valid = true, position = {x = 170, y = 0},
      name = "colony-town-hall"}, towers = {}}
    eq(t.owner_near(1, {x = 80, y = 0}), 1, "16 from colony 1, 90 from colony 2")
    eq(t.owner_near(1, {x = 100, y = 0}), 2, "6 from colony 2, 36 from colony 1")
    eq(t.owner_at(1, {x = 100, y = 0}), nil, "neither territory actually covers it yet")
  end)
  it("invalid waystations are skipped without mutating the registry", function()
    local t = setup()
    local c = colony_with_hall(t)
    c.waystations = {[9] = {valid = false, position = {x = 70, y = 0}}}
    eq(#t.emitters(c), 1)
    eq(t.owner_at(1, {x = 140, y = 0}), nil)
    truthy(c.waystations[9], "a dead entry is left for on_object_destroyed to prune")
  end)
  it("removing a waystation releases its ring immediately", function()
    local t = setup()
    local c = colony_with_hall(t)
    c.waystations = {[9] = {valid = true, position = {x = 70, y = 0}}}
    eq(t.owner_at(1, {x = 140, y = 0}), 1)
    c.waystations[9] = nil
    eq(t.owner_at(1, {x = 140, y = 0}), nil)
    eq(t.owner_at(1, {x = 50, y = 0}), 1, "the hall's own land is untouched")
  end)
  it("an empty registry leaves the old territory byte-identical", function()
    local t = setup()
    local c = colony_with_hall(t)
    eq(t.owner_at(1, {x = 63, y = 0}), 1)
    eq(t.owner_at(1, {x = 65, y = 0}), nil)
    local before = t.chunks(c)
    c.waystations = {}
    local after = t.chunks(c)
    eq(#after, #before)
    for i, chunk in ipairs(before) do eq(after[i][1], chunk[1]); eq(after[i][2], chunk[2]) end
  end)
end)
