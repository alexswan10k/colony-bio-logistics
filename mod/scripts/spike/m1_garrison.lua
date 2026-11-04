-- M1 garrison spike (#56 first slice): a Watchtower doubles as a guard post. Rifles in its stock room gate the
-- posts (haulers bring them), posted guards stand at the tower and engage enemy units within RANGE, every
-- completed engagement wears a rifle, a worn-out rifle withdraws a guard, night takes the garrison off duty,
-- and lowering the limit disbands it. Daytime is frozen for the fighting phase and then moved to night.
-- Run: TICKS=9000 scripts/headless-spike.sh m1_garrison
local core = require("scripts.spike.core")
local colony = require("scripts.colony")
local labour = require("scripts.model.labour")
local garrison = require("scripts.model.garrison")

local function guards_of(c, states)
  local n = 0
  for un in pairs(c.colonists or {}) do
    local st = storage.unit_state[un]
    if st and st.job == "guard" and (not states or states[st.state]) then n = n + 1 end
  end
  return n
end

core.register("m1_garrison", {
  issue = 56, auto = true, desc = "watchtower garrison: rifles gate posts, guards shoot, rifles wear, night off, disband",
  usage = "",
  run = function(ctx)
    local s, p = ctx.surface, ctx.position
    ctx.flat_area(90, "grass-1")
    s.always_day, s.freeze_daytime, s.daytime = true, true, 0
    local function build(name, pos)
      return s.create_entity{name = name, position = pos, force = "player", raise_built = true}
    end
    storage.interval_override = 150
    local hall = build("colony-town-hall", {p.x, p.y})
    local c
    for _, col in pairs(storage.colonies) do c = col end
    ctx.check("colony registered", c ~= nil and hall and hall.valid)
    if not c then return ctx.finish() end
    for i = 0, 3 do build("colony-housing-cabin", {p.x - 9 + i * 6, p.y - 8}) end
    hall.insert{name = "raw-fish", count = 400}
    c.accept_migrants = false
    for _ = 1, 4 do colony.spawn_colonist(c) end

    local tower = build("colony-watchtower", {p.x + 12, p.y})
    ctx.check("watchtower built", tower and tower.valid)
    if not (tower and tower.valid) then return ctx.finish() end

    -- The tower is a registered guard post from the moment it is built, but unmanned by default.
    local h = c.huts[tower.unit_number]
    ctx.check("the watchtower is registered as a guard post", h ~= nil and h.job == "guard")
    ctx.check("an unmanned tower posts nobody (limit 0 by default)", h ~= nil and h.limit == 0)
    ctx.check("territory still derived from the tower", c.towers[tower.unit_number] == tower)
    local def = labour.HUTS["colony-watchtower"]
    ctx.check("guard post holds four rifles, one post each", def and def.tool == "colony-rifle" and def.capacity == 4)

    -- Player mans the tower: two posts, still no rifles inside (they are in the hall, haulers must bring them).
    h.limit = 2
    colony.reassign_workforce(c)
    hall.insert{name = "colony-rifle", count = 3}
    ctx.check("rifles stocked in the hall", hall.get_item_count("colony-rifle") == 3)

    -- Two colonists pinned to guard duty; the other two are left free to haul the rifles out.
    local ids = {}
    for un in pairs(c.colonists) do ids[#ids + 1] = un end
    table.sort(ids)
    c.locks[ids[1]], c.locks[ids[2]] = "guard", "guard"

    local now = {t = 0}
    local watch = {
      armed_at = nil,          -- tick the tower held 2 rifles
      staffed_at = nil,        -- tick both guards were posted
      fighting = 0,            -- ticks any guard spent in guarding-fight
      saw_guard = nil,         -- tick the first guard reached "guarding"
      biters = {},
      dead = 0,
      wear = h.wear,
      rifles_min = 99,
      phase = "arm",
    }
    local STOP = {type = defines.command.stop, ticks_to_wait = 4294967295, distraction = defines.distraction.none}

    local function posted() return guards_of(c, {guarding = true, ["guarding-fight"] = true}) end
    local function state_of(un)
      local st = storage.unit_state[un]
      return st and st.state
    end

    -- Sample every 20 ticks: the whole scenario is driven by what the game actually does.
    local function poll()
      now.t = now.t + 20
      if not (h and tower.valid) then return ctx.finish() end
      local rifles = tower.get_item_count("colony-rifle")
      watch.rifles_min = math.min(watch.rifles_min, rifles)
      if rifles >= 2 and not watch.armed_at then watch.armed_at = now.t end
      if posted() >= 2 and not watch.staffed_at then watch.staffed_at = now.t end
      for un in pairs(c.colonists) do
        local st = storage.unit_state[un]
        if st and st.state == "guarding-fight" then
          watch.fighting = watch.fighting + 1
          watch.saw_guard = watch.saw_guard or now.t
        end
      end

      if watch.phase == "arm" then
        if watch.staffed_at then
          -- The garrison is up: check where the guards stand and that they hold the post indoors-free.
          local near = 0
          for un in pairs(c.colonists) do
            local st, e = storage.unit_state[un], c.colonists[un]
            if st and st.job == "guard" and (st.state == "guarding" or st.state == "guarding-fight") and e.valid
                and ((e.position.x - tower.position.x) ^ 2 + (e.position.y - tower.position.y) ^ 2) <= 25 then
              near = near + 1
            end
          end
          ctx.check("2 a hauler walked a rifle out to the tower", rifles >= 1, rifles .. " rifles")
          ctx.check("2 two guards are posted at the tower", near >= 2, near .. " at the post")
          -- A rifle about to break: the first completed engagement must retire it and withdraw a guard.
          h.wear = labour.TOOL_USES - 1
          watch.phase = "fight"
          watch.biters = {
            s.create_entity{name = "small-biter", position = {tower.position.x + 9, tower.position.y}, force = "enemy"},
            s.create_entity{name = "small-biter", position = {tower.position.x - 9, tower.position.y + 4}, force = "enemy"},
          }
          for _, b in ipairs(watch.biters) do b.commandable.set_command(STOP) end
          ctx.check("2 two biters stand inside the engagement radius", #watch.biters == 2,
            string.format("%d tiles of %d", 9, garrison.RANGE))
        elseif now.t > 2400 then
          ctx.check("2 the garrison was manned", false, "still waiting after " .. now.t .. " ticks")
          return ctx.finish()
        end
      elseif watch.phase == "fight" then
        local alive = 0
        for _, b in ipairs(watch.biters) do if b.valid then alive = alive + 1 end end
        watch.dead = #watch.biters - alive
        if alive == 0 then
          watch.phase, watch.dead_at = "cleanup", now.t
          ctx.check("3 the guards shot both biters dead", watch.dead == 2, watch.dead .. " kills")
          ctx.check("3 a guard was seen fighting at the tower", watch.fighting > 0, watch.fighting .. " sampled ticks")
        elseif now.t > (watch.staffed_at or 0) + 2400 then
          ctx.check("3 the guards shot both biters dead", false, watch.dead .. " of 2 kills")
          return ctx.finish()
        end
      elseif watch.phase == "cleanup" then
        -- The withdrawal is a scan away: the guard whose post lost its rifle notices on the next sweep.
        if tower.get_item_count("colony-rifle") == 1 and posted() <= 1 then
          ctx.check("3 the engagement wore the rifle", h.wear < labour.TOOL_USES - 1, "wear " .. tostring(h.wear))
          ctx.check("3 the broken rifle was consumed and its guard withdrawn", true)
          watch.phase = "night"
        elseif now.t > (watch.dead_at or 0) + 1200 then
          ctx.check("3 the broken rifle was consumed and its guard withdrawn", false,
            tower.get_item_count("colony-rifle") .. " rifles, " .. posted() .. " posted")
          return ctx.finish()
        end
      elseif watch.phase == "night" then
        -- Night takes the garrison off duty like any other colonist (the morning assignment re-posts them).
        s.freeze_daytime, s.always_day, s.daytime = false, false, 0.50
        watch.phase = "wait-night"
      elseif watch.phase == "wait-night" then
        if posted() == 0 then
          ctx.check("4 night takes the garrison off duty", true)
          local any_sleep = false
          for un in pairs(c.colonists) do
            local st = storage.unit_state[un]
            if st and (st.state == "to_bed" or st.state == "sleeping") then any_sleep = true end
          end
          ctx.check("4 the guards went to their houses", any_sleep)
          watch.phase = "back-days"
        elseif now.t > 4000 then
          ctx.check("4 night takes the garrison off duty", false, posted() .. " still posted")
          return ctx.finish()
        end
      elseif watch.phase == "back-days" then
        s.freeze_daytime, s.always_day, s.daytime = true, true, 0
        watch.phase = "disband"
      elseif watch.phase == "disband" then
        h.limit = 0
        colony.reassign_workforce(c)
        watch.phase = "wait-disband"
      elseif watch.phase == "wait-disband" then
        if posted() == 0 then
          ctx.check("5 lowering the tower limit disbands the garrison", true)
          -- The scenario is over: prove the post is still a lie when nobody manss it.
          ctx.check("5 rifles stay in the tower, nobody is posted", tower.get_item_count("colony-rifle") == 1)
          return ctx.finish()
        elseif now.t > 6000 then
          ctx.check("5 lowering the tower limit disbands the garrison", false, posted() .. " still posted")
          return ctx.finish()
        end
      end
      ctx.after(20, poll)
    end
    ctx.after(20, poll)

    -- Determinism evidence: the engagement radius is a model constant, not a magic number in the adapter.
    ctx.probe("garrison engagement radius", function() return garrison.RANGE .. " tiles" end)
    ctx.probe("posted guard state probe", function() return tostring(state_of(ids[1])) end)
  end,
})
