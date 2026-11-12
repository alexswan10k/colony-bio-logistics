-- M2 colony ledger spike (#92): the colony's own inventory, published onto the circuit network.
-- A 1x1 constant combinator the colony writes every 60 ticks: stock on hand, or the shortfall against the
-- town's quotas, as ordinary item signals a belt/inserter/pump can read. The engine questions (sections,
-- `min` as the wire value, wiring from Lua, stale-slot clearing) are answered by s14_circuit; this spike is
-- the feature: registration, the publish pass, both modes, the caps, blueprint tags and teardown.
-- The colony is deliberately empty of houses, food and jobs, so nothing in it consumes the stock and every
-- count on the wire can be compared exactly.
-- Run: TICKS=2400 scripts/headless-spike.sh m2_ledger
local core = require("scripts.spike.core")
local colony = require("scripts.colony")
local ledger_signal = require("scripts.ledger_signal")
local labour = require("scripts.model.labour")
local territory = require("scripts.territory")

local CFG = defines.wire_connector_id.circuit_green
local TAG = "colony-bio-logistics"

local function wire(a, b)
  local ca = a.get_wire_connector(CFG, true)
  local cb = b.get_wire_connector(CFG, true)
  if not (ca and cb) then return false end
  return ca.connect_to(cb) == true     -- LuaWireConnector methods are bound: no `:`
end

