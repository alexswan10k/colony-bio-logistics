-- SPIKE #58: Command Whistle engine facts (RTS orders on colonist units).
-- /spike run s18_command
-- Headless has no player, so input gestures are labelled [needs in-game]; everything a spawned unit or a
-- prototype can prove is labelled [engine] / [proto] and actually executed on this 2.1 build.
-- Questions:
--  1. Does `set_command` on a colonist replace a parked `stop` (guards/sleepers use a huge stop)?
--  2. Does `go_to_location` converge and fire on_ai_command_completed with a usable result?
--  3. What does `attack_area` do with an enemy nearby: does it complete, get distracted, kill the target?
--  4. Is there an `attack_move` command (there is not, per docs - assert it here)?
--  5. Are compound commands accepted, and can `destructible=false` units be ordered?
--  6. Do group members still fire per-unit completion events, and is set_multi_command force-wide?
--  7. Do custom-input `cursor_position` / selected-area events reach a Lua handler (shape only headless)?
--  8. Is a label preserved across a command, and what does 200 set_commands cost?
local core = require("scripts.spike.core")
local events = require("scripts.events")
local scheduler = require("scripts.scheduler")
local construct = require("scripts.model.construct")
local command_adapter = require("scripts.command")

local S   -- module-local spike state; not save-safe on purpose (dev-only)

-- Load-time handlers: these see BOTH real engine events and anything script.raise_event synthesised here.
events.on(defines.events.on_ai_command_completed, function(ev)
  if not S then return end
  local rec = S.units[ev.unit_number]
  if not rec then return end
  rec.completions = rec.completions + 1
  rec.last = {result = tostring(ev.result), distracted = tostring(ev.was_distracted), tick = ev.tick}
  S.results[rec.last.result] = (S.results[rec.last.result] or 0) + 1
end)

events.on("colony-command-order", function(ev)
  if not S then return end
  S.custom = {
    player_index = ev.player_index, input_name = ev.input_name, in_gui = tostring(ev.in_gui),
    cursor = ev.cursor_position and {x = ev.cursor_position.x, y = ev.cursor_position.y} or nil,
  }
end)

events.on(defines.events.on_player_selected_area, function(ev)
  if not S then return end
  S.area = {item = ev.item, player_index = ev.player_index, n = #(ev.entities or {}),
    area = ev.area and {ev.area.left_top.x, ev.area.left_top.y, ev.area.right_bottom.x, ev.area.right_bottom.y} or nil}
end)

local function pos(e)
  if not (e and e.valid) then return "gone" end
  return string.format("%.2f,%.2f", e.position.x, e.position.y)
end

local function ctype(e)
  if not e then return "none" end
  -- A LuaCommandable (unit group) has no `.commandable` field; it owns `.command` directly.
  local ok, c = pcall(function()
    if e.commandable then return e.commandable.command end
    return e.command
  end)
  if not ok or not c then return "none" end
  return tostring(c.type)
end

