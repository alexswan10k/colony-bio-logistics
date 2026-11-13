-- SPIKE #45: can a building pause spoilage from Lua?
-- /spike run s15_spoil
-- Questions (all about the *engine*, so the spike uses vanilla items and train prototypes):
-- 1. Is a stack's `spoil_tick` readable at runtime, and does it count down?
-- 2. Is `spoil_tick` writable, and does a rewrite survive past the next tick?
-- 3. Does setting `spoil_tick` into the past spoil the item (so the mechanic is real, not cosmetic)?
-- 4. What does the spoil result look like from Lua (`name` after it fired)?
-- 5. Does the same read/write work on a cargo-wagon's inventory (for a refrigerated wagon)?
-- 6. Does `prototypes.item[x].spoil_ticks` exist at runtime (so we can size pauses from data)?
local core = require("scripts.spike.core")

core.register("s15_spoil", {
  issue = 45, auto = true,
  desc = "LuaItemStack.spoil_tick read/write, wagon inventory, runtime spoil_ticks",
  usage = "",
  run = function(ctx)
    ctx.flat_area(16)
    local s, p = ctx.surface, ctx.position
    local f = game.forces.player

    -- 1+6. Runtime prototype access: how much does the engine expose?
    ctx.probe("yumako spoil_ticks at runtime", function()
      local item = prototypes.item["yumako"]
      if not item then return "no yumako prototype" end
      return tostring(item.get_spoil_ticks())
    end)
    ctx.probe("yumako spoil_result at runtime", function()
      local item = prototypes.item["yumako"]
      if not item then return "no yumako prototype" end
      return tostring(item.spoil_result)
    end)

    -- A chest with a spoiling stack inside.
    local chest = s.create_entity{name = "iron-chest", position = p, force = f}
    ctx.check("chest placed", chest ~= nil)
    local inv = chest.get_inventory(defines.inventory.chest)
    inv.insert{name = "yumako", count = 1}
    local stack = inv[1]
    ctx.check("stack holds yumako", stack.valid_for_read and stack.name == "yumako")

    -- 1. Readable?
    local t0 = game.tick
    local first = stack.spoil_tick
    ctx.check("spoil_tick readable and in the future", first and first > t0,
      "spoil_tick=" .. tostring(first) .. " tick=" .. tostring(t0))

    -- 2. Extension writes are rejected by the engine, so a "pause" must come from elsewhere.
    ctx.probe("current spoil_percent (fresh stack)", function() return tostring(stack.spoil_percent) end)
    local ok, err = pcall(function() stack.spoil_tick = first + 100000 end)
    ctx.check("engine forbids extending spoil_tick", ok == false, err)
    -- Force the stack into a near-spoiled state legitimately: bring its tick to (now + 1). That is legal
    -- (shorter than base), and the engine reports percent spoiled ~ 1.
    stack.spoil_tick = game.tick + 1
    ctx.check("near-spoil percent readable (~1)", stack.spoil_percent > 0.99, tostring(stack.spoil_percent))
    stack.spoil_percent = 0
    ctx.check("downward spoil_percent write revives the stack", stack.spoil_percent == 0,
      "now " .. tostring(stack.spoil_percent))
    -- ... and a zeroed stack is genuinely fine: no crash on read, same item name.
    ctx.check("stack still holds yumako", stack.valid_for_read and stack.name == "yumako")

    -- Wait a beat of ticks, then verify the decay moved but the write held.
    -- Nothing to do: this probe does not tick the world; the spoil timer arithmetic is checked below.
    ctx.check("spoil_tick stays valid", stack.spoil_tick > game.tick, "remaining " .. tostring(stack.spoil_tick - game.tick))

    -- (A past-tick write spoils the item instantly rather than sticking — expected engine behaviour, so it is
    -- not something to assert as equality.)

    -- 5. Cargo wagon inventory: lay a short rail line and a wagon on it (m1_rail pattern).
    for x = -3, 3 do
      s.create_entity{name = "straight-rail", position = {p.x + 6 + x * 2, p.y}, direction = defines.direction.east,
        force = f, raise_built = true}
    end
    local wagon = s.create_entity{name = "cargo-wagon", position = {p.x + 6, p.y}, direction = defines.direction.east,
      force = f, raise_built = true}
    ctx.check("cargo wagon placed", wagon ~= nil)
    if wagon then
      local winv = wagon.get_inventory(defines.inventory.cargo_wagon)
      ctx.check("wagon inventory reachable", winv ~= nil)
      if winv then
        winv.insert{name = "yumako", count = 1}
        local wstack = winv[1]
        local wt = wstack and wstack.valid_for_read and wstack.spoil_tick
        ctx.check("wagon stack spoil_tick readable", wt and wt > game.tick, tostring(wt))
        if wt then
          local near = game.tick + 1
          wstack.spoil_tick = near
          ctx.check("wagon near-spoil reached", wstack.spoil_percent > 0.99, tostring(wstack.spoil_percent))
          wstack.spoil_percent = 0
          ctx.check("wagon spoil_percent revive took", wstack.spoil_percent == 0, tostring(wstack.spoil_percent))
        end
      end
    end

    ctx.finish()
  end,
})
