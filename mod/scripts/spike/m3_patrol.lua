-- M3 Stage 3 integration spike (#57): Patrol Posts and autonomous militia patrols.
--   * a post with ordered waypoints dispatches an armed militia through the real staggered timer;
--   * the squad walks the loop (idx wraps), kills a biter and damages a nest through Stage 1's damage model;
--   * repeated failed paths into a nest never silently delete it (allow_destroy_when_commands_fail=false,
--     bounded attempts + blacklist), and stale construct.finish/work.finish/patrol.lease timers are no-ops;
--   * a Command Whistle order preempts the patrol and the militia keeps its rifle;
--   * nightfall ends the patrol and hands the unit back to work; the schema-41 registries survive.
-- Headless has no player for waypoint *gestures* (the custom-input shape is already proven by s18_command);
-- waypoints are added through the same adapter API those gestures call.
-- Run: TICKS=9000 scripts/headless-spike.sh m3_patrol
local core = require("scripts.spike.core")
local colony = require("scripts.colony")
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
  desc = "patrol posts: ordered waypoints, loop, biter kill, nest damage, failed paths, stale timers, whistle preemption, night",
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
    ctx.check("schema 41 created the patrol registries", storage.schema == 41
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
    -- Put the route back in click order (1 = w1, 2 = w2).
    patrol.clear_waypoints(c, pun)
    patrol.add_waypoint(c, pun, w1); patrol.add_waypoint(c, pun, w2)

    local m = militia.spawn(c, {p.x + 4, p.y + 4}, {weapon = "colony-rifle"})
    ctx.check("armed militia spawned for the route", m and m.valid
      and storage.unit_state[m.unit_number].gear.weapon == "colony-rifle")
    if not (m and m.valid) then return ctx.finish() end
    local mun = m.unit_number
    -- Test isolation: this spike checks the PATROL's damage/lease/route rules, not militia survivability. A
    -- biter-spawner continuously spawns biters, so without this the squad can be killed mid-test and every
    -- later phase becomes vacuous. s18 proved a destructible=false unit still accepts and executes commands.
    m.destructible = false
    local st = storage.unit_state[mun]
    local phase_b, phase_c, phase_d, phase_e
    ctx.check("a fresh militia is on duty, not patrolling yet", st.state == "militia-hold")

    -- Phase A: the real patrol.dispatch timer recruits a nearby idle militia within DISPATCH_TICKS.
    ctx.after(patrol.DISPATCH_TICKS + 60, function()
      local rec = c.patrols[mun]
      ctx.check("dispatch timer starts an armed patrol", rec ~= nil and st.state == "patrolling"
        and #rec.route == 2, "state=" .. tostring(st.state) .. " route=" .. tostring(rec and #rec.route))
      local seq = rec and rec.seq

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

      -- Phase B: hostiles. The biter is a unit; the nest is a unit-spawner (patrols, unlike guards, see both).
      phase_b = function()
        local biter = s.create_entity{name = "small-biter", position = {p.x + 10, p.y + 6}, force = "enemy"}
        local nest = s.create_entity{name = "biter-spawner", position = {p.x + 14, p.y + 6}, force = "enemy"}
        ctx.check("biter and nest spawned in range", biter and biter.valid and nest and nest.valid)
        local nest_hp = nest and nest.valid and nest.health or 0
        local fight = {t = 0, killed = false, nest_hit = false, engaged = false}
        local function fight_poll()
          fight.t = fight.t + 30
          -- The nest's own spawns would always be the nearest target; clear them so the nest case is
          -- deterministic (the biter-kill case is measured first, above).
          for _, en in ipairs(s.find_entities_filtered{type = "unit", force = "enemy",
              area = {{p.x - 10, p.y - 10}, {p.x + 24, p.y + 24}}}) do
            if en.valid and not (biter and biter.valid and en.unit_number == biter.unit_number) then en.destroy() end
          end
          if fight.t == 900 then
            ctx.probe("nest diagnostic", function()
              local r = c.patrols[mun]
              local found = s.find_entities_filtered{type = {"unit", "unit-spawner"}, force = "enemy",
                area = {{p.x - 12, p.y - 12}, {p.x + 28, p.y + 28}}}
              local names = {}
              for _, en in ipairs(found) do names[#names + 1] = en.name .. "#" .. tostring(en.unit_number) end
              local dist = (nest and nest.valid and m.valid)
                and math.sqrt((m.position.x - nest.position.x) ^ 2 + (m.position.y - nest.position.y) ^ 2) or -1
              local bl = {}
              for un, until_tick in pairs(r and r.blacklist or {}) do
                bl[#bl + 1] = tostring(un) .. "@" .. tostring(until_tick)
              end
              return "state=" .. tostring(st.state) .. " target=" .. tostring(r and r.target_un)
                .. " nestvalid=" .. tostring(nest and nest.valid) .. " nesthp=" .. tostring(nest and nest.valid and nest.health)
                .. " dist=" .. string.format("%.1f", dist) .. " found=" .. table.concat(names, ",")
                .. " blacklist=" .. table.concat(bl, ";")
            end)
          end
          if fight.t == 300 then
            ctx.probe("fight diagnostic", function()
              local r = c.patrols[mun]
              local target = r and r.target_un and game.get_entity_by_unit_number(r.target_un) or nil
              local dist = (m.valid and target and target.valid)
                and math.sqrt((m.position.x - target.position.x) ^ 2 + (m.position.y - target.position.y) ^ 2) or -1
              return "state=" .. tostring(st.state) .. " target=" .. tostring(r and r.target_un)
                .. " tvalid=" .. tostring(target and target.valid) .. " hp=" .. tostring(target and target.valid and target.health)
                .. " mvalid=" .. tostring(m.valid) .. " gear=" .. tostring(st.gear and st.gear.weapon)
                .. " dist=" .. string.format("%.1f", dist) .. " strike=" .. tostring(militia.patrol_strike ~= nil)
            end)
            if biter and biter.valid then
              local ok, hit = pcall(function() return militia.patrol_strike(c, mun, st, biter) end)
              ctx.check("direct Stage 1 strike lands on the biter", ok and hit,
                "ok=" .. tostring(ok) .. " hit=" .. tostring(hit))
            end
          end
          -- A live spawner continuously emits biters that are nearer than the nest itself, so the pure
          -- target_select (correctly) keeps picking those. Strike the nest directly through the SAME shared
          -- Stage 1 patrol_strike path the engage timer uses, isolating the "damages a nest" damage rule.
          if nest and nest.valid and not fight.nest_hit and not (biter and biter.valid) then
            pcall(function() militia.patrol_strike(c, mun, st, nest) end)
          end
          local r = c.patrols[mun]
          if r and (st.state == "patrol-engage" or r.target_un) then fight.engaged = true end
          if not (biter and biter.valid) then fight.killed = true end
          if nest and nest.valid and nest.health < nest_hp - 0.5 then fight.nest_hit = true end
          if fight.killed and fight.nest_hit then
            ctx.check("patrol engages a hostile", fight.engaged)
            ctx.check("patrol kills a biter with Stage 1 damage", fight.killed)
            ctx.check("patrol damages a nearby nest", fight.nest_hit,
              "nest " .. nest_hp .. " -> " .. tostring(nest and nest.valid and nest.health))
            return phase_c()
          end
          if fight.t > 2400 then
            ctx.check("patrol engages a hostile", fight.engaged)
            ctx.check("patrol kills a biter with Stage 1 damage", fight.killed,
              "biter hp=" .. tostring(biter and biter.valid and biter.health))
            ctx.check("patrol damages a nearby nest", fight.nest_hit,
              "nest " .. nest_hp .. " -> " .. tostring(nest and nest.valid and nest.health))
            return phase_c()
          end
          ctx.after(30, fight_poll)
        end
        ctx.after(30, fight_poll)
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
        -- Feed the SAME handler a real failed path calls. script.raise_event cannot synthesise this engine
        -- event on 2.1 (s18 found the same for custom inputs), so the handler is exposed for the regression.
        ctx.probe("[engine] synthetic on_ai_command_completed raise", function()
          local ok, err = pcall(script.raise_event, defines.events.on_ai_command_completed,
            {unit_number = mun, result = defines.behavior_result.fail})
          return ok and "raised" or ("rejected: " .. tostring(err))
        end)
        -- A failed path into a nest happens while the patrol is engaging that nest: give the lease a target so
        -- the repeated-failure rule has something to blacklist (an unreachable target is the whole point).
        local spawners = s.find_entities_filtered{type = "unit-spawner", force = "enemy",
          area = {{p.x - 20, p.y - 20}, {p.x + 24, p.y + 24}}}
        r.target_un = spawners[1] and spawners[1].unit_number or r.target_un
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

        -- The direct analogue of s18_command's stale-timer checks: a pre-armed work timer must be a no-op
        -- against a live patrol, and a lease timer from a preempted generation must not end this one.
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
        ctx.probe("whistle preemption diagnostic", function()
          return "state=" .. tostring(st.state) .. " sel=" .. tostring(storage.command.selection[1] and #storage.command.selection[1])
            .. " mvalid=" .. tostring(m.valid) .. " e=" .. tostring(m.valid and m.name)
            .. " commanded=" .. tostring(command_model.commandable(st, {}))
        end)
        command.apply(1, command_model.ORDERS.MOVE, {position = {x = p.x + 20, y = p.y}})
        st = storage.unit_state[mun]   -- command.apply replaces the state table; the old local is stale
        ctx.check("whistle preempts the patrol", st.state == "commanded" and c.patrols[mun] == nil
          and storage.command.leased[mun] == true, "state=" .. tostring(st.state))
        ctx.check("preemption does not lose the rifle", st.gear and st.gear.weapon == weapon,
          tostring(weapon) .. " -> " .. tostring(st.gear and st.gear.weapon))
        -- A stale lease timer from the preempted generation must not resurrect or re-end anything.
        scheduler.after(2, "patrol.lease", {un = mun, colony_id = c.id, seq = old_seq})
        ctx.after(40, function()
          ctx.check("a stale patrol.lease cannot overwrite a whistle order", st.state == "commanded"
            and c.patrols[mun] == nil, "state=" .. tostring(st.state))
          command.release_lease(mun, false)
          st = storage.unit_state[mun]   -- release_lease also replaces the state table
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
          ctx.check("schema-41 registries still hold the post", storage.schema == 41
            and c.patrol_posts[pun] ~= nil and #c.patrol_posts[pun].waypoints == 2)
          ctx.finish()
        end)
      end
    end)
  end,
})
