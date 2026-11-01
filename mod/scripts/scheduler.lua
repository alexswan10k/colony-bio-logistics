-- Tick-bucket scheduler: avoids per-tick polling. Handlers are registered by name at load time;
-- storage holds only {handler name, data}.
local events = require("scripts.events")
local M = {}
local registry = {}

function M.register(name, fn) registry[name] = fn end

function M.at(tick, name, data)
  storage.scheduled[tick] = storage.scheduled[tick] or {}
  table.insert(storage.scheduled[tick], {handler = name, data = data})
end

function M.after(delta, name, data) M.at(game.tick + delta, name, data) end

events.on(defines.events.on_tick, function(ev)
  local bucket = storage.scheduled and storage.scheduled[ev.tick]
  if not bucket then return end
  storage.scheduled[ev.tick] = nil
  for _, job in ipairs(bucket) do
    local fn = registry[job.handler]
    if fn then fn(job.data) end
  end
end)

return M
