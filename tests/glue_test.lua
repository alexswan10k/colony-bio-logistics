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
    eq(storage.schema, 34); eq(storage.colony_chunks, nil); truthy(storage.scheduled)
    truthy(storage.cursor_overlays)
    truthy(storage.age)
  end)
  it("gives existing colonies towers, locks, plots and crates", function()
    local env = mock.install(); env = env.reset()
    storage.schema = 6
    storage.colonies = {[1] = {id = 1}}
    require("scripts.store").init()
    eq(storage.schema, 34); truthy(storage.colonies[1].cemeteries); truthy(storage.age); truthy(storage.colonies[1].alarms); truthy(storage.colonies[1].canteens); truthy(storage.commuters); truthy(storage.sick); eq(storage.colonies[1].fallen, 0); truthy(storage.colonies[1].pools); truthy(storage.colonies[1].taverns); truthy(storage.colonies[1].platforms); truthy(storage.coaches); truthy(storage.trucks); truthy(storage.colonies[1].towers); truthy(storage.colonies[1].locks)
    truthy(storage.colonies[1].plots); truthy(storage.colonies[1].crates); truthy(storage.colonies[1].bins)
    truthy(storage.colonies[1].animals)
    truthy(storage.colonies[1].salt_pans)
    truthy(storage.colonies[1].wells)
    truthy(storage.colonies[1].ghosts); truthy(storage.colonies[1].repairs)
    truthy(storage.colonies[1].quotas)
    truthy(storage.colonies[1].job_targets)
    truthy(storage.colonies[1].overflow)
    truthy(storage.colonies[1].ratings)
    truthy(storage.cursor_overlays)
    eq(storage.colonies[1].machine_dirty, true, "machine index rebuilt on load")
  end)
  it("is idempotent and preserves existing data", function()
    local env = mock.install(); env = env.reset()
    local store = require("scripts.store")
    store.init(); storage.colonies[1] = {name = "x"}; store.migrate()
    eq(storage.colonies[1].name, "x")
  end)
  it("turns existing watchtowers into unmanned guard posts (#56)", function()
    local env = mock.install(); env = env.reset()
    storage.schema = 28
    local tower = {valid = true}
    storage.colonies = {[1] = {id = 1, towers = {[7] = tower}}}
    require("scripts.store").init()
    local hut = storage.colonies[1].huts[7]
    eq(hut.job, "guard"); eq(hut.limit, 0); eq(hut.entity, tower)
    truthy(storage.colonies[1].towers[7], "the tower keeps its territory duty")
  end)
  it("prunes ghost entities from machines and crates (schema 31)", function()
    local env = mock.install(); env = env.reset()
    storage.schema = 30
    local ghost_ent = {valid = true, type = "entity-ghost"}
    local live_ent = {valid = true, type = "assembling-machine"}
    local destroyed_badge = false
    local badge = {valid = true, destroy = function() destroyed_badge = true end}
    storage.colonies = {[1] = {
      id = 1,
      machines = {
        [10] = {entity = ghost_ent, badge = badge},
        [20] = {entity = live_ent},
      },
      crates = {
        [30] = {entity = ghost_ent},
        [40] = {entity = live_ent},
      },
    }}
    require("scripts.store").init()
    eq(storage.schema, 34)
    eq(storage.colonies[1].machines[10], nil)
    truthy(storage.colonies[1].machines[20])
    eq(destroyed_badge, true)
    eq(storage.colonies[1].crates[30], nil)
    truthy(storage.colonies[1].crates[40])
    eq(storage.colonies[1].machine_dirty, true)
  end)
  it("purges function closures from unit_state and storage (schema 32)", function()
    local env = mock.install(); env = env.reset()
    storage.schema = 31
    storage.unit_state = {
      [100] = {
        job = "haul",
        target = {
          entity = {valid = true},
          accepts_item = function() return true end,
        },
      },
    }
    storage.random_leak = {
      fn = function() return 42 end,
      nested = {fn2 = function() end, data = "ok"},
    }
    require("scripts.store").init()
    eq(storage.schema, 34)
    eq(storage.unit_state[100].target.accepts_item, nil)
    eq(storage.random_leak.fn, nil)
    eq(storage.random_leak.nested.fn2, nil)
    eq(storage.random_leak.nested.data, "ok")
  end)
  it("initializes colony.overflow (schema 33)", function()
    local env = mock.install(); env = env.reset()
    storage.schema = 32
    storage.colonies = {[1] = {id = 1}}
    require("scripts.store").init()
    eq(storage.schema, 34)
    truthy(storage.colonies[1].overflow)
    eq(storage.colonies[1].overflow["wood"], true)
    eq(storage.colonies[1].overflow["iron-ore"], true)
  end)
  it("initializes colony.ratings (schema 34)", function()
    local env = mock.install(); env = env.reset()
    storage.schema = 33
    storage.colonies = {[1] = {id = 1}}
    require("scripts.store").init()
    eq(storage.schema, 34)
    truthy(storage.colonies[1].ratings)
    eq(next(storage.colonies[1].ratings), nil)
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

describe("hut out of range clarity", function()
  it("reports no-sites as red blocker when a forager has no bushes in range even if tool is missing", function()
    local env = mock.install(); env = env.reset()
    require("scripts.store").init()
    local colony_mod = require("scripts.colony")
    local labour = require("scripts.model.labour")
    local gui = require("scripts.gui")
    local work = require("scripts.work")
    local feedback = require("scripts.feedback")

    local forager_ent = {
      valid = true, name = "colony-forager-hut", unit_number = 300, position = {x = 0, y = 0},
      surface = {
        index = 1,
        find_entities_filtered = function() return {} end,
        count_tiles_filtered = function() return 0 end,
        count_entities_filtered = function() return 0 end,
        get_pollution = function() return 0 end,
      },
      force = {technologies = {}, connected_players = {}},
      get_item_count = function() return 0 end,
      get_inventory = function() return {get_item_count = function() return 0 end, get_contents = function() return {} end} end,
    }
    local hut = {entity = forager_ent, job = "forage", wear = 0, limit = 2, workers = {}, inflight = {}, colony_id = 1}
    local hall_ent = {
      valid = true, name = colony_mod.HALL, unit_number = 100, position = {x = 0, y = 0},
      surface = forager_ent.surface, force = forager_ent.force,
      get_item_count = function() return 0 end,
      get_inventory = function() return {get_item_count = function() return 0 end, get_contents = function() return {} end} end,
    }
    local c = {
      id = 1, surface_index = 1, hall = hall_ent, huts = {[300] = hut}, houses = {},
      machines = {}, towers = {}, plots = {}, crates = {}, bins = {}, salt_pans = {},
      wells = {}, pools = {}, taverns = {}, platforms = {}, cemeteries = {}, fallen = 0,
      buried = 0, alarms = {}, canteens = {}, away = 0, locks = {}, quotas = {},
      job_targets = {}, colonists = {}, deaths = {}, claimed = {}, no_site = {},
      ghosts = {}, repairs = {}, ghost_blocked = {}, animals = {},
    }
    storage.colonies = {[1] = c}
    storage.next_colony_id = 2

    local def, tools, allowed, workers = work.hut_info(hut)
    eq(tools, 0, "no hoe in hut")
    local sites = work.site_count(hut)
    eq(sites, 0, "0 forage patches in range")

    local reason, args, level = gui.hut_reason(hut, def, tools, workers)
    eq(reason, "hut-no-sites", "reason should be no-sites despite missing hoe")
    eq(level, "red", "no-sites should have red severity")
  end)
end)

describe("colony logistics network", function()
  local function make_chest(inv_contents)
    local contents = {}
    for k, v in pairs(inv_contents or {}) do contents[k] = v end
    local inv = {
      is_empty = function() return next(contents) == nil end,
      is_full = function() return false end,
      get_contents = function()
        local list = {}
        for k, v in pairs(contents) do list[#list + 1] = {name = k, count = v} end
        return list
      end,
      get_item_count = function(name) return contents[name] or 0 end,
      remove_item = function(t)
        local have = contents[t.name] or 0
        local take = math.min(have, t.count)
        contents[t.name] = (have - take > 0) and (have - take) or nil
        return take
      end,
      insert = function(t)
        contents[t.name] = (contents[t.name] or 0) + t.count
        return t.count
      end,
    }
    return inv, contents
  end

  it("delivers food directly from forager hut to hungry house without touching Town Hall", function()
    local env = mock.install(); env = env.reset()
    require("scripts.store").init()
    local colony_mod = require("scripts.colony")
    local work = require("scripts.work")
    work.bind(colony_mod)

    local hall_inv, hall_store = make_chest({})
    local hall_ent = {
      valid = true, name = colony_mod.HALL, unit_number = 100, position = {x = 100, y = 100},
      surface = {index = 1, find_non_colliding_position = function(_, pos) return pos end},
      force = {technologies = {}, print = function() end},
      get_item_count = function(item) return hall_inv.get_item_count(item) end,
      get_inventory = function() return hall_inv end,
      remove_item = function(t) return hall_inv.remove_item(t) end,
      insert = function(t) return hall_inv.insert(t) end,
    }

    local forager_inv, forager_store = make_chest({["colony-forage"] = 15, ["iron-axe"] = 1})
    local forager_ent = {
      valid = true, name = "colony-forager-hut", unit_number = 200, position = {x = 10, y = 10},
      surface = hall_ent.surface, force = hall_ent.force,
      get_item_count = function(item) return forager_inv.get_item_count(item) end,
      get_inventory = function() return forager_inv end,
      remove_item = function(t) return forager_inv.remove_item(t) end,
      insert = function(t) return forager_inv.insert(t) end,
    }
    local forager_hut = {entity = forager_ent, job = "forage", wear = 0, limit = 2, workers = {}, inflight = {}, colony_id = 1}

    local house_inv, house_store = make_chest({})
    local house_ent = {
      valid = true, name = "colony-housing-cabin", unit_number = 300, position = {x = 14, y = 10},
      surface = hall_ent.surface, force = hall_ent.force,
      get_item_count = function(item) return house_inv.get_item_count(item) end,
      get_inventory = function() return house_inv end,
      remove_item = function(t) return house_inv.remove_item(t) end,
      insert = function(t) return house_inv.insert(t) end,
    }
    local house = {entity = house_ent, kind = "cabin", occupants = 4, inflight = {}, sat = {food = false}}

    local colonist_ent = {
      valid = true, name = "colony-colonist", unit_number = 500, position = {x = 5, y = 10},
      surface = hall_ent.surface, force = hall_ent.force,
      commandable = {set_command = function() end},
    }

    local c = {
      id = 1, surface_index = 1, hall = hall_ent, huts = {[200] = forager_hut},
      houses = {[300] = house}, machines = {}, towers = {}, plots = {}, crates = {},
      bins = {}, salt_pans = {}, wells = {}, pools = {}, taverns = {}, platforms = {},
      cemeteries = {}, fallen = 0, buried = 0, alarms = {}, canteens = {}, away = 0,
      locks = {}, quotas = {}, job_targets = {}, colonists = {[500] = colonist_ent},
      deaths = {}, claimed = {}, no_site = {}, ghosts = {}, repairs = {},
      ghost_blocked = {}, animals = {}, priority = {},
    }
    storage.colonies = {[1] = c}
    storage.next_colony_id = 2
    storage.unit_state = {}

    -- Hauler gets assigned
    work.assign(c, 500)

    local st = storage.unit_state[500]
    truthy(st, "hauler has a state")
    eq(st.job, "haul")
    -- Check direct transfer pickup & destination
    eq(st.pickup.x, 10, "pickup is at forager hut")
    eq(st.pickup.y, 10)
    eq(st.dest.x, 14, "destination is at cabin")
    eq(st.dest.y, 10)
    eq(st.carry[1].item, "colony-forage")
    eq(st.carry[1].count, 15, "claimed all 15 forage from forager (cabin wanted 20)")
    eq(forager_store["colony-forage"], nil, "forager hut emptied")
    eq(hall_store["colony-forage"], nil, "Town Hall was not touched")

    -- Step 1: Arrive at pickup (forager hut)
    env.fire(defines.events.on_ai_command_completed, {unit_number = 500, result = defines.behavior_result.success})
    st = storage.unit_state[500]
    eq(st.state, "to_house", "now heading to house")

    -- Step 2: Arrive at destination (cabin)
    env.fire(defines.events.on_ai_command_completed, {unit_number = 500, result = defines.behavior_result.success})
    eq(house_store["colony-forage"], 15, "cabin received 15 forage directly!")
    eq(house.inflight["colony-forage"], 0, "inflight reservation cleared")
  end)

  it("pushes hut output directly to nearest warehouse instead of far Town Hall", function()
    local env = mock.install(); env = env.reset()
    require("scripts.store").init()
    local colony_mod = require("scripts.colony")
    local crates = require("scripts.model.crates")
    local work = require("scripts.work")
    work.bind(colony_mod)

    local hall_inv, hall_store = make_chest({})
    local hall_ent = {
      valid = true, name = colony_mod.HALL, unit_number = 100, position = {x = 100, y = 100},
      surface = {index = 1, find_non_colliding_position = function(_, pos) return pos end},
      force = {technologies = {}, print = function() end},
      get_item_count = function(item) return hall_inv.get_item_count(item) end,
      get_inventory = function() return hall_inv end,
      remove_item = function(t) return hall_inv.remove_item(t) end,
      insert = function(t) return hall_inv.insert(t) end,
    }

    local miner_inv, miner_store = make_chest({["copper-ore"] = 20, ["colony-pickaxe"] = 1})
    local miner_ent = {
      valid = true, name = "colony-miner-hut", unit_number = 200, position = {x = 10, y = 10},
      surface = hall_ent.surface, force = hall_ent.force,
      get_item_count = function(item) return miner_inv.get_item_count(item) end,
      get_inventory = function() return miner_inv end,
      remove_item = function(t) return miner_inv.remove_item(t) end,
      insert = function(t) return miner_inv.insert(t) end,
    }
    local miner_hut = {entity = miner_ent, job = "mine", wear = 0, limit = 2, workers = {}, inflight = {}, ores = {["copper-ore"] = 1}, colony_id = 1}

    local wh_inv, wh_store = make_chest({})
    local wh_ent = {
      valid = true, name = "colony-warehouse", unit_number = 300, position = {x = 15, y = 10},
      surface = hall_ent.surface, force = hall_ent.force,
      get_item_count = function(item) return wh_inv.get_item_count(item) end,
      get_inventory = function() return wh_inv end,
      remove_item = function(t) return wh_inv.remove_item(t) end,
      insert = function(t) return wh_inv.insert(t) end,
    }
    local wh = {entity = wh_ent, kind = crates.WAREHOUSE}

    local colonist_ent = {
      valid = true, name = "colony-colonist", unit_number = 500, position = {x = 10, y = 10},
      surface = hall_ent.surface, force = hall_ent.force,
      commandable = {set_command = function() end},
    }

    local c = {
      id = 1, surface_index = 1, hall = hall_ent, huts = {[200] = miner_hut},
      houses = {}, machines = {}, towers = {}, plots = {}, crates = {[300] = wh},
      bins = {}, salt_pans = {}, wells = {}, pools = {}, taverns = {}, platforms = {},
      cemeteries = {}, fallen = 0, buried = 0, alarms = {}, canteens = {}, away = 0,
      locks = {[500] = "haul"}, quotas = {}, job_targets = {}, colonists = {[500] = colonist_ent},
      deaths = {}, claimed = {}, no_site = {}, ghosts = {}, repairs = {},
      ghost_blocked = {}, animals = {}, priority = {},
    }
    storage.colonies = {[1] = c}
    storage.next_colony_id = 2
    storage.unit_state = {}

    work.assign(c, 500)
    local st = storage.unit_state[500]
    truthy(st)
    eq(st.job, "haul")
    eq(st.dest.x, 15, "destination is nearest warehouse at x=15, not hall at x=100")
    eq(st.dest.y, 10)
    eq(st.carry[1].item, "copper-ore")
    eq(st.carry[1].count, 20)

    -- Arrive at warehouse
    env.fire(defines.events.on_ai_command_completed, {unit_number = 500, result = defines.behavior_result.success})
    eq(wh_store["copper-ore"], 20, "copper ore stored in warehouse")
    eq(hall_store["copper-ore"], nil, "no copper ore in Town Hall")
  end)

  it("includes watchtowers in stock_table and storage_list as buffer storage", function()
    local env = mock.install(); env = env.reset()
    require("scripts.store").init()
    local colony_mod = require("scripts.colony")

    local hall_inv = make_chest({["colony-forage"] = 5})
    local hall_ent = {
      valid = true, name = colony_mod.HALL, unit_number = 100, position = {x = 0, y = 0},
      surface = {index = 1}, force = {},
      get_item_count = function(item) return hall_inv.get_item_count(item) end,
      get_inventory = function() return hall_inv end,
    }

    local tower_inv = make_chest({["colony-forage"] = 10, ["iron-axe"] = 2})
    local tower_ent = {
      valid = true, name = colony_mod.WATCHTOWER, unit_number = 200, position = {x = 40, y = 40},
      surface = hall_ent.surface, force = hall_ent.force,
      get_item_count = function(item) return tower_inv.get_item_count(item) end,
      get_inventory = function() return tower_inv end,
    }

    local c = {
      id = 1, surface_index = 1, hall = hall_ent, huts = {}, houses = {},
      machines = {}, towers = {[200] = tower_ent}, plots = {}, crates = {},
      bins = {}, salt_pans = {}, wells = {}, pools = {}, taverns = {}, platforms = {},
      cemeteries = {}, fallen = 0, buried = 0, alarms = {}, canteens = {}, away = 0,
      locks = {}, quotas = {}, job_targets = {}, colonists = {}, deaths = {},
      claimed = {}, no_site = {}, ghosts = {}, repairs = {}, ghost_blocked = {}, animals = {},
    }

    local stock = colony_mod.stock_table(c)
    eq(stock["colony-forage"], 15, "5 from hall + 10 from tower buffer")
    eq(stock["iron-axe"], 2, "2 from tower buffer")

    local storages = colony_mod.storage_list(c)
    eq(#storages, 2, "hall + watchtower")
    eq(storages[2].kind, "watchtower")
    eq(storages[2].key, 200)
    eq(storages[2].available["colony-forage"], 10)
  end)

  it("calls site.deplete() when mining exhausts a deposit", function()
    local env = mock.install(); env = env.reset()
    require("scripts.store").init()
    local colony_mod = require("scripts.colony")
    local work = require("scripts.work")
    local sched = require("scripts.scheduler")

    local depleted = false
    local ore_site = {
      valid = true, name = "iron-ore", position = {x = 5, y = 5}, surface = {index = 1}, amount = 5,
      deplete = function() depleted = true end,
      destroy = function() error("should call deplete instead of destroy") end,
    }

    local hall_inv = make_chest({})
    local hall_ent = {
      valid = true, name = colony_mod.HALL, unit_number = 100, position = {x = 0, y = 0},
      surface = {index = 1, pollute = function() end}, force = {},
      get_item_count = function(item) return hall_inv.get_item_count(item) end,
      get_inventory = function() return hall_inv end,
    }

    local miner_inv = make_chest({["colony-pickaxe"] = 1})
    local miner_ent = {
      valid = true, name = "colony-miner-hut", unit_number = 200, position = {x = 2, y = 2},
      surface = hall_ent.surface, force = hall_ent.force,
      get_item_count = function(item) return miner_inv.get_item_count(item) end,
      get_inventory = function() return miner_inv end,
    }
    local miner_hut = {entity = miner_ent, job = "mine", wear = 0, limit = 2, workers = {[500] = true}, inflight = {}, ores = {}, colony_id = 1}

    local colonist_ent = {
      valid = true, name = "colony-colonist", unit_number = 500, position = {x = 5, y = 5},
      surface = hall_ent.surface, force = hall_ent.force,
      commandable = {set_command = function() end},
    }

    local c = {
      id = 1, surface_index = 1, hall = hall_ent, huts = {[200] = miner_hut},
      houses = {}, machines = {}, towers = {}, plots = {}, crates = {},
      bins = {}, salt_pans = {}, wells = {}, pools = {}, taverns = {}, platforms = {},
      cemeteries = {}, fallen = 0, buried = 0, alarms = {}, canteens = {}, away = 0,
      locks = {}, quotas = {}, job_targets = {}, colonists = {[500] = colonist_ent}, deaths = {},
      claimed = {}, no_site = {}, ghosts = {}, repairs = {}, ghost_blocked = {}, animals = {},
    }
    storage.colonies = {[1] = c}
    storage.unit_state = {[500] = {colony_id = 1, job = "mine", state = "working", site = ore_site, hut = miner_hut}}

    sched.after(1, "work.finish", {un = 500})
    env.tick(2)
    eq(depleted, true, "site.deplete() called on mine completion")
  end)

  it("switches a solitary woodcutter to food gathering when the colony is starving", function()
    local env = mock.install(); env = env.reset()
    require("scripts.store").init()
    local colony_mod = require("scripts.colony")
    local work = require("scripts.work")

    local hall_inv = make_chest({})
    local hall_ent = {
      valid = true, name = colony_mod.HALL, unit_number = 100, position = {x = 0, y = 0},
      surface = {index = 1, pollute = function() end, find_entities_filtered = function() return {} end}, force = {},
      get_item_count = function(item) return hall_inv.get_item_count(item) end,
      get_inventory = function() return hall_inv end,
    }

    local wood_inv = make_chest({["colony-axe"] = 1})
    local wood_ent = {
      valid = true, name = "colony-woodcutter-hut", unit_number = 200, position = {x = 2, y = 2},
      surface = hall_ent.surface, force = hall_ent.force,
      get_item_count = function(item) return wood_inv.get_item_count(item) end,
      get_inventory = function() return wood_inv end,
    }
    local wood_hut = {entity = wood_ent, job = "chop", wear = 0, limit = 2, workers = {[500] = true}, inflight = {}, ores = {}, colony_id = 1}

    local forage_inv = make_chest({["colony-basket"] = 1})
    local forage_ent = {
      valid = true, name = "colony-forager-hut", unit_number = 201, position = {x = 4, y = 4},
      surface = hall_ent.surface, force = hall_ent.force,
      get_item_count = function(item) return forage_inv.get_item_count(item) end,
      get_inventory = function() return forage_inv end,
    }
    local forage_hut = {entity = forage_ent, job = "forage", wear = 0, limit = 2, workers = {}, inflight = {}, ores = {}, colony_id = 1}

    local forage_patch = {valid = true, name = "colony-forage-patch", position = {x = 5, y = 5}, surface = hall_ent.surface}

    hall_ent.surface.find_entities_filtered = function(filter)
      if filter.name == "colony-forage-patch" then return {forage_patch} end
      return {}
    end

    local colonist_ent = {
      valid = true, name = "colony-colonist", unit_number = 500, position = {x = 2, y = 2},
      surface = hall_ent.surface, force = hall_ent.force,
      commandable = {set_command = function() end},
    }

    local c = {
      id = 1, surface_index = 1, hall = hall_ent, huts = {[200] = wood_hut, [201] = forage_hut},
      houses = {}, machines = {}, towers = {}, plots = {}, crates = {},
      bins = {}, salt_pans = {}, wells = {}, pools = {}, taverns = {}, platforms = {},
      cemeteries = {}, fallen = 0, buried = 0, alarms = {}, canteens = {}, away = 0,
      locks = {}, quotas = {}, job_targets = {}, colonists = {[500] = colonist_ent}, deaths = {},
      claimed = {}, no_site = {}, ghosts = {}, repairs = {}, ghost_blocked = {}, animals = {},
      priority = {},
    }
    storage.colonies = {[1] = c}
    storage.next_colony_id = 2
    storage.unit_state = {[500] = {colony_id = 1, job = "chop", state = "idle", hut = wood_hut}}

    work.assign(c, 500)
    local st = storage.unit_state[500]
    truthy(st)
    eq(st.job, "forage", "solitary woodcutter switched to forage when starving")
  end)

  it("offers toolsmith output tools for hauling even with count 1 (< 10 threshold)", function()
    local env = mock.install(); env = env.reset()
    local work = require("scripts.work")
    local colony_mod = require("scripts.colony")
    local hp = require("scripts.model.haul_plan")
    work.bind(colony_mod)

    local function make_chest(contents)
      local items = {}
      for k, v in pairs(contents) do items[k] = v end
      return {
        is_empty = function() return next(items) == nil end,
        is_full = function() return false end,
        get_item_count = function(name) return items[name] or 0 end,
        get_contents = function()
          local list = {}
          for k, v in pairs(items) do list[#list + 1] = {name = k, count = v} end
          return list
        end,
        insert = function(stack) items[stack.name] = (items[stack.name] or 0) + stack.count; return stack.count end,
        remove = function(stack)
          local have = items[stack.name] or 0
          local take = math.min(have, stack.count)
          items[stack.name] = (have - take > 0) and (have - take) or nil
          return take
        end,
      }
    end

    local hall_inv = make_chest({})
    local hall_ent = {
      valid = true, name = colony_mod.HALL, unit_number = 100, position = {x = 0, y = 0},
      surface = {index = 1, find_entities_filtered = function() return {} end}, force = {},
      get_item_count = function(item) return hall_inv.get_item_count(item) end,
      get_inventory = function() return hall_inv end,
    }

    local smith_inv = make_chest({["colony-axe"] = 1, ["wood"] = 10})
    local smith_ent = {
      valid = true, name = "colony-toolsmith", unit_number = 205, position = {x = 5, y = 5},
      surface = hall_ent.surface, force = hall_ent.force,
      get_item_count = function(item) return smith_inv.get_item_count(item) end,
      get_inventory = function() return smith_inv end,
    }
    local smith_hut = {entity = smith_ent, job = "preserve", wear = 0, limit = 1, workers = {}, inflight = {}, ores = {}, colony_id = 1}

    local c = {
      id = 1, surface_index = 1, hall = hall_ent, huts = {[205] = smith_hut},
      houses = {}, machines = {}, towers = {}, plots = {}, crates = {},
      bins = {}, salt_pans = {}, wells = {}, pools = {}, taverns = {}, platforms = {},
      cemeteries = {}, fallen = 0, buried = 0, alarms = {}, canteens = {}, away = 0,
      locks = {}, quotas = {}, job_targets = {}, colonists = {}, deaths = {},
      claimed = {}, no_site = {}, ghosts = {}, repairs = {}, ghost_blocked = {}, animals = {},
      priority = {},
    }
    storage.colonies = {[1] = c}

    local task = work.find_haul_task(c, nil, {x = 0, y = 0})
    truthy(task, "found haul task for toolsmith output tool")
    eq(task.kind, "collect")
    eq(task.target.key, 100) -- delivers to hall storage
    eq(task.load[1].item, "colony-axe")
    eq(task.load[1].count, 1)
  end)

  it("collects machine output even with small count (< 10)", function()
    local env = mock.install(); env = env.reset()
    local work = require("scripts.work")
    local colony_mod = require("scripts.colony")
    work.bind(colony_mod)

    local function make_chest(contents)
      local items = {}
      for k, v in pairs(contents) do items[k] = v end
      return {
        is_empty = function() return next(items) == nil end,
        is_full = function() return false end,
        get_item_count = function(name) return items[name] or 0 end,
        get_contents = function()
          local list = {}
          for k, v in pairs(items) do list[#list + 1] = {name = k, count = v} end
          return list
        end,
        insert = function(stack) items[stack.name] = (items[stack.name] or 0) + stack.count; return stack.count end,
        remove = function(stack)
          local have = items[stack.name] or 0
          local take = math.min(have, stack.count)
          items[stack.name] = (have - take > 0) and (have - take) or nil
          return take
        end,
      }
    end

    local hall_inv = make_chest({})
    local hall_ent = {
      valid = true, name = colony_mod.HALL, unit_number = 100, position = {x = 0, y = 0},
      surface = {index = 1, find_entities_filtered = function() return {} end}, force = {},
      get_item_count = function(item) return hall_inv.get_item_count(item) end,
      get_inventory = function() return hall_inv end,
    }

    local machine_out_inv = make_chest({["iron-gear-wheel"] = 3})
    local machine_ent = {
      valid = true, name = "assembling-machine-1", unit_number = 301, position = {x = 6, y = 6},
      surface = hall_ent.surface, force = hall_ent.force,
      get_output_inventory = function() return machine_out_inv end,
      get_item_count = function(item) return machine_out_inv.get_item_count(item) end,
    }
    local machine = {entity = machine_ent, enabled = true, collect = true, priority = 4, requests = {}, inflight = {}, has_output = true}

    local c = {
      id = 1, surface_index = 1, hall = hall_ent, huts = {},
      houses = {}, machines = {[301] = machine}, towers = {}, plots = {}, crates = {},
      bins = {}, salt_pans = {}, wells = {}, pools = {}, taverns = {}, platforms = {},
      cemeteries = {}, fallen = 0, buried = 0, alarms = {}, canteens = {}, away = 0,
      locks = {}, quotas = {}, job_targets = {}, colonists = {}, deaths = {},
      claimed = {}, no_site = {}, ghosts = {}, repairs = {}, ghost_blocked = {}, animals = {},
      priority = {}, machine_output = {machine},
    }
    storage.colonies = {[1] = c}

    local task = work.find_haul_task(c, nil, {x = 0, y = 0})
    truthy(task, "found haul task for machine output")
    eq(task.kind, "collect")
    eq(task.load[1].item, "iron-gear-wheel")
    eq(task.load[1].count, 3)
  end)

  it("emergency pulls from town hall when house shelves are empty, preventing starvation", function()
    local env = mock.install(); env = env.reset()
    require("scripts.store").init()
    local colony_mod = require("scripts.colony")
    local work = require("scripts.work")
    work.bind(colony_mod)

    local function make_chest(contents)
      local items = {}
      for k, v in pairs(contents) do items[k] = v end
      return {
        is_empty = function() return next(items) == nil end,
        is_full = function() return false end,
        get_item_count = function(name) return items[name] or 0 end,
        get_contents = function()
          local list = {}
          for k, v in pairs(items) do list[#list + 1] = {name = k, count = v} end
          return list
        end,
        insert = function(stack) items[stack.name] = (items[stack.name] or 0) + stack.count; return stack.count end,
        remove = function(stack)
          local have = items[stack.name] or 0
          local take = math.min(have, stack.count)
          items[stack.name] = (have - take > 0) and (have - take) or nil
          return take
        end,
      }
    end

    local hall_inv = make_chest({["colony-forage"] = 10})
    local hall_ent = {
      valid = true, name = colony_mod.HALL, unit_number = 100, position = {x = 0, y = 0},
      surface = {
        index = 1, pollute = function() end,
        find_entities_filtered = function() return {} end,
        find_non_colliding_position = function(_, pos) return pos end,
        count_entities_filtered = function() return 0 end,
        create_entity = function() return {valid = true, unit_number = 999} end,
        get_tile = function() return {name = "grass-1"} end,
        get_pollution = function() return 0 end,
      },
      force = {print = function() end, technologies = {}},
      get_item_count = function(item) return hall_inv.get_item_count(item) end,
      get_inventory = function() return hall_inv end,
      remove_item = function(stack) return hall_inv.remove(stack) end,
    }
    game.surfaces[1] = hall_ent.surface

    local tent_inv = make_chest({}) -- empty tent shelves!
    local tent_ent = {
      valid = true, name = "colony-housing-tent", unit_number = 401, position = {x = 2, y = 2},
      surface = hall_ent.surface, force = hall_ent.force,
      get_item_count = function(item) return tent_inv.get_item_count(item) end,
      get_inventory = function() return tent_inv end,
    }
    local tent_house = {entity = tent_ent, kind = "tent", occupants = 1, mouths = 1, hungry = 0, inflight = {}, acc = {}}

    local colonist_ent = {
      valid = true, name = "colony-colonist", unit_number = 501, position = {x = 2, y = 2},
      surface = hall_ent.surface, force = hall_ent.force,
      die = function() error("colonist died!") end,
    }

    local c = {
      id = 1, surface_index = 1, hall = hall_ent, huts = {},
      houses = {[401] = tent_house}, machines = {}, towers = {}, plots = {}, crates = {},
      bins = {}, salt_pans = {}, wells = {}, pools = {}, taverns = {}, platforms = {},
      cemeteries = {}, fallen = 0, buried = 0, alarms = {}, canteens = {}, away = 0,
      locks = {}, quotas = {}, job_targets = {}, colonists = {[501] = colonist_ent}, deaths = {},
      claimed = {}, no_site = {}, ghosts = {}, repairs = {}, ghost_blocked = {}, animals = {},
      priority = {}, interval = 1200,
    }
    storage.colonies = {[1] = c}

    -- Trigger evaluation step
    colony_mod.evaluate({colony_id = 1})

    eq(tent_house.hungry, 0, "hungry counter was reset by emergency pull from town hall")
    eq(hall_inv.get_item_count("colony-forage"), 9, "consumed 1 meal from town hall stock")
    truthy(colonist_ent.valid, "colonist stayed alive")
  end)
end)

describe("blueprint construction and carried item safety", function()
  local function make_chest(contents)
    local items = {}
    for k, v in pairs(contents) do items[k] = v end
    return {
      is_empty = function() return next(items) == nil end,
      is_full = function() return false end,
      get_item_count = function(name) return items[name] or 0 end,
      get_contents = function()
        local list = {}
        for k, v in pairs(items) do list[#list + 1] = {name = k, count = v} end
        return list
      end,
      insert = function(stack) items[stack.name] = (items[stack.name] or 0) + stack.count; return stack.count end,
      remove = function(stack)
        local have = items[stack.name] or 0
        local take = math.min(have, stack.count)
        items[stack.name] = (have - take > 0) and (have - take) or nil
        return take
      end,
    }
  end

  it("take_stock never re-entrantly runs worker assignment", function()
    local env = mock.install(); env = env.reset()
    local colony_mod = require("scripts.colony")
    local work = require("scripts.work")
    work.bind(colony_mod)

    local hall_inv = make_chest({["stone-furnace"] = 5})
    local hall_ent = {
      valid = true, name = colony_mod.HALL, unit_number = 100, position = {x = 0, y = 0},
      surface = {index = 1}, force = {print = function() end},
      get_item_count = function(item) return hall_inv.get_item_count(item) end,
      get_inventory = function() return hall_inv end,
      remove_item = function(stack) return hall_inv.remove(stack) end,
      insert = function(stack) return hall_inv.insert(stack) end,
    }
    local colony = {id = 1, hall = hall_ent, surface_index = 1, huts = {}, warehouses = {}, colonists = {}}
    storage.colonies = {[1] = colony}

    local taken = colony_mod.take_stock(colony, "stone-furnace", 2)
    eq(taken, 2)
    eq(hall_inv.get_item_count("stone-furnace"), 3)
  end)

  it("job_slots calculates construct capacity and slots without double subtraction", function()
    local env = mock.install(); env = env.reset()
    local colony_mod = require("scripts.colony")
    local work = require("scripts.work")
    work.bind(colony_mod)

    local g1 = {valid = true, surface = {index = 1}, position = {x = 5, y = 0}}
    local g2 = {valid = true, surface = {index = 1}, position = {x = 7, y = 0}}
    local colony = {
      id = 1,
      ghosts = {["1:5,0"] = g1, ["1:7,0"] = g2},
      repairs = {},
      claimed = {["1:5,0"] = true}, -- 1 ghost claimed by an active builder
      ghost_blocked = {},
      huts = {},
      colonists = {[10] = {valid = true}},
    }
    storage.colonies = {[1] = colony}
    storage.unit_state = {
      [10] = {colony_id = 1, job = "construct", state = "to_construct"},
    }

    local slots, cap = work.job_slots(colony)
    eq(slots.construct, 1, "exactly 1 unclaimed ghost slot remains")
    eq(cap.construct, 2, "total capacity is 1 open + 1 active builder = 2")
  end)

  it("work.assign protects active delivery and construction trips from state wipe", function()
    local env = mock.install(); env = env.reset()
    local colony_mod = require("scripts.colony")
    local work = require("scripts.work")
    work.bind(colony_mod)

    local c_ent = {
      valid = true, name = "colony-colonist", unit_number = 20, position = {x = 1, y = 1},
      surface = {index = 1, dark_fraction = 0}, force = {print = function() end},
      commandable = {set_command = function() end},
    }
    local hall_ent = {valid = true, name = colony_mod.HALL, unit_number = 100, position = {x = 0, y = 0}}
    local colony = {
      id = 1, hall = hall_ent, surface_index = 1, colonists = {[20] = c_ent},
      huts = {}, claimed = {},
    }
    storage.colonies = {[1] = colony}
    storage.unit_state = {
      [20] = {colony_id = 1, job = "construct", state = "to_construct", carry = {{item = "stone-furnace", count = 1}}},
    }

    -- Ambient assign trigger must NOT wipe to_construct state!
    work.assign(colony, 20)
    eq(storage.unit_state[20].state, "to_construct", "state was preserved")
    eq(#storage.unit_state[20].carry, 1, "carried items were preserved")
    eq(storage.unit_state[20].carry[1].item, "stone-furnace")
  end)

  it("releasing a colonist refunds carried goods to the hall", function()
    local env = mock.install(); env = env.reset()
    local colony_mod = require("scripts.colony")
    local work = require("scripts.work")
    work.bind(colony_mod)

    local hall_inv = make_chest({})
    local hall_ent = {
      valid = true, name = colony_mod.HALL, unit_number = 100, position = {x = 0, y = 0},
      surface = {index = 1}, force = {print = function() end},
      get_item_count = function(item) return hall_inv.get_item_count(item) end,
      get_inventory = function() return hall_inv end,
      insert = function(stack) return hall_inv.insert(stack) end,
    }
    local colony = {
      id = 1, hall = hall_ent, surface_index = 1, huts = {}, warehouses = {}, claimed = {["1:5,0"] = true},
    }
    storage.colonies = {[1] = colony}

    local st = {colony_id = 1, job = "construct", site_key = "1:5,0", carry = {{item = "stone-furnace", count = 1}}}
    work.release(st)

    eq(st.carry, nil, "carried items cleared from unit state")
    eq(colony.claimed["1:5,0"], nil, "site claim released")
    eq(hall_inv.get_item_count("stone-furnace"), 1, "furnace returned to town hall")
  end)
end)

describe("material priorities GUI (#91)", function()
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
  local function setup()
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
      ratings = {},
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
  it("round-trips the material rank (more = higher priority = lower number)", function()
    local env, c = setup()
    local mp = require("scripts.model.material_priority")
    eq(mp.rank(c.ratings, "iron-ore"), 3)
    env.fire(defines.events.on_gui_click, {player_index = 1, element = {name = "colony_mat_iron-ore_more"}})
    eq(mp.rank(c.ratings, "iron-ore"), 2, "more should raise priority 3 -> 2")
    env.fire(defines.events.on_gui_click, {player_index = 1, element = {name = "colony_mat_iron-ore_less"}})
    eq(mp.rank(c.ratings, "iron-ore"), 3, "less should lower 2 -> 3")
    env.fire(defines.events.on_gui_click, {player_index = 1, element = {name = "colony_mat_reset"}})
    eq(mp.rank(c.ratings, "iron-ore"), 3, "reset clears the rating")
    eq(next(c.ratings), nil)
  end)
  it("toggles enabled separately from rank", function()
    local env, c = setup()
    local mp = require("scripts.model.material_priority")
    env.fire(defines.events.on_gui_checked_state_changed, {player_index = 1, element = {name = "colony_mat_enabled_iron-ore", state = false}})
    eq(mp.enabled(c.ratings, "iron-ore"), false)
    eq(mp.score(c.ratings, "iron-ore"), mp.DISABLED)
    eq(mp.rank(c.ratings, "iron-ore"), 3, "disabling preserves rank")
    env.fire(defines.events.on_gui_checked_state_changed, {player_index = 1, element = {name = "colony_mat_enabled_iron-ore", state = true}})
    eq(mp.enabled(c.ratings, "iron-ore"), true)
    eq(mp.score(c.ratings, "iron-ore"), 3)
  end)
end)

describe("colony_missing_list ranks jobs (#91)", function()
  it("orders missing chop before mine when wood outranks ore", function()
    local env = mock.install(); env = env.reset()
    require("scripts.store").init()
    local colony_mod = require("scripts.colony")
    local work = require("scripts.work")
    work.bind(colony_mod)
    -- need stub for stock and quotas: use minimal colony with hall inventory counts
    local function make_chest(contents)
      local items = {}
      for k, v in pairs(contents or {}) do items[k] = v end
      return {
        get_item_count = function(name) return items[name] or 0 end,
        get_contents = function()
          local list = {}
          for k, v in pairs(items) do list[#list + 1] = {name = k, count = v} end
          return list
        end,
      }
    end
    local hall_inv = make_chest({})
    local hall_ent = {
      valid = true, name = colony_mod.HALL, unit_number = 100, position = {x = 0, y = 0},
      surface = {index = 1, find_entities_filtered = function() return {} end}, force = {},
      get_item_count = function(item) return hall_inv.get_item_count(item) end,
      get_inventory = function() return hall_inv end,
    }
    local c = {
      id = 1, surface_index = 1, hall = hall_ent, huts = {}, houses = {}, machines = {},
      towers = {}, plots = {}, crates = {}, bins = {}, salt_pans = {}, wells = {}, pools = {},
      taverns = {}, platforms = {}, cemeteries = {}, fallen = 0, buried = 0, alarms = {},
      canteens = {}, away = 0, locks = {}, quotas = {wood = 100, ["iron-ore"] = 100, ["copper-ore"] = 100, coal = 100, stone = 100},
      job_targets = {}, overflow = {}, ratings = {wood = {rank = 1, enabled = true}, ["iron-ore"] = {rank = 5, enabled = true}},
      colonists = {}, deaths = {}, claimed = {}, no_site = {}, ghosts = {}, repairs = {}, ghost_blocked = {},
    }
    storage.colonies = {[1] = c}
    local rows = work.colony_missing_list(c)
    eq(rows[1].job, "chop", "wood rank 1 is most wanted")
    local mine_pos = nil
    for i, r in ipairs(rows) do if r.job == "mine" then mine_pos = i end end
    truthy(mine_pos, "mine is among the missing")
    -- mine (iron rank 5) sorts after the rank-3 food jobs, not before them
    truthy(mine_pos > 2, "iron rank 5 sorts last among the missing")
  end)
end)

describe("steel tool tiers (#95) glue", function()
  local function make_chest(contents)
    local items = {}
    for k, v in pairs(contents or {}) do items[k] = v end
    return {
      get_item_count = function(name) return items[name] or 0 end,
      get_contents = function()
        local list = {}
        for k, v in pairs(items) do list[#list + 1] = {name = k, count = v} end
        return list
      end,
      is_empty = function() return next(items) == nil end,
      is_full = function() return false end,
    }
  end
  it("hut_info counts a steel ladder (steel + tier-1 both open slots)", function()
    local env = mock.install(); env = env.reset()
    require("scripts.store").init()
    local colony_mod = require("scripts.colony")
    local work = require("scripts.work")
    work.bind(colony_mod)
    local inv = make_chest({["colony-steel-axe"] = 1, ["colony-axe"] = 1})
    local ent = {
      valid = true, name = "colony-woodcutter-hut", unit_number = 401, position = {x = 0, y = 0},
      surface = {index = 1}, force = {},
      get_item_count = function(item) return inv.get_item_count(item) end,
      get_inventory = function() return inv end,
    }
    local hut = {entity = ent, job = "chop", wear = 0, limit = 3, workers = {}, inflight = {}, colony_id = 1}
    local def, tools, allowed = work.hut_info(hut)
    eq(def.tool, "colony-axe")
    eq(tools, 2)
    eq(allowed, 2)
    local farm_inv = make_chest({["colony-steel-hoe"] = 2})
    local farm_ent = {
      valid = true, name = "colony-farm-hut", unit_number = 402, position = {x = 0, y = 0},
      surface = {index = 1}, force = {},
      get_item_count = function(item) return farm_inv.get_item_count(item) end,
      get_inventory = function() return farm_inv end,
    }
    local farm_hut = {entity = farm_ent, job = "farm", wear = 0, limit = 3, workers = {}, inflight = {}, colony_id = 1}
    local _, ftools, fallowed = work.hut_info(farm_hut)
    eq(ftools, 2)
    eq(fallowed, 2)
  end)
  it("tool_gaps reports the tier-1 gap for a short steel-ladder hut", function()
    local env = mock.install(); env = env.reset()
    require("scripts.store").init()
    local colony_mod = require("scripts.colony")
    local work = require("scripts.work")
    work.bind(colony_mod)
    local hall_inv = make_chest({})
    local hall_ent = {
      valid = true, name = colony_mod.HALL, unit_number = 100, position = {x = 0, y = 0},
      surface = {index = 1}, force = {},
      get_item_count = function(item) return hall_inv.get_item_count(item) end,
      get_inventory = function() return hall_inv end,
    }
    -- One steel axe in a 3-capacity woodcutter: short 2, reported as tier-1 colony-axe (tier-1 first).
    local inv = make_chest({["colony-steel-axe"] = 1})
    local ent = {
      valid = true, name = "colony-woodcutter-hut", unit_number = 403, position = {x = 5, y = 5},
      surface = {index = 1}, force = {},
      get_item_count = function(item) return inv.get_item_count(item) end,
      get_inventory = function() return inv end,
    }
    local hut = {entity = ent, job = "chop", wear = 0, limit = 3, workers = {}, inflight = {}, colony_id = 1}
    local c = {
      id = 1, surface_index = 1, hall = hall_ent, huts = {[403] = hut}, houses = {}, machines = {},
      towers = {}, plots = {}, crates = {}, bins = {}, salt_pans = {}, wells = {}, pools = {},
      taverns = {}, platforms = {}, cemeteries = {}, fallen = 0, buried = 0, alarms = {},
      canteens = {}, away = 0, locks = {}, quotas = {}, job_targets = {}, colonists = {},
      deaths = {}, claimed = {}, no_site = {}, ghosts = {}, repairs = {}, ghost_blocked = {},
    }
    local gaps = colony_mod.tool_gaps(c)
    eq(#gaps, 1)
    eq(gaps[1].tool, "colony-axe")
    eq(gaps[1].short, 2)
  end)
end)

describe("miner quota (downstream iron vs stale coal, #54 repro)", function()
  local function make_chest(contents)
    local items = {}
    for k, v in pairs(contents or {}) do items[k] = v end
    return {
      get_item_count = function(name) return items[name] or 0 end,
      get_contents = function()
        local list = {}
        for k, v in pairs(items) do list[#list + 1] = {name = k, count = v} end
        return list
      end,
      is_empty = function() return next(items) == nil end,
      is_full = function() return false end,
    }
  end
  it("a met coal ore does not close a miner whose iron is still wanted", function()
    local env = mock.install(); env = env.reset()
    require("scripts.store").init()
    local colony_mod = require("scripts.colony")
    local work = require("scripts.work")
    work.bind(colony_mod)
    -- Stock: coal 20 (met at default 20), iron 0 (wanted). No machines/demand, so target = base 20.
    local hall_inv = make_chest({coal = 20})
    local hall_ent = {
      valid = true, name = colony_mod.HALL, unit_number = 100, position = {x = 0, y = 0},
      surface = {index = 1}, force = {},
      get_item_count = function(item) return hall_inv.get_item_count(item) end,
      get_inventory = function() return hall_inv end,
    }
    local hut_inv = make_chest({["colony-pickaxe"] = 3})
    local hut_ent = {
      valid = true, name = "colony-miner-hut", unit_number = 901, position = {x = 5, y = 5},
      surface = {index = 1}, force = {},
      get_item_count = function(item) return hut_inv.get_item_count(item) end,
      get_inventory = function() return hut_inv end,
    }
    -- Stale memo from a previous find_site where only coal was met.
    local hut = {entity = hut_ent, job = "mine", wear = 0, limit = 3, workers = {}, inflight = {}, colony_id = 1,
      quota_item = "coal", quota_met = true}
    local c = {
      id = 1, surface_index = 1, hall = hall_ent, huts = {[901] = hut}, houses = {}, machines = {},
      towers = {}, plots = {}, crates = {}, bins = {}, salt_pans = {}, wells = {}, pools = {},
      taverns = {}, platforms = {}, cemeteries = {}, fallen = 0, buried = 0, alarms = {},
      canteens = {}, away = 0, locks = {}, quotas = {}, job_targets = {}, ratings = {},
      colonists = {}, deaths = {}, claimed = {}, no_site = {}, ghosts = {}, repairs = {}, ghost_blocked = {},
    }
    storage.colonies = {[1] = c}
    -- Sanity: coal met, iron not.
    eq(colony_mod.quota_met(c, "coal"), true)
    eq(colony_mod.quota_met(c, "iron-ore"), false)
    -- The hut must be open (not quota-met) and the stale memo cleared.
    local met, item = work.hut_quota_met(c, hut)
    eq(met, false)
    eq(item, nil)
    eq(hut.quota_item, nil)
    -- And job_slots must give the hut an allowed slot (3 pickaxes would be labour.allowed then).
    local slots, _, slot_list = work.job_slots(c)
    eq(slots.mine, 3)
    eq(#slot_list, 1)
  end)
end)

describe("supply cap with sink (#54)", function()
  local function make_chest(contents)
    local items = {}
    for k, v in pairs(contents or {}) do items[k] = v end
    return {
      get_item_count = function(name) return items[name] or 0 end,
      get_contents = function()
        local list = {}
        for k, v in pairs(items) do list[#list + 1] = {name = k, count = v} end
        return list
      end,
      is_empty = function() return next(items) == nil end,
      is_full = function() return false end,
    }
  end
  it("plates pile up to 20 with no sink, but flow when a consuming machine is the sink", function()
    local env = mock.install(); env = env.reset()
    require("scripts.store").init()
    local colony_mod = require("scripts.colony")
    local work = require("scripts.work")
    work.bind(colony_mod)
    -- Stock 25 copper plates, no consumer: base 20, demand 0 -> capped.
    local hall_inv = make_chest({["copper-plate"] = 25})
    local hall_ent = {
      valid = true, name = colony_mod.HALL, unit_number = 100, position = {x = 0, y = 0},
      surface = {index = 1}, force = {},
      get_item_count = function(item) return hall_inv.get_item_count(item) end,
      get_inventory = function() return hall_inv end,
    }
    local base_c = {
      id = 1, surface_index = 1, hall = hall_ent, huts = {}, houses = {}, machines = {},
      towers = {}, plots = {}, crates = {}, bins = {}, salt_pans = {}, wells = {}, pools = {},
      taverns = {}, platforms = {}, cemeteries = {}, fallen = 0, buried = 0, alarms = {},
      canteens = {}, away = 0, locks = {}, quotas = {}, job_targets = {}, ratings = {},
      colonists = {}, deaths = {}, claimed = {}, no_site = {}, ghosts = {}, repairs = {}, ghost_blocked = {},
    }
    storage.colonies = {[1] = base_c}
    eq(colony_mod.base_quota_target(base_c, "copper-plate"), 20)
    eq(colony_mod.quota_target(base_c, "copper-plate"), 20)
    eq(work.supply_capped(base_c, "copper-plate"), true)
    -- Stock below cap is not capped.
    hall_inv = make_chest({["copper-plate"] = 19})
    base_c.stock_cache, base_c.stock_tick = nil, nil
    eq(work.supply_capped(base_c, "copper-plate"), false)
    -- A consuming assembler (sink) raises the ceiling to base + demand.
    hall_inv = make_chest({["copper-plate"] = 25})
    base_c.stock_cache, base_c.stock_tick = nil, nil
    base_c.machines = {[500] = {
      entity = {valid = true, unit_number = 500, position = {x = 9, y = 9}, surface = {index = 1}},
      enabled = true, collect = false, inflight = {}, priority = 4,
      requests = {{item = "copper-plate", count = 100}},
    }}
    base_c.hall = hall_ent
    colony_mod.invalidate_demand(base_c)
    eq(work.supply_capped(base_c, "copper-plate"), false)
    eq(colony_mod.quota_target(base_c, "copper-plate"), 120)
  end)
end)

describe("machine output helper (#54)", function()
  local function mock_frame()
    local captions = {}
    local elem
    elem = {
      style = {},
      clear = function() end,
      add = function(spec)
        if spec and spec.caption then captions[#captions + 1] = spec.caption end
        return mock_frame().elem
      end,
      elem = {style = {}},
    }
    elem.elem = elem
    return elem, captions
  end
  local function make_chest(contents)
    local items = {}
    for k, v in pairs(contents or {}) do items[k] = v end
    return {
      get_item_count = function(name) return items[name] or 0 end,
      get_contents = function()
        local list = {}
        for k, v in pairs(items) do list[#list + 1] = {name = k, count = v} end
        return list
      end,
      is_empty = function() return next(items) == nil end,
      is_full = function() return false end,
    }
  end
  local function capstr(captions)
    local parts = {}
    for _, cap in ipairs(captions) do
      if type(cap) == "table" then
        for _, piece in ipairs(cap) do parts[#parts + 1] = tostring(piece) end
      else parts[#parts + 1] = tostring(cap) end
    end
    return table.concat(parts, "|")
  end
  it("shows capped output with stock/cap so the player sees why haulers leave it", function()
    local env = mock.install(); env = env.reset()
    require("scripts.store").init()
    local colony_mod = require("scripts.colony")
    local work = require("scripts.work")
    work.bind(colony_mod)
    local gui = require("scripts.gui")
    gui.bind(colony_mod)
    local hall_inv = make_chest({["copper-plate"] = 25})
    local hall_ent = {
      valid = true, name = colony_mod.HALL, unit_number = 100, position = {x = 0, y = 0},
      surface = {index = 1}, force = {},
      get_item_count = function(item) return hall_inv.get_item_count(item) end,
      get_inventory = function() return hall_inv end,
    }
    local out_inv = make_chest({["copper-plate"] = 5})
    local furnace = {
      valid = true, name = "stone-furnace", unit_number = 500, position = {x = 9, y = 9},
      surface = {index = 1}, force = {},
      get_item_count = function(item) return out_inv.get_item_count(item) end,
      get_inventory = function() return out_inv end,
      get_output_inventory = function() return out_inv end,
    }
    local m = {entity = furnace, enabled = true, collect = true, requests = {}, inflight = {}, priority = 4, capped = true}
    local c = {
      id = 1, surface_index = 1, hall = hall_ent, huts = {}, houses = {}, machines = {[500] = m},
      towers = {}, plots = {}, crates = {}, bins = {}, salt_pans = {}, wells = {}, pools = {},
      taverns = {}, platforms = {}, cemeteries = {}, fallen = 0, buried = 0, alarms = {},
      canteens = {}, away = 0, locks = {}, quotas = {}, job_targets = {}, ratings = {},
      colonists = {}, deaths = {}, claimed = {}, no_site = {}, ghosts = {}, repairs = {}, ghost_blocked = {},
    }
    storage.colonies = {[1] = c}
    -- colony_of in mock: patch to find our colony via hall position? gui.colony_at uses colony_mod.colony_of(e).
    -- That helper looks up by unit_number/territory; without it the helper still renders (colony nil -> capped false).
    -- Force the colony by stubbing colony_of is brittle, so assert on the capped flag line + Output header which need no colony.
    local frame, captions = mock_frame()
    gui.fill_machine(frame, m, furnace)
    local s = capstr(captions)
truthy(s:find("supply-output", 1, true), "Output header present")
    truthy(s:find("copper-plate", 1, true), "output item shown")
    truthy(s:find("supply-output-capped", 1, true), "capped hint shown when machine capped")
  end)
  it("shows collect-off and empty states", function()
    local env = mock.install(); env = env.reset()
    require("scripts.store").init()
    local colony_mod = require("scripts.colony")
    local work = require("scripts.work")
    work.bind(colony_mod)
    local gui = require("scripts.gui")
    gui.bind(colony_mod)
    local out_inv = make_chest({})
    local furnace = {
      valid = true, name = "stone-furnace", unit_number = 501, position = {x = 9, y = 9},
      surface = {index = 1}, force = {},
      get_item_count = function(item) return 0 end,
      get_inventory = function() return out_inv end,
      get_output_inventory = function() return out_inv end,
    }
    local frame1, cap1 = mock_frame()
    gui.fill_machine(frame1, {entity = furnace, enabled = true, collect = false, requests = {}, inflight = {}, priority = 4}, furnace)
    truthy(capstr(cap1):find("supply-output-off", 1, true), "collect off hint")
    local frame2, cap2 = mock_frame()
    gui.fill_machine(frame2, {entity = furnace, enabled = true, collect = true, requests = {}, inflight = {}, priority = 4}, furnace)
    truthy(capstr(cap2):find("supply-output-empty", 1, true), "empty output hint")
  end)
end)
