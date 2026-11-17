-- M3 militia integration spike (#55): the Stage 0 engine facts exercised through the real adapter.
--   * two militia (rifle + pistol) kill a biter inside 600 ticks via script-damage engagements;
--   * weapon wear / ammo spend follows the pure model;
--   * an armoured militia takes measurably less damage than an unarmoured one (scripted heal-back);
--   * a militia death is recorded exactly once through scripts/mortality.lua (colony.fallen +1);
--   * night takes a militia off duty and gives its gear back in the morning, like a guard.
-- Run: TICKS=9000 scripts/headless-spike.sh m3_militia
local core = require("scripts.spike.core")
local scheduler = require("scripts.scheduler")
local colony = require("scripts.colony")
local militia = require("scripts.militia")
local militia_model = require("scripts.model.militia")
local armour = require("scripts.model.armour")

local STOP = {type = defines.command.stop, ticks_to_wait = 4294967295, distraction = defines.distraction.none}

core.register("m3_militia", {
  issue = 55, auto = true, desc = "militia: scripted kill, gear wear/ammo, armour heal-back, single mortality, night duty",
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
      rifle_wear = 0, pistol_ammo = 0, killed_at = nil,
      arm_hp0 = nil, plain_hp0 = nil,
    }

    local function state_of(e) return storage.unit_state[e.unit_number] end

    local function poll()
      watch.t = watch.t + 20
      if not (hall.valid and arm_e.valid) then return ctx.finish() end

      if watch.phase == "fight" then
        watch.start = watch.start or watch.t
        local b = watch.biter
        if b and not b.valid then
          watch.killed_at = watch.t
          ctx.check("1 two militia killed a biter inside 600 ticks", true, "at poll " .. watch.t)
          watch.phase = "wear-wait"   -- end_engagement runs on the strike timer after the kill is observed
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
          -- Equal scripted damage to both; heal-back should make the armoured one lose less. Do NOT reset
          -- health first: a direct health write on 2.1 makes damage() a no-op until the following tick.
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
          -- Death: kill the UNARMOURED militia with a biter cause; mortality must count it exactly once.
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
          return ctx.finish()
        elseif watch.t > 3600 then
          ctx.check("5 the morning re-posts the militia", false, tostring(st and st.state))
          return ctx.finish()
        end
      end
      ctx.after(20, poll)
    end

    -- Spawn the biter inside both militia's scan+attack range, after their first scan has settled.
    ctx.after(180, function()
      watch.biter = s.create_entity{name = "small-biter", position = {p.x, p.y + 6}, force = "enemy"}
      if watch.biter and watch.biter.valid then watch.biter.commandable.set_command(STOP) end
      ctx.check("1 a biter stands inside both militia's engagement range", watch.biter and watch.biter.valid)
      -- Both militia must actually engage: their normal scan timers are jittered by unit number, so without
      -- this the pistol could kill the biter before the rifle's next scan and the wear assertion would flake.
      for _, un in ipairs({plain_un, arm_un}) do scheduler.after(5, "militia.scan", {un = un}) end
      ctx.after(20, poll)
    end)

    ctx.probe("militia damage model constants", function()
      return "range=" .. militia.RANGE .. " attack=" .. militia.ATTACK_RANGE
        .. " rifle_damage=" .. tostring(select(1, militia_model.outgoing("colony-rifle", "normal")))
    end)
  end,
})
