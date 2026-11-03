-- Minimal Factorio API mock for running the real glue modules (events, scheduler, store, territory) under plain Lua.
-- Usage: local env = require("tests.mock_factorio").install()  ; env.fire(defines.events.on_tick, {tick=1}) ; env.reset()
local M = {}

function M.install()
  local env = {handlers = {}}
  _G.storage = {}
  _G.game = {tick = 0, print = function() end, get_player = function() end}
  _G.rendering = {
    draw_rectangle = function() return {valid = true, destroy = function() end} end,
    draw_circle = function() return {valid = true, destroy = function() end} end,
    draw_text = function() return {valid = true, destroy = function() end} end,
    draw_sprite = function() return {valid = true, destroy = function() end} end,
    destroy = function() end,
  }
  _G.prototypes = {technology = {}, item = {}}
  _G.defines = {
    events = setmetatable({}, {__index = function(t, k) local v = #t + 1000 + (rawlen and 0 or 0); rawset(t, k, k); return k end}),
    entity_status_diode = {green = 1, red = 2},
    relative_gui_type = {container_gui = 1},
    relative_gui_position = {right = 1},
    gui_type = {entity = 1},
    alert_type = {custom = 1},
    inventory = {chest = 1},
  }
  _G.log = function() end
  _G.script = {
    on_event = function(ev, fn) env.handlers[ev] = fn end,
    on_init = function(fn) env.on_init = fn end,
    on_configuration_changed = function(fn) env.on_cfg = fn end,
    register_on_object_destroyed = function() end,
  }
  function env.fire(ev, data) if env.handlers[ev] then env.handlers[ev](data or {}) end end
  function env.tick(n) for _ = 1, n or 1 do game.tick = game.tick + 1; env.fire("on_tick", {tick = game.tick}) end end
  function env.reset()
    for k in pairs(package.loaded) do if k:match("^scripts%.") then package.loaded[k] = nil end end
    return M.install()
  end
  _G.table_size = function(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end
  return env
end

return M
