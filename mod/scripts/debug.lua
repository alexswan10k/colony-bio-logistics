-- Dev/testing helper: /colony-kit gives a starter set of colony items to the calling player.
local KIT = {
  ["colony-town-hall"] = 1, ["colony-housing-tent"] = 3, ["colony-housing-cabin"] = 2,
  ["colony-forager-hut"] = 1, ["colony-woodcutter-hut"] = 1, ["colony-miner-hut"] = 1,
  ["colony-hunting-lodge"] = 1, ["colony-fishing-dock"] = 1, ["colony-compost-bin"] = 1,
  ["colony-basket"] = 5, ["colony-axe"] = 10, ["colony-pickaxe"] = 10, ["colony-rifle"] = 5, ["colony-rod"] = 5,
  ["wood"] = 200, ["iron-plate"] = 200, ["stone-brick"] = 50,
  ["raw-fish"] = 50, ["small-electric-pole"] = 10,
}
commands.add_command("colony-kit", "Give a starter set of colony buildings, tools and materials.", function(cmd)
  local player = cmd.player_index and game.get_player(cmd.player_index)
  if not player then return end
  for item, n in pairs(KIT) do player.insert{name = item, count = n} end
  player.print("Colony starter kit added.")
end)
