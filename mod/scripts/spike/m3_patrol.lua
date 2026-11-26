-- M3 Stage 3 integration spike (#57): Patrol Posts and autonomous militia patrols.
--   * a post with ordered waypoints dispatches an armed militia through the real staggered timer;
--   * the squad walks the loop (idx wraps) and, with ZERO scripted strikes from the spike, autonomously
--     kills a biter and destroys an isolated biter-spawner (all biter units swept) through Stage 1's damage;
--   * repeated failed paths into a nest never silently delete it (allow_destroy_when_commands_fail=false,
--     bounded attempts + blacklist), and stale construct.finish/work.finish/patrol.lease timers are no-ops;
--   * a Command Whistle order preempts the patrol and the militia keeps its rifle;
--   * nightfall ends the patrol; a patroller that DIES frees its squad slot and the post re-recruits;
--   * the schema-41 registries survive.
-- Headless has no player for waypoint *gestures* (the custom-input shape is already proven by s18_command);
-- waypoints are added through the same adapter API those gestures call.
-- Run: TICKS=9000 scripts/headless-spike.sh m3_patrol
local core = require("scripts.spike.core")
require("scripts.colony")
local work = require("scripts.work")
local militia = require("scripts.militia")
local patrol = require("scripts.patrol")
local command = require("scripts.command")
local command_model = require("scripts.model.command")
local patrol_model = require("scripts.model.patrol")
local scheduler = require("scripts.scheduler")
local construct = require("scripts.model.construct")

core.register("m3_patrol", {
  issue = 57, auto = true,
  desc = "patrol posts: loop, autonomous biter kill, autonomous nest kill, no direct strikes, failed paths, stale timers, whistle preemption, night, death cleanup",
  usage = "",
  run = function(ctx)
    local s, p = ctx.surface, ctx.position
    ctx.flat_area(100, "grass-1")
    s.always_day, s.freeze_daytime, s.daytime = true, true, 0
    local function build(name, pos)
      return s.create_entity{name = name, position = pos, force = "player", raise_built = true}
    end
    storage.interval_override = 300
    local hall = build("colony-town-hall", p)
    local c
    for _, col in pairs(storage.colonies) do c = col end
    ctx.check("colony registered", c ~= nil and hall and hall.valid)
    if not c then return ctx.finish() end
    c.accept_migrants = false
    hall.insert{name = "raw-fish", count = 400}

    local post = build("colony-patrol-post", {p.x + 4, p.y + 4})
    ctx.check("patrol post built and registered", post and post.valid and c.patrol_posts[post.unit_number] ~= nil)
    if not (post and post.valid) then return ctx.finish() end
    local pun = post.unit_number
    ctx.check("schema 41+ created the patrol registries", storage.schema >= 41
      and c.patrols ~= nil and c.patrol_posts ~= nil and storage.patrol_ui ~= nil,
      "schema=" .. tostring(storage.schema))

    local w1 = {x = p.x + 7, y = p.y + 4}
    local w2 = {x = p.x + 7, y = p.y + 7}
    local i1 = patrol.add_waypoint(c, pun, w1)
    local i2 = patrol.add_waypoint(c, pun, w2)
    ctx.check("waypoints append in click order", i1 == 1 and i2 == 2
      and #c.patrol_posts[pun].waypoints == 2)
    local route = patrol_model.route({{id = pun, colony_id = c.id,
      waypoints = c.patrol_posts[pun].waypoints}}, c.id)
    ctx.check("pure route is ordered and keyed", #route == 2 and route[1].key == pun .. ":1"
      and route[2].key == pun .. ":2")
    ctx.check("removal renumbers the GUI list", patrol.remove_waypoint(c, pun, 1)
      and #c.patrol_posts[pun].waypoints == 1
      and patrol.add_waypoint(c, pun, w1) == 2)
    patrol.clear_waypoints(c, pun)
    patrol.add_waypoint(c, pun, w1); patrol.add_waypoint(c, pun, w2)

    local m = militia.spawn(c, {p.x + 4, p.y + 4}, {weapon = "colony-rifle"})
    ctx.check("armed militia spawned for the route", m and m.valid
      and storage.unit_state[m.unit_number].gear.weapon == "colony-rifle")
    if not (m and m.valid) then return ctx.finish() end
    local mun = m.unit_number
    -- The biter/nest phases must not be interrupted by spawns killing the squad. The DEATH case at the end
    -- deliberately makes the unit destructible again and kills it through the real engine path.
    m.destructible = false
    local st = storage.unit_state[mun]
    local phase_b, phase_b2, phase_c, phase_d, phase_e, phase_f
    ctx.check("a fresh militia is on duty, not patrolling yet", st.state == "militia-hold")

    -- Sweep every biter UNIT (never a spawner) so a nest is the only target left. The reviewer's isolated-nest
    -- reproduction used the same idea; without it a spawner's own near-spawns are always the nearest target and
    -- the strictly-nearest model (correctly) keeps picking them first.
    local sweeping = false
    local function sweep_units()
      if not sweeping then return end
      for _, en in ipairs(s.find_entities_filtered{type = "unit", force = "enemy",
          area = {{p.x - 30, p.y - 30}, {p.x + 40, p.y + 40}}}) do
        if en.valid then en.destroy() end
      end
      ctx.after(5, sweep_units)
    end

    -- Phase A: the real patrol.dispatch timer recruits a nearby idle militia within DISPATCH_TICKS.
    ctx.after(patrol.DISPATCH_TICKS + 60, function()
      local rec = c.patrols[mun]
      ctx.check("dispatch timer starts an armed patrol", rec ~= nil and st.state == "patrolling"
        and #rec.route == 2, "state=" .. tostring(st.state) .. " route=" .. tostring(rec and #rec.route))

      local loop = {t = 0, prev = nil, wrapped = false, indices = {}}
      local function loop_poll()
        loop.t = loop.t + 20
        local r = c.patrols[mun]
        if r then
          loop.indices[r.idx] = true
          if loop.prev and loop.prev > r.idx then loop.wrapped = true end
          loop.prev = r.idx
          if loop.wrapped then
            ctx.check("patrol walks the whole loop and wraps to waypoint 1", true,
              "indices=" .. tostring(loop.indices[1]) .. "/" .. tostring(loop.indices[2]))
            return phase_b()
          end
        end
        if loop.t > 1500 then
          ctx.check("patrol walks the whole loop and wraps to waypoint 1", false,
            "idx=" .. tostring(r and r.idx) .. " t=" .. loop.t)
          return phase_b()
        end
        ctx.after(20, loop_poll)
      end
      ctx.after(20, loop_poll)

      -- Phase B1: ONE biter, no spawner. ZERO strikes from the spike - the patrol's own patrol.engage timer
      -- must resolve its live target and land the damage. Reverting that fix makes this check fail.
      phase_b = function()
        local biter = s.create_entity{name = "small-biter", position = {p.x + 10, p.y + 6}, force = "enemy"}
        ctx.check("biter spawned in range", biter and biter.valid)
        local engaged, t = false, 0
        local function biter_poll()
          t = t + 30
          local r = c.patrols[mun]
          if r and (st.state == "patrol-engage" or r.target_un) then engaged = true end
          if not (biter and biter.valid) then
            ctx.check("patrol autonomously engages a hostile", engaged)
            ctx.check("patrol kills a biter with zero scripted strikes", true,
              "t=" .. t)
            return phase_b2()
          end
          if t > 1200 then
            ctx.check("patrol autonomously engages a hostile", engaged)
            ctx.check("patrol kills a biter with zero scripted strikes", false,
              "biter hp=" .. tostring(biter and biter.valid and biter.health) .. " state=" .. tostring(st.state))
            return phase_b2()
          end
          ctx.after(30, biter_poll)
        end
        ctx.after(30, biter_poll)
      end

      -- Phase B2: ISOLATED nest - only a biter-spawner, every biter unit swept every 5 ticks, and NOT ONE
      -- militia.patrol_strike call from the spike. The pass depends on the autonomous patrol damaging and
      -- destroying the nest. Reverting the live-entity fix makes this check fail (hp stays ~350).
      phase_b2 = function()
        local nest = s.create_entity{name = "biter-spawner", position = {p.x + 14, p.y + 6}, force = "enemy"}
        ctx.check("isolated nest spawned in range", nest and nest.valid)
        local nest_hp = nest and nest.valid and nest.health or 0
        sweeping = true
        sweep_units()
        local t, picked, damaged = 0, false, false
        local function nest_poll()
          t = t + 30
          local r = c.patrols[mun]
          local live = r and r.target
          if live and live.valid and live.unit_number == (nest and nest.valid and nest.unit_number) then picked = true end
          if not (nest and nest.valid) or (nest and nest.health <= 0) then
            ctx.check("patrol selects the isolated nest autonomously", picked)
            ctx.check("patrol destroys a nest with zero scripted strikes", true,
              "nest " .. nest_hp .. " -> destroyed at t=" .. t)
            sweeping = false
            return phase_c()
          end
          if nest.health < nest_hp - 0.5 then damaged = true end
          if t == 600 then
            ctx.probe("autonomous nest diagnostic", function()
              local rr = c.patrols[mun]
              local lt = rr and rr.target
              return "state=" .. tostring(st.state) .. " target_un=" .. tostring(rr and rr.target_un)
                .. " live=" .. tostring(lt and lt.valid) .. " liveun=" .. tostring(lt and lt.valid and lt.unit_number)
                .. " nestun=" .. tostring(nest and nest.valid and nest.unit_number)
                .. " hp=" .. tostring(nest and nest.valid and nest.health)
                .. " gear=" .. tostring(st.gear and st.gear.weapon)
            end)
          end
          if t > 1800 then
            ctx.check("patrol selects the isolated nest autonomously", picked,
              "target_un=" .. tostring(r and r.target_un) .. " state=" .. tostring(st.state))
            ctx.check("patrol destroys a nest with zero scripted strikes", false,
              "nest " .. nest_hp .. " -> " .. tostring(nest and nest.valid and nest.health)
              .. " damaged=" .. tostring(damaged))
            sweeping = false
            return phase_c()
          end
          ctx.after(30, nest_poll)
        end
        ctx.after(30, nest_poll)
      end

      -- Phase C: lifecycle guards. Kept local so every phase can re-enter after an earlier one ends a patrol.
      local function ensure_patrol()
        if c.patrols[mun] and patrol_model.is_patrol(st) then return c.patrols[mun] end
        if st.state == "commanded" and storage.command.leased[mun] then
          command.release_lease(mun, false)
        end
        if st.state ~= "militia-hold" then
          storage.unit_state[mun] = {colony_id = c.id, job = "militia", state = "militia-hold", gear = st.gear}
          st = storage.unit_state[mun]
        end
        patrol.start(c, mun, m, st)
        return c.patrols[mun]
      end

      phase_c = function()
        -- Engine fact (s19_defence): the runtime field is allow_destroy_when_commands_fail.
        local ok, flag = pcall(function() return m.ai_settings.allow_destroy_when_commands_fail end)
        ctx.check("militia cannot be silently deleted on a failed path", ok and flag == false,
          tostring(flag))

        local r = ensure_patrol()
        ctx.check("a patrol is live for the failure/stale-timer checks", r ~= nil)
        if not r then return phase_d() end
        local old_seq = r.seq
        -- script.raise_event cannot synthesise this engine event on 2.1 (s18 found the same for custom
        -- inputs), so the handler is exposed for the regression.
        ctx.probe("[engine] synthetic on_ai_command_completed raise", function()
          local raised, raise_err = pcall(script.raise_event, defines.events.on_ai_command_completed,
            {unit_number = mun, result = defines.behavior_result.fail})
          return raised and "raised" or ("rejected: " .. tostring(raise_err))
        end)
        -- A failed path into a nest happens while the patrol is engaging that nest: give the lease a target
        -- unit number so the repeated-failure rule has something to blacklist (an unreachable target is the
        -- whole point). No live entity is needed - the fail event only names the patroller.
        r.target_un = r.target_un or (mun + 99999)
        for _ = 1, patrol_model.MAX_PATH_ATTEMPTS + 2 do
          patrol.on_command_completed({unit_number = mun, result = defines.behavior_result.fail})
        end
        ctx.check("failed path events reached the patrol handler", true)
        ctx.probe("failed path diagnostic", function()
          return "attempts=" .. tostring(r.attempts) .. " blacklist=" .. tostring(next(r.blacklist))
            .. " state=" .. tostring(st.state) .. " same=" .. tostring(c.patrols[mun] == r)
            .. " seq=" .. tostring(r.seq) .. "/" .. tostring(st.patrol_seq)
            .. " lease=" .. tostring(r.until_tick) .. " now=" .. game.tick
        end)
        ctx.check("repeated failed paths never delete the patrol", m.valid and c.patrols[mun] ~= nil
          and patrol_model.is_patrol(st), "state=" .. tostring(st.state))
        ctx.check("failed paths are bounded by a blacklist", r.attempts <= patrol_model.MAX_PATH_ATTEMPTS
          and next(r.blacklist) ~= nil, "attempts=" .. tostring(r.attempts))

        -- The direct analogue of s18_command's stale-timer checks.
        scheduler.after(construct.WORK_TICKS, "construct.finish", {un = mun})
        scheduler.after(1, "work.finish", {un = mun})
        scheduler.after(2, "patrol.lease", {un = mun, colony_id = c.id, seq = old_seq - 1})
        ctx.after(construct.WORK_TICKS + 20, function()
          ctx.check("stale construct.finish/work.finish did not end the patrol",
            m.valid and c.patrols[mun] ~= nil and patrol_model.is_patrol(st),
            "state=" .. tostring(st.state))
          return phase_d(old_seq)
        end)
      end

      -- Phase D: a Command Whistle order preempts the patrol; gear follows the lease, the route does not.
      phase_d = function(old_seq)
        local r = ensure_patrol()
        if not r then old_seq = (c.patrols[mun] and c.patrols[mun].seq) or old_seq end
        local weapon = st.gear and st.gear.weapon
        storage.command.selection[1] = {mun}
        command.apply(1, command_model.ORDERS.MOVE, {position = {x = p.x + 20, y = p.y}})
        st = storage.unit_state[mun]   -- command.apply replaces the state table
        ctx.check("whistle preempts the patrol", st.state == "commanded" and c.patrols[mun] == nil
          and storage.command.leased[mun] == true, "state=" .. tostring(st.state))
        ctx.check("preemption does not lose the rifle", st.gear and st.gear.weapon == weapon,
          tostring(weapon) .. " -> " .. tostring(st.gear and st.gear.weapon))
        scheduler.after(2, "patrol.lease", {un = mun, colony_id = c.id, seq = old_seq})
        ctx.after(40, function()
          ctx.check("a stale patrol.lease cannot overwrite a whistle order", st.state == "commanded"
            and c.patrols[mun] == nil, "state=" .. tostring(st.state))
          command.release_lease(mun, false)
          st = storage.unit_state[mun]
          ctx.check("lease release leaves an armed idle militia", st.state == "idle"
            and st.gear and st.gear.weapon == weapon, "state=" .. tostring(st.state))
          return phase_e()
        end)
      end

      -- Phase E: nightfall ends a patrol and hands the unit back to work.
      phase_e = function()
        local r = ensure_patrol()
        ctx.check("a patrol is live for the nightfall check", r ~= nil)
        s.always_day, s.freeze_daytime, s.daytime = false, false, 0.5
        ctx.check("the surface is night", work.is_sleep_time(s))
        ctx.after(patrol_model.CHECK_TICKS + 30, function()
          ctx.check("nightfall ends the patrol", c.patrols[mun] == nil and not patrol_model.is_patrol(st),
            "state=" .. tostring(st.state))
          s.always_day, s.freeze_daytime, s.daytime = true, true, 0
          ctx.check("schema-41+ registries still hold the post", storage.schema >= 41
            and c.patrol_posts[pun] ~= nil and #c.patrol_posts[pun].waypoints == 2)
          return phase_f()
        end)
      end

      -- Phase F: a patroller that DIES must free its squad slot. work.lua nils unit_state on destruction, so
      -- the cleanup cannot depend on valid(st); the destroyed-object handler must prune colony.patrols[un].
      -- With the cleanup reverted, the stale lease keeps counting toward POST_SQUAD and this check fails.
      phase_f = function()
        local r = ensure_patrol()
        ctx.check("a patrol is live before the death case", r ~= nil)
        local m2 = militia.spawn(c, {p.x + 5, p.y + 5}, {weapon = "colony-rifle"})
        ctx.check("a second militia spawned for the squad", m2 and m2.valid)
        if not (m2 and m2.valid) then return ctx.finish() end
        m2.destructible = false
        local un2 = m2.unit_number
        ctx.after(patrol.DISPATCH_TICKS + 60, function()
          local active = 0
          for _, patrol_rec in pairs(c.patrols) do if patrol_rec.post == pun then active = active + 1 end end
          ctx.check("the post fills both squad slots", active == 2 and c.patrols[mun] and c.patrols[un2],
            "active=" .. active)
          -- Real engine death. No direct registry manipulation in the spike.
          m.destructible = true
          m.die()
          ctx.after(10, function()
            ctx.check("dead patroller's registry entry was pruned",
              c.patrols[mun] == nil and storage.unit_state[mun] == nil,
              "reg=" .. tostring(c.patrols[mun] ~= nil) .. " st=" .. tostring(storage.unit_state[mun] ~= nil))
            local m3 = militia.spawn(c, {p.x + 5, p.y + 6}, {weapon = "colony-rifle"})
            ctx.check("a replacement militia spawned", m3 and m3.valid)
            if not (m3 and m3.valid) then return ctx.finish() end
            local un3 = m3.unit_number
            ctx.after(patrol.DISPATCH_TICKS + 60, function()
              local active2 = 0
              for _, patrol_rec in pairs(c.patrols) do if patrol_rec.post == pun then active2 = active2 + 1 end end
              ctx.check("post re-recruits after a death",
                active2 == 2 and c.patrols[un3] ~= nil and c.patrols[mun] == nil,
                "active=" .. active2 .. " replacement=" .. tostring(c.patrols[un3] ~= nil))
              ctx.finish()
            end)
          end)
        end)
      end
    end)
  end,
})
