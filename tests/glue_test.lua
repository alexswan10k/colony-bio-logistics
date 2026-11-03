local mock = require("tests.mock_factorio")

describe("events multiplexer", function()
  it("dispatches to every subscriber", function()
    local env = mock.install(); env = env.reset()
    local events = require("scripts.events")
    local n = 0
    events.on("e", function() n = n + 1 end); events.on("e", function() n = n + 10 end)
    env.fire("e")
    eq(n, 11)
  end)
end)

describe("store migrations", function()
  it("initialises the current schema layout", function()
    local env = mock.install(); env = env.reset()
    require("scripts.store").init()
    eq(storage.schema, 27); eq(storage.colony_chunks, nil); truthy(storage.scheduled)
    truthy(storage.cursor_overlays)
  end)
  it("gives existing colonies towers, locks, plots and crates", function()
    local env = mock.install(); env = env.reset()
    storage.schema = 6
    storage.colonies = {[1] = {id = 1}}
    require("scripts.store").init()
    eq(storage.schema, 27); truthy(storage.colonies[1].cemeteries); truthy(storage.colonies[1].alarms); truthy(storage.colonies[1].canteens); truthy(storage.commuters); truthy(storage.sick); eq(storage.colonies[1].fallen, 0); truthy(storage.colonies[1].pools); truthy(storage.colonies[1].taverns); truthy(storage.colonies[1].platforms); truthy(storage.coaches); truthy(storage.trucks); truthy(storage.colonies[1].towers); truthy(storage.colonies[1].locks)
    truthy(storage.colonies[1].plots); truthy(storage.colonies[1].crates); truthy(storage.colonies[1].bins)
    truthy(storage.colonies[1].animals)
    truthy(storage.colonies[1].salt_pans)
    truthy(storage.colonies[1].wells)
    truthy(storage.colonies[1].ghosts); truthy(storage.colonies[1].repairs)
    truthy(storage.colonies[1].quotas)
    truthy(storage.colonies[1].job_targets)
    truthy(storage.cursor_overlays)
    eq(storage.colonies[1].machine_dirty, true, "machine index rebuilt on load")
  end)
  it("is idempotent and preserves existing data", function()
    local env = mock.install(); env = env.reset()
    local store = require("scripts.store")
    store.init(); storage.colonies[1] = {name = "x"}; store.migrate()
    eq(storage.colonies[1].name, "x")
  end)
end)

