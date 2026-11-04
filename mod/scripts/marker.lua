-- Colony logistics marker (#35): a selection tool that opts machines into colony supply in one drag.
-- Left-drag = opt in, alt-drag = opt out. Only machines with a supply panel, inside colony territory.
local events = require("scripts.events")
local territory = require("scripts.territory")
local colony = require("scripts.colony")
local gui = require("scripts.gui")
local labour = require("scripts.model.labour")
local M = {}

M.TOOL = "colony-logistics-marker"

local function apply(ev, enable)
  if ev.item ~= M.TOOL then return end
  local player = game.get_player(ev.player_index)
  if not player then return end
  local n, unset = 0, 0
  for _, e in ipairs(ev.entities or {}) do
    if e.valid then
      local id = territory.owner_at(e.surface.index, e.position)
      local col = id and storage.colonies[id]
      if col then
        if gui.MACHINE_GUIS[e.type] then
          local m = colony.set_machine(col, e, enable)
          n = n + 1
          if enable and m and next(m.requests) == nil then unset = unset + 1 end
        elseif colony.HOUSES[e.name] and col.houses and col.houses[e.unit_number] then
          col.houses[e.unit_number].logistics_enabled = enable
          n = n + 1
        elseif labour.HUTS[e.name] and col.huts and col.huts[e.unit_number] then
          col.huts[e.unit_number].logistics_enabled = enable
          n = n + 1
        elseif colony.CRATES[e.name] and col.crates and col.crates[e.unit_number] then
          col.crates[e.unit_number].logistics_enabled = enable
          n = n + 1
        end
      end
    end
  end
  local pos = ev.area and ev.area.left_top or player.position
  if n == 0 then
    player.create_local_flying_text{text = {"colony-message.marker-none"}, position = pos}
  else
    player.create_local_flying_text{
      text = {enable and "colony-message.marker-on" or "colony-message.marker-off", n}, position = pos}
    if unset > 0 then
      player.create_local_flying_text{text = {"colony-message.marker-unset", unset},
        position = {x = pos.x, y = pos.y + 1}}
    end
  end
end

events.on(defines.events.on_player_selected_area, function(ev) apply(ev, true) end)
events.on(defines.events.on_player_alt_selected_area, function(ev) apply(ev, false) end)

return M
