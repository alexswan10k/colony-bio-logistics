-- SPIKE #7: Territory placement restrictions (cancel + refund) incl. ghosts / robots / script, and overlay rendering.
-- /spike run s07_territory     -> automated script-raised tests + arms interactive enforcement
-- Interactive: after running, hand-place a stone-furnace INSIDE (3x3 chunks around you) and OUTSIDE, also via blueprint ghost and with construction robots.
local core = require("scripts.spike.core")
local events = require("scripts.events")
local territory = require("scripts.territory")

local RESTRICTED = {["stone-furnace"] = true}
local S

local function handle(ev, source)
  if not (S and S.armed) then return end
  local e = ev.entity or ev.created_entity
  if not (e and e.valid) then return end
  local name = e.type == "entity-ghost" and e.ghost_name or e.name
  if not RESTRICTED[name] then return end
  local owner = territory.owner_at(e.surface.index, e.position)
  if owner then S.ctx.log(source .. ": " .. name .. " allowed (colony " .. owner .. ")"); return end
  S.ctx.log(source .. ": " .. name .. " REJECTED outside territory at " .. e.position.x .. "," .. e.position.y)
  local player = ev.player_index and game.get_player(ev.player_index)
  if e.type ~= "entity-ghost" then
    if player then player.insert{name = name, count = 1, quality = e.quality}
    else e.surface.spill_item_stack{position = e.position, stack = {name = name, count = 1}} end
    if player then player.create_local_flying_text{text = "Outside colony territory", position = e.position} end
  end
  e.destroy()
  S.rejected = S.rejected + 1
end

events.on(defines.events.on_built_entity, function(ev) handle(ev, "player-built") end)
events.on(defines.events.on_robot_built_entity, function(ev) handle(ev, "robot-built") end)
events.on(defines.events.script_raised_built, function(ev) handle(ev, "script-built") end)
events.on(defines.events.script_raised_revive, function(ev) handle(ev, "script-revive") end)

core.register("s07_territory", {
  issue = 7, auto = false, desc = "cancel-and-refund building outside territory", usage = "",
  run = function(ctx)
    local s, p = ctx.surface, ctx.position
    ctx.flat_area(100)
    S = {ctx = ctx, armed = true, rejected = 0}
    storage.colonies[1] = storage.colonies[1] or {name = "spike"}
    local n = territory.claim_around(s.index, 1, p, 1)
    ctx.check("claimed 3x3 chunks", n == 9 or n == 0, n)
    local inside = {p.x, p.y}
    local outside = {p.x + 32 * 3 + 5, p.y}
    local function try(_, pos, ghost)
      local e = ghost and s.create_entity{name = "entity-ghost", inner_name = "stone-furnace", position = pos, force = "player", raise_built = true}
        or s.create_entity{name = "stone-furnace", position = pos, force = "player", raise_built = true}
      return e and e.valid
    end
    local in_ok = try("inside", inside)
    ctx.check("script-built furnace inside territory kept", in_ok == true)
    local out_ok = try("outside", outside)
    ctx.check("script-built furnace outside territory rejected", not out_ok, tostring(out_ok))
    local g_ok = try("ghost outside", {outside[1], outside[2] + 4}, true)
    ctx.check("ghost outside territory rejected", not g_ok, tostring(g_ok))
    -- overlay cost
    ctx.profile("draw overlay rectangle (3x3 chunks)", function()
      local cx, cy = territory.chunk_of(p)
      rendering.draw_rectangle{color = {0, 0.6, 0.2, 0.15}, filled = true,
        left_top = {(cx - 1) * 32, (cy - 1) * 32}, right_bottom = {(cx + 2) * 32, (cy + 2) * 32},
        surface = s, time_to_live = 60 * 30}
    end, 1)
    ctx.log("INTERACTIVE: enforcement is armed. Place furnaces in/out of the green box (30s). Try: blueprint paste, construction robots (build ghost), cursor-ghost. Check log lines above for 'player-built'/'robot-built'.")
    ctx.log("KNOWN LIMITS to confirm: no way to preview-block placement (only after-the-fact cancel); quality refunded via player.insert{quality=}; bots spill items on ground.")
    ctx.finish()
  end,
})
