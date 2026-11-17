-- M3 Armory integration spike (#56 remainder): the worker-free depot and the shared structural aura.
--   * an unmanned Armory emits no haul offer and grants no protection;
--   * militia equip from the Armory's own chest (not the hall), which mans the post and shrinks its stock;
--   * a structure inside the radius takes measurably less enemy damage than an identical one outside;
--   * heal-back is stable (no runaway healing, no revive, no enemy healing) on the SAME #61 damage handler;
--   * a Watchtower with a real posted guard grants the same aura from the same defence.covered path;
--   * drawing gear creates a restock offer and putting gear back clears it.
-- `colony.armories` save/load is asserted by m1_persist (scripts/save-load.sh, schema 40).
-- Run: TICKS=9000 scripts/headless-spike.sh m3_armory
local core = require("scripts.spike.core")
local colony = require("scripts.colony")
local work = require("scripts.work")
local militia = require("scripts.militia")
local armory = require("scripts.armory")
local defence = require("scripts.model.defence")

local STOP = {type = defines.command.stop, ticks_to_wait = 4294967295, distraction = defines.distraction.none}

core.register("m3_armory", {
  issue = 56, auto = true,
  desc = "armory: gear draw/restock, unmanned inert, shared structural aura with towers, stable heal-back",
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

    local a_e = build("colony-armory", {p.x + 2, p.y + 4})
    local inside = build("colony-supply-crate", {p.x + 6, p.y})
    local outside = build("colony-supply-crate", {p.x + 40, p.y})
    local tower_site = build("colony-supply-crate", {p.x + 45, p.y + 2})
    -- A second control, far from BOTH posts: the tower's aura also covers `outside` once it is manned.
    local far = build("colony-supply-crate", {p.x - 40, p.y})
    ctx.check("armory + four identical structures built", a_e and a_e.valid and inside and inside.valid
      and outside and outside.valid and tower_site and tower_site.valid and far and far.valid)
    if not (a_e and a_e.valid and inside and inside.valid and outside and outside.valid
        and tower_site and tower_site.valid and far and far.valid) then return ctx.finish() end
    local a = c.armories[a_e.unit_number]
    ctx.check("colony.armories registry holds the new armory", a ~= nil and a.entity == a_e
      and a.limit == 0 and a.colony_id == c.id)
    ctx.check("an unmanned armory emits no haul offer", armory.offer(a, c) == nil)
    ctx.check("an unmanned armory projects no posts", #armory.posts(c) == 0)

    -- A stationary enemy is the cause for all scripted hits (s19_defence: ev.cause is this entity).
    local cause = s.create_entity{name = "small-biter", position = {p.x - 30, p.y - 30}, force = "enemy"}
    if cause and cause.valid then cause.commandable.set_command(STOP) end

    local function hit(e) e.damage(30, "enemy", "physical", cause, cause) end
    local function loss_before_after(e)
      local before = e.health
      hit(e)
      return before - e.health
    end

    -- 1. Baseline: identical structures, one inside the (unmanned) armory radius, one outside.
    local il0, ol0 = loss_before_after(inside), loss_before_after(outside)
    ctx.check("1 unmanned armory: inside and outside take equal damage",
      math.abs(il0 - ol0) < 0.01, string.format("inside %.3f outside %.3f", il0, ol0))

    -- 2. Stock the depot, man it, and let two militia draw real gear out of its chest. Hall has no gear, so
    --    a hall-only implementation would leave them unarmed and this check would fail.
    a_e.insert{name = "colony-rifle", count = 2}
    a_e.insert{name = "heavy-armor", count = 2}
    local rifles_before = a_e.get_item_count("colony-rifle")
    a.limit = 2
    local m1 = militia.spawn(c, {p.x + 4, p.y + 4})
    local m2 = militia.spawn(c, {p.x + 4, p.y + 7})
    ctx.check("2 two militia spawned near the armory", m1 and m1.valid and m2 and m2.valid)
    if not (m1 and m1.valid and m2 and m2.valid) then return ctx.finish() end
    local s1, s2 = storage.unit_state[m1.unit_number], storage.unit_state[m2.unit_number]
    ctx.check("2 militia drew their rifles from the armory, not the hall",
      s1.gear.weapon == "colony-rifle" and s2.gear.weapon == "colony-rifle"
        and s1.gear.source_armory == a_e.unit_number and s2.gear.source_armory == a_e.unit_number,
      tostring(s1.gear.weapon) .. "/" .. tostring(s2.gear.weapon)
        .. " src=" .. tostring(s1.gear.source_armory) .. "/" .. tostring(s2.gear.source_armory))
    ctx.check("2 the armory chest was actually depleted",
      a_e.get_item_count("colony-rifle") == rifles_before - 2,
      rifles_before .. " -> " .. a_e.get_item_count("colony-rifle"))
    ctx.check("2 two posts are claimed from the depot's own gear", armory.equipped_count(c, a) == 2,
      tostring(armory.equipped_count(c, a)))
    local posts = armory.posts(c)
    ctx.check("2 a manned armory is in the shared post list", #posts == 1 and posts[1].strength == defence.aura(2),
      "posts=" .. #posts)
    ctx.check("2 manning turns on restock requests", #armory.offer(a, c).demands > 0)
    local rifle_demand
    for _, d in ipairs(armory.offer(a, c).demands) do if d.item == "colony-rifle" then rifle_demand = d.count end end
    ctx.check("2 the missing rifles are requested in the tools band", rifle_demand == 2, tostring(rifle_demand))
    armory.put(c, a, "colony-rifle", 2)
    local restocked = true
    for _, d in ipairs(armory.offer(a, c).demands or {}) do if d.item == "colony-rifle" then restocked = false end end
    ctx.check("2 replacing the gear clears that restock row", restocked)

    -- 3. Same damage test, now with the post manned.
    local il1, ol1 = loss_before_after(inside), loss_before_after(outside)
    local expected = 1 - defence.aura(2)
    ctx.check("3 a structure inside the radius takes measurably less damage",
      il1 < ol1 - 0.5, string.format("inside %.3f outside %.3f (expected factor %.2f)", il1, ol1, expected))
    ctx.check("3 the reduction matches the pure aura model",
      math.abs((il1 / ol1) - expected) < 0.06,
      string.format("ratio %.3f vs %.3f", il1 / ol1, expected))

    -- 4. Heal-back stability: no spontaneous healing, no revive of a lethal hit, no enemy healing.
    local stable_hp = inside.health
    local doomed = build("colony-supply-crate", {p.x + 8, p.y + 9})
    if doomed and doomed.valid then doomed.damage(10000, "enemy", "physical", cause, cause) end
    ctx.check("4 a lethal hit still kills inside the aura", not (doomed and doomed.valid))
    local enemy = s.create_entity{name = "big-biter", position = {p.x + 18, p.y + 18}, force = "enemy"}
    if enemy and enemy.valid then enemy.commandable.set_command(STOP) end
    local eh0 = enemy and enemy.valid and enemy.health or 0
    if enemy and enemy.valid then enemy.damage(50, "enemy", "physical", cause, cause) end
    ctx.check("4 an enemy inside the aura is never healed",
      not (enemy and enemy.valid) or enemy.health < eh0,
      tostring(eh0) .. " -> " .. tostring(enemy and enemy.valid and enemy.health))
    ctx.check("4 health never exceeds the prototype maximum", inside.health <= inside.max_health)

    -- 5. A real posted guard on a Watchtower grants the same aura. Man it the way the player does: a rifle in
    --    the stock room, a colonist locked to guard, and a direct assign (no fake workers bookkeeping).
    --    The scripted enemy hits above raised #61 alarms, which shelter every civilian: clear them so this
    --    phase measures the aura path, not civil defence (m1_shelter covers alarms).
    c.alarms, c.alarm_check = {}, nil
    local tower = build("colony-watchtower", {p.x + 45, p.y})
    ctx.check("5 watchtower built outside the armory aura", tower and tower.valid)
    if not (tower and tower.valid) then return ctx.finish() end
    local th = c.huts[tower.unit_number]
    ctx.check("5 the tower is registered as a guard post", th ~= nil and th.job == "guard")
    th.limit = 1
    tower.insert{name = "colony-rifle", count = 1}
    local guard = colony.spawn_colonist(c, {p.x + 42, p.y + 3})
    ctx.check("5 a colonist was spawned for guard duty", guard and guard.valid)
    if guard and guard.valid then
      -- spawn_colonist assigns immediately, before this lock exists, and the armory's restock offers can make
      -- it a hauler. Emulate the player locking an idle colonist; m1_garrison already proves the posting path.
      storage.unit_state[guard.unit_number] = {colony_id = c.id, state = "idle"}
      c.locks[guard.unit_number] = "guard"
      work.assign(c, guard.unit_number)
    end

    local watch = {t = 0, phase = "posts", stable_at = nil, posted_at = nil, checked_stable = nil}
    local function poll()
      watch.t = watch.t + 20
      if not (inside.valid and outside.valid and a_e.valid) then return ctx.finish() end
      if watch.phase == "posts" then
        if not watch.checked_stable then
          watch.checked_stable = true
          ctx.check("4 no runaway healing after 600 ticks", inside.health == stable_hp,
            stable_hp .. " -> " .. inside.health)
        end
        if not watch.probed then
          watch.probed = true
          local g_un = guard and guard.valid and guard.unit_number
          local gst = g_un and storage.unit_state[g_un]
          local def, tools, allowed, workers = th and work.hut_info(th)
          ctx.probe("5 guard diagnostic", function()
            return "guard=" .. tostring(gst and gst.job) .. "/" .. tostring(gst and gst.state)
              .. " lock=" .. tostring(g_un and c.locks[g_un]) .. " valid=" .. tostring(guard and guard.valid)
              .. " allowed=" .. tostring(allowed) .. " workers=" .. tostring(workers)
              .. " tools=" .. tostring(tools) .. " def=" .. tostring(def and def.job)
              .. " nosite=" .. tostring(c.no_site[tower.unit_number] or 0) .. " now=" .. game.tick
          end)
        end
        local workers = th and th.workers and next(th.workers) ~= nil
        if workers then
          watch.posted_at = watch.t
          ctx.check("5 the tower has a real posted guard", true, "at poll " .. watch.t)
          local all = armory.posts(c)
          local tower_post = false
          for _, post in ipairs(all) do if post.key == tower.unit_number then tower_post = true end end
          ctx.check("5 the posted tower joins the same shared post list", tower_post, "posts=" .. #all)
          local tl, ol2 = loss_before_after(tower_site), loss_before_after(far)
          ctx.check("5 the manned tower grants the same structural aura", tl < ol2 - 0.5,
            string.format("tower site %.3f far control %.3f", tl, ol2))
          return ctx.finish()
        elseif watch.t > 3000 then
          ctx.check("5 the tower has a real posted guard", false,
            "no worker after " .. watch.t .. " ticks; rifle=" .. tower.get_item_count("colony-rifle"))
          return ctx.finish()
        end
      end
      ctx.after(20, poll)
    end
    ctx.after(600, poll)
  end,
})
