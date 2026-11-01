-- Event multiplexer: Factorio allows ONE handler per event via script.on_event; this lets many modules subscribe.
-- Must be called at load time (top level of a module), never lazily, so it's identical on every load.
local M = {}
local handlers = {}
local init_fns, config_fns = {}, {}

function M.on(event, fn)
  if not handlers[event] then
    handlers[event] = {}
    script.on_event(event, function(ev)
      for _, h in ipairs(handlers[event]) do h(ev) end
    end)
  end
  table.insert(handlers[event], fn)
end

function M.on_init(fn) table.insert(init_fns, fn) end
function M.on_configuration_changed(fn) table.insert(config_fns, fn) end

script.on_init(function() for _, f in ipairs(init_fns) do f() end end)
script.on_configuration_changed(function(d) for _, f in ipairs(config_fns) do f(d) end end)

return M
