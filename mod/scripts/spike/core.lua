-- Spike framework. Each spike registers {issue, desc, usage, run(ctx)}.
-- In game:   /spike list | /spike run <name> [args...] | /spike all
-- Output:    chat + <factorio user dir>/script-output/colony-spikes/<name>.txt (written incrementally)
-- Headless:  scripts/headless-spike.sh generates an `autorun.lua` (see bottom) so no player is needed.
-- API errors inside a spike are caught and reported as findings ([ERR]) - an API mismatch is a result.
local events = require("scripts.events")

local core = {specs = {}, order = {}}
local pending = {}   -- tick -> { {fn, ctx} } ; module-local on purpose (spikes are dev-only, not save-safe)

local function mkprof()
  if helpers and helpers.create_profiler then return helpers.create_profiler() end
  return game.create_profiler()
end
core.mkprof = mkprof

function core.register(name, spec)
  spec.name = name
  core.specs[name] = spec
  table.insert(core.order, name)
end

local function out_path(name) return "colony-spikes/" .. name .. ".txt" end

local function make_ctx(spec, player, args)
  local ctx = {
    name = spec.name, player = player, args = args or {},
    surface = player and player.surface or game.surfaces[1],
    position = player and {x = math.floor(player.position.x), y = math.floor(player.position.y)} or {x = 0, y = 0},
    pass = 0, fail = 0, unknown = 0, errors = 0,
  }
  local pidx = player and player.index or 0
  local function write(line, append)
    local ok, err = pcall(function()
      if pidx and pidx > 0 then
        helpers.write_file(out_path(spec.name), type(line) == "string" and (line .. "\n") or {"", line, "\n"}, append, pidx)
      else
        helpers.write_file(out_path(spec.name), type(line) == "string" and (line .. "\n") or {"", line, "\n"}, append)
      end
    end)
    if not ok then log("[spike:write_err] " .. tostring(err)) end
  end
  write("# spike " .. spec.name .. " (issue #" .. tostring(spec.issue) .. ") tick " .. game.tick, false)

  function ctx.log(...)
    local parts = {...}
    local line
    if #parts == 1 and type(parts[1]) == "table" then line = parts[1]
    else
      for i, p in ipairs(parts) do parts[i] = tostring(p) end
      line = table.concat(parts, " ")
    end
    write(line, true)
    game.print(type(line) == "string" and ("[spike:" .. spec.name .. "] " .. line) or {"", "[spike:" .. spec.name .. "] ", line})
  end
  function ctx.check(label, ok, detail)
    local tag
    if ok == nil then tag = "[????]"; ctx.unknown = ctx.unknown + 1
    elseif ok then tag = "[PASS]"; ctx.pass = ctx.pass + 1
    else tag = "[FAIL]"; ctx.fail = ctx.fail + 1 end
    ctx.log(tag, label, detail and ("- " .. tostring(detail)) or "")
  end
  -- Run fn under pcall; log result or error. Returns ok, result.
  function ctx.probe(label, fn)
    local ok, res = pcall(fn)
    if ok then ctx.log("[OK ]", label, "->", tostring(res))
    else ctx.errors = ctx.errors + 1; ctx.log("[ERR]", label, "->", tostring(res)) end
    return ok, res
  end
  function ctx.profile(label, fn, reps)
    reps = reps or 1
    local p = mkprof()
    for _ = 1, reps do fn() end
    p.stop(); p.divide(reps)
    ctx.log({"", "[PROF] ", label, " avg of ", reps, ": ", p})
  end
  function ctx.after(ticks, fn)
    local t = game.tick + ticks
    pending[t] = pending[t] or {}
    table.insert(pending[t], {fn = fn, ctx = ctx})
  end
  -- Make a flat, empty, powered-friendly test area around ctx.position.
  function ctx.flat_area(radius, tile)
    local s, p = ctx.surface, ctx.position
    s.request_to_generate_chunks(p, math.ceil(radius / 32) + 1)
    s.force_generate_chunk_requests()
    local area = {{p.x - radius, p.y - radius}, {p.x + radius, p.y + radius}}
    for _, e in pairs(s.find_entities_filtered{area = area}) do
      if e.type ~= "character" and e.valid then e.destroy() end
    end
    local tiles = {}
    for x = p.x - radius, p.x + radius do
      for y = p.y - radius, p.y + radius do tiles[#tiles + 1] = {name = tile or "refined-concrete", position = {x, y}} end
    end
    s.set_tiles(tiles, true)
  end
  -- Place an eei + medium pole so machines placed within ~3 tiles of `pos` are powered.
  function ctx.power_at(pos)
    local s = ctx.surface
    local eei = s.create_entity{name = "electric-energy-interface", position = {pos.x, pos.y - 4}, force = "player"}
    if eei then eei.power_production = 5e6 / 60; eei.electric_buffer_size = 5e6 end
    s.create_entity{name = "medium-electric-pole", position = {pos.x + 2.5, pos.y - 2.5}, force = "player"}
    return eei
  end
  function ctx.finish()
    ctx.log(string.format("SUMMARY pass=%d fail=%d unknown=%d errors=%d", ctx.pass, ctx.fail, ctx.unknown, ctx.errors))
  end
  return ctx
end

function core.run(name, player, args)
  local spec = core.specs[name]
  if not spec then game.print("unknown spike: " .. tostring(name)) return end
  local ctx = make_ctx(spec, player, args)
  ctx.log("start; args=" .. table.concat(ctx.args, ","))
  local ok, err = pcall(spec.run, ctx)
  if not ok then ctx.errors = ctx.errors + 1; ctx.log("[ERR] spike crashed:", tostring(err)) end
  return ctx
end

events.on(defines.events.on_tick, function(ev)
  local b = pending[ev.tick]
  if not b then return end
  pending[ev.tick] = nil
  for _, item in ipairs(b) do
    local ok, err = pcall(item.fn)
    if not ok then item.ctx.errors = item.ctx.errors + 1; item.ctx.log("[ERR] deferred step crashed:", tostring(err)) end
  end
end)

commands.add_command("spike", "list | run <name> [args] | all", function(cmd)
  local player = cmd.player_index and game.get_player(cmd.player_index) or nil
  local words = {}
  for w in (cmd.parameter or "list"):gmatch("%S+") do words[#words + 1] = w end
  local sub = table.remove(words, 1) or "list"
  if sub == "list" then
    for _, n in ipairs(core.order) do
      local sp = core.specs[n]
      game.print(string.format("%s (#%s): %s | usage: %s", n, tostring(sp.issue), sp.desc, sp.usage or ""))
    end
  elseif sub == "run" then
    core.run(table.remove(words, 1), player, words)
  elseif sub == "all" then
    for _, n in ipairs(core.order) do if core.specs[n].auto then core.run(n, player, {}) end end
  end
end)

-- Headless autorun: scripts/headless-spike.sh writes mod/autorun.lua returning {{"s01_units","50","30"}, ...}
local ok, autorun = pcall(require, "autorun")
if ok and type(autorun) == "table" then
  events.on(defines.events.on_tick, function(ev)
    if ev.tick == 120 then
      for _, a in ipairs(autorun) do
        local name = table.remove(a, 1)
        core.run(name, nil, a)
      end
    end
  end)
end

-- Headless post-load tests: scripts/save-load.sh runs `--test-save <save> --test-arg <spike>` and the mod
-- runs that one spike on the first tick after the save loads. `script.test_arg` is only set by the CLI, so
-- normal games and the autorun above never see it.
local test_arg = script and script.test_arg
if test_arg and test_arg ~= "" then
  local fired = false
  events.on(defines.events.on_tick, function()
    if fired then return end
    fired = true
    core.run(test_arg, nil, {})
  end)
end

return core
