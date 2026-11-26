-- Command Whistle (#58): the pure rules. Engine facts live in s18_command; this file never mocks Factorio.
local command = require("scripts.model.command")

describe("command whistle (order precedence, #58)", function()
  it("refuses sleep, shelter, travel, commute, driving and children", function()
    for _, state in ipairs({"child", "to_bed", "sleeping", "to_shelter", "sheltered", "exposed",
        "to_platform", "waiting_train", "driving", "to_park"}) do
      eq(command.commandable({state = state}), false, "should be protected: " .. state)
    end
    eq(command.commandable({state = "idle"}, {is_child = true}), false)
    eq(command.commandable({state = "idle"}, {is_truck = true}), false)
    eq(command.commandable({state = "idle"}, {is_commuter = true}), false)
    eq(command.commandable({state = "idle"}, {driving = true}), false)
    eq(command.commandable(nil, {alarm_covers = true}), true, "a colonist with no state is idle")
  end)

  it("orders idle and ordinary work trips, including guards and hunters", function()
    for _, state in ipairs({"idle", "to_construct", "building", "repairing", "to_pickup", "to_house",
        "to_hut", "to_machine", "to_crate", "to_pool", "to_tavern", "to_bin", "to_hall", "to_site",
        "working", "hunting", "to_tower", "guarding", "guarding-fight"}) do
      eq(command.commandable({state = state}), true, "should be orderable: " .. state)
    end
    eq(command.commandable({state = "unknown-future-state"}), false, "unknown states fail closed")
    eq(command.commandable({state = "commanded"}), true, "a new order can replace an existing lease")
  end)

  it("select sorts, dedupes and respects set/add/remove/clear", function()
    eq(table.concat(command.select({9, 2, 2, 5}, {7, 5, 1}, "set"), ","), "1,5,7")
    eq(table.concat(command.select({1, 5, 7}, {3, 5}, "add"), ","), "1,3,5,7")
    eq(table.concat(command.select({1, 3, 5, 7}, {3, 7}, "remove"), ","), "1,5")
    eq(table.concat(command.select({1, 5}, {9}, "clear"), ","), "")
  end)

  it("accepts the storage map form and caps at MAX_SELECT without aliasing", function()
    local current = {[8] = true, [3] = true}
    local out = command.select(current, {[3] = true, [11] = true}, "add")
    eq(table.concat(out, ","), "3,8,11")
    current[5] = true
    eq(table.concat(out, ","), "3,8,11", "result must not alias its input")
    local many = {}
    for i = 1, command.MAX_SELECT + 50 do many[i] = true end
    local capped = command.select(nil, many, "set")
    eq(#capped, command.MAX_SELECT)
    eq(capped[1], 1)
    eq(capped[#capped], command.MAX_SELECT)
  end)

  it("abort intents describe every claim the adapter must release, without mutating", function()
    local st = {state = "to_pickup", job = "chop", colony_id = 4, carry = {{item = "wood", count = 3}},
      hut = {workers = {[7] = true}}, site_key = "tree:1,2", car = 88, trailer = 99}
    local intents = command.abort_intents(st)
    eq(intents.release_carry, true)
    eq(intents.free_hut_slot, true)
    eq(intents.free_site_claim, "tree:1,2")
    eq(intents.return_car, true)
    eq(intents.return_trailer, true)
    eq(intents.restore_destructible, false)
    eq(intents.old_job, "chop")
    eq(intents.old_state, "to_pickup")
    eq(st.state, "to_pickup", "input untouched")
    eq(st.site_key, "tree:1,2", "input untouched")
    local empty = command.abort_intents(nil)
    eq(empty.free_site_claim, false)
    eq(empty.old_job, "idle")
  end)

  it("guard and hunter intents free the hut post", function()
    for _, st in ipairs({{state = "guarding", job = "guard", hut = {}},
        {state = "hunting", job = "hunt", hut = {}}}) do
      eq(command.abort_intents(st).free_hut_slot, true)
      eq(command.commandable(st), true)
    end
  end)

  it("MOVE plans go_to_location with no distraction and a lease", function()
    local r = command.plan({12, 3}, command.ORDERS.MOVE, {position = {x = 5, y = -2}}, 1000,
      {colonies = {[12] = 2, [3] = 2}, jobs = {[12] = "haul", [3] = "chop"}, owner = 1})
    eq(table.concat(command.to_list(r.states), ","), "3,12")
    eq(r.states[12].state, "commanded")
    eq(r.states[12].job, "haul")
    eq(r.states[12].colony_id, 2)
    eq(r.states[12].lease_owner, 1)
    eq(r.states[12].until_tick, 1000 + command.LEASE_TICKS)
    eq(r.commands[12].kind, "go_to_location")
    eq(r.commands[12].destination.x, 5)
    eq(r.commands[12].destination.y, -2)
    eq(r.commands[12].radius, 1.5)
    eq(r.commands[12].distraction, "none")
  end)

  it("ATTACK_MOVE plans attack_area with by_enemy, ATTACK plans a target", function()
    local am = command.plan({4}, command.ORDERS.ATTACK_MOVE, {position = {x = 1, y = 2}, radius = 12}, 0)
    eq(am.commands[4].kind, "attack_area")
    eq(am.commands[4].radius, 12)
    eq(am.commands[4].distraction, "by_enemy")
    local at = command.plan({4}, command.ORDERS.ATTACK, {position = {x = 1, y = 2}, enemy_un = 99}, 0)
    eq(at.commands[4].kind, "attack")
    eq(at.commands[4].target_un, 99)
    eq(at.commands[4].distraction, "none")
    eq(at.states[4].order, command.ORDERS.ATTACK)
  end)

  it("STOP issues a stop command but creates no lease", function()
    local r = command.plan({2, 1}, command.ORDERS.STOP, nil, 50)
    eq(next(r.states), nil)
    eq(r.commands[1].kind, "stop")
    eq(r.commands[2].kind, "stop")
  end)

  it("plan is deterministic and returns fresh tables", function()
    local a = command.plan({5, 2}, command.ORDERS.MOVE, {position = {x = 1, y = 1}}, 7)
    local b = command.plan({2, 5}, command.ORDERS.MOVE, {position = {x = 1, y = 1}}, 7)
    eq(table.concat(command.to_list(a.states), ","), table.concat(command.to_list(b.states), ","))
    eq(a.commands[2].destination.x, b.commands[2].destination.x)
    a.commands[2].destination.x = 99
    eq(b.commands[2].destination.x, 1, "plans must not share command tables")
  end)

  it("expiry and completion release exactly when they should", function()
    local st = {state = "commanded", until_tick = 100}
    eq(command.expired(st, 99), false)
    eq(command.expired(st, 100), true)
    eq(command.after_completion(st, "success", 99), "release_to_work")
    eq(command.after_completion(st, "in_progress", 99), "keep")
    eq(command.after_completion(st, "in_progress", 100), "release_to_work")
    eq(command.after_completion(st, "deleted", 99), "release_to_work")
    eq(command.after_completion({state = "working"}, "success", 0), "keep")
  end)

  it("disconnect cleanup drops one player's selection/markers and releases only their leases", function()
    local data = {selection = {[1] = {4, 7}, [2] = {9}},
      markers = {[1] = {"a"}, [2] = {"b"}}, owner = {[4] = 1, [7] = 1, [9] = 2}}
    local out = command.drop_player(data, 1)
    eq(out.selection[1], nil)
    eq(table.concat(out.selection[2], ","), "9")
    eq(out.markers[1], nil)
    eq(table.concat(out.markers_removed, ","), "a")
    eq(table.concat(out.released, ","), "4,7")
    eq(out.owner[9], 2)
    eq(data.owner[4], 1, "input untouched")
    eq(command.drop_player(data, 3).released[1], nil)
  end)

  it("labels are plain text and distinct for move vs attack", function()
    truthy(command.label_for(command.ORDERS.MOVE):find("moving", 1, true))
    truthy(command.label_for(command.ORDERS.ATTACK):find("attacking", 1, true))
    truthy(command.label_for(command.ORDERS.ATTACK_MOVE):find("attacking", 1, true))
  end)
end)

-- Death cleanup (#58): a colonist killed under a whistle lease must not stay selected or leased. The pure
-- rules are here; the adapter's redraw is pinned in the mock test below and in s18_command's real engine case.
describe("command whistle death cleanup (#58)", function()
  it("forgets a dead unit in every player's selection and drops only that unit's lease/owner", function()
    local data = {selection = {[1] = {4, 7}, [2] = {7, 9}}, markers = {[1] = {"a"}, [2] = {"b"}},
      owner = {[4] = 1, [7] = 1, [9] = 2}, leased = {[4] = true, [7] = true, [9] = true}, watchdog = true}
    local out = command.forget_unit(data, 7)
    eq(table.concat(out.selection[1], ","), "4")
    eq(table.concat(out.selection[2], ","), "9")
    eq(table.concat(out.changed, ","), "1,2")
    eq(out.owner[7], nil)
    eq(out.leased[7], nil)
    eq(out.owner[4], 1)
    eq(out.owner[9], 2)
    eq(out.leased[4], true)
    eq(out.leased[9], true)
    eq(out.watchdog, true)
    eq(out.markers[1][1], "a", "marker render objects pass through untouched for the adapter")
    eq(data.selection[1][2], 7, "input untouched")
    eq(data.owner[7], 1, "input untouched")
  end)

  it("reports only the players who had the unit and accepts the map selection form", function()
    local data = {selection = {[3] = {[5] = true, [8] = true}, [4] = {[8] = true}}}
    local out = command.forget_unit(data, 5)
    eq(table.concat(out.selection[3], ","), "8")
    eq(table.concat(out.selection[4], ","), "8")
    eq(table.concat(out.changed, ","), "3")
    eq(command.forget_unit(data, 5).changed[2], nil)
  end)

  it("is a no-op for nil data and an absent unit number", function()
    eq(next(command.forget_unit(nil, 1).selection), nil)
    eq(next(command.forget_unit(nil, 1).owner), nil)
    local data = {selection = {[1] = {3}}, leased = {[3] = true}}
    local out = command.forget_unit(data, nil)
    eq(table.concat(out.selection[1], ","), "3")
    eq(out.leased[3], true)
    eq(next(out.changed), nil)
  end)
end)

-- Regression for the review's MAJOR finding: work.lua's hunt kill-credit (on_entity_died) writes meat into
-- st.carry whenever st.job == "hunt", even while state == "commanded". The old release_lease discarded the
-- whole state table, so the meat vanished. This pins the adapter's release path (the s18_command spike pins
-- the real hall insert). Reverting the fix (removing the work.release call) makes this test fail.
describe("command whistle release (item-loss regression, #58 review)", function()
  it("funnels a commanded hunter's carry through work.release before resetting the state", function()
    local mock = require("tests.mock_factorio")
    local env = mock.install(); env = env.reset()
    local released = {}
    package.loaded["scripts.work"] = {
      release = function(st)
        released[#released + 1] = {un = st.un, job = st.job, state = st.state, carry = st.carry}
        st.carry, st.state = nil, "idle"
      end,
      clear_label = function() end,
      assign = function() end,
      is_sleep_time = function() return false end,
    }
    package.loaded["scripts.scheduler"] = {register = function() end, after = function() end}
    local cmd = require("scripts.command")
    storage.unit_state, storage.unit_labels, storage.carry_sprites = {}, {}, {}
    storage.command = {selection = {}, markers = {}, owner = {}, leased = {}}
    storage.colonies = {[1] = {colonists = {[7] = {valid = true, name = "colony-colonist"}}}}
    storage.unit_state[7] = {un = 7, colony_id = 1, job = "hunt", state = "commanded",
      carry = {{item = "colony-meat", count = 3}}, until_tick = 9999}
    storage.command.leased[7] = true
    storage.command.owner[7] = 1
    cmd.release_lease(7, false)
    eq(#released, 1, "work.release must see the leased state")
    eq(released[1].job, "hunt")
    eq(released[1].state, "commanded")
    eq(released[1].carry[1].item, "colony-meat")
    eq(released[1].carry[1].count, 3)
    eq(storage.unit_state[7].state, "idle")
    eq(storage.unit_state[7].carry, nil)
    eq(storage.command.leased[7], nil)
    eq(storage.command.owner[7], nil)
  end)
end)

describe("command whistle death cleanup adapter (#58)", function()
  it("prunes a dead unit from every selection, redraws only affected players and drops its lease", function()
    local mock = require("tests.mock_factorio")
    local env = mock.install(); env = env.reset()
    package.loaded["scripts.work"] = {release = function() end, clear_label = function() end,
      assign = function() end, is_sleep_time = function() return false end}
    package.loaded["scripts.scheduler"] = {register = function() end, after = function() end}
    local cmd = require("scripts.command")
    local destroyed = 0
    local function mark() return {valid = true, destroy = function() destroyed = destroyed + 1 end} end
    storage.command = {selection = {[1] = {7, 9}, [2] = {7}},
      markers = {[1] = {mark()}, [2] = {mark()}},
      owner = {[7] = 1, [9] = 2}, leased = {[7] = true, [9] = true}}
    storage.unit_state = {[7] = {colony_id = 1}, [9] = {colony_id = 1}}
    storage.colonies = {[1] = {colonists = {[7] = {valid = true, surface = {}},
      [9] = {valid = true, surface = {}}}}}
    cmd.died(7)
    eq(table.concat(storage.command.selection[1], ","), "9")
    eq(table.concat(storage.command.selection[2], ","), "")
    eq(storage.command.owner[7], nil)
    eq(storage.command.leased[7], nil)
    eq(storage.command.owner[9], 2)
    eq(storage.command.leased[9], true)
    eq(destroyed, 2, "both players had their old circles cleared")
    eq(#storage.command.markers[1], 1, "player 1's surviving unit is redrawn")
    eq(#storage.command.markers[2], 0, "player 2 keeps an empty selection")
  end)
end)

-- Re-review regression: construct.finish used to guard only on st.job == "construct". A lease preserves the
-- job, so a 30-tick timer scheduled before the order fired on the commanded state and reassigned the colonist.
describe("construct.finish vs a live lease (#58 re-review)", function()
  it("a stale 30-tick build timer cannot overwrite a commanded state", function()
    local mock = require("tests.mock_factorio")
    local env = mock.install(); env = env.reset()
    local handlers = {}
    package.loaded["scripts.scheduler"] = {
      register = function(name, fn) handlers[name] = fn end,
      after = function() end, at = function() end,
    }
    require("scripts.work")
    storage.colonies, storage.unit_state = {}, {}
    -- A live-looking colony so an unguarded handler actually reaches its `state = "idle"` write.
    storage.colonies[1] = {hall = {valid = true}, colonists = {[7] = {valid = true}}, claimed = {}}
    storage.unit_state[7] = {colony_id = 1, job = "construct", state = "commanded", until_tick = 9999}
    local finish = handlers["construct.finish"]
    truthy(finish, "construct.finish registered")
    -- pcall keeps a mock-only error from masking the state assertion: the unguarded handler writes idle
    -- before it reaches work's colony_mod calls, so the assertion below is the real mutation guard.
    pcall(finish, {un = 7})
    eq(storage.unit_state[7].state, "commanded", "stale timer must not end the lease")
    eq(storage.unit_state[7].job, "construct")
    eq(storage.unit_state[7].until_tick, 9999, "lease must remain live")
  end)
end)