core.register("m2_ledger", {
  issue = 92, auto = true,
  desc = "colony ledger: publishes stock/shortfall as item signals, sections + caps, tags, teardown",
  usage = "",
  run = function(ctx)
    local s, p = ctx.surface, ctx.position
    ctx.flat_area(40, "refined-concrete")
    s.always_day, s.freeze_daytime, s.daytime = true, true, 0
    storage.interval_override = 150
    local function build(name, pos)
      return s.create_entity{name = name, position = pos, force = "player", raise_built = true}
    end

    -- ---------- the prototype (runtime prototypes expose only part of the data stage, so the technology
    -- is checked on the force, where prerequisites and research state are real) ----------
    ctx.check("colony-ledger is a constant combinator", prototypes.entity["colony-ledger"] ~= nil
      and prototypes.entity["colony-ledger"].type == "constant-combinator",
      prototypes.entity["colony-ledger"] and prototypes.entity["colony-ledger"].type)
    ctx.check("it has an item", prototypes.item["colony-ledger"] ~= nil)
    ctx.check("it has a recipe", prototypes.recipe["colony-ledger"] ~= nil)
    local tech = game.forces.player.technologies["colony-ledger"]
    -- LuaTechnology.prerequisites is a name-keyed dictionary, not an array.
    local prereqs = tech and tech.prerequisites or {}
    local names = {}
    for name in pairs(prereqs) do names[#names + 1] = name end
    table.sort(names)
    ctx.check("its tech needs the vanilla circuit network", prereqs["circuit-network"] ~= nil,
      table.concat(names, ","))
    ctx.check("it is researched, not free", tech ~= nil and tech.researched == false and tech.enabled == true)
    ctx.check("nobody works it", labour.HUTS["colony-ledger"] == nil)
    -- The panel (gui.open_ledger) anchors to the vanilla combinator GUI; a typo there is a nil index at
    -- open time, which headless cannot exercise but this can.
    ctx.check("the panel's relative GUI anchor exists",
      defines.relative_gui_type.constant_combinator_gui ~= nil)

    -- ---------- the colony ----------
    local hall = build("colony-town-hall", {p.x, p.y})
    local c
    for _, col in pairs(storage.colonies) do c = col end
    ctx.check("colony registered", c ~= nil and hall ~= nil and hall.valid)
    if not c then return ctx.finish() end
    c.accept_migrants = false
    local inv = hall.get_inventory(defines.inventory.chest)
    local function hall_count(item)
      return hall.get_item_count(item)
    end
    ctx.check("ores fit in the hall", hall.insert{name = "iron-ore", count = 400} == 400
      and hall.insert{name = "copper-ore", count = 200} == 200
      and hall.insert{name = "stone", count = 50} == 50
      and hall.insert{name = "colony-frontier-pack", count = 7} == 7,
      "iron=" .. hall_count("iron-ore") .. " copper=" .. hall_count("copper-ore")
        .. " stone=" .. hall_count("stone") .. " packs=" .. hall_count("colony-frontier-pack"))

    local led = build("colony-ledger", {p.x + 6, p.y})
    ctx.check("ledger built inside territory", led ~= nil and led.valid)
    if not (led and led.valid) then return ctx.finish() end
    ctx.check("ledger is on colony land", territory.owner_at(c.surface_index, led.position) == c.id)
    local rec = c.ledgers and c.ledgers[led.unit_number]
    ctx.check("ledger registered with the colony", rec ~= nil and rec.entity == led)
    if not rec then return ctx.finish() end
    ctx.check("registered in stock mode", rec.mode == "stock", tostring(rec.mode))
    ctx.check("the publish timer is armed", c.ledger_timer == true)

    local pole = build("medium-electric-pole", {p.x + 10, p.y})
    ctx.check("wired to a pole from Lua", pole ~= nil and wire(led, pole))
    local net = pole and pole.get_circuit_network(CFG)
    ctx.check("a circuit network is readable", net ~= nil)
    local function sig(name)
      return net and net.get_signal{type = "item", name = name} or -1
    end
    local function signal_count()
      local n = 0
      if net and net.signals then for _ in ipairs(net.signals) do n = n + 1 end end
      return n
    end

    ctx.after(4, function()
      -- Publishing happens on the build tick; the wire reads it on the next one.
      ctx.check("stock mode publishes the hall's iron ore", sig("iron-ore") == hall_count("iron-ore"),
        "wire=" .. sig("iron-ore") .. " hall=" .. hall_count("iron-ore"))
      ctx.check("... copper ore too", sig("copper-ore") == 200, "copper-ore=" .. sig("copper-ore"))
      ctx.check("... and stone", sig("stone") == 50, "stone=" .. sig("stone"))
      ctx.check("a colony item (Frontier Charter) is a normal signal too", sig("colony-frontier-pack") == 7,
        "packs=" .. sig("colony-frontier-pack"))
      ctx.check("empty tracked items are not published (no zero slots)",
        sig("colony-basket") == 0 and sig("coal") == 0)
      ctx.check("the wire carries one signal per published item", signal_count() == #rec.published,
        signal_count() .. " vs " .. #rec.published)
      ctx.check("the ledger agrees with the hall ledger snapshot", (function()
        for _, row in ipairs(colony.ledger_snapshot(c).items) do
          if row.item == "iron-ore" then return row.total == sig("iron-ore") end
        end
        return false
      end)())

      -- ---------- the pass follows the stock ----------
      hall.insert{name = "iron-ore", count = 1000}
      inv.remove{name = "copper-ore", count = 200}
      inv.remove{name = "stone", count = 50}
      ctx.after(70, function()
        ctx.check("a delivery reaches the wire on the next pass", sig("iron-ore") == hall_count("iron-ore"),
          "wire=" .. sig("iron-ore") .. " hall=" .. hall_count("iron-ore"))
        ctx.check("an item that left the colony stops being published", sig("copper-ore") == 0,
          "copper-ore=" .. sig("copper-ore"))
        -- The stale-slot bug a naive implementation has: the slot is reused or left behind and the wire
        -- keeps reading the old number. Replacing the whole filter array clears it.
        ctx.check("... and its stale signal is cleared, not left at the old value", sig("stone") == 0,
          "stone=" .. sig("stone"))

        -- ---------- shortfall mode ----------
        -- The player's own number: a quota set on the town, not the 20-item default.
        hall.insert{name = "wood", count = 100}
        colony.set_quota(c, "wood", 300)
        local wood_target = colony.quota_target(c, "wood")
        local iron_target = colony.quota_target(c, "iron-ore")
        ctx.check("wood has a quota target to fall short of", wood_target > 100, "target=" .. tostring(wood_target))
        ctx.check("want mode switches the wire at once", ledger_signal.set_mode(c, rec, "want") == true)
        ctx.after(70, function()
          ctx.check("a short stock publishes exactly the shortfall", sig("wood") == wood_target - hall_count("wood"),
            "wood=" .. sig("wood") .. " target=" .. wood_target .. " stock=" .. hall_count("wood"))
          ctx.check("a stock at or above its quota publishes nothing", iron_target <= hall_count("iron-ore")
            and sig("iron-ore") == 0, "iron=" .. sig("iron-ore") .. " target=" .. iron_target)
          ctx.check("want mode publishes wants, not counts", sig("colony-frontier-pack") == 0,
            "packs=" .. sig("colony-frontier-pack") .. " (packs have no quota)")

          -- ---------- sections and the cap ----------
          ledger_signal.set_mode(c, rec, "stock")
          local warehouse = build("colony-warehouse", {p.x - 8, p.y + 4})
          ctx.check("warehouse built for bulk stock", warehouse ~= nil and warehouse.valid)
          local spare = {"iron-plate", "copper-plate", "steel-plate", "iron-gear-wheel", "copper-cable",
            "electronic-circuit", "advanced-circuit", "processing-unit", "battery", "engine-unit", "pipe",
            "iron-stick", "stone-brick", "concrete", "rail", "beacon", "speed-module", "grenade",
            "firearm-magazine", "piercing-rounds-magazine", "light-armor", "solar-panel", "accumulator",
            "inserter", "transport-belt", "underground-belt", "splitter", "small-electric-pole",
            "medium-electric-pole", "substation", "construction-robot", "logistic-robot", "roboport", "radar",
            "lab", "assembling-machine-1", "stone-furnace", "boiler", "steam-engine", "offshore-pump",
            "oil-refinery", "chemical-plant", "storage-tank", "pump", "plastic-bar", "sulfur", "explosives"}
          local added = 0
          if warehouse and warehouse.valid then
            for _, name in ipairs(spare) do
              if prototypes.item[name] and warehouse.insert{name = name, count = 1} == 1 then added = added + 1 end
            end
          end
          ctx.log("[INFO] distinct warehouse items inserted:", added)
          ctx.after(70, function()
            local behavior = led.get_or_create_control_behavior()
            ctx.check("more than 20 tracked items use more than one section", behavior.sections_count >= 2,
              "sections=" .. behavior.sections_count .. " distinct=" .. tostring(added + 5))
            ctx.check("the publication cap holds the list at two sections", #rec.published == 40, #rec.published)
            ctx.check("... and the wire really carries 40 signals", signal_count() == 40, signal_count())
            ctx.check("the biggest stock is the one that survives the cap", sig("iron-ore") == hall_count("iron-ore"),
              "iron-ore=" .. sig("iron-ore") .. " hall=" .. hall_count("iron-ore"))

            -- ---------- self-healing: a player edit or a disabled combinator does not win ----------
            local behavior2 = led.get_or_create_control_behavior()
            behavior2.get_section(1).filters =
              {{value = {type = "item", name = "coal", quality = "normal"}, min = 999}}
            behavior2.enabled = false
            ctx.after(70, function()
              ctx.check("a hand-written filter is overwritten by the next pass", sig("coal") ~= 999,
                "coal=" .. tostring(sig("coal")))
              ctx.check("a disabled ledger turns itself back on",
                led.get_or_create_control_behavior().enabled == true)

              -- ---------- blueprints and copy-paste ----------
              ledger_signal.set_mode(c, rec, "want")
              local dict = colony.entity_tags(led)
              local payload = dict and dict[TAG]
              ctx.check("the mode rides in the blueprint tags", payload ~= nil and payload.ledger == true
                and payload.mode == "want", payload and tostring(payload.mode))
              local ghost = s.create_entity{name = "entity-ghost", inner_name = "colony-ledger",
                position = {p.x + 2, p.y - 3}, force = "player"}
              if ghost and ghost.valid then
                colony.apply_tags(c, ghost, dict)
                local gtags = ghost.tags and ghost.tags[TAG]
                ctx.check("a ghost restores the mode from its tags", gtags ~= nil and gtags.mode == "want",
                  gtags and tostring(gtags.mode))
                ghost.destroy()
              else
                ctx.check("a ghost could be created for the tag test", false)
              end
              local copy = build("colony-ledger", {p.x + 6, p.y + 4})
              if copy and copy.valid then
                colony.copy_settings(led, copy)
                local crec = c.ledgers[copy.unit_number]
                ctx.check("copy-paste carries the mode to a new ledger", crec ~= nil and crec.mode == "want",
                  crec and tostring(crec.mode))
                copy.destroy()
              else
                ctx.check("a second ledger could be placed", false)
              end
              ledger_signal.set_mode(c, rec, "stock")

              -- ---------- outside territory is refused, like every other colony building ----------
              local outside = build("colony-ledger", {p.x + 90, p.y + 90})
              ctx.check("a ledger outside territory is refused", outside == nil or not outside.valid)
              ctx.check("... and is refunded as a spilled item, not swallowed",
                #s.find_entities_filtered{type = "item-entity",
                  area = {{p.x + 80, p.y + 80}, {p.x + 100, p.y + 100}}} > 0)
              ctx.check("the colony's own ledger is untouched", led.valid and c.ledgers[led.unit_number] ~= nil)

              -- ---------- cost ----------
              ctx.profile("publish a capped 40-signal ledger", function() ledger_signal.publish_one(c, rec) end, 20)

              -- ---------- teardown ----------
              local un = led.unit_number
              led.destroy()
              -- The engine raises on_object_destroyed on the next tick, not inside destroy().
              ctx.after(2, function()
                ctx.check("destroying the ledger drops its record", c.ledgers[un] == nil)
                ctx.after(80, function()
                  ctx.check("the publish timer stops when the last ledger is gone", c.ledger_timer == nil,
                    tostring(c.ledger_timer))
                  ctx.finish()
                end)
              end)
            end)
          end)
        end)
      end)
    end)
  end,
})
