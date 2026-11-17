-- Command Whistle (#58, design §7.2). Our own selection-tool item and two rebindable custom inputs;
-- no vanilla prototype is edited. Left-drag selects colonists, right-click orders the selection, X stops it.
-- Alt-drag / shift-right-drag / alt-shift-right-drag are the gesture fallback if a mouse-button input conflicts
-- with the player's controls (they raise the same on_player_*_selected_area family as the logistics marker).
local G = "__colony-bio-logistics__/graphics/"

local function mode(colour)
  return {
    mode = {"any-entity", "same-force"},
    entity_filters = {"colony-colonist"}, entity_type_filters = {"unit"}, entity_filter_mode = "whitelist",
    cursor_box_type = "entity", border_color = colour, draw_selection_counts = true,
  }
end

data:extend({
  {
    type = "selection-tool", name = "colony-command-whistle",
    icon = G .. "icon-town-hall.png", icon_size = 64,
    localised_name = {"item-name.colony-command-whistle"},
    localised_description = {"item-description.colony-command-whistle"},
    subgroup = "tool", order = "z[colony]-h[whistle]", stack_size = 1,
    flags = {"not-stackable", "spawnable"},
    mouse_cursor = "selection-tool-cursor", send_pre_selection_events = false,
    select = mode({0.2, 0.9, 0.3}),            -- left-drag: set the selection
    alt_select = mode({0.3, 0.6, 1.0}),        -- alt-drag: Move to the area centre
    reverse_select = mode({1.0, 0.65, 0.2}),   -- shift+right-drag: Attack-Move to the area centre
    alt_reverse_select = mode({1.0, 0.25, 0.25}), -- alt+shift+right-drag: Stop/release
  },
  -- cursor_position on a CustomInputEvent is the world point under the mouse, so a plain button press is a
  -- usable order target. The event is global, so the adapter guards on in_gui, cursor stack and selection.
  {
    type = "custom-input", name = "colony-command-order",
    key_sequence = "mouse-button-2", action = "lua", consuming = "none",
    enabled = true, include_selected_prototype = false,
    localised_name = {"input-name.colony-command-order"},
  },
  {
    type = "custom-input", name = "colony-command-stop",
    key_sequence = "X", alternative_key_sequence = "mouse-button-3", action = "lua", consuming = "none",
    enabled = true, include_selected_prototype = false,
    localised_name = {"input-name.colony-command-stop"},
  },
  {
    type = "recipe", name = "colony-command-whistle",
    ingredients = {{type = "item", name = "iron-plate", amount = 2},
      {type = "item", name = "wood", amount = 1}},
    results = {{type = "item", name = "colony-command-whistle", amount = 1}},
    energy_required = 1, categories = {"crafting"}, enabled = false,
    subgroup = "tool", order = "z[colony]-h[whistle]",
    localised_name = {"recipe-name.colony-command-whistle"},
  },
})
