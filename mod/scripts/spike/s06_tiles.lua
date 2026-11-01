-- SPIKE #6: Terrain queries: tile prototype data (fertility?), scan cost for farms/scenic/forest.
-- /spike run s06_tiles [radius=32]   (stand somewhere representative: coast + forest ideal)
local core = require("scripts.spike.core")

core.register("s06_tiles", {
  issue = 6, auto = true, desc = "tile props + scan cost", usage = "[radius=32]",
  run = function(ctx)
    local r = tonumber(ctx.args[1]) or 32
    local s, p = ctx.surface, ctx.position
    local n, water = 0, {}
    local fields = {"fertility", "walking_speed_modifier", "collision_mask", "autoplace_specification", "fluid", "effect_color", "map_color"}
    local probed = {}
    for name, proto in pairs(prototypes.tile) do
      n = n + 1
      for _, f in ipairs(fields) do
        if probed[f] == nil then
          local ok = pcall(function() return proto[f] end)
          probed[f] = ok
        end
      end
      local ok, layers = pcall(function() return proto.collision_mask.layers end)
      if ok and layers and (layers["water_tile"]) then water[#water + 1] = name end
    end
    ctx.log("tile prototypes:", n)
    for f, ok in pairs(probed) do ctx.log("LuaTilePrototype." .. f .. " accessible:", ok) end
    ctx.check("native tile fertility property exists", probed.fertility == true,
      probed.fertility and "yes" or "no -> need our own tile->fertility lookup table")
    ctx.log("water-layer tiles:", table.concat(water, ","))
    -- dump all tile names to the report so the lookup table can be built
    local names = {}
    for name in pairs(prototypes.tile) do names[#names + 1] = name end
    table.sort(names)
    ctx.log("ALL TILES:", table.concat(names, ","))

    s.request_to_generate_chunks(p, math.ceil(r / 32) + 1); s.force_generate_chunk_requests()
    local area = {{p.x - r, p.y - r}, {p.x + r, p.y + r}}
    ctx.profile("count_tiles_filtered(water_tile)", function() local _ = s.count_tiles_filtered{area = area, collision_mask = "water_tile"} end, 50)
    ctx.profile("count_entities_filtered(tree)", function() local _ = s.count_entities_filtered{area = area, type = "tree"} end, 50)
    ctx.profile("find_entities_filtered(tree)", function() local _ = s.find_entities_filtered{area = area, type = "tree"} end, 50)
    ctx.profile("find_tiles_filtered(all)", function() local _ = s.find_tiles_filtered{area = area} end, 10)
    ctx.profile("get_tile loop over area", function()
      for x = p.x - r, p.x + r do for y = p.y - r, p.y + r do local _ = s.get_tile(x, y).name end end
    end, 3)
    ctx.log("water tiles:", s.count_tiles_filtered{area = area, collision_mask = "water_tile"},
      "trees:", s.count_entities_filtered{area = area, type = "tree"})
    ctx.log("Budget guidance: a scenic/fertility recompute should be amortised over many ticks; use the cheapest of the above.")
    ctx.finish()
  end,
})