describe("scheduler", function()
  it("runs handler at the scheduled tick only, once", function()
    local env = mock.install(); env = env.reset()
    require("scripts.store").init()
    local sched = require("scripts.scheduler")
    local hits = {}
    sched.register("h", function(d) hits[#hits + 1] = {tick = game.tick, v = d.v} end)
    sched.after(5, "h", {v = 42})
    env.tick(10)
    eq(#hits, 1); eq(hits[1].tick, 5); eq(hits[1].v, 42)
    eq(next(storage.scheduled), nil, "bucket cleaned up")
  end)
end)

describe("territory index", function()
  local function setup()
    local env = mock.install(); env = env.reset()
    require("scripts.store").init()
    storage.colonies = {}
    storage.next_colony_id = 8   -- owner_at walks ids 1..next-1 in numeric order
    return require("scripts.territory")
  end
  it("maps negative coords to chunks correctly", function()
    local t = setup()
    local cx, cy = t.chunk_of({x = -0.5, y = -32.5}); eq(cx, -1); eq(cy, -2)
    cx, cy = t.chunk_of({x = 31.9, y = 32}); eq(cx, 0); eq(cy, 1)
  end)
  it("checks distance-based ownership around town hall", function()
    local t = setup()
    storage.colonies[7] = {id = 7, surface_index = 1, hall = {valid = true, position = {x = 10, y = 10}}, towers = {}}
    -- Point within HALL_RADIUS (64 tiles)
    eq(t.owner_at(1, {x = -20, y = 40}), 7)
    -- Point outside HALL_RADIUS (dx = 70 - 10 = 60, dy = 60 - 10 = 50, dist = ~78 > 64)
    eq(t.owner_at(1, {x = 70, y = 60}), nil)
  end)
  it("watchtowers extend territory radius", function()
    local t = setup()
    storage.colonies[1] = {id = 1, surface_index = 1, hall = {valid = true, position = {x = 0, y = 0}}, towers = {}}
    eq(t.owner_at(1, {x = 70, y = 0}), nil)
    -- Add a watchtower at x = 50, y = 0 with TOWER_RADIUS (48 tiles)
    storage.colonies[1].towers[10] = {valid = true, position = {x = 50, y = 0}}
    -- Now x = 70 is within 20 tiles of tower (<= 48)
    eq(t.owner_at(1, {x = 70, y = 0}), 1)
    -- Beyond tower reach (50 + 48 = 98)
    eq(t.owner_at(1, {x = 105, y = 0}), nil)
  end)
  it("destroying or removing watchtower releases extended territory", function()
    local t = setup()
    storage.colonies[1] = {id = 1, surface_index = 1, hall = {valid = true, position = {x = 0, y = 0}},
      towers = {[10] = {valid = true, position = {x = 50, y = 0}}}}
    storage.colonies[2] = {id = 2, surface_index = 1, hall = {valid = true, position = {x = 200, y = 0}}, towers = {}}
    eq(t.owner_at(1, {x = 70, y = 0}), 1)
    eq(t.owner_at(1, {x = 200, y = 0}), 2)
    -- Watchtower removed
    storage.colonies[1].towers[10] = nil
    eq(t.owner_at(1, {x = 70, y = 0}), nil)
    eq(t.owner_at(1, {x = 200, y = 0}), 2)
  end)
end)

describe("gui priority and target buttons", function()
  local function mock_gui_elem()
    local elem
    elem = {
      style = {},
      clear = function() end,
      add = function() return mock_gui_elem() end,
    }
    return elem
  end

  local function mock_ent(name, un, pos)
    return {
      valid = true, name = name, unit_number = un or 100, position = pos or {x = 0, y = 0},
      surface = {
        index = 1,
        find_entities_filtered = function() return {} end,
        count_tiles_filtered = function() return 0 end,
        count_entities_filtered = function() return 0 end,
        get_pollution = function() return 0 end,
      },
      force = {technologies = {}},
      get_item_count = function() return 0 end,
      get_inventory = function() return {get_item_count = function() return 0 end, get_contents = function() return {} end} end,
    }
  end

  local function setup_hall()
    local env = mock.install(); env = env.reset()
    require("scripts.store").init()
    local colony_mod = require("scripts.colony")
    local hall_ent = mock_ent(colony_mod.HALL, 100)
    local c = {
      id = 1, surface_index = 1, hall = hall_ent, houses = {}, machines = {}, huts = {},
      towers = {}, plots = {}, crates = {}, bins = {}, salt_pans = {}, wells = {}, pools = {},
      taverns = {}, platforms = {}, cemeteries = {}, fallen = 0, buried = 0, alarms = {},
      canteens = {}, away = 0, locks = {}, quotas = {}, job_targets = {}, colonists = {},
      deaths = {}, claimed = {}, no_site = {}, ghosts = {}, repairs = {}, ghost_blocked = {},
      priority = nil,
    }
    storage.colonies = {[1] = c}
    storage.next_colony_id = 2
    require("scripts.gui")
    local player = {
      index = 1, valid = true, opened = hall_ent,
      gui = {relative = {colony_info_frame = {valid = true, body = mock_gui_elem()}}}
    }
    _G.game.get_player = function(idx) return player end
    return env, c
  end

  it("handles priority button clicks: more increases priority (rank 1), less lowers it", function()
    local env, c = setup_hall()
    -- Initial: default rank for chop is 2
    env.fire(defines.events.on_gui_click, {player_index = 1, element = {name = "colony_prio_chop_more"}})
    eq(c.priority and c.priority.chop, 1, "chop_more should increase priority from 2 to 1")

    env.fire(defines.events.on_gui_click, {player_index = 1, element = {name = "colony_prio_chop_less"}})
    eq(c.priority and c.priority.chop, 2, "chop_less should decrease priority from 1 to 2")

    -- Lowering further cycles: 2 -> 3 -> 4 -> 0 (off)
    env.fire(defines.events.on_gui_click, {player_index = 1, element = {name = "colony_prio_chop_less"}})
    eq(c.priority.chop, 3)
    env.fire(defines.events.on_gui_click, {player_index = 1, element = {name = "colony_prio_chop_less"}})
    eq(c.priority.chop, 4)
    env.fire(defines.events.on_gui_click, {player_index = 1, element = {name = "colony_prio_chop_less"}})
    eq(c.priority.chop, 0, "rank 4 less should turn role off (0)")

    -- From 0, more should cycle to MAX_RANK (4)
    env.fire(defines.events.on_gui_click, {player_index = 1, element = {name = "colony_prio_chop_more"}})
    eq(c.priority.chop, 4, "off more should turn role on at rank 4")

    env.fire(defines.events.on_gui_click, {player_index = 1, element = {name = "colony_prio_reset"}})
    eq(c.priority and c.priority.chop, 2, "reset should restore default priorities")
  end)

  it("handles target button clicks: more increases target, less decreases", function()
    local env, c = setup_hall()
    env.fire(defines.events.on_gui_click, {player_index = 1, element = {name = "colony_target_chop_more"}})
    eq(c.job_targets and c.job_targets.chop, 1, "target_more should set target")
    env.fire(defines.events.on_gui_click, {player_index = 1, element = {name = "colony_target_chop_less"}})
    eq(c.job_targets and c.job_targets.chop, 0, "target_less should decrease target")
  end)

  it("handles ore priority button clicks: more increases priority (rank 1), less lowers it", function()
    local env = mock.install(); env = env.reset()
    require("scripts.store").init()
    local colony_mod = require("scripts.colony")
    local hut_ent = mock_ent("colony-miner-hut", 200)
    local hut = {entity = hut_ent, ores = {}, wear = 0, limit = 2, workers = {}, inflight = {}}
    local hall_ent = mock_ent(colony_mod.HALL, 100)
    local c = {
      id = 1, surface_index = 1, hall = hall_ent, huts = {[200] = hut}, houses = {},
      machines = {}, towers = {}, plots = {}, crates = {}, bins = {}, salt_pans = {},
      wells = {}, pools = {}, taverns = {}, platforms = {}, cemeteries = {}, fallen = 0,
      buried = 0, alarms = {}, canteens = {}, away = 0, locks = {}, quotas = {},
      job_targets = {}, colonists = {}, deaths = {}, claimed = {}, no_site = {},
      ghosts = {}, repairs = {}, ghost_blocked = {},
    }
    storage.colonies = {[1] = c}
    storage.next_colony_id = 2
    require("scripts.gui")
    local player = {
      index = 1, valid = true, opened = hut_ent,
      gui = {relative = {colony_hut_frame = {valid = true, body = mock_gui_elem()}}}
    }
    _G.game.get_player = function(idx) return player end

    -- Default iron-ore rank is 1
    -- Clicking less on rank 1 lowers priority to rank 2
    env.fire(defines.events.on_gui_click, {player_index = 1, element = {name = "colony_ore_iron-ore_less"}})
    eq(hut.ores and hut.ores["iron-ore"], 2, "ore_less should lower priority to rank 2")

    env.fire(defines.events.on_gui_click, {player_index = 1, element = {name = "colony_ore_iron-ore_less"}})
    eq(hut.ores["iron-ore"], 3)
    env.fire(defines.events.on_gui_click, {player_index = 1, element = {name = "colony_ore_iron-ore_less"}})
    eq(hut.ores["iron-ore"], 4)
    env.fire(defines.events.on_gui_click, {player_index = 1, element = {name = "colony_ore_iron-ore_less"}})
    eq(hut.ores["iron-ore"], 0, "rank 4 less turns ore off")

    env.fire(defines.events.on_gui_click, {player_index = 1, element = {name = "colony_ore_iron-ore_more"}})
    eq(hut.ores["iron-ore"], 4, "off more turns ore on at rank 4")

    env.fire(defines.events.on_gui_click, {player_index = 1, element = {name = "colony_ore_iron-ore_more"}})
    eq(hut.ores["iron-ore"], 3)
    env.fire(defines.events.on_gui_click, {player_index = 1, element = {name = "colony_ore_iron-ore_more"}})
    eq(hut.ores["iron-ore"], 2)
    env.fire(defines.events.on_gui_click, {player_index = 1, element = {name = "colony_ore_iron-ore_more"}})
    eq(hut.ores["iron-ore"], 1, "ore_more should raise priority to rank 1")
  end)
end)
