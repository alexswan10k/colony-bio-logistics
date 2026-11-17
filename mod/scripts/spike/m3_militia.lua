-- M3 militia integration spike (#55): the Stage 0 engine facts exercised through the real adapter.
--   * two militia (rifle + pistol) kill a biter inside 600 ticks via script-damage engagements;
--   * weapon wear / ammo spend follows the pure model;
--   * an armoured militia takes measurably less damage than an unarmoured one (scripted heal-back);
--   * a militia death is recorded exactly once through scripts/mortality.lua (colony.fallen +1);
--   * night takes a militia off duty and gives its gear back in the morning, like a guard;
--   * REVIEW: locking a colonist through the real GUI/lock path creates an armed, scanning militia that
--     kills, cannot strip a manned tower's rifle, is whistle-orderable with clean gear carry, and can be
--     unlocked back to civilian work with its gear returned to the hall.
-- Run: TICKS=9000 scripts/headless-spike.sh m3_militia
local core = require("scripts.spike.core")
local scheduler = require("scripts.scheduler")
local colony = require("scripts.colony")
local work = require("scripts.work")
local command = require("scripts.command")
local cmd_model = require("scripts.model.command")
local militia = require("scripts.militia")
local militia_model = require("scripts.model.militia")
local armour = require("scripts.model.armour")

local STOP = {type = defines.command.stop, ticks_to_wait = 4294967295, distraction = defines.distraction.none}

core.register("m3_militia", {
  issue = 55, auto = true,
  desc = "militia: scripted kill, gear wear/ammo, armour, mortality, night, lock conversion, whistle, unlock",
  usage = "",
  run = function(ctx)
    local s, p = ctx.surface, ctx.position
    ctx.flat_area(90, "grass-1")
    s.always_day, s.freeze_daytime, s.daytime = true, true, 0
    local function build(name, pos)
      return s.create_entity{name = name, position = pos, force = "player", raise_built = true}
    end
    storage.interval_override = 300
    local hall = build("colony-town-hall", {p.x, p.y})
    local c
    for _, col in pairs(storage.colonies) do c = col end
    ctx.check("colony registered", c ~= nil and hall and hall.valid)
    if not c then return ctx.finish() end
    c.accept_migrants = false
    hall.insert{name = "raw-fish", count = 400}

    -- Stock gear. The unarmoured militia is spawned BEFORE armour exists, and only ONE suit of armour is
    -- stocked total: the adapter re-draws gear on every scan, so a second suit would re-arm the plain militia.
    hall.insert{name = "colony-rifle", count = 2}
    hall.insert{name = "pistol", count = 2}
    hall.insert{name = "firearm-magazine", count = 10}
    hall.insert{name = "colony-arrow", count = 20}
    local plain_e = militia.spawn(c, {p.x - 3, p.y}, {weapon = "pistol"})
    hall.insert{name = "heavy-armor", count = 1}
    local arm_e = militia.spawn(c, {p.x + 3, p.y}, {weapon = "colony-rifle", armour = "heavy-armor"})

    ctx.check("two militia spawned", plain_e and plain_e.valid and arm_e and arm_e.valid)
    if not (plain_e and plain_e.valid and arm_e and arm_e.valid) then return ctx.finish() end
    ctx.check("militia uses the dedicated prototype", arm_e.name == "colony-militia"
      and arm_e.is_military_target == true, arm_e.name .. " military=" .. tostring(arm_e.is_military_target))
    ctx.probe("militia ai_settings.allow_destroy_when_commands_fail", function()
      return tostring(arm_e.ai_settings.allow_destroy_when_commands_fail)
    end)
    -- Review finding 4: read the hitscan baseline back from the LIVE prototype, not from the data file.
    -- 2.1 readback: ammo_type.action is an ARRAY of action entries, each with action_delivery.target_effects.
    local function hitscan_damage()
      local proto = prototypes.entity["colony-militia"]
      local ap = proto and proto.attack_parameters
      local action = ap and ap.ammo_type and ap.ammo_type.action
      local a1 = type(action) == "table" and (action[1] or action) or nil
      local delivery = a1 and a1.action_delivery
      local d1 = type(delivery) == "table" and (delivery[1] or delivery) or nil
      local effects = d1 and d1.target_effects
      local e1 = type(effects) == "table" and (effects[1] or effects) or nil
      return e1 and e1.damage
    end
    ctx.probe("[review] live prototype hitscan damage path", function()
      local d = hitscan_damage()
      local ap = prototypes.entity["colony-militia"].attack_parameters
      local action = ap and ap.ammo_type and ap.ammo_type.action
      local a1 = type(action) == "table" and action[1] or nil
      local del = a1 and a1.action_delivery
      local function keys(t)
        if type(t) ~= "table" then return type(t) end
        local out = {}
        for k in pairs(t) do out[#out + 1] = tostring(k) end
        table.sort(out); return table.concat(out, ",")
      end
      return "amount=" .. tostring(d and d.amount) .. " a1=" .. keys(a1) .. " del=" .. keys(del)
        .. " a1type=" .. tostring(type(a1)) .. " deltype=" .. tostring(type(del))
    end)
    local baseline = hitscan_damage()
    ctx.check("[review] native hitscan is a 1-damage baseline (no engine+script double-count)",
      baseline ~= nil and baseline.amount == 1, "amount=" .. tostring(baseline and baseline.amount))
    local plain_un, arm_un = plain_e.unit_number, arm_e.unit_number
    local plain_st, arm_st = storage.unit_state[plain_un], storage.unit_state[arm_un]
    ctx.check("armoured militia holds rifle + heavy armour as pure data",
      arm_st.gear.weapon == "colony-rifle" and arm_st.gear.armour == "heavy-armor",
      tostring(arm_st.gear.weapon) .. "/" .. tostring(arm_st.gear.armour))
    ctx.check("unarmoured militia holds pistol and no armour",
      plain_st.gear.weapon == "pistol" and plain_st.gear.armour == nil,
      tostring(plain_st.gear.weapon) .. "/" .. tostring(plain_st.gear.armour))
    ctx.check("gear was drawn out of hall stock (no duplication)",
      hall.get_item_count("colony-rifle") == 1 and hall.get_item_count("pistol") == 1
        and hall.get_item_count("heavy-armor") == 0,
      "rifles=" .. hall.get_item_count("colony-rifle") .. " pistols=" .. hall.get_item_count("pistol"))

    -- A stationary enemy is the cause for the scripted armour / death hits. Keep it far from the fight.
    local cause = s.create_entity{name = "small-biter", position = {p.x + 40, p.y + 40}, force = "enemy"}
    if cause and cause.valid then cause.commandable.set_command(STOP) end

    local fallen_before = c.fallen or 0
    local watch = {
      phase = "fight", t = 0, start = nil, biter = nil,
      killed_at = nil, arm_hp0 = nil, plain_hp0 = nil,
      tower = nil, lock_un = nil, lock_biter = nil, lock_killed_at = nil,
      hall_weapon_before = nil, lock_weapon = nil, lock_phase_start = nil,
    }

    local function state_of(e) return storage.unit_state[e.unit_number] end
    local function find_by_lock(name, lock)
      for un, e in pairs(c.colonists) do
        if e.valid and e.name == name and c.locks and c.locks[un] == lock then return un, e end
      end
    end

    local function poll()
      watch.t = watch.t + 20
      if not hall.valid then return ctx.finish() end

      if watch.phase == "fight" then
        watch.start = watch.start or watch.t
        local b = watch.biter
        if b and not b.valid then
          watch.killed_at = watch.t
          ctx.check("1 two militia killed a biter inside 600 ticks", true, "at poll " .. watch.t)
          watch.phase = "wear-wait"
        elseif watch.t - watch.start > 600 then
          ctx.check("1 two militia killed a biter inside 600 ticks", false,
            "biter alive at " .. watch.t .. " states=" .. tostring(state_of(arm_e).state)
              .. "/" .. tostring(state_of(plain_e).state))
          return ctx.finish()
        end
      elseif watch.phase == "wear-wait" then
        if watch.t >= (watch.killed_at or 0) + 60 then
          local fresh_arm = storage.unit_state[arm_un]
          ctx.check("2 the rifle wore one engagement step", (fresh_arm.gear.uses or 0) >= 1,
            "wear=" .. tostring(fresh_arm.gear.uses))
          ctx.check("2 the pistol advanced its ammo counter", (plain_st.gear.ammo_count or 0) >= 1,
            "ammo_count=" .. tostring(plain_st.gear.ammo_count))
          watch.arm_hp0, watch.plain_hp0 = arm_e.health, plain_e.health
          arm_e.damage(30, "enemy", "physical", cause, cause)
          plain_e.damage(30, "enemy", "physical", cause, cause)
          watch.phase = "armour-wait"
        end
      elseif watch.phase == "armour-wait" then
        if watch.t >= (watch.killed_at or 0) + 100 then
          local a_loss = watch.arm_hp0 - arm_e.health
          local p_loss = watch.plain_hp0 - plain_e.health
          local expected = armour.mitigation("heavy-armor", "normal")
          ctx.check("3 armoured militia took measurably less damage", a_loss < p_loss,
            string.format("armoured lost %.2f, plain lost %.2f (mitigation %.2f)", a_loss, p_loss, expected))
          plain_e.damage(10000, "enemy", "physical", cause, cause)
          watch.phase = "death-wait"
        end
      elseif watch.phase == "death-wait" then
        local fallen_now = c.fallen or 0
        ctx.check("4 a militia death was recorded exactly once", fallen_now == fallen_before + 1,
          "fallen " .. fallen_before .. " -> " .. fallen_now)
        ctx.check("4 the militia was struck off the roster", c.colonists[plain_un] == nil)
        if cause and cause.valid then cause.destroy() end
        s.freeze_daytime, s.always_day, s.daytime = false, false, 0.50
        watch.phase = "night"
      elseif watch.phase == "night" then
        local st = state_of(arm_e)
        if st and (st.state == "to_bed" or st.state == "sleeping") then
          ctx.check("5 night takes the militia off duty", true, st.state)
          ctx.check("5 gear survives the night", st.gear and st.gear.weapon == "colony-rifle",
            tostring(st and st.gear and st.gear.weapon))
          s.freeze_daytime, s.always_day, s.daytime = true, true, 0
          watch.phase = "morning"
        elseif watch.t > 3000 then
          ctx.check("5 night takes the militia off duty", false, tostring(st and st.state))
          return ctx.finish()
        end
      elseif watch.phase == "morning" then
        local st = state_of(arm_e)
        if st and (st.state == "militia-hold" or st.state == "militia-fight") then
          ctx.check("5 the morning re-posts the militia", true, st.state)
          watch.phase = "lock-setup"   -- continue with the review's real-player-path cases
        elseif watch.t > 3600 then
          ctx.check("5 the morning re-posts the militia", false, tostring(st and st.state))
          return ctx.finish()
        end
      elseif watch.phase == "lock-setup" then
        -- The spawn-created militia has served its purpose; remove it so the lock-created unit is the only
        -- possible attacker in the engagement below (otherwise it could kill the biter first).
        if arm_e and arm_e.valid then arm_e.destroy() end
        -- A MANNED tower holds the only rifle outside the hall. A converted militia must not strip it.
        watch.tower = build("colony-watchtower", {p.x + 16, p.y})
        watch.tower.insert{name = "colony-rifle", count = 1}
        ctx.check("[review] manned tower holds one rifle", watch.tower.get_item_count("colony-rifle") == 1)
        -- A fresh civilian, locked to militia through the same lock field the house panel writes. Call
        -- work.assign directly (what a GUI-driven reassign does for an available unit): a reassign sweep can
        -- re-visit the newly-created unit and mask an uninitialised convert, which is exactly the mutant we
        -- want this case to catch. The civilian may be to_tower from the guard slot — militia conversion
        -- must still initialise it into an armed, scanning state.
        local civ = colony.spawn_colonist(c, {p.x - 8, p.y - 4})
        ctx.check("[review] a civilian colonist was spawned", civ and civ.valid)
        if not (civ and civ.valid) then return ctx.finish() end
        local civ_un = civ.unit_number
        c.locks = c.locks or {}
        c.locks[civ_un] = "militia"
        work.assign(c, civ_un)
        watch.lock_phase_start, watch.phase = watch.t, "lock-check"
      elseif watch.phase == "lock-check" then
        local lun, le = find_by_lock("colony-militia", "militia")
        if lun then
          watch.lock_un, watch.lock_weapon = lun, nil
          local st = storage.unit_state[lun]
          ctx.check("[review] locking a colonist creates a REAL militia (convert path)", le and le.valid,
            "un=" .. tostring(lun))
          ctx.check("[review] the converted militia is armed and on duty",
            st and st.job == "militia" and (st.state == "militia-hold" or st.state == "militia-fight")
              and st.gear and st.gear.weapon ~= nil,
            "job=" .. tostring(st and st.job) .. " state=" .. tostring(st and st.state)
              .. " weapon=" .. tostring(st and st.gear and st.gear.weapon))
          ctx.check("[review] militia did NOT strip the manned tower's rifle",
            watch.tower.valid and watch.tower.get_item_count("colony-rifle") == 1,
            "tower rifles=" .. tostring(watch.tower.valid and watch.tower.get_item_count("colony-rifle")))
          watch.lock_weapon = st.gear.weapon
          -- Man the tower only AFTER conversion: the rifle is physically inside it either way, and now no
          -- guard slot can compete with the militia lock during the assignment being tested.
          local th = c.huts and c.huts[watch.tower.unit_number]
          if th then th.limit = 1 end
          -- Force a scan (jitter is unit-number-based) at a biter so we prove it actually fights.
          watch.lock_biter = s.create_entity{name = "small-biter", position = {p.x - 8, p.y + 2}, force = "enemy"}
          if watch.lock_biter and watch.lock_biter.valid then watch.lock_biter.commandable.set_command(STOP) end
          scheduler.after(5, "militia.scan", {un = lun})
          watch.lock_killed_at = watch.t
          watch.phase = "lock-fight"
        elseif watch.t > (watch.lock_phase_start or 0) + 1200 then
          ctx.check("[review] locking a colonist creates a REAL militia (convert path)", false, "not converted")
          return ctx.finish()
        end
      elseif watch.phase == "lock-fight" then
        if not (watch.lock_biter and watch.lock_biter.valid) then
          ctx.check("[review] the lock-created militia scans and kills (not inert)", true,
            "at poll " .. watch.t)
          watch.lock_killed_at, watch.phase = watch.t, "lock-engaged-wait"
        elseif watch.t - (watch.lock_killed_at or watch.t) > 600 then
          ctx.check("[review] the lock-created militia scans and kills (not inert)", false,
            "biter alive; state=" .. tostring(storage.unit_state[watch.lock_un] and storage.unit_state[watch.lock_un].state))
          return ctx.finish()
        end
      elseif watch.phase == "lock-engaged-wait" then
        if watch.t >= (watch.lock_killed_at or 0) + 60 then
          local st = storage.unit_state[watch.lock_un] or {}
          local gear = st.gear or {}
          ctx.check("[review] the lock-created militia actually engaged (wear/ammo advanced)",
            (gear.uses or 0) > 0 or (gear.ammo_count or 0) > 0,
            "state=" .. tostring(st.state) .. " weapon=" .. tostring(gear.weapon)
              .. " uses=" .. tostring(gear.uses) .. " ammo=" .. tostring(gear.ammo_count))
          watch.phase = "whistle"
        end
      elseif watch.phase == "whistle" then
        local st = storage.unit_state[watch.lock_un]
        ctx.check("[review] militia is whistle-orderable (name filter admits it)",
          cmd_model.is_colony_unit("colony-militia") and st ~= nil and st.state ~= "commanded")
        storage.command = storage.command or {}
        storage.command.selection = storage.command.selection or {}
        storage.command.selection[1] = {[watch.lock_un] = true}   -- pi 0 is rejected by game.get_player
        local ordered = command.apply(1, cmd_model.ORDERS.MOVE, {position = {x = p.x + 6, y = p.y + 6}})
        local commanded = storage.unit_state[watch.lock_un]
        ctx.check("[review] whistle order accepted the militia", ordered == 1, "ordered=" .. tostring(ordered))
        ctx.check("[review] gear carried into the lease, claim released",
          commanded and commanded.state == "commanded" and commanded.gear and commanded.gear.weapon == watch.lock_weapon
            and commanded.site == nil and storage.command.leased[watch.lock_un] == true,
          "state=" .. tostring(commanded and commanded.state) .. " gear=" .. tostring(commanded and commanded.gear and commanded.gear.weapon)
            .. " site=" .. tostring(commanded and commanded.site) .. " leased=" .. tostring(storage.command.leased[watch.lock_un]))
        command.release_lease(watch.lock_un, true)
        local released = storage.unit_state[watch.lock_un]
        ctx.check("[review] whistle release keeps gear and clears the lease",
          released and released.gear and released.gear.weapon == watch.lock_weapon
            and storage.command.leased[watch.lock_un] == nil,
          "gear=" .. tostring(released and released.gear and released.gear.weapon))
        watch.phase = "unlock-setup"
      elseif watch.phase == "unlock-setup" then
        local st = storage.unit_state[watch.lock_un]
        if st and (st.state == "militia-hold" or st.state == "militia-fight") then
          ctx.check("[review] released militia is re-posted with its gear", st.gear and st.gear.weapon == watch.lock_weapon,
            "state=" .. st.state .. " gear=" .. tostring(st.gear and st.gear.weapon))
          watch.hall_weapon_before = hall.get_item_count(watch.lock_weapon)
          c.locks[watch.lock_un] = "chop"   -- the player changes their mind
          colony.reassign_workforce(c)
          watch.lock_phase_start, watch.phase = watch.t, "unlock-check"
        end
      elseif watch.phase == "unlock-check" then
        local un, e = find_by_lock("colony-colonist", "chop")
        if un then
          ctx.check("[review] unlocking converts the militia back to a civilian", e and e.valid,
            "un=" .. tostring(un))
          ctx.check("[review] job is no longer sticky (lock chop really took effect)",
            storage.unit_state[un] and storage.unit_state[un].job ~= "militia",
            "job=" .. tostring(storage.unit_state[un] and storage.unit_state[un].job))
          ctx.check("[review] gear returned to the hall on demobilisation",
            hall.get_item_count(watch.lock_weapon) == (watch.hall_weapon_before or 0) + 1,
            watch.lock_weapon .. " " .. tostring(watch.hall_weapon_before) .. " -> "
              .. tostring(hall.get_item_count(watch.lock_weapon)))
          return ctx.finish()
        end
        if watch.t > (watch.lock_phase_start or 0) + 1200 then
          ctx.check("[review] unlocking converts the militia back to a civilian", false, "not demobilised")
          return ctx.finish()
        end
      end
      ctx.after(20, poll)
    end

    -- Spawn the first biter inside both spawn-created militia's scan+attack range.
    ctx.after(180, function()
      watch.biter = s.create_entity{name = "small-biter", position = {p.x, p.y + 6}, force = "enemy"}
      if watch.biter and watch.biter.valid then watch.biter.commandable.set_command(STOP) end
      ctx.check("1 a biter stands inside both militia's engagement range", watch.biter and watch.biter.valid)
      for _, un in ipairs({plain_un, arm_un}) do scheduler.after(5, "militia.scan", {un = un}) end
      ctx.after(20, poll)
    end)

    ctx.probe("militia damage model constants", function()
      return "range=" .. militia.RANGE .. " attack=" .. militia.ATTACK_RANGE
        .. " rifle_damage=" .. tostring(select(1, militia_model.outgoing("colony-rifle", "normal")))
    end)
  end,
})
