-- Dev/testing helpers, so later stages can be reached quickly. All are chat commands:
--   /colony-kit [full]   starter set; `full` = every colony building (x10) and item
--   /colony-unlock       research every colony technology
--   /colony-stock [n]    pour n (default 200) of every colony item + basic materials into the nearest colony's stock
--   /colony-pop [n]      add n (default 10) colonists to the nearest colony
--   /colony-speed [x]    game speed (default 1; try 5-10 to watch things grow)
--   /colony-status       population, housing, stock and desirability of the nearest colony
local colony_mod = require("scripts.colony")

local KIT = {
  ["colony-town-hall"] = 1, ["colony-housing-tent"] = 4,
  ["colony-forager-hut"] = 1, ["colony-woodcutter-hut"] = 1, ["colony-miner-hut"] = 1,
  ["colony-toolsmith"] = 1, ["colony-compost-bin"] = 1, ["colony-supply-crate"] = 2,
  ["colony-logistics-marker"] = 1,
  ["colony-basket"] = 2, ["colony-axe"] = 2, ["colony-pickaxe"] = 2,
  ["colony-forage"] = 30,
  ["wood"] = 100, ["stone"] = 50, ["iron-plate"] = 20,
}
local BASICS = {wood = 1, ["stone-brick"] = 1, ["iron-plate"] = 1, ["copper-plate"] = 1, coal = 1, stone = 1,
  ["repair-pack"] = 1, ["small-electric-pole"] = 1, ["iron-ore"] = 1, ["copper-ore"] = 1}

local function player_of(cmd) return cmd.player_index and game.get_player(cmd.player_index) end

local function colony_items()
  local out = {}
  for name, proto in pairs(prototypes.item) do
    if name:find("^colony%-") then out[#out + 1] = {name = name, building = proto.place_result ~= nil, stack = proto.stack_size} end
  end
  table.sort(out, function(a, b) return a.name < b.name end)   -- pairs order is not stable
  return out
end

local function nearest_colony(player)
  local best, best_d
  for _, c in pairs(storage.colonies or {}) do
    if c.surface_index == player.surface.index and c.hall and c.hall.valid then
      local dx, dy = c.hall.position.x - player.position.x, c.hall.position.y - player.position.y
      local d = dx * dx + dy * dy
      if not best_d or d < best_d then best, best_d = c, d end
    end
  end
  return best
end

local function with_colony(cmd, fn)
  local p = player_of(cmd)
  if not p then return end
  local c = nearest_colony(p)
  if not c then p.print("No colony on this surface yet: build a Town Hall first."); return end
  fn(p, c)
end

commands.add_command("colony-kit", "[full] Give a starter set of colony buildings, tools and materials.", function(cmd)
  local player = player_of(cmd)
  if not player then return end
  if cmd.parameter == "full" then
    for _, it in ipairs(colony_items()) do
      player.insert{name = it.name, count = it.building and 10 or math.min(it.stack, 100)}
    end
    for item in pairs(BASICS) do player.insert{name = item, count = 200} end
    player.print("Full colony kit added (10 of every building, stacks of every item).")
    return
  end
  for item, n in pairs(KIT) do player.insert{name = item, count = n} end
  player.print("Colony starter kit added.")
end)

commands.add_command("colony-unlock", "Research every colony technology.", function(cmd)
  local p = player_of(cmd)
  if not p then return end
  local n = 0
  for name, tech in pairs(p.force.technologies) do
    if name:find("^colony%-") and not tech.researched then tech.researched = true; n = n + 1 end
  end
  p.print("Researched " .. n .. " colony technologies.")
end)

commands.add_command("colony-stock", "[n] Add n of every colony item and basic materials to the nearest colony's stock.", function(cmd)
  with_colony(cmd, function(p, c)
    local n = tonumber(cmd.parameter) or 200
    local put = 0
    for _, it in ipairs(colony_items()) do
      if not it.building then put = put + colony_mod.put_stock(c, it.name, n) end
    end
    for item in pairs(BASICS) do put = put + colony_mod.put_stock(c, item, n) end
    p.print("Added " .. put .. " items to the colony stock (hall and warehouses; the rest did not fit).")
  end)
end)

commands.add_command("colony-pop", "[n] Add n colonists to the nearest colony.", function(cmd)
  with_colony(cmd, function(p, c)
    local n, made = tonumber(cmd.parameter) or 10, 0
    for _ = 1, n do if colony_mod.spawn_colonist(c) then made = made + 1 end end
    p.print("Added " .. made .. " colonists (population " .. colony_mod.live_colonists(c) .. ").")
  end)
end)

commands.add_command("colony-speed", "[x] Set game speed (default 1).", function(cmd)
  local x = tonumber(cmd.parameter) or 1
  game.speed = math.max(0.1, math.min(x, 100))
  game.print("Game speed " .. game.speed)
end)

commands.add_command("colony-status", "Population, housing, stock and desirability of the nearest colony.", function(cmd)
  with_colony(cmd, function(p, c)
    local s = colony_mod.stats(c)
    p.print(string.format("pop %d/%d  food %d (target %d)  desirability %.1f  tents %d cabins %d homesteads %d apartments %d  huts %d towers %d crates %d machines %d",
      s.pop, s.capacity, s.food, s.food_target, s.d, s.tents, s.cabins, s.homesteads, s.apartments, s.huts, s.towers, s.crates, s.machines))
  end)
end)