core.register("s18_command", {
  issue = 58, auto = false,
  desc = "command whistle: set_command, attack_area, unit groups, input-event shapes, prototypes",
  usage = "",
  run = function(ctx)
    ctx.flat_area(18)
    local s, p, f = ctx.surface, ctx.position, game.forces.player
    S = {units = {}, results = {}, ctx = ctx, custom = nil, area = nil}
    local function spawn(dx, dy)
      local e = s.create_entity{name = "colony-colonist", position = {x = p.x + dx, y = p.y + dy}, force = f}
      if not e then return nil end
      S.units[e.unit_number] = {entity = e, completions = 0, last = nil}
      return e
    end
    local u1, u2, u3 = spawn(-10, 0), spawn(-10, 3), spawn(8, 0)
    local u4, u5, u6, u7 = spawn(-8, 6), spawn(-8, -6), spawn(0, 8), spawn(3, 8)
    ctx.check("colonists spawned for command probes", #S.units >= 7, tostring(#S.units) .. " units")

    -- [proto] The tool and the custom inputs must load on this build before any adapter can rely on them.
    local item = prototypes.item["colony-command-whistle"]
    ctx.check("[proto] whistle exists", item ~= nil)
    ctx.check("[proto] whistle is a selection-tool", item ~= nil and item.type == "selection-tool")
    ctx.probe("[proto] selection-tool fields visible at runtime", function()
      if not item then return "no whistle" end
      local ok, err = pcall(function() return item.select end)
      return ok and "select exposed" or ("NOT exposed at runtime (" .. tostring(err)
        .. ") - select filters are data-stage only; the game loading proves the shape is valid")
    end)
    local cin = prototypes.custom_input["colony-command-order"]
    local cstop = prototypes.custom_input["colony-command-stop"]
    ctx.check("[proto] order custom-input exists", cin ~= nil)
    ctx.check("[proto] stop custom-input exists", cstop ~= nil)
    ctx.probe("[proto] custom-input key sequences", function()
      return "order=" .. tostring(cin and cin.key_sequence) .. " stop=" .. tostring(cstop and cstop.key_sequence)
        .. " action=" .. tostring(cin and cin.action)
    end)
    ctx.check("[proto] no defines.command.attack_move (use attack_area)", defines.command.attack_move == nil,
      "attack_move=" .. tostring(defines.command.attack_move) .. " attack_area=" .. tostring(defines.command.attack_area))

    -- [input shape] Headless cannot press a mouse button, but a synthetic raise reaches the same handlers.
    ctx.probe("[input] synthetic custom input raise", function()
      local ok, err = pcall(script.raise_event, "colony-command-order", {player_index = 1,
        input_name = "colony-command-order", cursor_position = {x = p.x + 3.5, y = p.y - 2.5}, in_gui = false})
      return ok and "raised" or ("NOT raiseable: " .. tostring(err))
    end)
    ctx.probe("[input] synthetic selected-area raise", function()
      local ok, err = pcall(script.raise_event, defines.events.on_player_selected_area, {player_index = 1,
        item = "colony-command-whistle", surface = s,
        entities = u1 and {u1} or {}, area = {{p.x - 1, p.y - 1}, {p.x + 1, p.y + 1}}})
      return ok and "raised" or ("NOT raiseable: " .. tostring(err))
    end)

    -- [engine] A colonist carries a label; an order must not clear it.
    local label
    if u1 then
      label = rendering.draw_text{text = "⚑ probe", surface = s, target = {entity = u1, offset = {0, -1.4}},
        color = {1, 1, 1}, scale = 0.7, only_in_alt_mode = false}
    end

    -- 1) go_to_location from a standing start.
    if u1 then
      u1.commandable.set_command{type = defines.command.go_to_location, destination = {x = p.x + 8, y = p.y},
        radius = 1.5, distraction = defines.distraction.none}
      S.at_start_1 = pos(u1)
    end
    -- 2) stop -> override. Work.lua parks guards/truck drivers/sleepers under exactly this huge stop.
    if u2 then
      u2.commandable.set_command{type = defines.command.stop, ticks_to_wait = 4294967295,
        distraction = defines.distraction.none}
      S.stop_readback = ctype(u2)
      u2.commandable.set_command{type = defines.command.go_to_location, destination = {x = p.x - 8, y = p.y},
        radius = 1.5, distraction = defines.distraction.none}
      S.override_readback = ctype(u2)
    end
    -- 3) attack_area with an enemy unit nearby. Record whether it completes while the enemy lives.
    local biter = s.create_entity{name = "small-biter", position = {x = p.x + 13, y = p.y}, force = "enemy"}
    S.biter = biter
    if u3 then
      u3.commandable.set_command{type = defines.command.attack_area, destination = {x = p.x + 10, y = p.y},
        radius = 8, distraction = defines.distraction.by_enemy}
      S.attack_area_readback = ctype(u3)
    end
    -- 4) compound and 5) destructible=false are prepared now, issued in phase 1.
    if u6 then u6.destructible = false end

    ctx.log("commands issued at " .. pos(u1) .. " / biter " .. pos(biter) .. "; running 360 ticks")
    ctx.after(360, function()
      -- Move convergence and completion event.
      ctx.check("[engine] go_to_location moved the colonist", math.abs(u1.position.x - (p.x + 8)) <= 2,
        "start=" .. tostring(S.at_start_1) .. " now=" .. pos(u1))
      local r1 = S.units[u1.unit_number]
      ctx.check("[engine] completion event fired for the mover", r1.completions > 0,
        "n=" .. r1.completions .. " last=" .. tostring(r1.last and r1.last.result))
      ctx.check("[engine] completion result is success", r1.last and r1.last.result == tostring(defines.behavior_result.success),
        tostring(r1.last and r1.last.result) .. " distracted=" .. tostring(r1.last and r1.last.distracted))
      ctx.check("[engine] stop replaced by go_to_location", S.stop_readback == tostring(defines.command.stop)
        and S.override_readback == tostring(defines.command.go_to_location),
        "before=" .. tostring(S.stop_readback) .. " after=" .. tostring(S.override_readback))
      ctx.check("[engine] overridden stop colonist also moved", math.abs(u2.position.x - (p.x - 8)) <= 2, pos(u2))
      ctx.check("[engine] label survived set_command", label and label.valid and label.text == "⚑ probe",
        "valid=" .. tostring(label and label.valid) .. " text=" .. tostring(label and label.text))
      -- attack_area observation (a finding, not a pass/fail judgement).
      local r3 = S.units[u3.unit_number]
      ctx.log("[engine] attack_area: type=" .. tostring(S.attack_area_readback) .. " at=" .. pos(u3)
        .. " completions=" .. r3.completions .. " last=" .. tostring(r3.last and r3.last.result)
        .. " biter_hp=" .. tostring(biter and biter.valid and biter.health or "dead"))
      ctx.check("[engine] attack_area did not destroy the colonist outright", u3.valid, pos(u3))
      ctx.probe("[engine] compound command accepted", function()
        u5.commandable.set_command{type = defines.command.compound,
          structure_type = defines.compound_command.logical_or,
          commands = {{type = defines.command.go_to_location, destination = {x = p.x + 6, y = p.y - 4},
            radius = 1.5, distraction = defines.distraction.none},
            {type = defines.command.attack_area, destination = {x = p.x + 10, y = p.y}, radius = 8,
              distraction = defines.distraction.by_enemy}}}
        return ctype(u5)
      end)
      S.u5_type = ctype(u5)
      -- [engine] direct attack target, then a destructible=false move. A fresh biter: attack_area's target
      -- may already be dead by now, which would make this test vacuous.
      local biter2 = s.create_entity{name = "small-biter", position = {x = p.x - 12, y = p.y + 6}, force = "enemy"}
      if biter2 and biter2.valid then
        u4.commandable.set_command{type = defines.command.attack, target = biter2,
          distraction = defines.distraction.none}
      end
      S.biter_hp_before = biter2 and biter2.valid and biter2.health or 0
      S.biter2 = biter2
      u6.commandable.set_command{type = defines.command.go_to_location, destination = {x = p.x - 6, y = p.y + 10},
        radius = 1.5, distraction = defines.distraction.none}
      S.u6_type = ctype(u6)
      -- Unit group: does a grouped unit still report per-unit completion?
      local group = s.create_unit_group{position = p, force = f}
      group.add_member(u7)
      group.set_command{type = defines.command.go_to_location, destination = {x = p.x + 6, y = p.y + 8},
        radius = 2, distraction = defines.distraction.none}
      S.group = group
      S.group_sent_at = game.tick

      ctx.after(360, function()
        -- [engine] direct attack result.
        ctx.log("[engine] attack target: biter_hp " .. tostring(S.biter_hp_before) .. " -> "
          .. tostring(S.biter2 and S.biter2.valid and S.biter2.health or "dead")
          .. " colonist=" .. pos(u4) .. " completions=" .. S.units[u4.unit_number].completions
          .. " last=" .. tostring(S.units[u4.unit_number].last and S.units[u4.unit_number].last.result))
        ctx.check("[engine] compound command readback", S.u5_type == tostring(defines.command.compound)
          or ctype(u5) == tostring(defines.command.compound), "now=" .. ctype(u5))
        ctx.check("[engine] destructible=false unit accepted a command", S.u6_type == tostring(defines.command.go_to_location)
          and u6.valid and u6.destructible == false,
          "type=" .. tostring(S.u6_type) .. " destructible=" .. tostring(u6.valid and u6.destructible))
        ctx.check("[engine] destructible=false unit moved", math.abs(u6.position.x - p.x) >= 4
          and math.abs(u6.position.y - (p.y + 10)) <= 3, pos(u6))
        local r7 = S.units[u7.unit_number]
        ctx.log("[engine] unit group: member completions=" .. r7.completions .. " at=" .. pos(u7)
          .. " group_type=" .. tostring(S.group and S.group.valid and ctype(S.group)))
        ctx.check("[engine] unit groups suppress per-unit completion (use per-unit commands)", r7.completions == 0,
          "n=" .. r7.completions .. " at=" .. pos(u7))
        -- set_multi_command on three fresh units (force-wide, not a selection). A bare `stop` is rejected
        -- ("command has no destination") - this API wants a movement-style command; pin that too.
        spawn(-6, 12); spawn(-4, 12); spawn(-2, 12)
        local ok_stop, stop_err = pcall(s.set_multi_command, {command = {type = defines.command.stop,
          ticks_to_wait = 4294967295, distraction = defines.distraction.none},
          unit_count = 3, force = f, unit_search_distance = 40})
        ctx.log("[engine] set_multi_command with stop: " .. (ok_stop and "accepted" or ("rejected: " .. tostring(stop_err))))
        local ok_multi, n = ctx.probe("[engine] set_multi_command count with go_to_location", function()
          return s.set_multi_command{command = {type = defines.command.go_to_location,
            destination = {x = p.x + 12, y = p.y + 12}, radius = 1.5, distraction = defines.distraction.none},
            unit_count = 3, force = f, unit_search_distance = 40}
        end)
        ctx.check("[engine] set_multi_command is broad (not a selection)", ok_multi and type(n) == "number" and n >= 1,
          "count=" .. tostring(n))
        -- Input events cannot be raised from Lua in 2.1 (see probes above), so their payload shapes are a
        -- [needs in-game] finding, not a headless check. The handlers are registered and are proven by the
        -- existing marker tool for selected-area; CustomInputEvent.cursor_position is documented.
        ctx.log("[needs in-game] custom-input cursor_position / selected-area payload: real mouse input only; "
          .. "synthetic raises are rejected by the engine")
        ctx.log("[needs in-game] real right-click vs vanilla rotate/selection, GUI-click fix, and single-click zero-area selection")

        -- [integrated] Regression for the review's item-loss finding: work.lua credits a hunt kill to
        -- st.carry whenever job == "hunt", even while state == "commanded". Build a minimal real colony
        -- with a hall, credit meat to a commanded hunter, release the lease, and assert the hall got it.
        local cid = 9001
        local hall = s.create_entity{name = "colony-town-hall", position = {x = p.x + 14, y = p.y + 12}, force = f}
        local hunter = spawn(14, 9)
        if hall and hunter then
          storage.colonies[cid] = {id = cid, surface_index = s.index, hall = hall,
            colonists = {[hunter.unit_number] = hunter}, houses = {}, huts = {}, crates = {}, bins = {},
            claimed = {}, storage_priority = 3, alarms = {}, machines = {}, towers = {}, pools = {}}
          local hun = hunter.unit_number
          storage.unit_state[hun] = {colony_id = cid, job = "hunt", state = "commanded",
            carry = {{item = "colony-meat", count = 3}}, until_tick = game.tick + 3600}
          storage.command.leased[hun] = true
          storage.command.owner[hun] = 1
          local before = hall.get_item_count("colony-meat")
          command_adapter.release_lease(hun, false)
          ctx.check("[integrated] kill credit from a commanded hunter reached the hall",
            hall.get_item_count("colony-meat") - before == 3,
            "before=" .. before .. " after=" .. hall.get_item_count("colony-meat"))
          ctx.check("[integrated] lease release left a clean idle state",
            storage.unit_state[hun].state == "idle" and storage.unit_state[hun].carry == nil
            and storage.command.leased[hun] == nil and storage.command.owner[hun] == nil)
          -- Keep the scheduled command.reassign harmless: work.assign returns early with no colonist here.
          storage.colonies[cid].colonists[hun] = nil
          storage.unit_state[hun] = nil
        else
          ctx.check("[integrated] hall and hunter for the carry regression spawned", false)
        end

        -- [integrated] Re-review: a lease that starts inside construct.WORK_TICKS (30) after a builder
        -- entered "building". Case 1 releases the lease immediately: build materials and the site claim
        -- must be returned to the hall/registry, and the ghost must stay an unrevived ghost. Case 2 keeps
        -- the lease live until the stale timer fires and must still be "commanded" afterwards.
        local bld, bld2 = spawn(15, 11), spawn(16, 12)
        if bld and bld2 and storage.colonies[cid] then
          local c2, b1, b2 = storage.colonies[cid], bld.unit_number, bld2.unit_number
          c2.colonists[b1], c2.colonists[b2] = bld, bld2
          local ghost = s.create_entity{name = "entity-ghost", inner_name = "colony-housing-tent",
            position = {x = p.x + 17, y = p.y + 12}, force = "player"}
          local site_key = "ghost:" .. tostring(b1)
          c2.claimed[site_key] = true
          local wood_before = hall.get_item_count("wood")
          storage.unit_state[b1] = {colony_id = cid, job = "construct", state = "commanded",
            carry = {{item = "wood", count = 2}}, site = ghost, site_key = site_key, kind = "build",
            until_tick = game.tick + 3600, lease_owner = 1}
          storage.command.leased[b1], storage.command.owner[b1] = true, 1
          command_adapter.release_lease(b1, false)
          ctx.check("[integrated] order during build window returns materials and clears the claim",
            c2.claimed[site_key] == nil and hall.get_item_count("wood") - wood_before == 2,
            "claim=" .. tostring(c2.claimed[site_key]) .. " wood=" .. (hall.get_item_count("wood") - wood_before))
          c2.colonists[b1], storage.unit_state[b1] = nil, nil   -- keep the +1 reassign a no-op

          storage.unit_state[b2] = {colony_id = cid, job = "construct", state = "commanded",
            until_tick = game.tick + 3600, lease_owner = 1}
          storage.command.leased[b2], storage.command.owner[b2] = true, 1
          scheduler.after(construct.WORK_TICKS, "construct.finish", {un = b2})
          ctx.after(construct.WORK_TICKS + 10, function()
            ctx.check("[integrated] stale construct.finish timer did not end the lease",
              storage.unit_state[b2] and storage.unit_state[b2].state == "commanded"
              and storage.command.leased[b2] == true,
              "state=" .. tostring(storage.unit_state[b2] and storage.unit_state[b2].state))
            ctx.check("[integrated] ghost not half-built and no claim left",
              ghost and ghost.valid and c2.claimed[site_key] == nil)
            command_adapter.release_lease(b2, true)
            c2.colonists[b2], storage.unit_state[b2] = nil, nil
          end)
        else
          ctx.check("[integrated] builders for the construct-window regression spawned", false)
        end

        -- Cost: 200 set_commands on one unit, averaged over 20 passes.
        ctx.profile("set_command x 200", function()
          for i = 1, 200 do
            u1.commandable.set_command{type = defines.command.go_to_location,
              destination = {x = p.x + (i % 2 == 0 and 8 or -8), y = p.y}, radius = 1.5,
              distraction = defines.distraction.none}
          end
        end, 20)
        local results = {}
        for k, v in pairs(S.results) do results[#results + 1] = k .. "=" .. v end
        table.sort(results)
        ctx.log("completion results: " .. table.concat(results, " "))
        -- The stale-timer checks above are deferred; finish after them so the SUMMARY counts them too.
        ctx.after(construct.WORK_TICKS + 20, function() ctx.finish() end)
      end)
    end)
  end,
})
