-- SPIKE #92: Colony ledger on the circuit network.
-- /spike run s14_circuit
-- Questions (all about the *engine*, so the spike uses a vanilla constant combinator, not our entity):
-- 1. Can Lua write a constant combinator's signals in 2.1? (`LuaLogisticSection.filters` is documented RW,
--    `parameters` is gone - sections replaced it.)
-- 2. Which filter field reaches the wire: `min` or `max`?
-- 3. Does replacing the filter array clear stale signals (so a shrinking ledger does not lie)?
-- 4. Do two sections sum onto one network, and can a section be removed from Lua?
-- 5. Can a wire be made from Lua (LuaWireConnector.connect_to) in headless, and read back
--    (LuaCircuitNetwork.get_signal)?
-- 6. When do written values reach the network (same tick or next tick)? `signals` is documented "last tick".
-- 7. How many filters does a section take, and what does a 20-signal write pass cost?
local core = require("scripts.spike.core")

local CFG = defines.wire_connector_id.circuit_green

local function read(net, name)
  if not net then return "no-net" end
  return net.get_signal{type = "item", name = name}
end

local function count(list, name)
  local n = 0
  if not list then return -1 end
  for _, s in ipairs(list) do n = n + 1 end
  return n
end

core.register("s14_circuit", {
  issue = 92, auto = true,
  desc = "constant-combinator write-back: section filters, signal semantics, Lua wiring, timing, cost",
  usage = "",
  run = function(ctx)
    ctx.flat_area(12)
    local s, p = ctx.surface, ctx.position
    local f = game.forces.player
    local cc = s.create_entity{name = "constant-combinator", position = p, force = f}
    local pole = s.create_entity{name = "medium-electric-pole", position = {p.x + 2.5, p.y}, force = f}
    ctx.check("spike entities placed", cc ~= nil and pole ~= nil)

    -- The prototype we clone: which fields does a 2.1 constant combinator actually carry?
    ctx.probe("constant-combinator prototype keys", function()
      local e = prototypes.entity["constant-combinator"]
      local keys = {}
      for _, k in ipairs({"sprites", "activity_led_sprites", "activity_led_light", "activity_led_light_offsets",
        "circuit_wire_max_distance", "item_slot_count", "collision_box", "selection_box", "max_health",
        "flags", "minable", "placeable_by", "corpse"}) do
        local ok, v = pcall(function() return e[k] end)
        keys[#keys + 1] = k .. "=" .. (ok and tostring(v ~= nil) or "ERR")
      end
      return table.concat(keys, " ")
    end)

    -- The whole feature rides on this object.
    local behavior
    ctx.probe("get_or_create_control_behavior", function()
      behavior = cc.get_or_create_control_behavior()
      return tostring(behavior)
    end)
    ctx.check("control behavior exists", behavior ~= nil)
    if not behavior then ctx.finish() return end
    ctx.check("add_section is a method", type(behavior.add_section) == "function")
    local ok_legacy, legacy = pcall(function() return behavior.parameters end)
    ctx.check("`parameters` is gone (2.1 uses sections)", not ok_legacy or legacy == nil,
      "ok=" .. tostring(ok_legacy) .. " value=" .. tostring(legacy))
    -- A fresh constant combinator already carries one section in 2.1, so the ledger adopts section 1
    -- instead of adding its own.
    ctx.check("a fresh combinator already has a section", behavior.sections_count == 1,
      "sections_count=" .. tostring(behavior.sections_count))

    -- Wiring from Lua: if this does not work headless, the spike cannot read what it wrote.
    local cc_conn, pole_conn
    ctx.probe("wire connectors", function()
      cc_conn = cc.get_wire_connector(CFG, true)
      pole_conn = pole.get_wire_connector(CFG, true)
      return tostring(cc_conn) .. " / " .. tostring(pole_conn)
    end)
    ctx.check("both connectors exist", cc_conn ~= nil and pole_conn ~= nil)
    -- 2.1 userdata: LuaWireConnector methods are *bound*, so `.` is the call form and `:` passes the
    -- connector as the first argument (it fails with "bool expected, got userdata" - found on the first run).
    local ok_wire, wired = ctx.probe("connect (bound method)", function() return cc_conn.connect_to(pole_conn) end)
    ctx.check("wired from Lua", ok_wire and wired == true, tostring(wired))
    ctx.probe("is_connected_to (dot)", function() return cc_conn.is_connected_to(pole_conn) end)
    ctx.check("connected afterwards", cc_conn.is_connected_to(pole_conn) == true)
    local net = pole.get_circuit_network(CFG)
    ctx.check("pole reads a circuit network", net ~= nil, "net=" .. tostring(net))

    -- Step 1: one section, three signals. iron-plate carries `min`; copper-plate carries only `max`
    -- (to learn which field the wire actually reads); colony-axe proves a mod item maps to a signal.
    local sec
    ctx.probe("get_section(1) or add_section()", function()
      sec = behavior.get_section(1) or behavior.add_section()
      return tostring(sec)
    end)
    ctx.check("section 1 available", sec ~= nil)
    if not sec then ctx.finish() return end
    ctx.check("sections_count == 1", behavior.sections_count == 1, tostring(behavior.sections_count))
    ctx.check("filters start empty", sec.filters ~= nil and count(sec.filters) == 0, "n=" .. tostring(count(sec.filters)))
    local ok_set, err_set = pcall(function()
      sec.filters = {
        {value = {type = "item", name = "iron-plate", quality = "normal"}, min = 42},
        {value = {type = "item", name = "copper-plate", quality = "normal"}, max = 7},
        {value = {type = "item", name = "colony-axe", quality = "normal"}, min = 3},
      }
    end)
    ctx.check("filters array is writable", ok_set, tostring(err_set))
    ctx.check("filters read back", count(sec.filters) == 3, "n=" .. tostring(count(sec.filters)))
    ctx.probe("filter 1 read-back", function()
      local fl = sec.filters[1]
      return "name=" .. tostring(fl.value and fl.value.name) .. " min=" .. tostring(fl.min) .. " max=" .. tostring(fl.max)
    end)
    ctx.check("same-tick network is still empty (signals are 'last tick')",
      read(net, "iron-plate") == 0, "iron-plate=" .. tostring(read(net, "iron-plate")))

    ctx.after(3, function()
      ctx.check("min reaches the wire", read(net, "iron-plate") == 42, "iron=" .. tostring(read(net, "iron-plate")))
      ctx.check("max alone does NOT reach the wire", read(net, "copper-plate") == 0,
        "copper=" .. tostring(read(net, "copper-plate")))
      ctx.check("a mod item emits a normal item signal", read(net, "colony-axe") == 3,
        "colony-axe=" .. tostring(read(net, "colony-axe")))
      ctx.check("network.signals lists 2 signals", count(net.signals) == 2, "n=" .. tostring(count(net.signals)))

      -- Step 2: shrink the array. A shrinking ledger must not leave stale signals on the wire.
      sec.filters = {{value = {type = "item", name = "coal", quality = "normal"}, min = 5}}
      ctx.after(3, function()
        ctx.check("replaced array emits the new signal", read(net, "coal") == 5, "coal=" .. tostring(read(net, "coal")))
        ctx.check("stale iron-plate cleared", read(net, "iron-plate") == 0,
          "iron=" .. tostring(read(net, "iron-plate")))
        ctx.check("stale colony-axe cleared", read(net, "colony-axe") == 0,
          "colony-axe=" .. tostring(read(net, "colony-axe")))

        -- Step 3: sections sum onto one network (this is what lets a big ledger use more than one section).
        local sec2
        ctx.probe("add section 2", function() sec2 = behavior.add_section() return tostring(sec2) end)
        ctx.log("[INFO] sections after add:", tostring(behavior.sections_count))
        if sec2 then
          sec2.filters = {{value = {type = "item", name = "wood", quality = "normal"}, min = 9}}
          ctx.check("sections_count == 2", behavior.sections_count == 2, tostring(behavior.sections_count))
          ctx.after(3, function()
            ctx.check("second section emits too", read(net, "wood") == 9, "wood=" .. tostring(read(net, "wood")))
            ctx.check("first section still emits", read(net, "coal") == 5, "coal=" .. tostring(read(net, "coal")))

            -- Step 4: clear a section (a ledger with fewer items than before) and remove a section.
            sec.filters = {}
            ctx.after(3, function()
              ctx.check("cleared section stops emitting", read(net, "coal") == 0,
                "coal=" .. tostring(read(net, "coal")))
              ctx.check("other section unaffected", read(net, "wood") == 9, "wood=" .. tostring(read(net, "wood")))
              local ok_rm, rm = ctx.probe("remove_section(1)", function() return behavior.remove_section(1) end)
              ctx.check("remove_section works", ok_rm and rm == true, tostring(rm))
              ctx.after(3, function()
                -- Section 1 was empty when it was removed, so its signals (coal) stay gone and the
              -- remaining section (wood) is renumbered to 1 but keeps emitting.
              ctx.check("removing an empty section leaves the other section emitting", read(net, "wood") == 9,
                "wood=" .. tostring(read(net, "wood")))
              ctx.check("removed section signals stay gone", read(net, "coal") == 0,
                "coal=" .. tostring(read(net, "coal")))
              ctx.check("one section left", behavior.sections_count == 1,
                "sections_count=" .. tostring(behavior.sections_count))

                -- Step 5: capacity and value limits, so the model knows what it can publish.
                local section = behavior.get_section(1)
                if not section then section = behavior.add_section() end
                local many = {}
                for i = 1, 30 do
                  many[i] = {value = {type = "item", name = "iron-ore", quality = "normal"},
                             min = i, max = i}
                end
                -- Distinct items, not 30 copies of one: duplicates would sum, which is legal but useless here.
                local names = {"iron-ore", "copper-ore", "coal", "stone", "wood", "iron-plate", "copper-plate",
                  "steel-plate", "electronic-circuit", "advanced-circuit", "processing-unit", "battery"}
                local many2 = {}
                for i = 1, 30 do
                  local nm = names[(i - 1) % #names + 1]
                  many2[i] = {value = {type = "item", name = nm, quality = "normal"}, min = i}
                end
                local ok_many = pcall(function() section.filters = many2 end)
                ctx.log("[INFO] 30-filter write accepted:", tostring(ok_many),
                  "read back n=" .. tostring(count(section.filters)))
                local ok_big = pcall(function()
                  section.filters = {{value = {type = "item", name = "iron-ore", quality = "normal"}, min = 2000000000}}
                end)
                ctx.log("[INFO] int32-scale value accepted:", tostring(ok_big))
                local ok_over = pcall(function()
                  section.filters = {{value = {type = "item", name = "iron-ore", quality = "normal"}, min = 3000000000}}
                end)
                ctx.log("[INFO] >int32 value accepted:", tostring(ok_over))
                ctx.after(3, function()
                  ctx.log("[INFO] after 30-filter write the wire carries: iron-ore=" .. tostring(read(net, "iron-ore")))

                  -- Step 6: what a real publish pass costs (per ledger entity, per update).
                  local csv = {
                    {value = {type = "item", name = "iron-plate", quality = "normal"}, min = 1234},
                    {value = {type = "item", name = "copper-plate", quality = "normal"}, min = 2345},
                  }
                  local full = {}
                  for i = 1, 20 do
                    full[i] = {value = {type = "item", name = names[(i - 1) % #names + 1], quality = "normal"},
                               min = i * 10}
                  end
                  ctx.profile("write 20 filters", function() section.filters = full end, 200)
                  ctx.profile("clear filters", function() section.filters = {} end, 200)
                  ctx.profile("read back 20 filters", function()
                    local n = 0
                    for _, fl in ipairs(section.filters) do n = n + 1 end
                    return n
                  end, 200)
                  ctx.log("If PASS: the ledger publishes with `min` in section filters, replaces the whole array")
                  ctx.log("each pass (no stale signals), and can use several sections if 20 is not enough.")
                  ctx.finish()
                end)
              end)
            end)
          end)
        else
          ctx.log("[INFO] a second section could not be added: single-section publishing only")
          ctx.finish()
        end
      end)
    end)
  end,
})
