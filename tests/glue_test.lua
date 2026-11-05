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
    eq(storage.schema, 31); eq(storage.colony_chunks, nil); truthy(storage.scheduled)
    truthy(storage.cursor_overlays)
    truthy(storage.age)
  end)
  it("gives existing colonies towers, locks, plots and crates", function()
    local env = mock.install(); env = env.reset()
    storage.schema = 6
    storage.colonies = {[1] = {id = 1}}
    require("scripts.store").init()
    eq(storage.schema, 31); truthy(storage.colonies[1].cemeteries); truthy(storage.age); truthy(storage.colonies[1].alarms); truthy(storage.colonies[1].canteens); truthy(storage.commuters); truthy(storage.sick); eq(storage.colonies[1].fallen, 0); truthy(storage.colonies[1].pools); truthy(storage.colonies[1].taverns); truthy(storage.colonies[1].platforms); truthy(storage.coaches); truthy(storage.trucks); truthy(storage.colonies[1].towers); truthy(storage.colonies[1].locks)
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
    eq(storage.schema, 31)
    eq(storage.colonies[1].machines[10], nil)
    truthy(storage.colonies[1].machines[20])
    eq(destroyed_badge, true)
    eq(storage.colonies[1].crates[30], nil)
    truthy(storage.colonies[1].crates[40])
    eq(storage.colonies[1].machine_dirty, true)
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
end)
